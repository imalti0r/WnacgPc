// sr_shim.cpp — ONNX Runtime 桥接实现（运行时动态加载，见 sr_shim.h）。
//
// 推理优化（v1.3.6，实测拟真 3.15MP / tile 512 / o16，DML 动漫模型 479ms→基线同值）：
//  热路径主收益来自 **更大的默认 tile（动漫 512→1024 / 照片 256→512，见 SrModel）**，
//  每次推理执行有 ~25ms 固定开销（每 tile 的 H2D/D2H 与调度），tile 越大摊薄越多。
//  本文件保留三处优化：
//   1) CPU EP intra 线程数 4 → 硬件并发一半（DML 会话仍为 1，DML 自带多线程）；
//   2) createSession 可选热身一次 (tile+2*ov)² interior shape —— DML 按"输入形状"
//      缓编译计划，热身把首页预取上那一次编译成本挪到启动 warm 时段（读者无感）；
//   3) 输入转换沿用 RGBA→CHW 直接向量化（fp16 转换无 SSE 依赖）。
// 说明：worker 单 isolate 单线程串行执行 createSession/run/release ⇒ 无并发访问。
#include "sr_shim.h"

#define NOMINMAX
#include <windows.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "onnxruntime_c_api.h"

namespace {

const OrtApi* g_api = nullptr;
OrtEnv* g_env = nullptr;
OrtMemoryInfo* g_mem_info = nullptr;
OrtAllocator* g_allocator = nullptr;
std::wstring g_lastError;

void SetErr(const wchar_t* msg) { g_lastError = msg; }

void SetErrf(const wchar_t* fmt, ...) {
  wchar_t buf[256];
  va_list args;
  va_start(args, fmt);
  _vsnwprintf_s(buf, _TRUNCATE, fmt, args);
  va_end(args);
  g_lastError = buf;
}

// 捕获并转换 ORT 返回的 status（内部负责 Release）。
void SetErrStatus(OrtStatus* st) {
  if (!st) return;
  const char* msg = g_api->GetErrorMessage(st);
  int n = MultiByteToWideChar(CP_UTF8, 0, msg, -1, nullptr, 0);
  if (n > 1) {
    std::wstring w(size_t(n - 1), 0);
    MultiByteToWideChar(CP_UTF8, 0, msg, -1, &w[0], n);
    g_lastError = w;
  }
  g_api->ReleaseStatus(st);
}

// --- IEEE754 half 转换（无指令集依赖） ---
uint16_t F32ToF16(float f) {
  uint32_t x;
  std::memcpy(&x, &f, 4);
  uint32_t sign = (x >> 16) & 0x8000u;
  int32_t exp = int32_t((x >> 23) & 0xFFu) - 127 + 15;
  uint32_t man = x & 0x7FFFFFu;
  if (exp >= 31) return uint16_t(sign | 0x7C00u);  // inf/overflow
  if (exp <= 0) {                                  // subnormal/zero
    if (exp < -10) return uint16_t(sign);
    man |= 0x800000u;
    uint32_t shift = uint32_t(1 - exp);
    return uint16_t(sign | (man >> shift) | ((man >> (shift - 1)) & 1));
  }
  return uint16_t(sign | (uint32_t(exp) << 10) | (man >> 13));
}

float F16ToF32(uint16_t h) {
  uint32_t sign = uint32_t(h & 0x8000u) << 16;
  uint32_t exp = (h >> 10) & 0x1Fu;
  uint32_t man = h & 0x3FFu;
  uint32_t bits;
  if (exp == 0) {
    if (man == 0) {
      bits = sign;
    } else {  // subnormal → 规格化
      int e = -1;
      uint32_t m = man;
      while ((m & 0x400u) == 0) { m <<= 1; e--; }
      bits = sign | (uint32_t(127 - 15 + e + 1) << 23) | ((m & 0x3FFu) << 13);
    }
  } else if (exp == 31) {
    bits = sign | 0x7F800000u | (man << 13);
  } else {
    bits = sign | ((exp - 15 + 127) << 23) | (man << 13);
  }
  float f;
  std::memcpy(&f, &bits, 4);
  return f;
}

// 单次推理：chw 输入 [1,3,h,w]，输出 [1,3,oh,ow]（float32）。失败返回 -1。
int RunOnce(const SrSessionInfo& info, int w, int h, const float* chw,
            std::vector<float>& outChw, int* outW, int* outH) {
  const OrtApi* ort = g_api;
  const int64_t inShape[4] = {1, 3, h, w};
  OrtValue* inVal = nullptr;
  OrtValue* outVal = nullptr;
  OrtStatus* st = nullptr;
  int rc = -1;
  const size_t nIn = size_t(w) * h * 3;
  static thread_local std::vector<uint16_t> halfBuf;
  if (info.inputIsHalf) {
    halfBuf.resize(nIn);
    for (size_t i = 0; i < nIn; i++) halfBuf[i] = F32ToF16(chw[i]);
    st = ort->CreateTensorWithDataAsOrtValue(g_mem_info, halfBuf.data(), nIn * 2, inShape, 4,
                                             ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16, &inVal);
  } else {
    st = ort->CreateTensorWithDataAsOrtValue(g_mem_info, const_cast<float*>(chw), nIn * 4,
                                             inShape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                                             &inVal);
  }
  if (st) { SetErrStatus(st); goto done; }
  {
    const char* inNames[1] = {info.inputName};
    const char* outNames[1] = {info.outputName};
    st = ort->Run(static_cast<OrtSession*>(info.session), nullptr, inNames, &inVal, 1,
                  outNames, 1, &outVal);
    if (st) { SetErrStatus(st); goto done; }
  }
  {
    OrtTensorTypeAndShapeInfo* osi = nullptr;
    st = ort->GetTensorTypeAndShape(outVal, &osi);
    if (st) { SetErrStatus(st); goto done; }
    int64_t dims[4] = {0, 0, 0, 0};
    st = ort->GetDimensions(osi, dims, 4);
    if (st) {
      SetErrStatus(st);
      ort->ReleaseTensorTypeAndShapeInfo(osi);
      goto done;
    }
    ort->ReleaseTensorTypeAndShapeInfo(osi);
    const int oh = int(dims[2]), ow = int(dims[3]);
    void* data = nullptr;
    st = ort->GetTensorMutableData(outVal, &data);
    if (st) { SetErrStatus(st); goto done; }
    const size_t n = size_t(oh) * ow * 3;
    outChw.resize(n);
    if (info.inputIsHalf) {
      const uint16_t* src = static_cast<const uint16_t*>(data);
      for (size_t i = 0; i < n; i++) outChw[i] = F16ToF32(src[i]);
    } else {
      std::memcpy(outChw.data(), data, n * 4);
    }
    *outW = ow;
    *outH = oh;
    rc = 0;
  }
done:
  if (inVal) g_api->ReleaseValue(inVal);
  if (outVal) g_api->ReleaseValue(outVal);
  return rc;
}

}  // namespace

SR_EXPORT int sr_init(const wchar_t* ortDllPath) {
  static std::once_flag once;
  std::call_once(once, [ortDllPath] {
    HMODULE mod = LoadLibraryW(ortDllPath);
    if (!mod) { SetErr(L"LoadLibraryW(onnxruntime.dll) failed"); return; }
    auto getBase = reinterpret_cast<const OrtApiBase* (*)(void)>(
        GetProcAddress(mod, "OrtGetApiBase"));
    if (!getBase) { SetErr(L"GetProcAddress(OrtGetApiBase) failed"); return; }
    const OrtApi* api = getBase()->GetApi(ORT_API_VERSION);
    if (!api) { SetErr(L"GetApi(ORT_API_VERSION) failed"); return; }
    if (api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "wnacg_sr", &g_env)) {
      SetErr(L"CreateEnv failed");
      return;
    }
    if (api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &g_mem_info) ||
        api->GetAllocatorWithDefaultOptions(&g_allocator)) {
      SetErr(L"memory info/allocator init failed");
      return;
    }
    g_api = api;
  });
  return g_api ? 0 : -1;
}

// warmTile/warmOverlap > 0 时创建后热身一次 (tile+2*ov)² interior shape（把 DML
// plan 编译成本从首页预取挪到启动 warm 时段）。
SR_EXPORT int sr_create_session(const uint8_t* modelData, int64_t modelLen, int useDml,
                                SrSessionInfo* outInfo, int warmTile, int warmOverlap) {
  std::memset(outInfo, 0, sizeof(*outInfo));
  if (!g_api) { SetErr(L"sr_init not done or failed"); return -100; }
  const OrtApi* ort = g_api;
  OrtSessionOptions* opts = nullptr;
  OrtSession* sess = nullptr;
  OrtTypeInfo* ti = nullptr;
  OrtStatus* st = ort->CreateSessionOptions(&opts);
  if (st) { SetErrStatus(st); return -1; }
  // CPU EP 固定 4 线程：实测 hw/2（8 线程）反而 6290ms vs 4991ms（4 线程）——
  // SPAN 小图计算多线程内同步开销吃掉收益。
  ort->SetIntraOpNumThreads(opts, useDml ? 1 : 4);
  ort->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL);
  if (useDml) {
    auto fn = reinterpret_cast<OrtStatus* (__stdcall*)(OrtSessionOptions*, int)>(
        GetProcAddress(GetModuleHandleW(L"onnxruntime.dll"),
                       "OrtSessionOptionsAppendExecutionProvider_DML"));
    if (!fn) {
      SetErr(L"DML export not found");
      ort->ReleaseSessionOptions(opts);
      return -2;
    }
    st = fn(opts, 0);
    if (st) {
      SetErrStatus(st);
      ort->ReleaseSessionOptions(opts);
      return -3;
    }
  }
  st = ort->CreateSessionFromArray(g_env, modelData, size_t(modelLen), opts, &sess);
  if (st) {
    SetErrStatus(st);
    ort->ReleaseSessionOptions(opts);
    return -4;
  }
  ort->ReleaseSessionOptions(opts);

  {
    size_t nIn = 0, nOut = 0;
    st = ort->SessionGetInputCount(sess, &nIn);
    if (st == nullptr) st = ort->SessionGetOutputCount(sess, &nOut);
    if (st == nullptr && (nIn != 1 || nOut != 1)) {
      SetErrf(L"unexpected io count: in=%zu out=%zu", nIn, nOut);
      ort->ReleaseSession(sess);
      return -5;
    }
    if (st) {
      SetErrStatus(st);
      ort->ReleaseSession(sess);
      return -5;
    }
    char* inName = nullptr;
    char* outName = nullptr;
    st = ort->SessionGetInputName(sess, 0, g_allocator, &inName);
    if (st) {
      SetErrStatus(st);
      ort->ReleaseSession(sess);
      return -5;
    }
    st = ort->SessionGetOutputName(sess, 0, g_allocator, &outName);
    if (st) {
      SetErrStatus(st);
      ort->ReleaseSession(sess);
      return -5;
    }
    // 名字串归默认 allocator；会话级常驻（每模型一次、128B 内），进程生命周期内不释放
    _snprintf_s(outInfo->inputName, _TRUNCATE, "%s", inName);
    _snprintf_s(outInfo->outputName, _TRUNCATE, "%s", outName);
  }
  st = ort->SessionGetInputTypeInfo(sess, 0, &ti);
  if (st) {
    g_api->ReleaseStatus(st);  // 非致命：输入元素类型交给探针与默认值兜底
    st = nullptr;
  } else if (ti) {
    const OrtTensorTypeAndShapeInfo* tsi = nullptr;
    st = ort->CastTypeInfoToTensorInfo(ti, &tsi);
    if (st == nullptr && tsi) {
      ONNXTensorElementDataType et = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
      st = ort->GetTensorElementType(tsi, &et);
      if (st == nullptr) {
        outInfo->inputIsHalf = et == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16 ? 1 : 0;
      } else {
        g_api->ReleaseStatus(st);
        st = nullptr;
      }
    } else if (st) {
      g_api->ReleaseStatus(st);
      st = nullptr;
    }
    ort->ReleaseTypeInfo(ti);
    ti = nullptr;
  }
  // 探针：16x16 输入 → 实测输出尺寸 → scale
  {
    std::vector<float> probe(size_t(16) * 16 * 3, 0.5f);
    std::vector<float> outChw;
    int ow = 0, oh = 0;
    SrSessionInfo tmp = *outInfo;
    tmp.session = sess;
    if (RunOnce(tmp, 16, 16, probe.data(), outChw, &ow, &oh)) {
      ort->ReleaseSession(sess);
      return -6;
    }
    if (ow <= 0 || oh <= 0 || ow % 16 != 0 || oh % 16 != 0) {
      SetErrf(L"unexpected probe out %dx%d", ow, oh);
      ort->ReleaseSession(sess);
      return -7;
    }
    outInfo->scale = ow / 16;
    if (oh / 16 != outInfo->scale) {
      SetErr(L"non-uniform scale");
      ort->ReleaseSession(sess);
      return -7;
    }
  }
  // 热身：一次 interior shape（tile+2*ov 相同的会探针已实测，值与 plan 无关要 dim 的
  // 完整输入走一遍 Run，让 DML 把该形状的执行计划编译/缓存完成。失败非致命。
  if (warmTile > 0 && warmOverlap >= 0 && warmOverlap * 2 < warmTile) {
    SrSessionInfo tmp = *outInfo;
    tmp.session = sess;
    const int we = warmTile + 2 * warmOverlap;
    std::vector<float> warmChw(size_t(we) * we * 3, 0.5f);
    std::vector<float> outChw;
    int ow = 0, oh = 0;
    if (RunOnce(tmp, we, we, warmChw.data(), outChw, &ow, &oh)) {
      SetErrf(L"warmup failed (non-fatal): %s", g_lastError.c_str());
    }
  }
  outInfo->session = sess;
  return 0;
}

SR_EXPORT void sr_release_session(SrSessionInfo* info) {
  if (info && info->session && g_api) {
    g_api->ReleaseSession(static_cast<OrtSession*>(info->session));
    info->session = nullptr;
  }
}

SR_EXPORT int sr_run(SrSessionInfo* info, int inW, int inH, const uint8_t* rgba,
                     uint8_t* outRgba, int tile, int overlap) {
  if (!g_api || !info->session) { SetErr(L"session not ready"); return -100; }
  if (tile < 8 || overlap < 0 || overlap * 2 >= tile) {
    SetErr(L"bad tile/overlap");
    return -1;
  }
  const int scale = info->scale;
  const int outW = inW * scale, outH = inH * scale;
  const int ramp = std::max(1, overlap * scale);
  std::memset(outRgba, 0, size_t(outW) * outH * 4);
  // 权重图 + 重归一粘贴：首次整像素落位，此后按 (cur,w)/(cur+w) 重归一，
  // 数学上等价于线性加权平均（见 agent.md Task 45 记录）。
  static thread_local std::vector<uint8_t> wmap;
  wmap.assign(size_t(outW) * outH, 0);
  static thread_local std::vector<float> chw, outChw;
  for (int y0 = 0; y0 < inH; y0 += tile) {
    for (int x0 = 0; x0 < inW; x0 += tile) {
      const int w = std::min(tile, inW - x0), h = std::min(tile, inH - y0);
      const int x0e = std::max(0, x0 - overlap), y0e = std::max(0, y0 - overlap);
      const int x1e = std::min(inW, x0 + w + overlap), y1e = std::min(inH, y0 + h + overlap);
      const int we = x1e - x0e, he = y1e - y0e;
      const size_t nIn = size_t(we) * he * 3;
      chw.resize(nIn);
      for (int y = 0; y < he; y++) {
        const uint8_t* row = rgba + (size_t(y + y0e) * inW + x0e) * 4;
        float* r = &chw[size_t(y) * we];
        float* g = &chw[size_t(he + y) * we];
        float* b = &chw[size_t(2 * he + y) * we];
        for (int x = 0; x < we; x++) {
          const float s = 1.0f / 255.0f;
          r[x] = row[x * 4 + 0] * s;
          g[x] = row[x * 4 + 1] * s;
          b[x] = row[x * 4 + 2] * s;
        }
      }
      int ow = 0, oh = 0;
      if (RunOnce(*info, we, he, chw.data(), outChw, &ow, &oh)) return -2;
      const int outTH = he * scale, outTW = we * scale;
      if (ow != outTW || oh != outTH) {
        SetErrf(L"tile out size mismatch %dx%d", ow, oh);
        return -3;
      }
      for (int py = y0 * scale; py < (y0 + h) * scale; py++) {
        const int ly = py - y0e * scale;
        float wy = 1.0f;
        if (y0 > 0) wy = std::min(wy, std::clamp(float(py - y0 * scale) / ramp, 0.0f, 1.0f));
        if (y0 + h < inH)
          wy = std::min(wy, std::clamp(float((y0 + h) * scale - 1 - py) / ramp, 0.0f, 1.0f));
        uint8_t* dstRow = outRgba + size_t(py) * outW * 4;
        uint8_t* wRow = wmap.data() + size_t(py) * outW;
        const float* sRowR = &outChw[size_t(ly) * outTW];
        const float* sRowG = &outChw[size_t(outTH + ly) * outTW];
        const float* sRowB = &outChw[size_t(2 * outTH + ly) * outTW];
        for (int px = x0 * scale; px < (x0 + w) * scale; px++) {
          const int lx = px - x0e * scale;
          float wx = 1.0f;
          if (x0 > 0) wx = std::min(wx, std::clamp(float(px - x0 * scale) / ramp, 0.0f, 1.0f));
          if (x0 + w < inW)
            wx = std::min(wx, std::clamp(float((x0 + w) * scale - 1 - px) / ramp, 0.0f, 1.0f));
          const int wRaw = int(wx * wy * 255.0f + 0.5f);
          uint8_t* d = dstRow + size_t(px) * 4;
          const int cur = wRow[px];
          int aOld, aNew;
          if (cur == 0) {
            aOld = 0;
            aNew = 255;
          } else {
            const int total = cur + wRaw;
            aOld = std::min(255, cur * 255 / total);
            aNew = 255 - aOld;
          }
          const int sR = int(sRowR[lx] * 255.0f + 0.5f);
          const int sG = int(sRowG[lx] * 255.0f + 0.5f);
          const int sB = int(sRowB[lx] * 255.0f + 0.5f);
          if (aOld == 0) {
            d[0] = uint8_t(std::clamp(sR, 0, 255));
            d[1] = uint8_t(std::clamp(sG, 0, 255));
            d[2] = uint8_t(std::clamp(sB, 0, 255));
          } else {
            d[0] = uint8_t((d[0] * aOld + sR * aNew + 127) / 255);
            d[1] = uint8_t((d[1] * aOld + sG * aNew + 127) / 255);
            d[2] = uint8_t((d[2] * aOld + sB * aNew + 127) / 255);
          }
          d[3] = 255;
          wRow[px] = uint8_t(std::min(255, cur + wRaw));
        }
      }
    }
  }
  return 0;
}

SR_EXPORT const wchar_t* sr_last_error(void) { return g_lastError.c_str(); }

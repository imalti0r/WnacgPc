// sr_shim.h — 阅读器神经超分（ONNX）桥接层。
// 以运行时 LoadLibrary 方式加载 onnxruntime.dll（DirectML 版），
// 导出一组扁平 C 接口供 Dart dart:ffi 调用，避免在 Dart 侧还原 OrtApi 结构体布局。
#pragma once

#include <stdint.h>

#if defined(_WIN32)
#define SR_EXPORT extern "C" __declspec(dllexport)
#else
#define SR_EXPORT extern "C" __attribute__((visibility("default")))
#endif

struct SrSessionInfo {
  void* session;      // OrtSession*
  int inputIsHalf;    // 1: 模型输入输出为 float16；0: float32
  int scale;          // 输出边长 / 输入边长（由 16x16 探针实测）
  char inputName[64];
  char outputName[64];
};

// 加载 onnxruntime.dll 并初始化全局 env/allocator。成功返回 0。
SR_EXPORT int sr_init(const wchar_t* ortDllPath);

// 由模型字节创建会话。useDml!=0 时追加 DirectML EP(设备0)，失败由调用方改走 CPU 重试。
// 成功返回 0 并填充 outInfo（含实测 scale 与输入元素类型）。
SR_EXPORT int sr_create_session(const uint8_t* modelData, int64_t modelLen, int useDml,
                                SrSessionInfo* outInfo);

SR_EXPORT void sr_release_session(SrSessionInfo* info);

// 对整张 RGBA8 图执行内部分块推理。rgba: inW*inH*4；outRgba: inW*scale*inH*scale*4（调用方分配）。
// tile/overlap 为输入像素粒度（建议 tile>=2*overlap）。同步阻塞，返回 0 表示成功。
SR_EXPORT int sr_run(SrSessionInfo* info, int inW, int inH, const uint8_t* rgba,
                     uint8_t* outRgba, int tile, int overlap);

// 最近一次错误的 UTF-16 文本（线程内有效，调用方只读）。
SR_EXPORT const wchar_t* sr_last_error(void);

#version 320 es
#extension GL_GOOGLE_include_directive : enable
precision highp float;
precision highp sampler2D;
// 照片超分单 pass：Lanczos3（6×6 可分离 sinc 核）重采样 + 噪点门控 RCAS 锐化。
// 与 FSR（动漫向 EASU 逆梯度加权）不同：真实照片富含连续渐变与噪声纹理，
// 逆梯度加权易把噪声/胶片颗粒抹成水彩块；Lanczos3 是经典照片放大核，
// 完整保留高频细节，锐化用 luma 差门控避免放大平坦区的压缩噪声。
#include <flutter/runtime_effect.glsl>

uniform sampler2D uTex;
uniform vec2 uSrcSize;
uniform vec2 uDstSize;
uniform float uSharp;     // 锐化强度 0..1
uniform float uNoiseGate; // 噪点门限（luma 0..0.12），亮度波动低于它的区域不做锐化

out vec4 fragColor;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 srcTap(vec2 px) {
  vec2 p = clamp(px, vec2(0.0), uSrcSize - vec2(1.0));
  return texture(uTex, (p + 0.5) / uSrcSize).rgb;
}

float sinc(float x) {
  if (abs(x) < 1e-4) return 1.0;
  float px = 3.141592653589793 * x;
  return sin(px) / px;
}

// Lanczos3 核：sinc(x)*sinc(x/3)，|x|>=3 时为 0（半径 3 → 每轴 6 tap）
float lanczos3(float x) {
  x = abs(x);
  if (x >= 3.0) return 0.0;
  return sinc(x) * sinc(x / 3.0);
}

// 6×6 可分离 Lanczos3 重采样：X/Y 权重独立计算后相乘，
// 权重和归一化（配合 srcTap 的 clamp 边缘处理，边缘不塌色）。
vec3 lanczos(vec2 dstPx) {
  vec2 scale = uSrcSize / uDstSize;
  vec2 c = (dstPx + 0.5) * scale - 0.5;
  vec2 ic = floor(c);
  vec2 f = c - ic;
  float wx[6];
  float wy[6];
  float sx = 0.0;
  float sy = 0.0;
  for (int k = 0; k < 6; k++) {
    wx[k] = lanczos3(f.x + 2.0 - float(k));
    wy[k] = lanczos3(f.y + 2.0 - float(k));
    sx += wx[k];
    sy += wy[k];
  }
  vec3 sum = vec3(0.0);
  for (int j = 0; j < 6; j++) {
    for (int k = 0; k < 6; k++) {
      sum += srcTap(ic + vec2(float(k) - 2.0, float(j) - 2.0)) * (wx[k] * wy[j]);
    }
  }
  return sum / (sx * sy);
}

// RCAS 锐化 + 噪点门控：十字邻域 luma 波动低于门限（平坦噪声区）时锐化量衰减到 0，
// 真实边缘/纹理照常增强；逐通道限幅抑制振铃（与 fsr.frag 同策略）。
vec3 rcasCombine(vec3 e, vec3 b, vec3 d, vec3 f, vec3 h) {
  vec3 blur = (b + d + f + h) * 0.25;
  float dl = abs(luma(e) - luma(blur));
  float gate = smoothstep(uNoiseGate, uNoiseGate * 2.0 + 0.01, dl);
  vec3 outC = e + (e - blur) * (uSharp * 2.5 * gate);
  vec3 mn = min(e, min(min(b, d), min(f, h)));
  vec3 mx = max(e, max(max(b, d), max(f, h)));
  return clamp(outC, mn - vec3(0.09), mx + vec3(0.09));
}

void main() {
  vec2 dstPx = FlutterFragCoord().xy;
  vec3 e = lanczos(dstPx);
  vec3 b = lanczos(dstPx - vec2(0.0, 1.0));
  vec3 d = lanczos(dstPx - vec2(1.0, 0.0));
  vec3 f = lanczos(dstPx + vec2(1.0, 0.0));
  vec3 h = lanczos(dstPx + vec2(0.0, 1.0));
  fragColor = vec4(rcasCombine(e, b, d, f, h), 1.0);
}

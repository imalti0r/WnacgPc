#version 320 es
#extension GL_GOOGLE_include_directive : enable
precision highp float;
precision highp sampler2D;
// FSR 1.0 风格超分单 pass：EASU（边缘自适应上采样，逆梯度加权近似）+ RCAS（限幅锐化）。
// 说明：受 Flutter 单 pass 片段着色器限制，EASU 用逆梯度加权的 5 点双线性采样近似，
// RCAS 保留"十字邻域 luma 限幅锐化"的核心逻辑，避免振铃。
#include <flutter/runtime_effect.glsl>

uniform sampler2D uTex;
uniform vec2 uSrcSize;
uniform vec2 uDstSize;
uniform float uSharp; // RCAS 锐化强度 0..1

out vec4 fragColor;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 srcTap(vec2 px) {
  vec2 p = clamp(px, vec2(0.0), uSrcSize - vec2(1.0));
  return texture(uTex, (p + 0.5) / uSrcSize).rgb;
}

vec3 bilinear(vec2 px) {
  vec2 p = px - 0.5;
  vec2 ic = floor(p);
  vec2 fp = p - ic;
  vec3 t00 = srcTap(ic);
  vec3 t10 = srcTap(ic + vec2(1.0, 0.0));
  vec3 t01 = srcTap(ic + vec2(0.0, 1.0));
  vec3 t11 = srcTap(ic + vec2(1.0, 1.0));
  return mix(mix(t00, t10, fp.x), mix(t01, t11, fp.x), fp.y);
}

// EASU 近似：中心 + 四向双线性采样，按各方向梯度取逆权重大小做边缘自适应混合，
// 梯度越小的方向（连续区域）参与越多，梯度越大的方向（跨边缘）参与越少。
vec3 easu(vec2 dstPx) {
  vec2 scale = uSrcSize / uDstSize;
  vec2 c = (dstPx + 0.5) * scale;
  vec2 ox = vec2(scale.x, 0.0);
  vec2 oy = vec2(0.0, scale.y);
  vec3 cc = bilinear(c);
  vec3 w = bilinear(c - ox);
  vec3 e = bilinear(c + ox);
  vec3 n = bilinear(c - oy);
  vec3 s = bilinear(c + oy);
  float lc = luma(cc);
  float wW = 1.0 / (0.03 + abs(luma(w) - lc));
  float wE = 1.0 / (0.03 + abs(luma(e) - lc));
  float wN = 1.0 / (0.03 + abs(luma(n) - lc));
  float wS = 1.0 / (0.03 + abs(luma(s) - lc));
  return (cc * 4.0 + w * wW + e * wE + n * wN + s * wS) / (4.0 + wW + wE + wN + wS);
}

vec3 rcasCombine(vec3 e, vec3 b, vec3 d, vec3 f, vec3 h) {
  vec3 blur = (b + d + f + h) * 0.25;
  vec3 outC = e + (e - blur) * (uSharp * 2.5);
  // 限幅到十字邻域逐通道范围外留少量余量，抑制锐化振铃（真 FSR RCAS 的
  // hitMin/hitMax 即逐通道）。不能用亮度标量钳制三通道：饱和色的极端
  // 通道会被压向亮度值（蓝天的 B 通道被压灰等），造成整体色彩失真。
  vec3 mn = min(e, min(min(b, d), min(f, h)));
  vec3 mx = max(e, max(max(b, d), max(f, h)));
  return clamp(outC, mn - vec3(0.09), mx + vec3(0.09));
}

void main() {
  vec2 dstPx = FlutterFragCoord().xy;
  vec2 st = vec2(1.0);
  vec3 e = easu(dstPx);
  vec3 b = easu(dstPx - vec2(0.0, st.y));
  vec3 d = easu(dstPx - vec2(st.x, 0.0));
  vec3 f = easu(dstPx + vec2(st.x, 0.0));
  vec3 h = easu(dstPx + vec2(0.0, st.y));
  fragColor = vec4(rcasCombine(e, b, d, f, h), 1.0);
}

#version 320 es
#extension GL_GOOGLE_include_directive : enable
precision highp float;
precision highp sampler2D;
// Anime4K 风格线条增强单 pass：Sobel 边缘检测 + 高频增强 + 深色线条加深变细。
// 说明：Anime4K v4 的 Restore/Upscale 为 CNN 权重生成的多 pass 管线，无法在
// Flutter 单 pass 片段着色器内完整复刻；本 shader 实现其视觉目标（锐利干净的
// 动漫线条）：线条处锐化更强、深线略微加深，参数（强度/边缘阈值）可调。
#include <flutter/runtime_effect.glsl>

uniform sampler2D uTex;
uniform vec2 uSrcSize; // 与 uDstSize 相同（1:1 处理 pass）
uniform vec2 uDstSize;
uniform float uStrength; // 强度 0..1
uniform float uEdge;     // 边缘阈值 0..1

out vec4 fragColor;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

void main() {
  vec2 st = 1.0 / uDstSize;
  vec2 uv = FlutterFragCoord().xy / uDstSize;
  vec3 c = texture(uTex, uv).rgb;
  vec3 n = texture(uTex, uv - vec2(0.0, st.y)).rgb;
  vec3 s = texture(uTex, uv + vec2(0.0, st.y)).rgb;
  vec3 w = texture(uTex, uv - vec2(st.x, 0.0)).rgb;
  vec3 e = texture(uTex, uv + vec2(st.x, 0.0)).rgb;
  vec3 nw = texture(uTex, uv - st).rgb;
  vec3 ne = texture(uTex, uv + vec2(st.x, -st.y)).rgb;
  vec3 sw = texture(uTex, uv + vec2(-st.x, st.y)).rgb;
  vec3 se = texture(uTex, uv + st).rgb;

  // Sobel 边缘强度（luma）
  float sx = luma(nw) + 2.0 * luma(w) + luma(sw) - luma(ne) - 2.0 * luma(e) - luma(se);
  float sy = luma(nw) + 2.0 * luma(n) + luma(ne) - luma(sw) - 2.0 * luma(s) - luma(se);
  float edge = length(vec2(sx, sy));
  float lineMask = smoothstep(uEdge, uEdge + 0.3, edge);

  // 高频增强：线条处权重更高
  vec3 blur = (n + s + w + e + nw + ne + sw + se) * 0.125;
  vec3 outC = c + (c - blur) * (uStrength * 1.6 * (0.4 + lineMask));

  // 深线加深（变细观感）：中心比十字邻域均值更暗时略微压暗
  float nbAvg = (luma(n) + luma(s) + luma(w) + luma(e)) * 0.25;
  float darkBias = clamp((nbAvg - luma(c)) * 2.5, 0.0, 1.0) * lineMask;
  outC = mix(outC, outC * (1.0 - 0.22 * uStrength), darkBias);

  fragColor = vec4(clamp(outC, 0.0, 1.0), 1.0);
}

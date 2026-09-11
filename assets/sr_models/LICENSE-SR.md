# 神经超分模型与运行时许可说明

本目录包含阅读器「神经超分」功能随安装包分发的 ONNX 模型与第三方许可文件。
应用本体（WNACG）代码与模型文件的分发/使用方式如下。

## 文件清单

| 文件 | 用途 | 来源 | 许可 |
| --- | --- | --- | --- |
| `2x_AnimeJaNai_HD_V3.1_Balanced.onnx` | 漫画/动漫内容 2x 超分（SPAN 架构，fp16） | the-database/mpv-upscale-2x_animejanai（AnimeJaNai V3.1 HD Balanced） | CC BY-NC-SA 4.0（全文见 `CC-BY-NC-SA-4.0.txt`） |
| `realesr-general-x4v3.onnx` | 写真/照片内容 4x 超分（SRVGGNetCompact，fp32） | xinntao/Real-ESRGAN 官方权重 realesr-general-x4v3（CoderViking/realesr-general-x4v3-onnx 格式转换） | BSD-3-Clause（全文见 `LICENSE-RealESRGAN-BSD3.txt`） |

推理运行时 `onnxruntime.dll`（随安装包置于主程序目录）来自
Microsoft.ML.OnnxRuntime.DirectML（nuget，v1.20.1，win-x64 native），
MIT 许可：https://github.com/microsoft/onnxruntime/blob/main/LICENSE

## 许可要点

- **AnimeJaNai 模型（CC BY-NC-SA 4.0）**：署名-非商业性使用-相同方式共享。
  本应用为免费个人使用软件，属非商业使用。分发未修改的模型原文件并附本署名文件即满足要求。
  **若日后将本应用用于商业目的，必须将动漫模型替换为非 NC 许可的模型**
  （如 Real-ESRGAN 官方 realesr-animevideov3，BSD-3-Clause）。
- **Real-ESRGAN 模型（BSD-3-Clause）**：保留版权与许可声明即可自由再分发。
- 本目录未对模型权重做任何修改，均为官方/作者发布的原始文件（仅重命名）。

## 致谢

- AnimeJaNai by JaNai (the-database) — https://github.com/the-database/mpv-upscale-2x_animejanai
- Real-ESRGAN by Xintao Wang et al. (XPixel Group) — https://github.com/xinntao/Real-ESRGAN
- ONNX Runtime by Microsoft — https://github.com/microsoft/onnxruntime

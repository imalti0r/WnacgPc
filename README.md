# WnacgPc

wnacg（紳士漫畫）桌面漫画客户端，Flutter + Material Design 3，Windows。

![平台](https://img.shields.io/badge/platform-Windows-blue) ![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B)

## 功能

- **浏览**：最新 / 20 个分类 / 标签页，无限滚动加载
- **搜索**：支持站点高级语法（`["abc"]` 仅标题、`tags:a` 仅标签、`a -b` 排除、`a OR b`）
- **详情**：封面、分类、标签（可点按标签浏览）、简介、上传者
- **阅读器**（移植自 [mihon_fx](../mihon_fx)，`lib/reader/`，仅做最小适配）：
  - 右开（日漫）/ 左开（西漫）/ 上下（条漫）三种方向；单页 / 双页布局（连续两竖页配对，横页自动独占一屏，参考 Mihon DualPageHolder）
  - 页面适应（屏幕/宽/高/原始大小）、InteractiveViewer 缩放（Ctrl+滚轮、双击缩放）、滚轮翻页
  - 键盘：←/→/Space/PageUp/PageDown 翻页，Home/End 跳转，Esc 退出，F11 全屏
  - 画质增强（Anime4K 线条增强 + FSR 超分 + RCAS 锐化，GPU 片段着色器，可在阅读器内调参）
  - 按页预取、后台尺寸嗅探（双页分组）、阅读进度续读
  - 数据源：在线（WebView2 图片桥） / 本地文件夹 / 本地 ZIP（随机访问懒解压）
- **下载**：整本队列下载（并发 4 + 逐页 120ms 间隔限速）、断点续传、进度条、离线阅读、书架管理；保存格式可选**文件夹**或 **ZIP**（设置 → 下载；页面先写入 `<aid>.part/` 临时目录支持续传，完成后打包为 `<净化标题>.zip` 并清理临时目录，离线阅读直接从 ZIP 按页解压）
- **书架**：收藏 / 历史（含阅读进度续读）/ 下载
- **设置**：深色模式、阅读方向（右开/左开/条漫）、页面布局（单页/双页）、**在线阅读预加载页数（0-20）**、**下载保存格式（文件夹/ZIP）**、线路自动测速 / 手动指定（域名失效可自救）

## 技术要点

- **图片加载走 WebView2 桥**：站点图片 CDN（`t4.wnacgimg.date`、`img5.wnimg1.ru`）按 TLS/JA3 指纹拦截非浏览器客户端（curl、openssl、Python、Dart 的握手全部被 RST）。应用用系统 WebView2（Edge/Chromium 内核）在隐藏页面执行 JS `fetch` 取回图片字节（`window.chrome.webview.postMessage` 回传，`ExecuteScript` 不等待 Promise），CORS 由启动参数 `--disable-web-security` 放行；若 fetch 被拒自动降级为"顶层导航 + canvas 读回"。磁盘缓存位于 `appSupport/image_cache/`。
- 站点 HTML 解析在 `lib/api/wnacg_api.dart`（路由模板 + html 包）。
- 本地数据（收藏/历史/设置/下载记录）为 JSON 文件，位于 `appSupport/`；下载图片在 `Documents/WnacgPc/downloads/<aid>/`。
- **线路检测**：启动后可从发布页 `wnacg01.link` 解析候选线路并测速（浏览页顶栏线路 Chip 或设置页触发）。

## 构建运行

```powershell
flutter pub get
flutter run -d windows        # 开发
flutter build windows --release   # 产物: build\windows\x64\runner\Release\wnacg_pc.exe
```

需要 Windows 10+ 与 WebView2 Runtime（Win10/11 一般自带；缺失时状态会显示在图片错误占位中）。

## 目录结构

```
lib/
├── main.dart                 # 入口 / MD3 主题 / NavigationRail 外壳
├── api/wnacg_api.dart        # 线路检测 + 站点 HTML 解析
├── models/models.dart        # GalleryItem / GalleryDetail / ReaderImage
├── net/
│   ├── image_bridge.dart     # WebView2 图片桥 + BridgedImageProvider + 磁盘缓存
│   └── download_service.dart # 下载队列 / 断点续传 / ZIP 打包 / 离线注册表
├── reader/                   # 阅读器（移植自 mihon_fx，最小适配）
│   ├── reader_page.dart      # 阅读器主体（方向/布局/适应/缩放/FX）
│   ├── library.dart          # ZipBook + PageItem(+在线url) + 章节加载适配
│   ├── reader_store.dart     # 阅读偏好持久化 + 进度写回 AppStore 历史
│   ├── models.dart           # ReadingMode / PageFit / PageLayout / AppSettings
│   ├── imgsize.dart          # 图片头尺寸嗅探（在线页只读磁盘缓存）
│   ├── fx_engine.dart        # 画质增强引擎（FSR/Anime4K/RCAS）
│   ├── fx_panel.dart         # 画质增强调参面板
│   ├── util.dart / app_log.dart
├── state/app_store.dart      # 收藏 / 历史 / 设置（JSON 持久化）
├── pages/                    # browse / search / detail / library / settings
└── widgets/                  # NetImage / GalleryCard
shaders/                      # fsr.frag / a4k.frag（画质增强着色器）
```

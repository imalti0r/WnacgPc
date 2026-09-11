import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../api/wnacg_api.dart';
import '../reader/app_log.dart';
import '../state/data_dirs.dart';

/// FNV-1a 稳定哈希（跨重启一致，作缓存文件名）
String fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode(s)) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// WebView2 图片桥：
/// 图片 CDN 按 TLS/JA3 指纹拦截非浏览器客户端（curl/openssl/dart 全被 RST），
/// 因此用系统 WebView2（真实 Chromium 网络栈）获取图片字节，带磁盘缓存。
///
/// 注意：WebView2 ExecuteScript 不等待 Promise，异步结果一律通过
/// window.chrome.webview.postMessage 回传（webMessage 流接收）。
///
/// 两种策略：
///  A. fetch 模式：在主站页面里执行 JS fetch（Referer 正确、并发高）
///  B. 导航模式：顶层导航到图片 URL，用 canvas 读回（无 CORS 依赖，需串行）
/// 启动时探测，A 失败自动切 B。
class ImageBridge {
  ImageBridge._();
  static final ImageBridge instance = ImageBridge._();

  final controller = WebviewController();
  Future<void>? _initFuture;

  /// 最近一次错误，用于 UI 展示诊断
  String lastError = '';

  /// 初始化状态描述（诊断用）
  String status = '未初始化';

  bool _useNavMode = false;
  bool _pageLoaded = false;
  final _gate = _Semaphore(4); // fetch 模式并发
  final _navLock = _Semaphore(1); // 导航模式必须串行

  int _msgId = 0;
  final _pending = <int, Completer<dynamic>>{};

  Directory? _cacheDir;

  /// 迁移数据目录后切换缓存位置（旧缓存已复制过去）
  void setCacheDir(String path) {
    _cacheDir = Directory(path);
    try {
      _cacheDir!.createSync(recursive: true);
    } catch (_) {}
  }

  Directory _ensureCacheDir() {
    final d = _cacheDir;
    if (d != null) return d;
    setCacheDir(DataDirs.instance.imageCachePath);
    return _cacheDir!;
  }

  Future<void> ensureInit() => _initFuture ??= _init();

  void _onMessage(dynamic msg) {
    if (msg is Map && msg['id'] is int) {
      final c = _pending.remove(msg['id'] as int);
      if (c != null && !c.isCompleted) c.complete(msg);
    } else if (msg is Map && msg['probe'] == true) {
      _probeCompleter?.complete(msg);
    }
  }

  Completer<dynamic>? _probeCompleter;

  Future<void> _init() async {
    try {
      // 图片缓存跟随数据目录；WebView2 自身配置留在固定支持目录（只读环境约束）
      setCacheDir(DataDirs.instance.imageCachePath);
      final support = await getApplicationSupportDirectory();
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        status = '未安装 WebView2 运行时';
        return;
      }
      status = '运行时 $version';
      try {
        await WebviewController.initializeEnvironment(
          userDataPath: '${support.path}/webview2',
          additionalArguments:
              '--disable-web-security --disable-site-per-process',
        );
      } catch (_) {} // 环境只能初始化一次，重复调用忽略
      controller.webMessage.listen(_onMessage);
      await controller.initialize();
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      // 加载主站页面，使 fetch 携带正确的 Referer
      await controller.loadUrl(WnacgApi.instance.baseUrl);
      await controller.loadingState
          .firstWhere((s) => s == LoadingState.navigationCompleted)
          .timeout(const Duration(seconds: 25));
      _pageLoaded = true;
      // 探测：fetch 一张缩略图，判断 CORS 是否放行
      const probe = 'https://t4.wnacgimg.date/data/t/3725/09/xxsnpc.gif';
      const js = '''
(async () => {
  const reply = (v) => window.chrome.webview.postMessage(Object.assign({ probe: true }, v));
  try {
    const r = await fetch("$probe", { mode: 'cors', credentials: 'omit' });
    reply({ ok: r.ok, code: r.status });
  } catch (e) {
    reply({ ok: false, err: String(e).slice(0, 120) });
  }
})()
''';
      _probeCompleter = Completer<dynamic>();
      await controller.executeScript(js);
      final res = await _probeCompleter!.future
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      _probeCompleter = null;
      if (res is Map && res['ok'] == true) {
        _useNavMode = false;
        status += ' · fetch 模式(HTTP ${res['code']})';
      } else {
        _useNavMode = true;
        status += ' · fetch 被拒(${res is Map ? (res['err'] ?? res['code'] ?? '空') : '无响应'}) → 导航模式';
      }
    } catch (e) {
      status = '初始化失败: $e';
      lastError = '$e';
    }
  }

  String _extOf(String url) {
    final m = RegExp(r'\.(jpe?g|png|webp|gif|bmp|avif)').firstMatch(url.toLowerCase());
    return m != null ? '.${m.group(1)}'.replaceFirst('.jpeg', '.jpg') : '.jpg';
  }

  /// 缓存文件：带 [cacheId]（漫画 aid）时按漫画分目录
  /// `<cache>/<aid>/<cacheName>.<ext>`；否则旧版扁平 `<fnv1a(url)>.<ext>`。
  File? _cacheFile(String url, {String? cacheId, String? cacheName}) {
    if (_cacheDir == null) return null;
    if (cacheId != null && cacheName != null) {
      final id = cacheId.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '');
      final nm = cacheName.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '');
      if (id.isNotEmpty && nm.isNotEmpty) {
        return File('${_cacheDir!.path}/$id/$nm${_extOf(url)}');
      }
    }
    return File('${_cacheDir!.path}/${fnv1a(url)}${_extOf(url)}');
  }

  /// 旧版扁平缓存文件（迁移兼容读）
  File? _legacyCacheFile(String url) {
    if (_cacheDir == null) return null;
    return File('${_cacheDir!.path}/${fnv1a(url)}${_extOf(url)}');
  }

  Future<Uint8List?> readCache(String url,
      {String? cacheId, String? cacheName}) async {
    final f = _cacheFile(url, cacheId: cacheId, cacheName: cacheName);
    if (f != null && await f.exists()) {
      try {
        final bytes = await f.readAsBytes();
        if (bytes.lengthInBytes > 0) return bytes;
      } catch (_) {}
    }
    // 兼容旧版扁平缓存：命中后惰性迁移到新位置
    final legacy = _legacyCacheFile(url);
    if (cacheId != null &&
        cacheName != null &&
        legacy != null &&
        await legacy.exists()) {
      try {
        final bytes = await legacy.readAsBytes();
        if (bytes.lengthInBytes > 0) {
          unawaited(_lazyMigrate(bytes, f!, legacy));
          return bytes;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> _lazyMigrate(Uint8List bytes, File target, File legacy) async {
    try {
      await writeCacheBytes(target, bytes);
      try {
        await legacy.delete();
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> writeCacheBytes(File f, Uint8List bytes) async {
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  Future<void> writeCache(String url, Uint8List bytes,
      {String? cacheId, String? cacheName}) async {
    final f = _cacheFile(url, cacheId: cacheId, cacheName: cacheName);
    if (f == null) return;
    await writeCacheBytes(f, bytes);
  }

  /// 超分结果缓存：`<cache>/<aid>/sr/<cacheName>.png`（SR 输出统一 PNG）。
  /// 位于 image_cache 子树内 —— cacheStats/clearCache/enforceCacheLimit/relocateCache
  /// 的递归收集自动覆盖，无需额外接线。
  File? _srCacheFile(String cacheId, String cacheName) {
    if (_cacheDir == null) return null;
    final id = cacheId.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '');
    final nm = cacheName.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '');
    if (id.isEmpty || nm.isEmpty) return null;
    return File('${_cacheDir!.path}/$id/sr/$nm.png');
  }

  Future<Uint8List?> readSrCache(String cacheId, String cacheName) async {
    final f = _srCacheFile(cacheId, cacheName);
    if (f != null && await f.exists()) {
      try {
        final bytes = await f.readAsBytes();
        if (bytes.lengthInBytes > 0) return bytes;
      } catch (_) {}
    }
    return null;
  }

  Future<void> writeSrCache(String cacheId, String cacheName, Uint8List bytes) async {
    final f = _srCacheFile(cacheId, cacheName);
    if (f == null) return;
    await writeCacheBytes(f, bytes);
  }

  Future<void> deleteSrCache(String cacheId, String cacheName) async {
    final f = _srCacheFile(cacheId, cacheName);
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ---------- 缓存管理（设置页 / 调试接口共用） ----------

  /// 递归收集目录下全部文件（缓存已按漫画分目录）
  Future<void> _collectFiles(Directory dir, List<File> out) async {
    await for (final e in dir.list(followLinks: false)) {
      if (e is File) {
        out.add(e);
      } else if (e is Directory) {
        try {
          await _collectFiles(e, out);
        } catch (_) {}
      }
    }
  }

  /// 清理删除后遗留的空目录
  Future<void> _pruneEmptyDirs(Directory dir) async {
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is Directory) {
          await _pruneEmptyDirs(e);
          try {
            await e.delete(); // 非空会抛错，忽略即可
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 缓存统计：文件数与总字节（含子目录）。
  Future<({int files, int bytes})> cacheStats() async {
    final dir = _ensureCacheDir();
    if (!await dir.exists()) return (files: 0, bytes: 0);
    var files = 0, bytes = 0;
    final list = <File>[];
    try {
      await _collectFiles(dir, list);
    } catch (_) {}
    for (final f in list) {
      files++;
      try {
        bytes += await f.length();
      } catch (_) {}
    }
    return (files: files, bytes: bytes);
  }

  /// 手动清空磁盘缓存，返回删除的文件数。
  Future<int> clearCache() async {
    final dir = _ensureCacheDir();
    if (!await dir.exists()) return 0;
    final list = <File>[];
    try {
      await _collectFiles(dir, list);
    } catch (_) {}
    var n = 0;
    for (final f in list) {
      try {
        await f.delete();
        n++;
      } catch (_) {}
    }
    await _pruneEmptyDirs(dir);
    return n;
  }

  /// 按大小上限自动清理：超过 [maxBytes] 时从最旧文件开始删，降到上限的
  /// 80% 为止（留余量，避免每次写入都触发）。maxBytes<=0 = 不限制。
  /// 返回释放的字节数。
  Future<int> enforceCacheLimit(int maxBytes) async {
    if (maxBytes <= 0) return 0;
    final dir = _ensureCacheDir();
    if (!await dir.exists()) return 0;
    var total = 0;
    final files = <File>[];
    try {
      await _collectFiles(dir, files);
    } catch (_) {}
    for (final f in files) {
      try {
        total += await f.length();
      } catch (_) {}
    }
    if (total <= maxBytes) return 0;
    final withTime = <(File, DateTime)>[];
    for (final f in files) {
      try {
        withTime.add((f, (await f.stat()).modified));
      } catch (_) {}
    }
    withTime.sort((a, b) => a.$2.compareTo(b.$2));
    final target = maxBytes * 8 ~/ 10;
    var freed = 0;
    for (final (f, _) in withTime) {
      if (total <= target) break;
      try {
        final len = await f.length();
        await f.delete();
        total -= len;
        freed += len;
      } catch (_) {}
    }
    if (freed > 0) {
      await _pruneEmptyDirs(dir);
      AppLog.i('缓存', '超过上限，自动清理释放 ${(freed / 1048576).toStringAsFixed(1)} MB');
    }
    return freed;
  }

  /// 更改缓存位置：把现有缓存（文件与漫画子目录）移到新目录（同盘 rename，
  /// 跨盘 copy+delete），然后切换并持久化指针。返回移动的条目数。
  Future<int> relocateCache(String newPath) async {
    final dst = Directory(newPath);
    await dst.create(recursive: true);
    final src = _cacheDir;
    var moved = 0;
    final srcN = src?.path.replaceAll('\\', '/');
    final dstN = newPath.replaceAll('\\', '/');
    // 新路径位于源缓存目录内部时不搬移，否则边遍历边移入自身子目录
    final dstInsideSrc =
        srcN != null && srcN != dstN && '$dstN/'.startsWith('$srcN/');
    if (src != null && srcN != dstN && !dstInsideSrc && await src.exists()) {
      await for (final e in src.list()) {
        final name = e.uri.pathSegments.last;
        if (name.isEmpty) continue;
        final targetPath = '${dst.path}/$name';
        try {
          if (e is File) {
            final target = File(targetPath);
            try {
              await e.rename(target.path);
            } catch (_) {
              await e.copy(target.path);
              await e.delete();
            }
            moved++;
          } else if (e is Directory) {
            final target = Directory(targetPath);
            try {
              await e.rename(target.path);
            } catch (_) {
              await _copyDir(e, target);
              await e.delete(recursive: true);
            }
            moved++;
          }
        } catch (_) {}
      }
    }
    setCacheDir(newPath);
    await DataDirs.instance.setCacheOverride(newPath);
    return moved;
  }

  Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list()) {
      final name = e.uri.pathSegments.last;
      if (name.isEmpty) continue;
      if (e is File) {
        await e.copy('${dst.path}/$name');
      } else if (e is Directory) {
        await _copyDir(e, Directory('${dst.path}/$name'));
      }
    }
  }

  /// 取图片字节：先磁盘缓存（新位置 → 旧版扁平），再 WebView 桥；
  /// 成功后写缓存。失败抛异常。
  /// [cacheId]/[cacheName] 提供时缓存按漫画分目录（`<aid>/<页号|cover>`）。
  /// [onSource] 在来源确定时回调一次：true=磁盘缓存命中（未联网），
  /// false=联网取回（随后写入磁盘缓存）。阅读器用它驱动命中/未命中角标。
  Future<Uint8List> getBytes(String url,
      {String? cacheId,
      String? cacheName,
      void Function(bool cacheHit)? onSource}) async {
    final cached = await readCache(url, cacheId: cacheId, cacheName: cacheName);
    if (cached != null) {
      onSource?.call(true);
      return cached;
    }
    await ensureInit();
    Uint8List bytes;
    try {
      bytes = _useNavMode ? await _fetchByNav(url) : await _fetchByJs(url);
    } catch (e) {
      lastError = '$e';
      if (_useNavMode) rethrow;
      // fetch 模式意外失败时降级导航模式重试一次
      _useNavMode = true;
      bytes = await _fetchByNav(url);
    }
    await writeCache(url, bytes, cacheId: cacheId, cacheName: cacheName);
    onSource?.call(false);
    return bytes;
  }

  /// 执行脚本并等待 postMessage 回传结果
  Future<dynamic> _eval(String js, {Duration timeout = const Duration(seconds: 60)}) {
    final id = ++_msgId;
    final c = Completer<dynamic>();
    _pending[id] = c;
    // 顶层包裹：把 id 传进异步任务
    final script = '''
(async () => {
  const reply = (v) => window.chrome.webview.postMessage(Object.assign({ id: $id }, v));
$js
})()
''';
    controller.executeScript(script).catchError((e) {
      final c2 = _pending.remove(id);
      if (c2 != null && !c2.isCompleted) {
        c2.completeError(Exception('桥脚本执行失败: $e'));
      }
    });
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('桥脚本超时');
    });
  }

  /// A. JS fetch（在已加载的站点页面上下文）
  Future<Uint8List> _fetchByJs(String url) async {
    await _gate.acquire();
    try {
      await _ensureOriginPage();
      final u = jsonEncode(url);
      final raw = await _eval('''
  try {
    const r = await fetch($u, { mode: 'cors', credentials: 'omit' });
    if (!r.ok) { reply({ err: 'HTTP ' + r.status }); return; }
    const b = await r.blob();
    const d = await new Promise((res) => {
      const f = new FileReader();
      f.onload = () => res(f.result);
      f.onerror = () => res(null);
      f.readAsDataURL(b);
    });
    reply(d ? { data: d } : { err: 'readAsDataURL 失败' });
  } catch (e) {
    reply({ err: String(e).slice(0, 200) });
  }
''');
      return _bytesFrom(raw);
    } finally {
      _gate.release();
    }
  }

  /// B. 顶层导航到图片 URL + canvas 读回（串行）
  Future<Uint8List> _fetchByNav(String url) async {
    await _navLock.acquire();
    try {
      await ensureInit();
      await controller.loadUrl(url);
      await controller.loadingState
          .firstWhere((s) => s == LoadingState.navigationCompleted)
          .timeout(const Duration(seconds: 25));
      final raw = await _eval('''
  try {
    const img = document.images && document.images[0];
    if (!img) { reply({ err: 'no img element' }); return; }
    if (img.decode) { try { await img.decode(); } catch (_) {} }
    const c = document.createElement('canvas');
    c.width = img.naturalWidth || img.width;
    c.height = img.naturalHeight || img.height;
    if (!c.width || !c.height) { reply({ err: 'zero size' }); return; }
    const ctx = c.getContext('2d');
    ctx.drawImage(img, 0, 0);
    reply({ data: c.toDataURL('image/jpeg', 0.92) });
  } catch (e) {
    reply({ err: String(e).slice(0, 200) });
  }
''', timeout: const Duration(seconds: 40));
      _pageLoaded = false; // 顶层页面已被图片替换
      return _bytesFrom(raw);
    } finally {
      _navLock.release();
    }
  }

  /// 恢复主站页面（fetch 模式需要）
  Future<void> _ensureOriginPage() async {
    if (_pageLoaded) return;
    await controller.loadUrl(WnacgApi.instance.baseUrl);
    await controller.loadingState
        .firstWhere((s) => s == LoadingState.navigationCompleted)
        .timeout(const Duration(seconds: 25));
    _pageLoaded = true;
  }

  Uint8List _bytesFrom(dynamic raw) {
    if (raw is Map) {
      if (raw['data'] is String) {
        final dataUrl = raw['data'] as String;
        final i = dataUrl.indexOf('base64,');
        if (i < 0) throw Exception('桥返回数据异常');
        return base64Decode(dataUrl.substring(i + 7));
      }
      throw Exception('图片桥: ${raw['err']}');
    }
    throw Exception('图片桥返回异常: $raw');
  }
}

/// 基于图片桥的 ImageProvider（磁盘缓存由桥负责）
class BridgedImageProvider extends ImageProvider<BridgedImageProvider> {
  final String url;
  final double scale;

  /// 重试种子：变化时视为新 key 触发重新加载，网络请求仍用原始 [url]
  /// （不改写 URL，避免去缓存参数导致 CDN 404 / 磁盘缓存键漂移）。
  final int attempt;

  /// 漫画 id 与缓存名（如 aid + 'cover'）：磁盘缓存按漫画分目录
  final String? cacheId;
  final String? cacheName;

  BridgedImageProvider(this.url,
      {this.scale = 1.0, this.attempt = 0, this.cacheId, this.cacheName});

  @override
  Future<BridgedImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<BridgedImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(BridgedImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
    );
  }

  Future<ui.Codec> _load(BridgedImageProvider key, ImageDecoderCallback decode) async {
    final bytes = await ImageBridge.instance
        .getBytes(key.url, cacheId: key.cacheId, cacheName: key.cacheName);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buffer);
    return codec;
  }

  @override
  bool operator ==(Object other) =>
      other is BridgedImageProvider &&
      other.url == url &&
      other.attempt == attempt &&
      other.cacheId == cacheId &&
      other.cacheName == cacheName;

  @override
  int get hashCode => Object.hash(url, attempt, cacheId, cacheName);

  @override
  String toString() => 'BridgedImageProvider($url#$attempt/$cacheId)';
}

/// 简单计数信号量
class _Semaphore {
  final int capacity;
  int _running = 0;
  final _waiters = ListQueue<Completer<void>>();

  _Semaphore(this.capacity);

  Future<void> acquire() {
    if (_running < capacity) {
      _running++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(); // 名额直接转移给等待者
    } else {
      _running = _running > 0 ? _running - 1 : 0;
    }
  }
}

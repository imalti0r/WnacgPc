import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../api/wnacg_api.dart';
import '../net/download_service.dart';
import '../net/image_bridge.dart';
import '../reader/app_log.dart';
import '../state/app_store.dart';
import '../state/data_dirs.dart';

/// 本地调试 HTTP 服务（仅监听 127.0.0.1，设置内可开关）。
/// 供外部脚本/AI 调试 UI：查询元素树、模拟点击/输入/滚动、截图、读日志。
///
/// 元素定位三种方式：
///  1. id    —— /tree 或 /find 返回的路径 id（如 "0.3.1"），点击时按路径重新走树
///  2. key   —— 匹配 Widget key（ValueKey 的 value 或 key 字符串包含）
///  3. text  —— 匹配 Text/EditableText 的可见文本（适合"点'设置'按钮"这类操作）
class DebugServer {
  DebugServer._();
  static final DebugServer instance = DebugServer._();

  /// 全局截图边界（main.dart 包住 MaterialApp）
  static final GlobalKey screenKey = GlobalKey(debugLabel: 'debug-screenshot');

  /// 根导航器（back 用）
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'debug-navigator');

  /// 首页 shell 注册的导航回调（切 Tab / 打开搜索）
  static void Function(String route)? navigateHook;

  /// 首页 shell 注册的当前 Tab 查询（0 浏览 1 书架 2 设置，3=搜索中）
  static int Function()? tabGetter;

  /// 首页 shell 注册的返回处理（关闭搜索页 / 弹出详情路由）
  static Future<bool> Function()? backHook;

  HttpServer? _server;
  int get port => _port;
  int _port = 18080;
  bool get running => _server != null;

  int _pointerSeq = 0;
  int _startAt = DateTime.now().millisecondsSinceEpoch;

  Future<void> start({int? port}) async {
    if (running) return;
    _port = port ?? _port;
    Object? lastErr;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
        break;
      } catch (e) {
        lastErr = e;
        _port++;
      }
    }
    final server = _server;
    if (server == null) {
      AppLog.e('debug', '调试服务启动失败(端口 $_port 起)', lastErr);
      return;
    }
    _startAt = DateTime.now().millisecondsSinceEpoch;
    AppLog.i('debug', '调试服务已启动 http://127.0.0.1:$_port');
    server.listen(_safeHandle, onError: (e) {});
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    try {
      await s?.close(force: true);
    } catch (_) {}
    AppLog.i('debug', '调试服务已停止');
  }

  // ---------------- HTTP 层 ----------------

  Future<void> _safeHandle(HttpRequest req) async {
    try {
      await _handle(req);
    } catch (e, st) {
      AppLog.e('debug', '处理 ${req.method} ${req.uri.path} 失败', e, st);
      try {
        _json(req, {'ok': false, 'error': '$e'}, 500);
      } catch (_) {}
    }
  }

  Future<void> _handle(HttpRequest req) async {
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    req.response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    final path = req.uri.path;
    final q = req.uri.queryParameters;
    Map<String, dynamic> body = {};
    if (req.method == 'POST') {
      try {
        final raw = await utf8.decoder.bind(req).join();
        if (raw.isNotEmpty) {
          body = (jsonDecode(raw) as Map).cast<String, dynamic>();
        }
      } catch (e) {
        _json(req, {'ok': false, 'error': '请求体不是合法 JSON: $e'}, 400);
        return;
      }
    }

    switch (path) {
      case '/ping':
        _json(req, await _ping());
      case '/help':
        _json(req, {'ok': true, 'endpoints': help});
      case '/state':
        _json(req, await _state());
      case '/tree':
        _json(req, await _tree(q));
      case '/find':
        _json(req, await _find(q));
      case '/screenshot':
        await _screenshot(req, q);
      case '/log':
        _json(req, await _log(q));
      case '/tap':
        _json(req, await _act(body, longPress: false));
      case '/longpress':
        _json(req, await _act(body, longPress: true));
      case '/text':
        _json(req, await _setText(body));
      case '/scroll':
        _json(req, await _scroll(body));
      case '/navigate':
        _json(req, await _navigate(body));
      case '/back':
        _json(req, await _back());
      case '/cache':
        _json(req, await _cacheInfo());
      case '/cache/clean':
        _json(req, await _cacheClean());
      case '/cache/enforce':
        _json(req, await _cacheEnforce(body));
      default:
        _json(req, {'ok': false, 'error': '未知端点 $path，见 GET /help'}, 404);
    }
  }

  static const help = [
    'GET  /ping                          活性 + 基本信息',
    'GET  /state                         应用状态摘要（线路/设置/下载/收藏等）',
    'GET  /tree?maxDepth=&maxNodes=      当前 Widget 树（含 id/类型/文本/矩形）',
    'GET  /find?q=&type=&text=&key=      按类型/文本/key 过滤元素，返回 id',
    'POST /tap      {id|key|text|x,y}    模拟点击',
    'POST /longpress{ id|key|text|x,y}   模拟长按',
    'POST /text     {id|key|text, value} 向输入框写入文本（触发 onChanged）',
    'POST /scroll   {x,y,dx,dy}          模拟滚轮（dy>0 向下）',
    'POST /navigate {tab: 0|1|2|browse|library|settings|search}  切换主页面',
    'POST /back                          返回上一页',
    'GET  /cache                         图片磁盘缓存信息（dir/files/bytes/maxMb）',
    'POST /cache/clean                   清空图片磁盘缓存',
    'POST /cache/enforce {mb?}           按大小上限清理（缺省用设置值）',
    'GET  /screenshot?pixelRatio=        当前窗口截图 (image/png)',
    'GET  /log?lines=100                 最近日志',
  ];

  // ---------------- 具体端点 ----------------

  Future<Map<String, dynamic>> _ping() async {
    return {
      'ok': true,
      'app': 'WNACG',
      'uptimeSec': (DateTime.now().millisecondsSinceEpoch - _startAt) ~/ 1000,
      'tab': tabGetter?.call(),
      'baseUrl': WnacgApi.instance.baseUrl,
      'dataDir': DataDirs.instance.root,
      'frameScheduled': SchedulerBinding.instance.hasScheduledFrame,
    };
  }

  // ---------------- 图片磁盘缓存 ----------------

  Future<Map<String, dynamic>> _cacheInfo() async {
    final s = await ImageBridge.instance.cacheStats();
    return {
      'ok': true,
      'dir': DataDirs.instance.imageCachePath,
      'files': s.files,
      'bytes': s.bytes,
      'maxMb': AppStore.instance.imageCacheMaxMb,
    };
  }

  Future<Map<String, dynamic>> _cacheClean() async {
    final n = await ImageBridge.instance.clearCache();
    AppLog.i('调试', '接口清空图片缓存：$n 个文件');
    return {'ok': true, 'deleted': n};
  }

  Future<Map<String, dynamic>> _cacheEnforce(Map<String, dynamic> body) async {
    final mb = body['mb'] is num
        ? (body['mb'] as num).toInt()
        : AppStore.instance.imageCacheMaxMb;
    final freed = await ImageBridge.instance.enforceCacheLimit(mb * 1048576);
    final s = await ImageBridge.instance.cacheStats();
    return {
      'ok': true,
      'limitMb': mb,
      'freedBytes': freed,
      'files': s.files,
      'bytes': s.bytes,
    };
  }

  Future<Map<String, dynamic>> _state() async {
    final store = AppStore.instance;
    final dl = DownloadService.instance;
    return {
      'ok': true,
      'baseUrl': WnacgApi.instance.baseUrl,
      'darkMode': store.darkMode,
      'preloadDistance': store.preloadDistance,
      'zipDownloads': store.zipDownloads,
      'debugEnabled': store.debugEnabled,
      'debugPort': store.debugPort,
      'dataDir': DataDirs.instance.root,
      'dataDirCustom': DataDirs.instance.isCustom,
      'favorites': store.favorites.length,
      'history': store.history.length,
      'downloadsDone': dl.downloads.length,
      'downloadsActive': dl.activeTasks
          .map((t) => {
                'aid': t.item.aid,
                'title': t.item.title,
                'progress': t.progress,
                'status': t.status.name,
              })
          .toList(),
      'imageBridge': ImageBridge.instance.status,
    };
  }

  Future<Map<String, dynamic>> _tree(Map<String, String> q) async {
    // MD3 页面嵌套极深（真实内容可在 100~200 层），深度默认放开、由 maxNodes 兜底
    final maxDepth = int.tryParse(q['maxDepth'] ?? '') ?? 1000;
    final maxNodes = int.tryParse(q['maxNodes'] ?? '') ?? 4000;
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) {
      return {'ok': false, 'error': 'Widget 树尚未挂载'};
    }
    final nodes = <Map<String, dynamic>>[];
    _visit(rootElement, '0', 0, maxDepth, maxNodes, nodes);
    return {'ok': true, 'count': nodes.length, 'nodes': nodes};
  }

  void _visit(Element el, String id, int depth, int maxDepth, int maxNodes,
      List<Map<String, dynamic>> out) {
    if (depth > maxDepth || out.length >= maxNodes) return;
    out.add(_describe(el, id));
    var i = 0;
    el.visitChildren((child) {
      _visit(child, '$id.$i', depth + 1, maxDepth, maxNodes, out);
      i++;
    });
  }

  Map<String, dynamic> _describe(Element el, String id) {
    final w = el.widget;
    String? text;
    var editable = false;
    if (w is Text) text = w.data;
    if (w is RichText) {
      try {
        text = (w.text as TextSpan).toPlainText();
      } catch (_) {}
    }
    if (w is EditableText) {
      text = w.controller.text;
      editable = true;
    }
    var offstage = false;
    if (w is Offstage) offstage = w.offstage;
    final k = w.key;
    final node = <String, dynamic>{
      'id': id,
      'type': w.runtimeType.toString(),
      if (k != null) 'key': k.toString(),
      if (k is ValueKey<String>) 'keyValue': k.value,
      if (text != null && text.isNotEmpty) 'text': _clip(text),
      if (editable) 'editable': true,
      if (offstage) 'offstage': true,
    };
    final box = _boxOf(el);
    if (box != null) {
      node['rect'] = {
        'x': box.left.round(),
        'y': box.top.round(),
        'w': box.width.round(),
        'h': box.height.round(),
      };
    }
    return node;
  }

  Rect? _boxOf(Element el) {
    final ro = el.renderObject;
    if (ro is RenderBox && ro.attached && ro.hasSize) {
      final tl = ro.localToGlobal(Offset.zero);
      return Rect.fromLTWH(tl.dx, tl.dy, ro.size.width, ro.size.height);
    }
    return null;
  }

  /// 当前可视窗口区域（截图边界即 MaterialApp 全域）
  Rect? _windowRect() {
    final ctx = screenKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  String _clip(String s, [int n = 160]) =>
      s.length <= n ? s : s.substring(0, n);

  /// 遍历树收集匹配节点；[match] 返回 true 的进入结果
  Future<Map<String, dynamic>> _find(Map<String, String> q) async {
    final typeQ = (q['type'] ?? '').toLowerCase();
    final textQ = q['text'] ?? q['q'] ?? '';
    final keyQ = q['key'] ?? '';
    final exact = q['exact'] == 'true';
    final limit = int.tryParse(q['limit'] ?? '') ?? 50;
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return {'ok': false, 'error': 'Widget 树尚未挂载'};
    final nodes = <Map<String, dynamic>>[];
    void walk(Element el, String id) {
      if (nodes.length >= limit) return;
      final w = el.widget;
      var hit = true;
      if (typeQ.isNotEmpty) {
        hit = w.runtimeType.toString().toLowerCase().contains(typeQ);
      }
      if (hit && textQ.isNotEmpty) {
        String? t;
        if (w is Text) t = w.data;
        if (w is EditableText) t = w.controller.text;
        if (w is RichText) {
          try {
            t = (w.text as TextSpan).toPlainText();
          } catch (_) {}
        }
        hit = t != null && (exact ? t.trim() == textQ : t.contains(textQ));
      }
      if (hit && keyQ.isNotEmpty) {
        hit = w.key.toString().contains(keyQ);
      }
      if (hit) nodes.add(_describe(el, id));
      var i = 0;
      el.visitChildren((c) {
        walk(c, '$id.$i');
        i++;
      });
    }

    walk(rootElement, '0');
    return {'ok': true, 'count': nodes.length, 'nodes': nodes};
  }

  /// 按条件定位元素并点击/长按
  Future<Map<String, dynamic>> _act(Map<String, dynamic> body,
      {required bool longPress}) async {
    final el = await _resolve(body);
    if (el == null) {
      return {'ok': false, 'error': '未找到目标元素，先 GET /tree 或 /find 获取 id/key/text'};
    }
    var box = _boxOf(el);
    var viaAncestor = false;
    // 目标可能不可见（如 NavigationRail 未展开时 label 尺寸为 0）：
    // 向上找第一个有可见尺寸的祖先作为点击位置
    if (box == null || box.width <= 0 || box.height <= 0) {
      Element? via;
      el.visitAncestorElements((a) {
        final b = _boxOf(a);
        if (b != null && b.width > 0 && b.height > 0) {
          via = a;
          return false;
        }
        return true;
      });
      final target = via;
      if (target != null) {
        box = _boxOf(target);
        viaAncestor = true;
      }
    }
    if (box == null) {
      return {'ok': false, 'error': '目标及其祖先均无渲染盒（可能不可见），换个目标'};
    }
    // 目标在可视窗口外时，先滚动到可见位置再点
    final win = _windowRect();
    bool outside(Rect r) =>
        win != null &&
        (r.left < win.left ||
            r.top < win.top ||
            r.right > win.right ||
            r.bottom > win.bottom);
    if (outside(box)) {
      try {
        await Scrollable.ensureVisible(el,
            duration: const Duration(milliseconds: 300), alignment: 0.5);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      } catch (_) {}
      // 滚动后重新取盒（含零尺寸祖先回退）
      box = _boxOf(el);
      if (box == null || box.width <= 0 || box.height <= 0) {
        Element? via;
        el.visitAncestorElements((a) {
          final b = _boxOf(a);
          if (b != null && b.width > 0 && b.height > 0) {
            via = a;
            return false;
          }
          return true;
        });
        final t = via;
        if (t != null) box = _boxOf(t);
      }
      if (box == null) {
        return {'ok': false, 'error': '目标在可视区外且无法滚动到位'};
      }
    }
    final center = box.center;
    if (center.dx < 0 || center.dy < 0) {
      return {'ok': false, 'error': '目标在窗口外 $center'};
    }
    await _tapAt(center, longPress: longPress);
    return {
      'ok': true,
      'tapped': {'x': center.dx.round(), 'y': center.dy.round()},
      'type': el.widget.runtimeType.toString(),
      if (el.widget.key != null) 'key': el.widget.key.toString(),
      if (viaAncestor) 'viaAncestor': true,
    };
  }

  /// 解析 {id|key|text} → Element（每次请求实时走树，避免过期引用）
  Future<Element?> _resolve(Map<String, dynamic> body) async {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return null;
    final idPath = body['id'] as String?;
    final keyQ = body['key'] as String?;
    final textQ = body['text'] as String?;

    if (idPath != null) {
      // id 形如 "0.3.1"：首段恒为根 '0'，其后是每层 visitChildren 的序号
      final parts = idPath.split('.');
      if (parts.isEmpty || parts.first != '0') return null;
      Element? cur = rootElement;
      for (final part in parts.skip(1)) {
        final idx = int.tryParse(part);
        if (idx == null || cur == null) return null;
        Element? next;
        var i = 0;
        cur.visitChildren((c) {
          if (i == idx) next = c;
          i++;
        });
        cur = next;
      }
      return cur;
    }

    Element? found;
    final exact = body['exact'] == true;
    bool textHit(String? t) {
      final q = textQ;
      if (t == null || q == null) return false;
      return exact ? t.trim() == q : t.contains(q);
    }
    void walk(Element el) {
      if (found != null) return;
      final w = el.widget;
      if (keyQ != null) {
        final k = w.key;
        if (k.toString().contains(keyQ) ||
            (k is ValueKey<String> && k.value == keyQ)) {
          found = el;
          return;
        }
      } else if (textQ != null) {
        String? t;
        if (w is Text) t = w.data;
        if (w is EditableText) t = w.controller.text;
        if (w is RichText) {
          try {
            t = (w.text as TextSpan).toPlainText();
          } catch (_) {}
        }
        if (textHit(t)) {
          found = el;
          return;
        }
      }
      el.visitChildren(walk);
    }

    walk(rootElement);
    return found;
  }

  /// 在逻辑坐标处合成一次点击/长按
  Future<void> _tapAt(Offset pos, {required bool longPress}) async {
    final pointer = ++_pointerSeq;
    const kind = PointerDeviceKind.mouse;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
          pointer: pointer,
          position: pos,
          kind: kind,
          buttons: kPrimaryButton),
    );
    final hold = longPress ? 700 : 60;
    await Future<void>.delayed(Duration(milliseconds: hold));
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(pointer: pointer, position: pos, kind: kind),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  Future<Map<String, dynamic>> _setText(Map<String, dynamic> body) async {
    final value = (body['value'] ?? '').toString();
    Element? el = await _resolveEditable(body) ?? await _resolve(body);
    if (el == null) return {'ok': false, 'error': '未找到输入框（可先 GET /find?type=editabletext）'};
    final w = el.widget;
    if (w is EditableText) {
      w.controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      w.onChanged?.call(value);
      return {'ok': true, 'value': value};
    }
    return {'ok': false, 'error': '目标不是输入框 (${w.runtimeType})'};
  }

  /// 文本定位时优先挑 EditableText
  Future<Element?> _resolveEditable(Map<String, dynamic> body) async {
    final textQ = body['text'] as String? ?? body['value'] as String?;
    if (textQ == null) return null;
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return null;
    Element? found;
    void walk(Element el) {
      if (found != null) return;
      final w = el.widget;
      if (w is EditableText && w.controller.text.contains(textQ)) {
        found = el;
        return;
      }
      el.visitChildren(walk);
    }

    walk(rootElement);
    return found;
  }

  Future<Map<String, dynamic>> _scroll(Map<String, dynamic> body) async {
    final x = (body['x'] as num?)?.toDouble() ?? 400;
    final y = (body['y'] as num?)?.toDouble() ?? 300;
    final dx = (body['dx'] as num?)?.toDouble() ?? 0;
    final dy = (body['dy'] as num?)?.toDouble() ?? 0;
    GestureBinding.instance.handlePointerEvent(
      PointerScrollEvent(
        position: Offset(x, y),
        scrollDelta: Offset(dx, dy),
        kind: PointerDeviceKind.mouse,
      ),
    );
    return {'ok': true};
  }

  Future<Map<String, dynamic>> _navigate(Map<String, dynamic> body) async {
    final hook = navigateHook;
    if (hook == null) return {'ok': false, 'error': '主页未注册导航钩子'};
    final tab = body['tab'];
    final map = {
      'browse': 0,
      '浏览': 0,
      'library': 1,
      '书架': 1,
      'settings': 2,
      '设置': 2,
      'search': 3,
      '搜索': 3,
    };
    int? index;
    if (tab is int) index = tab;
    if (tab is String) {
      index = int.tryParse(tab) ?? map[tab];
    }
    if (index == null || index < 0 || index > 3) {
      return {'ok': false, 'error': 'tab 取值: 0/1/2 或 browse/library/settings/search'};
    }
    hook('$index');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return {'ok': true, 'tab': index};
  }

  Future<Map<String, dynamic>> _back() async {
    final hook = backHook;
    if (hook != null) {
      final popped = await hook();
      return {'ok': popped, 'popped': popped};
    }
    final nav = navigatorKey.currentState;
    if (nav == null) return {'ok': false, 'error': '无导航器'};
    final popped = await nav.maybePop();
    return {'ok': popped, 'popped': popped};
  }

  Future<void> _screenshot(HttpRequest req, Map<String, String> q) async {
    final ratio = double.tryParse(q['pixelRatio'] ?? '') ?? 1.0;
    final ctx = screenKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is! RenderRepaintBoundary) {
      _json(req, {'ok': false, 'error': '截图边界未就绪'}, 500);
      return;
    }
    final image = await ro.toImage(pixelRatio: ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      _json(req, {'ok': false, 'error': 'PNG 编码失败'}, 500);
      return;
    }
    req.response.headers.contentType = ContentType('image', 'png');
    req.response.add(data.buffer.asUint8List());
    await req.response.close();
  }

  Future<Map<String, dynamic>> _log(Map<String, String> q) async {
    final n = int.tryParse(q['lines'] ?? '') ?? 100;
    return {'ok': true, 'lines': AppLog.tail(n.clamp(1, 2000))};
  }

  void _json(HttpRequest req, Object data, [int status = 200]) {
    req.response.statusCode = status;
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.write(jsonEncode(data));
    req.response.close();
  }
}

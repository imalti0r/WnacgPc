import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

import '../reader/app_log.dart';
import 'sr_shim_ffi.dart';

/// 推理设备：directml（N/A/I 全兼容 GPU）→ cpu（同 DLL 内置 CPU EP）→ unavailable。
enum SrDevice { unavailable, directml, cpu }

/// 模型注册表。scale/输入元素类型由会话探针实测（见 sr_shim.cpp），此处仅承载静态配置。
class SrModel {
  final String id;
  final String asset;
  final int tile; // 输入 tile 边长（像素）
  final int overlap; // 输入 tile 重叠（像素）
  final int expectedScale; // 设计倍率（真实倍率以会话探针为准，用于目标尺寸预计算）
  const SrModel(this.id, this.asset, this.tile, this.overlap,
      {this.expectedScale = 2});

  static const anime = SrModel(
      'anime', 'assets/sr_models/2x_AnimeJaNai_HD_V3.1_Balanced.onnx', 512, 16,
      expectedScale: 2);
  static const photo =
      SrModel('photo', 'assets/sr_models/realesr-general-x4v3.onnx', 256, 16,
          expectedScale: 4);

  /// 写真&Cosplay（站点分类 3）用照片模型，其余用动漫模型。
  static SrModel pickFor(List<String> categoryIds) =>
      categoryIds.contains('3') ? photo : anime;
}

/// 一页超分结果（RGBA 纹理，所有权归调用方，用后 dispose）。
class SrResult {
  final ui.Image image;
  final int width;
  final int height;
  final String modelId;
  final String device; // 'directml' | 'cpu'
  SrResult(this.image, this.width, this.height, this.modelId, this.device);
}

/// 神经超分引擎：单例。
///
/// 架构：主 isolate 负责 ui 编解码与调度；FFI 推理全部在常驻 worker isolate 内串行执行
///（ORT Run 是同步 C 调用，不能在 UI isolate）。worker 首个会话创建时先试 DirectML、
/// 失败自动落 CPU、再失败上报 unavailable —— 三级降级，任何失败都不抛异常到调用方。
class SrEngine {
  SrEngine._();
  static final SrEngine instance = SrEngine._();

  /// 输出像素上限，与阅读器解码上限（12MP）同口径，防止大页超分打穿内存。
  static const maxOutPixels = 12 * 1000 * 1000;
  // 45s：首次安装后杀软可能全盘扫描 14MB onnxruntime.dll，LoadLibrary 被拖到
  // 数十秒（v1.3.1 首启必失败的实测原因，15s 直接超时且失败被永久缓存）。
  static const _initTimeout = Duration(seconds: 45);
  static const _sessionTimeout = Duration(seconds: 60);
  static const _runTimeout = Duration(seconds: 180);
  static const _retryThrottle = Duration(seconds: 3);

  SrDevice device = SrDevice.unavailable;
  String? initError;

  bool get available => device != SrDevice.unavailable;

  /// 是否已有一次初始化尝试结束（成功或失败）。进行中 UI 显示"初始化中"，
  /// 失败显示"不可用"，两者都允许下次调用重试。
  bool get initialized => _starting == null && _lastAttempt != null;

  Completer<void>? _starting;
  DateTime? _lastAttempt;
  bool _initOk = false;
  ReceivePort? _fromWorker;
  SendPort? _toWorker;
  Isolate? _isolate;
  final Map<int, Completer<Map>> _pendingTasks = {};
  final Map<String, Completer<Map>> _pendingSessions = {};
  final Map<String, int> _scaleCache = {};
  final Map<String, Uint8List?> _modelBytes = {};
  var _taskSeq = 0;

  /// 幂等初始化：拉起 worker 并等待其 ready/裁定。
  /// 成功后不再重复；失败允许后续调用节流重试——首启 LoadLibrary 被杀软
  /// 拖慢等瞬时失败若被永久缓存，本次会话引擎就再也起不来（只能重启应用）。
  Future<void> ensureInit() async {
    if (_initOk) return;
    final inFlight = _starting;
    if (inFlight != null) return inFlight.future;
    final last = _lastAttempt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < _retryThrottle) {
        await Future<void>.delayed(_retryThrottle - elapsed);
      }
    }
    final c = Completer<void>();
    _starting = c;
    _lastAttempt = DateTime.now();
    _startWorker().whenComplete(() {
      _starting = null; // 释放，允许下次失败重试
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  /// 预热指定模型的会话（后台执行，失败静默）。
  Future<void> warm(List<SrModel> models) async {
    try {
      await ensureInit();
      for (final m in models) {
        await _sessionScaleFor(m);
      }
    } catch (e) {
      AppLog.w('fx', '[sr] warm failed: $e');
    }
  }

  /// 超分一页。srcBytes 为原始图片字节；targetW/H 为期望输出尺寸（≤12MP）。
  /// 任何失败（不可用/解码失败/推理失败）返回 null，由调用方回退现有着色器路径。
  Future<SrResult?> upscale({
    required SrModel model,
    required Uint8List srcBytes,
    required int targetW,
    required int targetH,
  }) async {
    try {
      await ensureInit();
      final scale = await _sessionScaleFor(model);
      if (scale == null || !available) return null;
      if (targetW < 16 || targetH < 16 || targetW * targetH > maxOutPixels) return null;
      final inW = (targetW / scale).round(), inH = (targetH / scale).round();
      if (inW < 8 || inH < 8) return null;

      final codec =
          await ui.instantiateImageCodec(srcBytes, targetWidth: inW, targetHeight: inH);
      final frame = await codec.getNextFrame();
      final bd = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      if (bd == null) return null;
      final rgba = bd.buffer.asUint8List();

      final id = ++_taskSeq;
      final reply = await _askTask({
        'op': 'run',
        'id': id,
        'model': model.id,
        'inW': inW,
        'inH': inH,
        'tile': model.tile,
        'overlap': model.overlap,
        'in': rgba,
      }, _runTimeout);
      if (reply == null || reply['err'] != null) {
        if (reply?['err'] != null) {
          AppLog.w('fx', '[sr] run failed: ${reply!['err']}');
        }
        return null;
      }
      final out = reply['out'] as Uint8List;
      final outW = inW * scale, outH = inH * scale;
      final buf = await ui.ImmutableBuffer.fromUint8List(out);
      final desc = ui.ImageDescriptor.raw(buf,
          width: outW, height: outH, pixelFormat: ui.PixelFormat.rgba8888);
      final codec2 = await desc.instantiateCodec();
      final frame2 = await codec2.getNextFrame();
      final img = frame2.image;
      desc.dispose();
      buf.dispose();
      codec2.dispose();
      return SrResult(img, outW, outH, model.id,
          device == SrDevice.directml ? 'directml' : 'cpu');
    } catch (e) {
      AppLog.w('fx', '[sr] upscale failed: $e');
      return null;
    }
  }

  // ---- 内部 ----

  Future<void> _startWorker() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final shimPath = '$exeDir\\sr_shim.dll';
    final ortPath = '$exeDir\\onnxruntime.dll';
    _toWorker = null;
    _fromWorker = ReceivePort();
    final ready = Completer<void>();
    late final StreamSubscription sub;
    sub = _fromWorker!.listen((m) {
      if (m is! Map) return;
      switch (m['op']) {
        case 'ready':
          _toWorker = m['myPort'] as SendPort?;
          if (!ready.isCompleted) ready.complete();
          return;
        case 'status':
          final d = m['device'] as String?;
          device = d == 'directml'
              ? SrDevice.directml
              : d == 'cpu'
                  ? SrDevice.cpu
                  : SrDevice.unavailable;
          initError = m['err'] as String?;
          if (device != SrDevice.unavailable) _initOk = true;
          if (device == SrDevice.unavailable) {
            AppLog.w('fx', '[sr] engine unavailable: ${initError ?? 'unknown'}');
          } else {
            AppLog.i('fx', '[sr] engine ready on $device');
          }
          if (!ready.isCompleted) ready.complete();
          return;
      }
      _route(m);
    }, onDone: () {
      _toWorker = null;
      device = SrDevice.unavailable;
      _initOk = false; // worker 死亡后允许下次调用重新拉起
      initError ??= 'worker exited';
      _failAllPending(initError!);
    });
    try {
      _isolate = await Isolate.spawn(_workerMain, {
        'port': _fromWorker!.sendPort,
        'shim': shimPath,
        'ort': ortPath,
      });
      await ready.future.timeout(_initTimeout);
    } catch (e) {
      initError = '$e';
      device = SrDevice.unavailable;
      AppLog.w('fx', '[sr] init worker failed: $e');
      sub.cancel();
      _fromWorker?.close();
      _fromWorker = null;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
    }
  }

  void _route(dynamic m) {
    if (m is! Map) return;
    switch (m['op']) {
      case 'session':
        final id = m['model'] as String;
        _pendingSessions.remove(id)?.complete(m);
      case 'done':
        final id = m['id'] as int;
        _pendingTasks.remove(id)?.complete(m);
      case 'fail':
        final tid = m['id'] as int?;
        if (tid != null) {
          _pendingTasks.remove(tid)?.complete(m);
        } else {
          _failAllPending(m['err']?.toString() ?? 'failed');
        }
    }
  }

  void _failAllPending(String err) {
    for (final c in _pendingTasks.values) {
      if (!c.isCompleted) c.complete({'op': 'fail', 'err': err});
    }
    _pendingTasks.clear();
    for (final c in _pendingSessions.values) {
      if (!c.isCompleted) c.complete({'op': 'sessionFail', 'err': err});
    }
    _pendingSessions.clear();
  }

  Future<Map?> _askTask(Map msg, Duration timeout) async {
    final id = msg['id'] as int;
    final c = Completer<Map>();
    _pendingTasks[id] = c;
    _toWorker?.send(msg);
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      AppLog.w('fx', '[sr] task $id timeout');
      _pendingTasks.remove(id);
      return null;
    }
  }

  Future<int?> _sessionScaleFor(SrModel model) async {
    final cached = _scaleCache[model.id];
    if (cached != null) return cached;
    if (!_modelBytes.containsKey(model.asset)) {
      _modelBytes[model.asset] = _loadAssetSync(model.asset);
    }
    final bytes = _modelBytes[model.asset];
    if (bytes == null) {
      AppLog.w('fx', '[sr] model asset missing: ${model.asset}');
      _modelBytes[model.asset] = Uint8List(0); // 不再重复尝试
      return null;
    }
    if (bytes.isEmpty) return null; // 此前已判定缺失
    var c = _pendingSessions[model.id];
    if (c == null) {
      c = Completer<Map>();
      _pendingSessions[model.id] = c;
      _toWorker?.send({'op': 'session', 'model': model.id, 'bytes': bytes});
    }
    // 并发调用者共用同一 completer：此前第二个调用会覆盖第一个的等待器并
    // 重复发请求，先到者挂到 60s 超时（预热与首页预取并发时的真实竞态）。
    Map? reply;
    try {
      reply = await c.future.timeout(_sessionTimeout);
    } on TimeoutException {
      AppLog.w('fx', '[sr] session ${model.id} timeout');
      if (identical(_pendingSessions[model.id], c)) {
        if (!c.isCompleted) {
          c.complete({'op': 'session', 'model': model.id, 'scale': null, 'err': 'timeout'});
        }
        _pendingSessions.remove(model.id); // 允许后续重发
      }
      return null;
    }
    final scale = reply['scale'] as int?;
    if (scale == null || scale < 1 || scale > 8) {
      AppLog.w('fx', '[sr] session ${model.id} failed: ${reply['err']}');
      return null;
    }
    _scaleCache[model.id] = scale;
    return scale;
  }

  /// 模型字节：打包后位于 data/flutter_assets/<模型相对路径>，直接读文件（worker 不可用 rootBundle）。
  static Uint8List? _loadAssetSync(String asset) {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final f = File('$exeDir\\data\\flutter_assets\\$asset');
      if (f.existsSync()) return f.readAsBytesSync();
      return null;
    } catch (_) {
      return null;
    }
  }
}

// ---- worker isolate ----
// 协议：worker 收 {op:session|run}，应答 {op:session|done|fail|status} 回主端口。
// 消息逐条同步处理 ⇒ 天然串行队列。

void _workerMain(Map init) {
  final mainPort = init['port'] as SendPort;
  final shimPath = init['shim'] as String;
  final ortPath = init['ort'] as String;

  SrShim? shim;
  try {
    if (!File(shimPath).existsSync() || !File(ortPath).existsSync()) {
      mainPort.send({'op': 'status', 'device': 'unavailable', 'err': 'runtime dlls missing'});
      return;
    }
    shim = SrShim.open(shimPath);
    final pOrt = ortPath.toNativeUtf16();
    final rc = shim.init(pOrt);
    malloc.free(pOrt);
    if (rc != 0) {
      mainPort.send({'op': 'status', 'device': 'unavailable', 'err': shim.lastErrorText});
      return;
    }
  } catch (e) {
    mainPort.send({'op': 'status', 'device': 'unavailable', 'err': '$e'});
    return;
  }

  final inbox = ReceivePort();
  mainPort.send({'op': 'ready', 'myPort': inbox.sendPort});

  var useDml = true;
  var deviceDecided = false;
  final sessions = <String, ffi.Pointer<SrSessionInfo>>{};

  // 会话创建：返回 (会话指针, 失败原因)。指针为 nullptr 表示失败。
  (ffi.Pointer<SrSessionInfo>, String) createSession(Uint8List bytes, int dml) {
    final p = malloc<ffi.Uint8>(bytes.length);
    p.asTypedList(bytes.length).setAll(0, bytes);
    final info = malloc<SrSessionInfo>();
    final rc = shim!.createSession(p, bytes.length, dml, info);
    malloc.free(p);
    if (rc != 0) {
      final err = shim.lastErrorText;
      malloc.free(info);
      return (ffi.nullptr, err);
    }
    return (info, '');
  }

  inbox.listen((m) {
    try {
      if (m is! Map) return;
      switch (m['op'] as String) {
        case 'session':
          final id = m['model'] as String;
          final bytes = m['bytes'] as Uint8List;
          if (sessions.containsKey(id)) {
            final scale = sessions[id]!.ref.scale;
            mainPort.send({'op': 'session', 'model': id, 'scale': scale});
            return;
          }
          ffi.Pointer<SrSessionInfo> info = ffi.nullptr;
          var err = '';
          if (!deviceDecided || useDml) {
            (info, err) = createSession(bytes, 1);
            if (info != ffi.nullptr) {
              deviceDecided = true;
              useDml = true;
              mainPort.send({'op': 'status', 'device': 'directml', 'err': null});
            }
          }
          if (info == ffi.nullptr && (!deviceDecided || !useDml)) {
            final dmlErr = err;
            (info, err) = createSession(bytes, 0);
            if (info != ffi.nullptr) {
              deviceDecided = true;
              useDml = false;
              mainPort.send({'op': 'status', 'device': 'cpu', 'err': null});
            } else if (!deviceDecided) {
              mainPort.send({
                'op': 'status',
                'device': 'unavailable',
                'err': 'dml: $dmlErr | cpu: $err'
              });
            }
          }
          if (info == ffi.nullptr) {
            mainPort.send({'op': 'session', 'model': id, 'scale': null, 'err': err});
            return;
          }
          sessions[id] = info;
          mainPort.send({
            'op': 'session',
            'model': id,
            'scale': info.ref.scale,
            'half': info.ref.inputIsHalf
          });
        case 'run':
          final id = m['id'] as int;
          final model = m['model'] as String;
          final info = sessions[model];
          if (info == null || info.ref.session == ffi.nullptr) {
            mainPort.send({'op': 'fail', 'id': id, 'err': 'session $model not ready'});
            return;
          }
          final inW = m['inW'] as int, inH = m['inH'] as int;
          final scale = info.ref.scale;
          final rgba = m['in'] as Uint8List;
          final outW = inW * scale, outH = inH * scale;
          final pIn = malloc<ffi.Uint8>(rgba.length);
          final pOut = malloc<ffi.Uint8>(outW * outH * 4);
          try {
            pIn.asTypedList(rgba.length).setAll(0, rgba);
            final rc = shim!.run(info, inW, inH, pIn, pOut, m['tile'] as int,
                m['overlap'] as int);
            if (rc == 0) {
              final out = Uint8List.fromList(pOut.asTypedList(outW * outH * 4));
              mainPort.send({'op': 'done', 'id': id, 'out': out});
            } else {
              mainPort.send({'op': 'fail', 'id': id, 'err': shim.lastErrorText});
            }
          } catch (e) {
            mainPort.send({'op': 'fail', 'id': id, 'err': '$e'});
          } finally {
            malloc.free(pIn);
            malloc.free(pOut);
          }
      }
    } catch (e) {
      mainPort.send({'op': 'fail', 'err': '$e'});
    }
  });
}

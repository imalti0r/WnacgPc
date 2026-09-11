// 画质增强引擎：GPU 片段着色器（FragmentProgram）+ toImageSync 纹理链。
// pass 顺序：FSR（EASU 上采样 + RCAS 锐化，输出 src*scale 纹理）→ Anime4K（1:1 线条增强）。
// 结果按 (参数, 源图) 缓存；换参/换页时淘汰最旧条目（不主动 dispose，
// 交由 GC finalizer 回收，避免 double-dispose 崩溃，量级可控）。
// ⚠ apply 的返回值与缓存条目是同一对象，且可能同时被多个页面组件共享——
// 调用方只许持有引用，绝不 dispose，否则共享方会绘制已释放纹理导致原生崩溃。
import 'dart:ui' as ui;

import 'app_log.dart';
import 'models.dart';

/// 一次处理的完整参数（值相等即视为同一参数，避免缓存反复失效）。
class FxParams {
  const FxParams({
    required this.a4k,
    required this.a4kStrength,
    required this.a4kEdge,
    required this.fsr,
    required this.fsrScale,
    required this.rcas,
    required this.photo,
    required this.photoScale,
    required this.photoSharp,
    required this.photoGate,
    this.neural = false,
  });

  factory FxParams.fromSettings(AppSettings s) => FxParams(
        a4k: s.fxA4k,
        a4kStrength: s.fxA4kStrength,
        a4kEdge: s.fxA4kEdge,
        fsr: s.fxFsr,
        fsrScale: s.fxFsrScale,
        rcas: s.fxRcas,
        photo: s.fxPhoto,
        photoScale: s.fxPhotoScale,
        photoSharp: s.fxPhotoSharp,
        photoGate: s.fxPhotoGate,
        neural: s.fxNeural,
      );

  final bool a4k;
  final double a4kStrength;
  final double a4kEdge;
  final bool fsr;
  final double fsrScale;
  final double rcas;
  // 照片超分（Lanczos3 + 噪点门控锐化）：与 fsr 同为上采样，引擎内互斥，
  // photo 优先；UI 层切换时联动关闭另一方。
  final bool photo;
  final double photoScale;
  final double photoSharp;
  final double photoGate; // UI 值 0..1，传给着色器前映射为 luma 门限 *0.12
  // 神经超分（ONNX 推理，SR 就绪页跳过放大着色器防双重放大）。
  // 不与 fsr/photo 互斥：未就绪页仍走现有着色器路径（渐进式替换）。
  final bool neural;

  bool get enabled => a4k || fsr || photo || neural;

  /// 神经超分就绪页使用的参数：关闭放大类 pass，仅保留 a4k 线条增强。
  FxParams get withoutUpscale => copyWith(fsr: false, photo: false);

  /// 仅覆盖非 null 字段（UI 滑杆/开关局部更新用）。
  FxParams copyWith({
    bool? a4k,
    double? a4kStrength,
    double? a4kEdge,
    bool? fsr,
    double? fsrScale,
    double? rcas,
    bool? photo,
    double? photoScale,
    double? photoSharp,
    double? photoGate,
    bool? neural,
  }) =>
      FxParams(
        a4k: a4k ?? this.a4k,
        a4kStrength: a4kStrength ?? this.a4kStrength,
        a4kEdge: a4kEdge ?? this.a4kEdge,
        fsr: fsr ?? this.fsr,
        fsrScale: fsrScale ?? this.fsrScale,
        rcas: rcas ?? this.rcas,
        photo: photo ?? this.photo,
        photoScale: photoScale ?? this.photoScale,
        photoSharp: photoSharp ?? this.photoSharp,
        photoGate: photoGate ?? this.photoGate,
        neural: neural ?? this.neural,
      );

  @override
  bool operator ==(Object other) =>
      other is FxParams &&
      other.a4k == a4k &&
      other.a4kStrength == a4kStrength &&
      other.a4kEdge == a4kEdge &&
      other.fsr == fsr &&
      other.fsrScale == fsrScale &&
      other.rcas == rcas &&
      other.photo == photo &&
      other.photoScale == photoScale &&
      other.photoSharp == photoSharp &&
      other.photoGate == photoGate &&
      other.neural == neural;

  @override
  int get hashCode => Object.hash(a4k, a4kStrength, a4kEdge, fsr, fsrScale, rcas, photo,
      photoScale, photoSharp, photoGate, neural);
}

class FxEngine {
  FxEngine._();

  static final FxEngine instance = FxEngine._();

  ui.FragmentProgram? _fsr;
  ui.FragmentProgram? _a4k;
  ui.FragmentProgram? _photo;
  bool _loadFailed = false;
  bool _loaded = false;

  final Map<Object, ui.Image> _cache = {};
  // 缓存条目上限：单条输出纹理可达数十至百余 MB（受限大图），条数必须小
  static const _cacheCap = 4;

  bool get available => !_loadFailed;

  Future<void> _ensurePrograms() async {
    if (_loaded || _loadFailed) return;
    try {
      _fsr = await ui.FragmentProgram.fromAsset('shaders/fsr.frag');
      _a4k = await ui.FragmentProgram.fromAsset('shaders/a4k.frag');
      _photo = await ui.FragmentProgram.fromAsset('shaders/photo.frag');
      _loaded = true;
      AppLog.i('fx', '着色器加载完成');
    } catch (e, st) {
      _loadFailed = true;
      AppLog.e('fx', '着色器加载失败（滤镜将回退原图）', e, st);
    }
  }

  /// 处理一张页面图。未开启任何滤镜返回 null（调用方直接用原图）。
  /// 着色器加载失败时也返回 null，保证阅读器永不因滤镜挂掉。
  /// 已加载时本方法在首个 await 前同步完成全部着色器工作，
  /// src 不存在"await 期间被调用方 dispose、随后才被着色器引用"的窗口。
  Future<ui.Image?> apply(ui.Image src, FxParams p) async {
    if (!p.enabled) return null;
    // 保险：超大源图（>24MP）上采样会产生 GB 级输出纹理，直接跳过
    // （正常路径已在上游解码时限制到 12MP，这里兜底防绕过）
    if (src.width * src.height > 24 * 1000 * 1000) {
      AppLog.w('fx', '源图过大 ${src.width}x${src.height}，跳过画质增强');
      return null;
    }
    if (!_loaded) {
      await _ensurePrograms();
      if (_loadFailed) return null;
    }

    final key = Object.hash(p, src);
    final hit = _cache[key];
    if (hit != null) return hit;

    ui.Image cur = src;
    // 上采样互斥：照片超分优先（两条同时开启时只跑 photo，避免输出分辨率翻倍）
    if (p.photo && _photo != null) {
      cur = _pass(_photo!, cur, (cur.width * p.photoScale).round(), (cur.height * p.photoScale).round(), [
        p.photoSharp,
        p.photoGate * 0.12,
      ]);
    } else if (p.fsr && _fsr != null) {
      cur = _pass(_fsr!, cur, (cur.width * p.fsrScale).round(), (cur.height * p.fsrScale).round(), [
        p.rcas,
      ]);
    }
    if (p.a4k && _a4k != null) {
      cur = _pass(_a4k!, cur, cur.width, cur.height, [
        p.a4kStrength,
        p.a4kEdge,
      ]);
    }

    _cache[key] = cur;
    while (_cache.length > _cacheCap) {
      _cache.remove(_cache.keys.first);
    }
    return cur;
  }

  /// 把 [input] 经着色器画到 dw×dh 的 GPU 纹理上。
  /// 耗时超过 80ms 时记录警告（慢通道是定位卡顿/卡死的重要线索）。
  ui.Image _pass(ui.FragmentProgram prog, ui.Image input, int dw, int dh, List<double> params) {
    if (dw < 1) dw = 1; // 防御：尺寸来自已解码图片，兜底避免 0 尺寸纹理
    if (dh < 1) dh = 1;
    final sw = Stopwatch()..start();
    final shader = prog.fragmentShader();
    shader.setImageSampler(0, input);
    var fi = 0;
    shader.setFloat(fi++, input.width.toDouble());
    shader.setFloat(fi++, input.height.toDouble());
    shader.setFloat(fi++, dw.toDouble());
    shader.setFloat(fi++, dh.toDouble());
    for (final v in params) {
      shader.setFloat(fi++, v);
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, dw.toDouble(), dh.toDouble()));
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, dw.toDouble(), dh.toDouble()), ui.Paint()..shader = shader);
    final img = recorder.endRecording().toImageSync(dw, dh);
    sw.stop();
    if (sw.elapsedMilliseconds > 80) {
      AppLog.w('fx', '慢通道 ${input.width}x${input.height}→$dw×$dh 耗时=${sw.elapsedMilliseconds}ms');
    }
    return img;
  }
}

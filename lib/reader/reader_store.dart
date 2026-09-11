import 'dart:convert';
import 'dart:io';

import '../models/models.dart' as w;
import '../state/app_store.dart';
import '../state/data_dirs.dart';
import 'models.dart' as r;

/// mihon_fx 阅读器所需的存储适配层：
/// - 阅读偏好（方向/布局/适应/画质增强参数）持久化到 `reader_settings.json`；
/// - 阅读进度写回 WnacgPc 的 AppStore 阅读历史（用于"继续阅读"与徽标）。
/// 进度API带总页数（[updateProgress] 第4参），这是对原 reader_page 的最小改动。
class ReaderStore {
  ReaderStore._();
  static final ReaderStore instance = ReaderStore._();

  r.AppSettings settings = r.AppSettings();
  w.GalleryItem? _item;

  /// 打开阅读器前绑定当前画廊，进度记录用
  void bind(w.GalleryItem item) => _item = item;

  /// 在线阅读预加载页数（设置里的"在线阅读预加载页数"，0=关闭）
  int get preloadPages => AppStore.instance.preloadDistance.round();

  Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        settings = r.AppSettings.fromJson(
            jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      }
    } catch (_) {}
  }

  Future<File> _file() async {
    return File(DataDirs.instance.file('reader_settings.json'));
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(settings.toJson()));
    } catch (_) {}
  }

  void setDefaultMode(r.ReadingMode m) {
    settings.defaultMode = m;
    _save();
  }

  void setDefaultLayout(r.PageLayout l) {
    settings.defaultLayout = l;
    _save();
  }

  void setDefaultFit(r.PageFit f) {
    settings.defaultFit = f;
    _save();
  }

  // ---------- 画质增强参数 ----------
  void setFxA4k(bool v) {
    settings.fxA4k = v;
    _save();
  }

  void setFxA4kStrength(double v) {
    settings.fxA4kStrength = v;
    _save();
  }

  void setFxA4kEdge(double v) {
    settings.fxA4kEdge = v;
    _save();
  }

  void setFxFsr(bool v) {
    settings.fxFsr = v;
    _save();
  }

  void setFxFsrScale(double v) {
    settings.fxFsrScale = v;
    _save();
  }

  void setFxRcas(double v) {
    settings.fxRcas = v;
    _save();
  }

  void setFxPhoto(bool v) {
    settings.fxPhoto = v;
    _save();
  }

  void setFxPhotoScale(double v) {
    settings.fxPhotoScale = v;
    _save();
  }

  void setFxPhotoSharp(double v) {
    settings.fxPhotoSharp = v;
    _save();
  }

  void setFxPhotoGate(double v) {
    settings.fxPhotoGate = v;
    _save();
  }

  void setFxNeural(bool v) {
    settings.fxNeural = v;
    _save();
  }

  void setFxNeuralScale(double v) {
    settings.fxNeuralScale = v;
    _save();
  }

  void setFxNeuralTile(int v) {
    settings.fxNeuralTile = v;
    _save();
  }

  void setFxNeuralOverlap(int v) {
    settings.fxNeuralOverlap = v;
    _save();
  }

  /// 进度 → WnacgPc 阅读历史（原签名增加总页数参数）
  void updateProgress(String mangaId, int ch, int page, [int total = 0]) {
    final item = _item;
    if (item == null) return;
    AppStore.instance.recordHistory(item, page, total);
  }

  /// 阅读器退出时立即落盘（AppStore 已即时写盘，无需额外操作）
  void flushSave() {}

  /// "重新扫描"按钮：WnacgPc 无本地库扫描，重开章节即视为刷新
  Future<void> rescanManga(r.Manga manga) async {}
}

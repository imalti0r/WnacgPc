import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/wnacg_api.dart';
import '../models/models.dart';
import 'data_dirs.dart';

/// 一条历史记录
class HistoryEntry {
  GalleryItem item;
  int lastPage; // 阅读到的页索引（0 基）
  int totalPages;
  DateTime updatedAt;

  HistoryEntry({
    required this.item,
    required this.lastPage,
    required this.totalPages,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'item': item.toJson(),
        'lastPage': lastPage,
        'totalPages': totalPages,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        item: GalleryItem.fromJson(j['item'] as Map<String, dynamic>),
        lastPage: (j['lastPage'] ?? 0) as int,
        totalPages: (j['totalPages'] ?? 0) as int,
        updatedAt: DateTime.fromMillisecondsSinceEpoch((j['updatedAt'] ?? 0) as int),
      );
}

/// 全局状态：收藏 / 历史 / 设置，JSON 文件持久化
class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore instance = AppStore._();

  final List<GalleryItem> _favorites = [];
  final List<HistoryEntry> _history = [];

  bool darkMode = true;
  double preloadDistance = 5; // 在线阅读预加载页数
  bool zipDownloads = false; // 下载保存为 ZIP（否则为文件夹）
  bool debugEnabled = true; // 本地调试 HTTP 接口
  int debugPort = 18080;
  /// 图片磁盘缓存大小上限（MB），0=不限制；超限自动从最旧文件清理
  int imageCacheMaxMb = 2048;

  /// 缓存上限可选项（MB）。加载与写入都 snap 到这些值，保证设置页
  /// 下拉显示的值与实际生效值一致（旧配置/手改值不在选项内时收敛）。
  static const List<int> imageCacheLimitOptions = [0, 512, 1024, 2048, 4096, 8192];

  static int snapImageCacheLimit(int v) {
    var best = imageCacheLimitOptions.first;
    for (final o in imageCacheLimitOptions) {
      if (o <= v) best = o;
    }
    return best;
  }

  List<GalleryItem> get favorites => List.unmodifiable(_favorites);
  List<HistoryEntry> get history => List.unmodifiable(_history);

  bool isFavorite(String aid) => _favorites.any((e) => e.aid == aid);

  HistoryEntry? historyOf(String aid) {
    for (final h in _history) {
      if (h.item.aid == aid) return h;
    }
    return null;
  }

  Future<File> _file(String name) async {
    return File(DataDirs.instance.file('$name.json'));
  }

  Future<void> load() async {
    try {
      final f = await _file('favorites');
      if (await f.exists()) {
        final list = (jsonDecode(await f.readAsString()) as List)
            .map((e) => GalleryItem.fromJson(e as Map<String, dynamic>))
            .toList();
        _favorites
          ..clear()
          ..addAll(list);
      }
    } catch (_) {}
    try {
      final f = await _file('history');
      if (await f.exists()) {
        final list = (jsonDecode(await f.readAsString()) as List)
            .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        _history
          ..clear()
          ..addAll(list);
      }
    } catch (_) {}
    try {
      final f = await _file('settings');
      if (await f.exists()) {
        final s = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final base = s['baseUrl'] as String?;
        if (base != null && base.isNotEmpty) WnacgApi.instance.baseUrl = base;
        darkMode = (s['darkMode'] ?? true) as bool;
        preloadDistance = normalizeOddPreload(
            ((s['preloadDistance'] ?? 5) as num).toDouble());
        zipDownloads = (s['zipDownloads'] ?? false) as bool;
        debugEnabled = (s['debugEnabled'] ?? true) as bool;
        debugPort = (s['debugPort'] ?? 18080) as int;
        imageCacheMaxMb =
            snapImageCacheLimit(((s['imageCacheMaxMb'] ?? 2048) as num).toInt());
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _saveFavorites() async {
    final f = await _file('favorites');
    await f.writeAsString(jsonEncode(_favorites.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveHistory() async {
    final f = await _file('history');
    await f.writeAsString(jsonEncode(_history.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveSettings() async {
    final f = await _file('settings');
    await f.writeAsString(jsonEncode({
      'baseUrl': WnacgApi.instance.baseUrl,
      'darkMode': darkMode,
      'preloadDistance': preloadDistance,
      'zipDownloads': zipDownloads,
      'debugEnabled': debugEnabled,
      'debugPort': debugPort,
      'imageCacheMaxMb': imageCacheMaxMb,
    }));
  }

  /// 设置图片缓存大小上限（MB，0=不限）。是否立即按上限清理由调用方决定
  /// （避免 app_store 依赖图片桥）。
  Future<void> setImageCacheMaxMb(int v) async {
    imageCacheMaxMb = snapImageCacheLimit(v < 0 ? 0 : v);
    await _saveSettings();
    notifyListeners();
  }

  Future<void> toggleFavorite(GalleryItem item) async {
    if (isFavorite(item.aid)) {
      _favorites.removeWhere((e) => e.aid == item.aid);
    } else {
      _favorites.removeWhere((e) => e.aid == item.aid);
      _favorites.insert(0, item);
    }
    await _saveFavorites();
    notifyListeners();
  }

  Future<void> removeFavorite(String aid) async {
    _favorites.removeWhere((e) => e.aid == aid);
    await _saveFavorites();
    notifyListeners();
  }

  Future<void> recordHistory(GalleryItem item, int page, int total) async {
    _history.removeWhere((e) => e.item.aid == item.aid);
    _history.insert(
        0,
        HistoryEntry(
          item: item,
          lastPage: page,
          totalPages: total,
          updatedAt: DateTime.now(),
        ));
    if (_history.length > 200) _history.removeRange(200, _history.length);
    await _saveHistory();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _saveHistory();
    notifyListeners();
  }

  Future<void> setDarkMode(bool v) async {
    darkMode = v;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setPreloadDistance(double v) async {
    preloadDistance = normalizeOddPreload(v);
    await _saveSettings();
    notifyListeners();
  }

  /// 预加载页数恒为奇数（双向缓冲要求向后比向前多 1，N 奇数才能对半分）。
  /// 0=关闭（仅当前屏）；偶数向下收敛到最近奇数（旧配置兼容，20→19）。
  static double normalizeOddPreload(double v) {
    final i = v.round();
    if (i <= 0) return 0;
    return (i.isEven ? i - 1 : i).toDouble();
  }

  Future<void> setZipDownloads(bool v) async {
    zipDownloads = v;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setBaseUrl(String url) async {
    WnacgApi.instance.baseUrl = url;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setDebugEnabled(bool v) async {
    debugEnabled = v;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setDebugPort(int v) async {
    debugPort = v;
    await _saveSettings();
    notifyListeners();
  }
}

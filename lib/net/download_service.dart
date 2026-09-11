import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../reader/app_log.dart';
import '../state/app_store.dart';
import '../state/data_dirs.dart';
import 'image_bridge.dart';

enum DownloadStatus { queued, running, done, failed }

/// 单本下载任务
class DownloadTask {
  final GalleryItem item;
  final List<ReaderImage> images;
  final bool asZip; // 完成后打包为 ZIP
  int downloaded = 0;
  DownloadStatus status = DownloadStatus.queued;
  String? error;
  bool abort = false;

  DownloadTask(this.item, this.images, {this.asZip = false});

  double get progress =>
      images.isEmpty ? 0 : (downloaded / images.length).clamp(0, 1);
}

/// 已完成的下载记录（持久化）
class DownloadedInfo {
  final GalleryItem item;
  final String dir; // 文件夹模式为页面目录；ZIP 模式为所在目录（无页面文件）
  final int count;
  final bool isZip;
  final String? zipPath;

  /// true = 站点官方预打包 ZIP（爬取打包下载）；false = 本应用逐页取图
  final bool official;

  DownloadedInfo({
    required this.item,
    required this.dir,
    required this.count,
    this.isZip = false,
    this.zipPath,
    this.official = false,
  });

  Map<String, dynamic> toJson() => {
        'item': item.toJson(),
        'dir': dir,
        'count': count,
        'isZip': isZip,
        'zipPath': zipPath,
        'official': official,
      };

  factory DownloadedInfo.fromJson(Map<String, dynamic> j) => DownloadedInfo(
        item: GalleryItem.fromJson(j['item'] as Map<String, dynamic>),
        dir: (j['dir'] ?? '') as String,
        count: (j['count'] ?? 0) as int,
        isZip: (j['isZip'] ?? false) as bool,
        zipPath: j['zipPath'] as String?,
        official: (j['official'] ?? false) as bool,
      );
}

/// 下载服务：整本排队、逐页下载（复用图片桥绕过 CDN 指纹拦截）、
/// 断点续传（已存在的文件跳过）、完成后注册为离线可读。
/// ZIP 模式：页面先写入 `<root>/<aid>.part/` 临时目录（同样支持续传），
/// 全部完成后打包为 `<root>/<净化标题>.zip` 并删除临时目录。
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  final Map<String, DownloadTask> _tasks = {}; // aid → 活动任务
  final Map<String, DownloadedInfo> _registry = {}; // aid → 已完成
  bool _pumping = false;
  Directory? _rootDir;
  File? _registryFile;

  List<DownloadTask> get activeTasks => _tasks.values.toList();
  List<DownloadedInfo> get downloads => _registry.values.toList();

  DownloadTask? taskOf(String aid) => _tasks[aid];
  DownloadedInfo? infoOf(String aid) => _registry[aid];
  bool isDownloaded(String aid) => _registry.containsKey(aid);

  Future<void> load() async {
    // v1 的下载目录在 Documents/WnacgPc/downloads，DataDirs.init 已自动并入
    _rootDir = Directory(DataDirs.instance.downloadsPath);
    await _rootDir!.create(recursive: true);
    _registryFile = File('${_rootDir!.path}/downloads.json');
    if (await _registryFile!.exists()) {
      try {
        final list = (jsonDecode(await _registryFile!.readAsString()) as List)
            .map((e) => DownloadedInfo.fromJson(e as Map<String, dynamic>));
        for (final info in list) {
          _registry[info.item.aid] = info;
        }
      } catch (_) {}
    }
    await _migrateLegacyZipNames();
    notifyListeners();
  }

  /// 旧版 ZIP 用 `<净化标题>.zip` 命名；统一迁移为 `<aid>-<标题>.zip`
  /// 并改写注册表（迁移目录时的前缀改写不受影响，仍是整路径替换）。
  Future<void> _migrateLegacyZipNames() async {
    var changed = false;
    for (final info in _registry.values.toList()) {
      if (!info.isZip || info.zipPath == null) continue;
      final old = info.zipPath!;
      // 根目录之外的 zip（迁移导入的外部文件）不在改名范围内，
      // 否则每次 load 都会对 E: 等外部路径发起跨盘 rename 必败
      final rootN = _rootDir!.path.replaceAll('\\', '/');
      final oldN = old.replaceAll('\\', '/');
      if (!oldN.startsWith('$rootN/')) continue;
      final next = zipPathFor(info.item);
      if (old == next) continue;
      final oldFile = File(old);
      final nextFile = File(next);
      try {
        if (await oldFile.exists()) {
          if (!await nextFile.exists()) {
            await oldFile.rename(next);
          } else {
            await oldFile.delete(); // 新名已存在（同 aid 重复下载过），去重
          }
        } else if (!await nextFile.exists()) {
          continue; // 两边都没有：保留原记录，zipOf 会按存在性兜底
        }
      } catch (e) {
        AppLog.w('下载', '迁移 ZIP 命名失败 ${info.item.aid}: $e');
        continue;
      }
      _registry[info.item.aid] = DownloadedInfo(
        item: info.item,
        dir: info.dir,
        count: info.count,
        isZip: true,
        zipPath: next,
        official: info.official,
      );
      changed = true;
      AppLog.i('下载', 'ZIP 改名 ${_baseName(old)} -> ${_baseName(next)}');
    }
    if (changed) await _saveRegistry();
  }

  static String _baseName(String p) =>
      p.replaceAll('\\', '/').split('/').last;

  String dirFor(String aid) => '${_rootDir!.path}/$aid';

  /// ZIP 路径：统一 `<aid>-<净化标题>.zip`（漫画 id 前缀，跨列表/收藏稳定）
  String zipPathFor(GalleryItem item) {
    var name = item.title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.length > 60) name = name.substring(0, 60).trim();
    if (name.isEmpty) name = 'wnacg';
    return '${_rootDir!.path}/${item.aid}-$name.zip';
  }

  /// 外部（打包下载服务）注册成品 ZIP：写入注册表并广播。
  Future<void> registerZip(GalleryItem item, String zipPath, int count,
      {bool official = false}) async {
    _registry[item.aid] = DownloadedInfo(
      item: item,
      dir: _rootDir!.path,
      count: count,
      isZip: true,
      zipPath: zipPath,
      official: official,
    );
    await _saveRegistry();
    notifyListeners();
  }

  /// 本地已下载的页文件（按序，仅文件夹模式）
  List<String>? localFilesOf(String aid) {
    final info = _registry[aid];
    if (info == null || info.isZip) return null;
    if (!Directory(info.dir).existsSync()) return null;
    final files = <String>[];
    for (var i = 0; i < info.count; i++) {
      final idx = i.toString().padLeft(5, '0');
      final f = File('${info.dir}/$idx.jpg');
      if (f.existsSync()) {
        files.add(f.path);
      } else {
        return null; // 缺页则视为不完整
      }
    }
    return files;
  }

  /// ZIP 离线信息（仅 ZIP 模式）
  ({String zipPath, int count})? zipOf(String aid) {
    final info = _registry[aid];
    if (info == null || !info.isZip || info.zipPath == null) return null;
    if (!File(info.zipPath!).existsSync()) return null;
    return (zipPath: info.zipPath!, count: info.count);
  }

  /// 入队（images 由调用方先取好；格式取当前设置，对进行中任务不回溯）
  Future<void> enqueue(GalleryItem item, List<ReaderImage> images) async {
    if (_tasks.containsKey(item.aid)) return;
    await load();
    _tasks[item.aid] = DownloadTask(
      item,
      images,
      asZip: AppStore.instance.zipDownloads,
    );
    notifyListeners();
    _pump();
  }

  void retry(String aid) {
    final t = _tasks[aid];
    if (t == null) return;
    t.status = DownloadStatus.queued;
    t.error = null;
    t.abort = false;
    notifyListeners();
    _pump();
  }

  void cancel(String aid) {
    final t = _tasks[aid];
    if (t == null) return;
    t.abort = true;
    if (t.status == DownloadStatus.queued) {
      _tasks.remove(aid);
      notifyListeners();
    }
  }

  Future<void> delete(String aid) async {
    // 先中止并移除活动任务，避免边下载边删目录
    _tasks.remove(aid)?.abort = true;
    final info = _registry.remove(aid);
    final dir = Directory(dirFor(aid));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    // ZIP 模式的临时目录与成品 zip
    final partDir = Directory('${dirFor(aid)}.part');
    if (await partDir.exists()) {
      await partDir.delete(recursive: true);
    }
    if (info?.zipPath != null) {
      final z = File(info!.zipPath!);
      if (await z.exists()) await z.delete();
      // 打包下载的 .part 半成品
      final part = File('${info.zipPath}.part');
      if (await part.exists()) await part.delete();
    }
    await _saveRegistry();
    notifyListeners();
  }

  Future<void> _saveRegistry() async {
    if (_registryFile == null) return;
    await _registryFile!.writeAsString(
        jsonEncode(_registry.values.map((e) => e.toJson()).toList()));
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        DownloadTask? task;
        for (final t in _tasks.values) {
          if (t.status == DownloadStatus.queued) {
            task = t;
            break;
          }
        }
        if (task == null) break;
        await _run(task);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(DownloadTask task) async {
    task.status = DownloadStatus.running;
    notifyListeners();
    final workDir = Directory(
        task.asZip ? '${dirFor(task.item.aid)}.part' : dirFor(task.item.aid));
    await workDir.create(recursive: true);
    try {
      for (var i = 0; i < task.images.length; i++) {
        if (task.abort) throw Exception('已取消');
        final name = i.toString().padLeft(5, '0');
        final target = File('${workDir.path}/$name.jpg');
        if (!await target.exists()) {
          final url = task.images[i].url;
          final bytes = await ImageBridge.instance
              .getBytes(url,
                  cacheId: task.item.aid,
                  cacheName: name) // 缓存与在线阅读共享 <aid>/ 目录
              .timeout(const Duration(seconds: 90));
          final tmp = File('${target.path}.tmp');
          await tmp.writeAsBytes(bytes, flush: true);
          await tmp.rename(target.path);
          // 礼貌性间隔，降低对站点的请求压力
          await Future.delayed(const Duration(milliseconds: 120));
        }
        task.downloaded = i + 1;
        if (task.downloaded % 3 == 0 || task.downloaded == task.images.length) {
          notifyListeners();
        }
      }
      if (task.asZip) {
        final zipPath = zipPathFor(task.item);
        await _packZip(workDir, task.images.length, zipPath);
        await workDir.delete(recursive: true);
        _tasks.remove(task.item.aid);
        _registry[task.item.aid] = DownloadedInfo(
          item: task.item,
          dir: _rootDir!.path,
          count: task.images.length,
          isZip: true,
          zipPath: zipPath,
        );
      } else {
        _tasks.remove(task.item.aid);
        _registry[task.item.aid] = DownloadedInfo(
          item: task.item,
          dir: workDir.path,
          count: task.images.length,
        );
      }
      await _saveRegistry();
      notifyListeners();
    } catch (e) {
      if (task.abort) {
        // 用户取消：直接移除，不留 failed 残留
        _tasks.remove(task.item.aid);
      } else {
        task.status = DownloadStatus.failed;
        task.error = '$e';
      }
      notifyListeners();
    }
  }

  /// 把临时目录里的 00000.jpg… 打包为 ZIP（逐文件流式读写，内存峰值
  /// 只与单页大小相关而非整本；先写 .tmp 再原子改名）
  Future<void> _packZip(Directory workDir, int count, String zipPath) async {
    final tmpPath = '$zipPath.tmp';
    final encoder = ZipFileEncoder();
    encoder.create(tmpPath);
    try {
      for (var i = 0; i < count; i++) {
        final name = i.toString().padLeft(5, '0');
        await encoder.addFile(File('${workDir.path}/$name.jpg'), name);
      }
      await encoder.close();
    } catch (e) {
      try {
        await encoder.close();
      } catch (_) {}
      final tmp = File(tmpPath);
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
    await File(tmpPath).rename(zipPath);
  }
}

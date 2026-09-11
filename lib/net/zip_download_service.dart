// 打包下载服务（移植自 mangareload 的 core/worker.py + app_core.py）：
// 解析站点官方预打包 ZIP 直链（download-index 页 a.ads），用 dart:io
// HttpClient 流式下载到 `<root>/downloads/<aid>-<标题>.zip`，完成注册进
// 下载注册表（离线可读）。.part 临时文件 + 原子改名，限速检测 + 重试 + 取消。
// 直链域（dl*.wn01.download）不校验 TLS 指纹，Dart 可直连（已实测）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/wnacg_api.dart';
import '../models/models.dart';
import '../reader/app_log.dart';
import '../reader/library.dart';
import 'download_service.dart';

enum ZipDownloadStatus { queued, resolving, running, done, failed }

/// 打包下载任务（按字节计进度）
class ZipDownloadTask {
  final GalleryItem item;
  ZipDownloadStatus status = ZipDownloadStatus.queued;
  int downloaded = 0; // 已收字节
  int total = 0; // 总字节（content-length，未知为 0）
  double speed = 0; // B/s
  int attempt = 0;
  int attempts = 3;
  String? error;
  bool abort = false;

  ZipDownloadTask(this.item);

  double get progress => total > 0 ? (downloaded / total).clamp(0, 1) : 0;
}

class ZipDownloadService extends ChangeNotifier {
  ZipDownloadService._();
  static final ZipDownloadService instance = ZipDownloadService._();

  final Map<String, ZipDownloadTask> _tasks = {}; // aid → 任务
  bool _pumping = false;

  List<ZipDownloadTask> get activeTasks => _tasks.values.toList();
  ZipDownloadTask? taskOf(String aid) => _tasks[aid];

  /// 入队打包下载（已下载/逐页任务进行中则忽略）
  Future<void> enqueue(GalleryItem item) async {
    if (_tasks.containsKey(item.aid)) return;
    final dl = DownloadService.instance;
    if (dl.infoOf(item.aid) != null || dl.taskOf(item.aid) != null) return;
    await dl.load();
    _tasks[item.aid] = ZipDownloadTask(item);
    notifyListeners();
    AppLog.i('下载', '打包下载入队 ${item.aid} ${item.title}');
    _pump();
  }

  void retry(String aid) {
    final t = _tasks[aid];
    if (t == null) return;
    t.status = ZipDownloadStatus.queued;
    t.error = null;
    t.abort = false;
    notifyListeners();
    _pump();
  }

  void cancel(String aid) {
    final t = _tasks[aid];
    if (t == null) return;
    t.abort = true;
    if (t.status == ZipDownloadStatus.queued || t.status == ZipDownloadStatus.resolving) {
      _tasks.remove(aid);
      notifyListeners();
    }
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        ZipDownloadTask? task;
        for (final t in _tasks.values) {
          if (t.status == ZipDownloadStatus.queued) {
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

  Future<void> _run(ZipDownloadTask task) async {
    task.status = ZipDownloadStatus.resolving;
    notifyListeners();
    final dl = DownloadService.instance;
    try {
      if (task.abort) throw Exception('已取消');
      final info = await WnacgApi.instance.fetchDownloadInfo(task.item.aid);
      if (task.abort) throw Exception('已取消');
      final zipPath = dl.zipPathFor(task.item);
      // 上次会话可能下完但未注册：成品存在则直接注册
      if (await File(zipPath).exists()) {
        await _register(task, zipPath);
        return;
      }
      task.status = ZipDownloadStatus.running;
      notifyListeners();
      await _streamDownload(task, info.url, zipPath);
      await _register(task, zipPath);
    } catch (e) {
      if (task.abort) {
        _tasks.remove(task.item.aid); // 用户取消：无残留
      } else {
        task.status = ZipDownloadStatus.failed;
        task.error = '$e';
        AppLog.e('下载', '打包下载失败 ${task.item.aid}', e);
      }
      notifyListeners();
    }
  }

  /// 校验成品并注册（页数取自 ZIP 中央目录）
  Future<void> _register(ZipDownloadTask task, String zipPath) async {
    var count = 0;
    try {
      final book = ZipBook(zipPath);
      count = book.pageCount;
      book.close();
    } catch (e) {
      try {
        await File(zipPath).delete();
      } catch (_) {}
      throw Exception('ZIP 校验失败（文件可能损坏）: $e');
    }
    _tasks.remove(task.item.aid);
    await DownloadService.instance
        .registerZip(task.item, zipPath, count, official: true);
    AppLog.i('下载',
        '打包下载完成 ${task.item.aid} · $count 页 · ${(task.downloaded / 1048576).toStringAsFixed(1)} MB');
    notifyListeners();
  }

  /// 带重试的下载（限速/网络错误按退避重试，取消不重试）
  Future<void> _streamDownload(
      ZipDownloadTask task, String url, String zipPath) async {
    const attempts = 3;
    const minSpeed = 0.2 * 1024 * 1024; // 0.2 MB/s
    Object? lastErr;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (task.abort) throw Exception('已取消');
      task.attempt = attempt;
      task.attempts = attempts;
      task.downloaded = 0;
      task.total = 0;
      task.speed = 0;
      notifyListeners();
      try {
        await _tryOnce(task, url, zipPath, minSpeed);
        return;
      } catch (e) {
        if (task.abort) rethrow;
        lastErr = e;
        AppLog.w('下载', '打包下载第 $attempt/$attempts 次失败 ${task.item.aid}: $e');
        if (attempt < attempts) {
          await Future.delayed(Duration(seconds: 5 * attempt));
        }
      }
    }
    throw Exception('重试 $attempts 次仍失败: $lastErr');
  }

  Future<void> _tryOnce(
      ZipDownloadTask task, String url, String zipPath, double minSpeed) async {
    final partPath = '$zipPath.part';
    final partFile = File(partPath);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      final req = await client.getUrl(Uri.parse(url));
      final h = WnacgApi.instance.headers();
      req.headers.set(HttpHeaders.userAgentHeader, h['User-Agent']!);
      req.headers.set(HttpHeaders.refererHeader, h['Referer'] ?? 'https://www.wnacg.com/');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      task.total = res.contentLength > 0 ? res.contentLength : 0;
      sink = partFile.openWrite();
      final sw = Stopwatch()..start();
      var windowStart = 0;
      var windowBytes = 0;
      const windowMs = 3000;
      const minBytesBeforeCheck = 256 * 1024;
      var lastNotify = 0;
      await for (final chunk in res) {
        if (task.abort) throw Exception('已取消');
        sink.add(chunk);
        task.downloaded += chunk.length;
        windowBytes += chunk.length;
        final now = sw.elapsedMilliseconds;
        task.speed = task.downloaded / (now > 0 ? now / 1000 : 0.001);
        // 限速检测：下载到一定量后按窗口速度判断，防死流挂着
        if (minSpeed > 0 &&
            task.downloaded > minBytesBeforeCheck &&
            now - windowStart >= windowMs) {
          final windowSpeed = windowBytes / ((now - windowStart) / 1000);
          if (windowSpeed < minSpeed) {
            throw Exception(
                '速度过低 (${(windowSpeed / 1048576).toStringAsFixed(2)} MB/s)');
          }
          windowStart = now;
          windowBytes = 0;
        }
        if (now - lastNotify >= 150) {
          // 节流广播，避免重建风暴
          lastNotify = now;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (task.total > 0 && task.downloaded != task.total) {
        throw Exception('长度不符 (${task.downloaded}/${task.total})');
      }
      await partFile.rename(zipPath);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

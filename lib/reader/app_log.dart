// 轻量操作日志：环形文件（<数据目录>/logs/app.log，2MB × 5 份轮转）。
// 记录用户操作路径、生命周期与异常，便于事后排查（卡死/闪退直接看日志）。
// 写入策略：普通事件缓冲 500ms 合并落盘；警告/错误立即落盘，尽量保住崩溃前的记录。
import 'dart:async';
import 'dart:io';

class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  IOSink? _sink;
  File? _file;
  final List<String> _buf = <String>[];
  Timer? _flushTimer;
  bool _broken = false;
  static const int _maxBytes = 2 * 1024 * 1024;
  static const int _keepFiles = 4;

  static final Map<String, Timer> _throttleTimers = <String, Timer>{};

  /// [supportDir] = getApplicationSupportDirectory()（与 library.json 同级）。
  static Future<void> initIn(Directory supportDir) async {
    final inst = instance;
    try {
      final logs = Directory('${supportDir.path}${Platform.pathSeparator}logs');
      if (!logs.existsSync()) logs.createSync(recursive: true);
      final cur = File('${logs.path}${Platform.pathSeparator}app.log');
      if (cur.existsSync()) {
        // 上次会话正常退出时最后一行有 session end 标记；没有则提示排查线索
        var clean = false;
        try {
          final lines = cur.readAsLinesSync();
          for (var i = lines.length - 1; i >= 0 && i >= lines.length - 5; i--) {
            if (lines[i].contains('session end')) {
              clean = true;
              break;
            }
          }
        } catch (_) {}
        if (!clean) {
          inst._appendLineSync(cur, _line('W', 'app', '上次会话未正常退出（缺 session end 标记：可能卡死后被关闭/崩溃/被杀）'));
        }
      }
      _rotateFiles(cur.parent, cur);
      inst._file = cur;
      inst._sink = cur.openWrite(mode: FileMode.append);
    } catch (_) {
      inst._broken = true; // 日志不可用时静默降级，绝不影响功能
    }
    i('app', 'session start');
  }

  static void i(String category, String msg) => instance._write('I', category, msg);
  static void w(String category, String msg) => instance._write('W', category, msg);
  static void e(String category, String msg, [Object? error, StackTrace? stack]) {
    var line = msg;
    if (error != null) line += ' | $error';
    instance._write('E', category, line);
    if (stack != null) {
      instance._write('E', category, stack.toString().trimRight());
    }
  }

  /// 高频事件（FX 滑杆拖动等）静默期聚合：静默 800ms 后只记最终值。
  static void throttled(String category, String msg) {
    _throttleTimers[category]?.cancel();
    _throttleTimers[category] = Timer(const Duration(milliseconds: 800), () {
      _throttleTimers.remove(category);
      i(category, msg);
    });
  }

  /// 正常退出标记（窗口关闭时调用）。
  static void sessionEnd([String reason = '窗口关闭']) {
    i('app', 'session end ($reason)');
    instance._flush();
  }

  /// 数据目录迁移时切换日志目录（先关旧 sink，再在新位置续写）。
  static Future<void> switchDir(Directory dir) async {
    final inst = instance;
    try {
      inst._flush();
      try {
        await inst._sink?.close();
      } catch (_) {}
      inst._sink = null;
      final logs = Directory('${dir.path}${Platform.pathSeparator}logs');
      if (!logs.existsSync()) logs.createSync(recursive: true);
      inst._file = File('${logs.path}${Platform.pathSeparator}app.log');
      inst._broken = false;
      inst._sink = inst._file!.openWrite(mode: FileMode.append);
    } catch (_) {
      inst._broken = true;
    }
    i('app', 'log dir switched to ${dir.path}');
  }

  /// 读最近 [n] 行日志（调试接口用）。
  static List<String> tail(int n) {
    final f = instance._file;
    if (f == null || !f.existsSync()) return const [];
    try {
      final lines = f.readAsLinesSync();
      if (lines.length <= n) return lines;
      return lines.sublist(lines.length - n);
    } catch (_) {
      return const [];
    }
  }

  static String _line(String level, String category, String msg) {
    return '${DateTime.now().toIso8601String()} [$level][$category] $msg';
  }

  void _appendLineSync(File f, String line) {
    try {
      f.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  void _write(String level, String category, String msg) {
    final line = _line(level, category, msg);
    if (_broken) return;
    _buf.add(line);
    if (level != 'I') {
      _flush();
      return;
    }
    _flushTimer ??= Timer(const Duration(milliseconds: 500), _flush);
    final f = _file;
    if (f != null && _sink != null) {
      try {
        if (f.lengthSync() > _maxBytes) _rotate();
      } catch (_) {}
    }
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final sink = _sink;
    if (sink == null) return; // 轮转进行中：内容留在缓冲，完成后补写
    if (_buf.isEmpty) return;
    final out = _buf.join('\n');
    _buf.clear();
    try {
      sink.writeln(out);
      sink.flush();
    } catch (_) {
      // 一次写失败曾永久 _broken（之后所有日志静默丢失，排查无从下手）。
      // 改为丢弃本轮并重开 sink，下次写入自动重试；连续 5 次失败才降级。
      _retries++;
      _buf.clear();
      _broken = _retries >= 5;
      if (!_broken) {
        try {
          _sink?.close();
        } catch (_) {}
        _sink = null;
        _reopener ??= Timer(const Duration(milliseconds: 1500), _reopenSink);
      }
    }
  }

  Timer? _reopener;
  int _retries = 0;

  void _reopenSink() {
    _reopener = null;
    final f = _file;
    if (f == null || _sink != null) return;
    try {
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      _sink = f.openWrite(mode: FileMode.append);
      _broken = false;
      _retries = 0;
      _flush(); // 补写重开期间积压的日志
    } catch (_) {
      _broken = _retries >= 5;
      if (!_broken) {
        _reopener = Timer(const Duration(milliseconds: 1500), _reopenSink);
      }
    }
  }

  static void _rotateFiles(Directory logs, File cur) {
    for (var i = _keepFiles - 1; i >= 1; i--) {
      final src = File('${logs.path}${Platform.pathSeparator}app-$i.log');
      final dst = File('${logs.path}${Platform.pathSeparator}app-${i + 1}.log');
      if (!src.existsSync()) continue;
      if (i == _keepFiles - 1) {
        try {
          src.deleteSync();
        } catch (_) {}
      } else {
        try {
          src.renameSync(dst.path);
        } catch (_) {}
      }
    }
    if (cur.existsSync()) {
      try {
        cur.renameSync('${logs.path}${Platform.pathSeparator}app-1.log');
      } catch (_) {}
    }
  }

  bool _rotating = false;

  /// 异步轮转：先等 sink 真正关闭（Windows 句柄竞争会让 renameSync 失败），
  /// 期间写入留在 _buf；失败则原地续写，不永久禁用日志。
  void _rotate() {
    if (_rotating) return;
    _rotating = true;
    _flush();
    final f = _file;
    final sink = _sink;
    _sink = null;
    () async {
      try {
        try {
          await sink?.close();
        } catch (_) {}
        // 等待期间发生 switchDir（目录迁移）则放弃本次轮转
        if (f == null || !identical(f, _file)) return;
        _rotateFiles(f.parent, f);
        _file = File(f.path);
        _sink = _file!.openWrite(mode: FileMode.append);
      } catch (_) {
        // 轮转失败：回退为在原文件续写；连回退也失败则停用日志（防缓冲无限增长）
        try {
          if (f != null) _sink = File(f.path).openWrite(mode: FileMode.append);
        } catch (_) {
          _broken = true;
        }
      } finally {
        _rotating = false;
        _flush();
      }
    }();
  }
}

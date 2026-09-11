import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../reader/app_log.dart';

/// 兼容正/反斜杠的文件名提取（用户可能输入 E:/dir 形式路径）
String _baseName(String p) => p.split(RegExp(r'[\\/]')).last;

/// 把路径前缀 [oldPrefix] 改写为 [newPrefix]，比较时忽略分隔符差异。
/// 返回的新路径用 [newPrefix] 自带的分隔符风格。
String rewritePathPrefix(String? p, String oldPrefix, String newPrefix) {
  if (p == null || p.isEmpty) return p ?? '';
  final norm = p.replaceAll('\\', '/');
  final oldN = oldPrefix.replaceAll('\\', '/');
  // 边界匹配：`downloads` 不得误匹配 `downloads2`
  if (norm == oldN || norm.startsWith('$oldN/')) {
    return newPrefix + norm.substring(oldN.length);
  }
  return p;
}

/// 迁移结果摘要（给 UI 展示）
class MigrationResult {
  final bool ok;
  final String newPath;
  final int files;
  final int bytes;
  final String? error;
  const MigrationResult(this.ok, this.newPath,
      {this.files = 0, this.bytes = 0, this.error});
}

/// 统一数据目录管理：
/// 所有用户数据（favorites/history/settings/reader_settings/downloads/
/// image_cache/logs）都放在一个可配置的根目录下。
/// 默认 = getApplicationSupportDirectory()；用户改目录后，位置记录在
/// 固定位置（支持目录）的指针文件 `data_dir.txt` 中，启动时先读它。
/// 旧版本数据（Documents/WnacgPc/downloads）在首次加载时自动并入。
class DataDirs {
  DataDirs._();
  static final DataDirs instance = DataDirs._();

  /// 固定的应用支持目录（指针文件与 WebView2 配置所在，永不改变）
  late String supportPath;

  /// 当前数据根目录
  late String root;

  /// 图片磁盘缓存自定义位置（空 = 跟随数据根 `<root>/image_cache`）。
  /// 独立于数据根：记录在支持目录指针文件 image_cache_dir.txt。
  String imageCacheOverride = '';

  bool get isCustom => _norm(root) != _norm(supportPath);

  static String _norm(String p) => p.replaceAll('\\', '/');

  String get supportDir => supportPath;
  String file(String name) => '$root/$name';
  String get downloadsPath => '$root/downloads';
  String get imageCachePath =>
      imageCacheOverride.isEmpty ? '$root/image_cache' : imageCacheOverride;
  String get logsPath => '$root/logs';

  File get _pointerFile => File('$supportPath/data_dir.txt');
  File get _cachePointerFile => File('$supportPath/image_cache_dir.txt');

  /// 更改图片缓存位置（不移动文件；移动由 ImageBridge.relocateCache 负责）
  Future<void> setCacheOverride(String p) async {
    var clean = p.trim();
    while (clean.endsWith('/') || clean.endsWith('\\')) {
      clean = clean.substring(0, clean.length - 1);
    }
    imageCacheOverride = clean;
    try {
      if (clean.isEmpty) {
        if (await _cachePointerFile.exists()) await _cachePointerFile.delete();
      } else {
        await _cachePointerFile.writeAsString(clean);
      }
    } catch (_) {}
  }

  /// 启动初始化：读指针文件决定数据根目录，并把旧版分散数据并入。
  Future<void> init() async {
    supportPath = (await getApplicationSupportDirectory()).path;
    root = supportPath;
    try {
      if (await _pointerFile.exists()) {
        final p = (await _pointerFile.readAsString()).trim();
        if (p.isNotEmpty && Directory(p).existsSync()) {
          root = p;
        }
      }
      if (await _cachePointerFile.exists()) {
        final p = (await _cachePointerFile.readAsString()).trim();
        if (p.isNotEmpty && Directory(p).existsSync()) {
          imageCacheOverride = p;
        }
      }
    } catch (_) {}
    await _importLegacyDownloads();
  }

  /// v1 下载目录在 Documents/WnacgPc/downloads：若新位置还没有下载数据，
  /// 尝试整个目录改名搬入（同盘瞬间完成）；跨盘则只搬注册表并改写路径。
  Future<void> _importLegacyDownloads() async {
    try {
      final docs = '${await _documentsPath()}/WnacgPc/downloads';
      final legacyReg = File('$docs/downloads.json');
      if (!await legacyReg.exists()) return;
      final newReg = File('$downloadsPath/downloads.json');
      if (await newReg.exists()) return; // 已有数据，不覆盖
      final legacyDir = Directory(docs);
      if (!await legacyDir.exists()) return;
      await Directory(downloadsPath).create(recursive: true);
      try {
        // Windows 下目录被占用会失败；失败则退回仅搬注册表
        for (final e in legacyDir.listSync()) {
          final name = _baseName(e.path);
          if (name == 'downloads.json') continue;
          try {
            await e.rename('$downloadsPath/$name');
          } catch (_) {
            if (e is File) {
              await e.copy('$downloadsPath/$name');
            } else {
              await _copyDir(
                  e as Directory, Directory('$downloadsPath/$name'), (_) {});
            }
          }
        }
        await legacyReg.copy(newReg.path);
        await _rewriteRegistry(downloadsPath, docs);
        AppLog.i('data', '旧下载目录已并入: $docs -> $downloadsPath');
      } catch (e) {
        // 搬不动就只搬注册表并把路径指回旧目录，功能不受影响
        await legacyReg.copy(newReg.path);
        await _rewriteRegistry(downloadsPath, docs);
        AppLog.w('data', '旧下载目录搬移失败，注册表指向原位置: $e');
      }
    } catch (_) {}
  }

  Future<String> _documentsPath() async {
    // 必须与 v1 写注册表时用的路径完全一致（path_provider 的带反斜杠形式）
    final d = await getApplicationDocumentsDirectory();
    return d.path;
  }

  /// 更改数据根目录并迁移现有数据（复制语义：原目录保留作备份）。
  /// [onProgress] 0.0~1.0。要求当前没有进行中的下载任务。
  Future<MigrationResult> migrateTo(String newPath,
      {void Function(double)? onProgress}) async {
    // 规范化用户输入：去首尾空白与尾部分隔符（避免 E:/dir/ 拼出双斜杠）
    var cleanPath = newPath.trim();
    while (cleanPath.endsWith('/') || cleanPath.endsWith('\\')) {
      cleanPath = cleanPath.substring(0, cleanPath.length - 1);
    }
    if (cleanPath.isEmpty) {
      return MigrationResult(false, newPath, error: '路径为空');
    }
    final dst = Directory(cleanPath);
    try {
      await dst.create(recursive: true);
      final probe = File('${dst.path}/.wnacg_probe');
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (e) {
      return MigrationResult(false, newPath, error: '目录不可写: $e');
    }
    final src = Directory(root);
    if (_norm(cleanPath) == _norm(src.path)) {
      return MigrationResult(false, newPath, error: '新目录与当前目录相同');
    }
    // 新目录位于当前数据根内部会造成递归复制，拒绝
    if ('${_norm(cleanPath)}/'.startsWith('${_norm(src.path)}/')) {
      return MigrationResult(false, newPath, error: '新目录不能位于当前数据目录内部');
    }

    // 1. 收集要迁移的内容（缓存位置被自定义时，<root>/image_cache 是
    // 陈旧残留，不随数据根迁移）
    final entries = <FileSystemEntity>[];
    final names = <String>[
      'favorites.json',
      'history.json',
      'settings.json',
      'reader_settings.json',
      'downloads',
      if (imageCacheOverride.isEmpty) 'image_cache',
      'logs'
    ];
    for (final n in names) {
      final e = FileSystemEntity.typeSync('${src.path}/$n');
      if (e == FileSystemEntityType.file) {
        entries.add(File('${src.path}/$n'));
      } else if (e == FileSystemEntityType.directory) {
        entries.add(Directory('${src.path}/$n'));
      }
    }

    // 2. 统计总量（进度用；并发删文件时统计失败不阻塞迁移）
    var total = 0, done = 0, totalBytes = 0;
    try {
      for (final e in entries) {
        if (e is File) {
          total++;
          totalBytes += _lenSync(e);
        } else {
          (e as Directory).listSync(recursive: true, followLinks: false).forEach((f) {
            if (f is File) {
              total++;
              totalBytes += _lenSync(f);
            }
          });
        }
      }
    } catch (_) {}
    void tick(int bytes) {
      done++;
      onProgress?.call(total == 0 ? 1 : done / total);
    }

    // 3. 复制（logs 的 sink 需要先由调用方关闭）
    try {
      for (final e in entries) {
        final name = _baseName(e.path);
        if (e is File) {
          final target = File('${dst.path}/$name');
          if (name == 'downloads.json') {
            // 绝对路径改写后写入
            await _copyRegistryRewritten(e, target);
            tick(_lenSync(e));
          } else {
            await e.copy(target.path);
            tick(_lenSync(e));
          }
        } else {
          await _copyDir(e as Directory, Directory('${dst.path}/$name'), tick,
              rewriteRegistry: name == 'downloads');
        }
      }
    } catch (e) {
      return MigrationResult(false, newPath, error: '复制失败: $e');
    }

    // 4. 写指针文件并切换根目录
    try {
      await _pointerFile.writeAsString(dst.path);
    } catch (e) {
      return MigrationResult(false, newPath, error: '写入指针文件失败: $e');
    }
    root = dst.path;
    AppLog.i('data', '数据目录已迁移: $src -> $dst ($total 个文件)');
    return MigrationResult(true, dst.path, files: total, bytes: totalBytes);
  }

  /// downloads.json 里的 dir/zipPath 是绝对路径：迁移时把旧根前缀改写为新根
  Future<void> _copyRegistryRewritten(File src, File target) async {
    try {
      final raw = await src.readAsString();
      final list = jsonDecode(raw) as List;
      // 旧前缀 = 旧下载目录（root/downloads），新前缀 = 新下载目录
      String fix(String? p) =>
          rewritePathPrefix(p, '$root/downloads', target.parent.path);

      final out = list.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        m['dir'] = fix(m['dir'] as String?);
        if (m['zipPath'] != null) m['zipPath'] = fix(m['zipPath'] as String);
        return m;
      }).toList();
      await target.writeAsString(jsonEncode(out));
    } catch (_) {
      await src.copy(target.path);
    }
  }

  int _lenSync(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _copyDir(Directory src, Directory dst, void Function(int) tick,
      {bool rewriteRegistry = false}) async {
    await dst.create(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      final name = _baseName(e.path);
      if (e is Directory) {
        await _copyDir(e, Directory('${dst.path}/$name'), tick);
      } else if (e is File) {
        final target = File('${dst.path}/$name');
        if (rewriteRegistry && name == 'downloads.json') {
          await _copyRegistryRewritten(e, target);
        } else {
          await e.copy(target.path);
        }
        tick(_lenSync(e));
      }
    }
  }

  /// 只改写注册表路径（不移动文件时使用）
  Future<void> _rewriteRegistry(String regDir, String oldDownloads) async {
    final f = File('$regDir/downloads.json');
    if (!await f.exists()) return;
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      String fix(String? p) => rewritePathPrefix(p, oldDownloads, regDir);

      final out = list.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        m['dir'] = fix(m['dir'] as String?);
        if (m['zipPath'] != null) m['zipPath'] = fix(m['zipPath'] as String);
        return m;
      }).toList();
      await f.writeAsString(jsonEncode(out));
    } catch (_) {}
  }
}

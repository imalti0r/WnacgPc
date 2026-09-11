// WnacgPc 阅读器数据源适配层。
// ZipBook / PageItem / ChapterPages / loadChapterPages / readPageBytes 移植自
// mihon_fx 的 library.dart，唯一差异是 PageItem 增加了在线图片（url）来源：
// 在线页字节经 WebView2 图片桥获取（绕过 CDN 的 TLS 指纹拦截）。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

import '../net/image_bridge.dart';
import 'models.dart';
import 'util.dart';

/// 打开一个 CBZ/ZIP：解析中央目录，支持整条读取与“只读头部”快速探测。
/// 不经 ZipDecoder 整包解压，条目按需从文件偏移读取（STORE 直读 / DEFLATE 原始流解压）。
class ZipBook {
  ZipBook(String path) : _path = path {
    _fileLen = File(path).lengthSync();
    _assertHasEocd(path, _fileLen);
    InputFileStream? input;
    try {
      input = InputFileStream(path);
      final dir = ZipDirectory.read(input);
      _entries = [
        for (final h in dir.fileHeaders)
          if (!h.filename.endsWith('/') && isImagePath(h.filename))
            _ZipEntry(
              name: h.filename,
              localHeaderOffset: h.localHeaderOffset ?? 0,
              method: h.compressionMethod,
              compressedSize: h.compressedSize ?? 0,
              size: h.uncompressedSize ?? 0,
              encrypted: (h.generalPurposeBitFlag & 0x1) != 0,
            ),
      ]..sort((a, b) => compareNatural(a.name, b.name));
      input.close();
    } catch (_) {
      try {
        input?.close();
      } catch (_) {}
      rethrow;
    }
    _raf = File(path).openSync();
  }

  final String _path;
  late final int _fileLen;
  late final RandomAccessFile _raf;
  late final List<_ZipEntry> _entries;

  String get path => _path;
  int get pageCount => _entries.length;

  String nameAt(int i) => _entries[i].name;

  bool _seekEntry(int i) {
    final e = _entries[i];
    if (e.encrypted || e.localHeaderOffset < 0) return false;
    if (e.localHeaderOffset + 30 > _fileLen) return false; // 头部越界
    _raf.setPositionSync(e.localHeaderOffset);
    final lh = _raf.readSync(30);
    if (lh.length < 30) return false;
    if (_u32le(lh, 0) != 0x04034b50) return false; // 非标准本地头
    final nameLen = _u16le(lh, 26);
    final extraLen = _u16le(lh, 28);
    _raf.setPositionSync(e.localHeaderOffset + 30 + nameLen + extraLen);
    return true;
  }

  /// 原始 deflate 解压（partial=true 时用于只解出头部字节，容忍截断）。
  Uint8List _inflate(List<int> comp, {bool complete = true}) {
    final filter = RawZLibFilter.inflateFilter(raw: true);
    final out = BytesBuilder(copy: false);
    void run(List<int> data, {bool flush = true, bool end = false}) {
      try {
        filter.process(data, 0, data.length);
        while (true) {
          final chunk = filter.processed(flush: flush, end: end);
          if (chunk == null) break;
          out.add(chunk);
        }
      } catch (_) {
        // 截断/损坏流：返回已解出的部分
      }
    }

    run(comp, flush: false);
    if (complete) run(const [], flush: true, end: true);
    return out.toBytes();
  }

  /// 读取条目完整内容。
  Uint8List bytesAt(int i) {
    final e = _entries[i];
    if (!_seekEntry(i)) {
      throw FileSystemException('无法读取 ZIP 条目', '$_path#${e.name}');
    }
    // 声明尺寸超出文件剩余字节 = 损坏/截断，直接报错（防巨型分配与垃圾解压）。
    final want = e.method == 0 ? e.size : e.compressedSize;
    if (want > _fileLen - _raf.positionSync()) {
      throw FileSystemException('ZIP 条目尺寸越界（文件损坏或截断）', '$_path#${e.name}');
    }
    if (e.method == 0) {
      return _raf.readSync(e.size);
    } else if (e.method == 8) {
      return _inflate(_raf.readSync(e.compressedSize));
    }
    throw FileSystemException('不支持的压缩方式 ${e.method}', '$_path#${e.name}');
  }

  /// 只读条目前 [want] 字节（用于尺寸嗅探，不解压整条）。
  Uint8List headAt(int i, [int want = 1 << 16]) {
    final e = _entries[i];
    if (!_seekEntry(i)) return Uint8List(0);
    final remaining = _fileLen - _raf.positionSync();
    if (e.method == 0) {
      var n = want > e.size ? e.size : want;
      if (n > remaining) n = remaining;
      return _raf.readSync(n);
    } else if (e.method == 8) {
      var n = (want * 2) > e.compressedSize ? e.compressedSize : (want * 2);
      if (n > remaining) n = remaining;
      final comp = _raf.readSync(n);
      return _inflate(comp, complete: false);
    }
    return Uint8List(0);
  }

  void close() {
    try {
      _raf.closeSync();
    } catch (_) {}
  }
}

class _ZipEntry {
  _ZipEntry({
    required this.name,
    required this.localHeaderOffset,
    required this.method,
    required this.compressedSize,
    required this.size,
    required this.encrypted,
  });

  final String name;
  final int localHeaderOffset;
  final int method;
  final int compressedSize;
  final int size;
  final bool encrypted;
}

int _u16le(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

int _u32le(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

/// 快速校验文件尾部存在 EOCD 记录（合法 zip 必在最后 22+65535 字节内）。
/// archive 3.6.1 的 `_findEocdrSignature` 找不到签名时会把整个文件逐字节回扫
/// （176MB 截断文件 ≈ 106 分钟 100% CPU，表现为导入永久卡死），必须在此提前拦截。
void _assertHasEocd(String path, int len) {
  if (len < 22) {
    throw FileSystemException('ZIP 文件过小或为空', path);
  }
  final raf = File(path).openSync();
  try {
    final start = len > 22 + 65535 ? len - (22 + 65535) : 0;
    raf.setPositionSync(start);
    final tail = raf.readSync(len - start);
    for (var i = tail.length - 4; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4B &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        return;
      }
    }
    throw FileSystemException('ZIP 缺少中央目录结尾记录（文件损坏或未下载完成）', path);
  } finally {
    raf.closeSync();
  }
}

/// 一个页面引用：在线图片 URL、文件夹里的图片文件，或压缩包内条目。
class PageItem {
  PageItem.file(String path)
      : file = path,
        zip = null,
        url = null,
        index = 0,
        name = baseName(path);

  PageItem.zip(this.zip, this.index, this.name)
      : file = null,
        url = null;

  PageItem.url(String this.url, {String? name})
      : file = null,
        zip = null,
        index = 0,
        name = name ?? url;

  final String? file;
  final ZipBook? zip;
  final String? url;
  final int index;
  final String name;
}

/// 在线画廊章节：页面列表在打开前已由 API 解析好。
class OnlineChapter extends Chapter {
  OnlineChapter({
    required super.id,
    required super.title,
    required List<PageItem> pages,
  })  : prebuilt = pages,
        super(path: '', isZip: false);

  final List<PageItem> prebuilt;
}

class ChapterPages {
  ChapterPages(this.pages, this.book);

  final List<PageItem> pages;
  final ZipBook? book;

  void close() {
    book?.close();
  }
}

ChapterPages _loadChapterPagesSync(Chapter ch) {
  if (ch is OnlineChapter) {
    return ChapterPages(ch.prebuilt, null);
  }
  if (ch.isZip) {
    final book = ZipBook(ch.path);
    final pages = [
      for (var i = 0; i < book.pageCount; i++) PageItem.zip(book, i, book.nameAt(i)),
    ];
    return ChapterPages(pages, book);
  }
  final dir = Directory(ch.path);
  final files = <String>[];
  if (dir.existsSync()) {
    for (final e in dir.listSync(followLinks: false)) {
      if (e is File && isImagePath(e.path)) files.add(e.path);
    }
    files.sort(compareNatural);
  }
  return ChapterPages([for (final p in files) PageItem.file(p)], null);
}

Future<ChapterPages> loadChapterPages(Chapter ch) async => _loadChapterPagesSync(ch);

Uint8List _readPageBytesSync(PageItem p) {
  if (p.zip != null) return p.zip!.bytesAt(p.index);
  return File(p.file!).readAsBytesSync();
}

/// 读取一页字节。在线页经图片桥（磁盘缓存按漫画分目录：
/// [cacheId]=漫画 aid、[page]=页序，缓存为 `<aid>/<00001>.<ext>`）。
Future<Uint8List> readPageBytes(PageItem p,
    {String? cacheId, int? page, void Function(bool cacheHit)? onSource}) async {
  final url = p.url;
  if (url != null) {
    return ImageBridge.instance.getBytes(url,
        cacheId: cacheId,
        cacheName: page?.toString().padLeft(5, '0'),
        onSource: onSource);
  }
  return _readPageBytesSync(p);
}

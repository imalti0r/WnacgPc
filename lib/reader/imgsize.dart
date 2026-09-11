// 图片尺寸嗅探：只读文件头部几十 KB 就解析出宽高（在线页只读磁盘缓存），
// 用于双页模式的“跨页自动独占一屏”（参考 Mihon 的 automatic 宽页处理）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'library.dart';
import '../net/image_bridge.dart' show ImageBridge;

int _u16le(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

int _u32le(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

int _u32be(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

bool _startsWith(Uint8List b, int offset, String ascii) {
  if (b.length < offset + ascii.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (b[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

/// 从文件头部字节解析图片尺寸，失败返回 null。
Size? sniffImageSize(Uint8List b) {
  if (b.length < 8) return null;
  // JPEG
  if (b[0] == 0xFF && b[1] == 0xD8) return _jpeg(b);
  // PNG
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    if (b.length >= 24) {
      return Size(_u32be(b, 16).toDouble(), _u32be(b, 20).toDouble());
    }
    return null;
  }
  // GIF
  if (_startsWith(b, 0, 'GIF8')) {
    if (b.length >= 10) {
      return Size(_u16le(b, 6).toDouble(), _u16le(b, 8).toDouble());
    }
    return null;
  }
  // BMP
  if (b[0] == 0x42 && b[1] == 0x4D && b.length >= 26) {
    final w = _u32le(b, 18);
    final hSigned = _u32le(b, 22);
    final h = (hSigned & 0x80000000) != 0 ? hSigned & 0x7FFFFFFF : hSigned;
    return Size(w.toDouble(), h.toDouble());
  }
  // WebP: RIFF....WEBP
  if (_startsWith(b, 0, 'RIFF') && _startsWith(b, 8, 'WEBP') && b.length >= 30) {
    return _webp(b);
  }
  return null;
}

/// 从文件头部魔数判定编码格式（判定规则与 sniffImageSize 同源）。
String sniffImageFormat(Uint8List b) {
  if (b.length < 12) return '未知';
  if (b[0] == 0xFF && b[1] == 0xD8) return 'JPEG';
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'PNG';
  if (_startsWith(b, 0, 'GIF8')) return 'GIF';
  if (b[0] == 0x42 && b[1] == 0x4D) return 'BMP';
  // WebP: RIFF....WEBP，fourcc 细分有损/无损/扩展
  if (_startsWith(b, 0, 'RIFF') && _startsWith(b, 8, 'WEBP')) {
    if (b.length < 16) return 'WebP';
    switch (String.fromCharCodes(b.sublist(12, 16))) {
      case 'VP8 ':
        return 'WebP（有损）';
      case 'VP8L':
        return 'WebP（无损）';
      default:
        return 'WebP（扩展）';
    }
  }
  return '未知';
}

Size? _webp(Uint8List b) {
  final fourcc = String.fromCharCodes(b.sublist(12, 16));
  if (fourcc == 'VP8 ') {
    // 有损：帧头 3 字节 + 同步码 9D 01 2A，宽高在 26/28
    if (b[23] == 0x9D && b[24] == 0x01 && b[25] == 0x2A) {
      return Size(
        (_u16le(b, 26) & 0x3FFF).toDouble(),
        (_u16le(b, 28) & 0x3FFF).toDouble(),
      );
    }
  } else if (fourcc == 'VP8L') {
    if (b.length >= 26 && b[21] == 0x2F) {
      final bits = _u32le(b, 22);
      return Size(
        ((bits & 0x3FFF) + 1).toDouble(),
        (((bits >> 14) & 0x3FFF) + 1).toDouble(),
      );
    }
  } else if (fourcc == 'VP8X') {
    final w = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
    final h = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
    return Size(w.toDouble(), h.toDouble());
  }
  return null;
}

Size? _jpeg(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    // 填充与无长度段
    if (marker == 0xFF || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return null; // SOS/EOI：之前没有 SOF
    final len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2) return null;
    if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
      // SOF 段：精度(1) 高(2) 宽(2)
      if (i + 8 >= b.length) return null;
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return Size(w.toDouble(), h.toDouble());
    }
    i += 2 + len;
  }
  return null;
}

/// 探测一个页面（在线 URL / 文件夹文件 / 压缩包条目）的尺寸。
/// 在线页只嗅探磁盘缓存中已有的字节（避免为分组预取而批量下载），
/// 未缓存时返回 null（双页分组按普通竖页处理）。
/// [cacheId]/[page] 用于按漫画分目录的缓存寻址。
Future<Size?> probePageSize(PageItem p, {String? cacheId, int? page}) async {
  try {
    final Uint8List head;
    if (p.url != null) {
      final cached = await ImageBridge.instance.readCache(p.url!,
          cacheId: cacheId,
          cacheName: page?.toString().padLeft(5, '0'));
      if (cached == null) return null;
      head = cached.length > (1 << 16)
          ? Uint8List.sublistView(cached, 0, 1 << 16)
          : cached;
    } else if (p.zip != null) {
      head = p.zip!.headAt(p.index);
    } else {
      final raf = await File(p.file!).open();
      try {
        head = await raf.read(1 << 16);
      } finally {
        await raf.close();
      }
    }
    return sniffImageSize(head);
  } catch (_) {
    return null;
  }
}

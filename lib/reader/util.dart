// 通用小工具：自然排序、扩展名判断、路径处理、稳定 ID。

const imageExts = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif'];
const zipExts = ['.zip', '.cbz'];

String extOf(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i).toLowerCase();
}

bool isImagePath(String name) => imageExts.contains(extOf(name));

bool isZipPath(String path) => zipExts.contains(extOf(path));

String baseName(String p) {
  final norm = p.replaceAll('\\', '/');
  final i = norm.lastIndexOf('/');
  return i < 0 ? norm : norm.substring(i + 1);
}

String stripExt(String name) {
  final i = name.lastIndexOf('.');
  return i <= 0 ? name : name.substring(0, i);
}

/// FNV-1a，用于把路径映射成稳定 ID（跨重启一致）。
String hashId(String s) {
  var h = 0x811c9dc5;
  for (final c in s.toLowerCase().codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// “第2话”排在“第10话”前面的自然比较。
int compareNatural(String a, String b) {
  var ia = 0, ib = 0;
  while (ia < a.length && ib < b.length) {
    final ca = a.codeUnitAt(ia), cb = b.codeUnitAt(ib);
    if (_isDigit(ca) && _isDigit(cb)) {
      var ea = ia;
      while (ea < a.length && _isDigit(a.codeUnitAt(ea))) {
        ea++;
      }
      var eb = ib;
      while (eb < b.length && _isDigit(b.codeUnitAt(eb))) {
        eb++;
      }
      final na = int.tryParse(a.substring(ia, ea)) ?? 0;
      final nb = int.tryParse(b.substring(ib, eb)) ?? 0;
      final c = na.compareTo(nb);
      if (c != 0) return c;
      ia = ea;
      ib = eb;
    } else {
      final c = ca.compareTo(cb);
      if (c != 0) return c;
      ia++;
      ib++;
    }
  }
  return (a.length - ia).compareTo(b.length - ib);
}

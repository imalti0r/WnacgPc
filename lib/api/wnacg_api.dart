import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

import '../models/models.dart';

/// wnacg 站点 API：线路检测 + 列表/详情/图片解析
class WnacgApi {
  WnacgApi._();
  static final WnacgApi instance = WnacgApi._();

  static const releasePage = 'https://wnacg01.link/';
  static const fallbackLines = [
    'https://www.wn10.shop/',
    'https://www.wn10.cfd/',
  ];

  String baseUrl = fallbackLines.first;
  final http.Client _client = http.Client();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  Map<String, String> headers({String? referer}) => {
        'User-Agent': _ua,
        'Referer': referer ?? baseUrl,
        'Accept-Language': 'zh-TW,zh;q=0.9',
      };

  /// 解析地址发布页：返回主站线路（www.*）与发布页镜像（wnacgXX.link）。
  /// 发布页条目形如 <a href="https://www.wn10.cfd/"><i>www.wn10.cfd</i></a>。
  Future<({List<String> lines, List<String> publishPages})>
      fetchReleaseInfo() async {
    final lines = <String>[];
    final publishPages = <String>[];
    for (final page in const [releasePage, 'https://wnacg02.link/']) {
      if (publishPages.contains(page)) continue;
      try {
        final res = await _client
            .get(Uri.parse(page), headers: headers())
            .timeout(const Duration(seconds: 12));
        final doc = html_parser.parse(res.body);
        for (final a in doc.querySelectorAll('a[href^="http"]')) {
          final href = a.attributes['href'] ?? '';
          final host = Uri.tryParse(href)?.host ?? '';
          if (host.isEmpty) continue;
          var u = href;
          if (!u.endsWith('/')) u += '/';
          // 主站线路条目的链接文本就是域名本身（<a><i>www.wn10.cfd</i></a>），
          // 借此排除发布页上的无关链接（如 chrome 官网）
          final label = a.text.trim();
          if (host.startsWith('www.')) {
            if (label.contains(host) && !lines.contains(u)) lines.add(u);
          } else if (host.startsWith('wnacg')) {
            if (!publishPages.contains(u)) publishPages.add(u);
          }
        }
      } catch (_) {}
    }
    for (final f in fallbackLines) {
      if (!lines.contains(f)) lines.add(f);
    }
    return (lines: lines, publishPages: publishPages);
  }

  /// 测速 [url]，失败返回 null
  Future<Duration?> measure(String url) => _measure(url);

  /// 从发布页解析线路并测速，返回最佳 baseUrl
  Future<String> resolveBestLine() async {
    final candidates = <String>[];
    try {
      final info = await fetchReleaseInfo();
      for (final l in info.lines) {
        if (!candidates.contains(l)) candidates.add(l);
      }
    } catch (_) {}
    for (final f in fallbackLines) {
      if (!candidates.contains(f)) candidates.add(f);
    }
    String best = baseUrl;
    Duration bestTime = const Duration(seconds: 8);
    for (final c in candidates) {
      final t = await _measure(c);
      if (t != null && t < bestTime) {
        bestTime = t;
        best = c;
      }
    }
    baseUrl = best;
    return best;
  }

  Future<Duration?> _measure(String url) async {
    final sw = Stopwatch()..start();
    try {
      final res = await _client
          .get(Uri.parse(url), headers: headers())
          .timeout(const Duration(seconds: 8));
      sw.stop();
      if (res.statusCode == 200) return sw.elapsed;
    } catch (_) {}
    return null;
  }

  Future<String> _get(String path) async {
    final uri = path.startsWith('http') ? Uri.parse(path) : Uri.parse('$baseUrl$path');
    final res = await _client
        .get(uri, headers: headers())
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode} $uri');
    }
    return res.body;
  }

  String absUrl(String src, {String? base}) {
    final b = base ?? baseUrl;
    var u = src.trim();
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http')) return u;
    if (u.startsWith('/')) return b.endsWith('/') ? '$b${u.substring(1)}' : b + u;
    return u;
  }

  // ---------- 列表 ----------

  /// 最新：page=1 -> /albums.html
  String latestUrl(int page) =>
      page <= 1 ? '/albums.html' : '/albums-index-page-$page.html';

  /// 分类：page=1 -> /albums-index-cate-{id}.html，
  /// 第 n 页 -> /albums-index-page-{n}-cate-{id}.html（站点标准分页格式）
  String categoryUrl(int cateId, int page) => page <= 1
      ? '/albums-index-cate-$cateId.html'
      : '/albums-index-page-$page-cate-$cateId.html';

  /// 标签：page=1 -> /albums-index-tag-{tag}.html
  String tagUrl(String tag, int page) {
    final t = Uri.encodeComponent(tag);
    return page <= 1
        ? '/albums-index-tag-$t.html'
        : '/albums-index-tag-$t-page-$page.html';
  }

  String searchUrl(String q, int page) {
    final qe = Uri.encodeQueryComponent(q);
    return page <= 1
        ? '/search/?q=$qe'
        : '/search/index.php?q=$qe&m=&syn=yes&f=_all&s=&p=$page';
  }

  Future<List<GalleryItem>> fetchList(String path) async {
    final body = await _get(path);
    final doc = html_parser.parse(body);
    final items = <GalleryItem>[];
    for (final li in doc.querySelectorAll('li.gallary_item')) {
      final a = li.querySelector('.pic_box a') ?? li.querySelector('a[href*="photos-index-aid"]');
      if (a == null) continue;
      final href = a.attributes['href'] ?? '';
      final m = RegExp(r'aid-(\d+)').firstMatch(href);
      if (m == null) continue;
      // 搜索结果站方会把 <em> 高亮标签写进 title 属性（&lt;em&gt; 转义后
      // 被解析成字面文本），剥掉标签并归一 &nbsp;，避免污染标题与下载命名
      final title = (a.attributes['title'] ??
              li.querySelector('.title a')?.text ??
              a.text)
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&nbsp;', ' ')
          .trim();
      final img = li.querySelector('.pic_box img, img');
      var cover = img?.attributes['src'] ?? '';
      // 详情页封面存在 //// 开头的写法，absUrl 已处理 //
      cover = cover.replaceAll(RegExp('^/+'), '//');
      final infoText = li.querySelector('.info_col')?.text ?? '';
      final cm = RegExp(r'(\d+)\s*張圖片').firstMatch(infoText);
      final dm = RegExp(r'創建於(\d{4}-\d{2}-\d{2})').firstMatch(infoText);
      items.add(GalleryItem(
        aid: m.group(1)!,
        title: title,
        coverUrl: cover.isEmpty ? '' : absUrl(cover),
        imageCount: cm != null ? int.parse(cm.group(1)!) : null,
        date: dm?.group(1),
      ));
    }
    return items;
  }

  // ---------- 详情 ----------

  Future<GalleryDetail> fetchDetail(String aid) async {
    final body = await _get('/photos-index-aid-$aid.html');
    final doc = html_parser.parse(body);
    final title = doc.querySelector('#bodywrap h2')?.text.trim() ??
        doc.querySelector('title')?.text.trim() ??
        '';
    var cover = doc.querySelector('.uwthumb img')?.attributes['src'] ?? '';
    cover = cover.replaceAll(RegExp('^/+'), '//');
    final labels = doc.querySelectorAll('.uwconn label').map((e) => e.text).toList();
    var categories = <String>[];
    var pages = 0;
    for (final l in labels) {
      if (l.contains('分類')) {
        categories = l
            .replaceAll(RegExp(r'^\s*分類：'), '')
            .split(RegExp(r'[/／]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      } else if (l.contains('頁數')) {
        final m = RegExp(r'(\d+)').firstMatch(l);
        if (m != null) pages = int.parse(m.group(1)!);
      }
    }
    final tags = doc
        .querySelectorAll('.addtags a.tagshow')
        .map((e) => e.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final descList = doc
        .querySelectorAll('.uwconn p')
        .map((e) => e.text.trim())
        .where((t) => t.startsWith('簡介'))
        .join('\n');
    final desc = descList.replaceFirst(RegExp(r'^簡介：?'), '');
    final uploader = doc.querySelector('.uwuinfo p')?.text.trim() ?? '';
    return GalleryDetail(
      aid: aid,
      title: title,
      coverUrl: cover.isEmpty ? '' : absUrl(cover),
      categories: categories,
      pages: pages,
      tags: tags,
      description: desc,
      uploader: uploader,
    );
  }

  // ---------- 阅读页图片 ----------

  /// 解析官方打包下载页 /download-index-aid-{aid}.html：
  /// a.ads 即站点预打包 ZIP 直链（文件名在 ?n= 参数或 .download_filename）。
  /// 移植自 mangareload 的 resolve_download。
  Future<({String url, String name})> fetchDownloadInfo(String aid) async {
    final body = await _get('/download-index-aid-$aid.html');
    final doc = html_parser.parse(body);
    final href = doc.querySelector('a.ads')?.attributes['href']?.trim() ?? '';
    if (href.isEmpty) {
      throw Exception('未找到打包下载链接（可能站点限制或资源不存在）');
    }
    final url = href.startsWith('//')
        ? 'https:$href'
        : href.startsWith('http')
            ? href
            : absUrl(href);
    var name = Uri.tryParse(url)?.queryParameters['n'] ?? '';
    if (name.isEmpty) {
      name = doc.querySelector('.download_filename')?.text.trim() ?? '';
    }
    return (url: url, name: name);
  }

  /// 解析 /photos-gallery-aid-{aid}.html 中的 imglist
  Future<List<ReaderImage>> fetchGalleryImages(String aid) async {
    final raw = await _get('/photos-gallery-aid-$aid.html');
    // 内容为 document.writeln 包裹、引号被 \ 转义的 JS，先反转义
    var js = raw.replaceAll(r'\"', '"').replaceAll(r'\/', '/');
    final hostM = RegExp(r'var\s+fast_img_host\s*=\s*"([^"]*)"').firstMatch(js);
    final host = hostM?.group(1) ?? '';
    final listM = RegExp(r'var\s+imglist\s*=\s*\[').firstMatch(js);
    if (listM == null) {
      throw Exception('未找到图片列表 (aid=$aid)');
    }
    final start = listM.end;
    // 字符串感知的括号配平：caption 含 [ ] 时不会提前截断数组
    var depth = 1;
    var i = start;
    var inStr = false;
    while (i < js.length && depth > 0) {
      final c = js[i];
      if (inStr) {
        if (c == r'\') {
          i += 2; // 跳过转义序列
          continue;
        }
        if (c == '"') inStr = false;
      } else if (c == '"') {
        inStr = true;
      } else if (c == '[') {
        depth++;
      } else if (c == ']') {
        depth--;
      }
      i++;
    }
    if (depth != 0) {
      throw Exception('图片列表括号不配对 (aid=$aid)');
    }
    final arrText = js.substring(start, i - 1);
    final images = <ReaderImage>[];
    final entryReg = RegExp(r'url:\s*fast_img_host\s*\+\s*"([^"]+)"(?:\s*,\s*caption:\s*"([^"]*)")?');
    for (final m in entryReg.allMatches(arrText)) {
      var u = m.group(1)!;
      final caption = m.group(2) ?? '';
      String full;
      if (u.startsWith('//')) {
        full = 'https:$u';
      } else if (u.startsWith('http')) {
        full = u;
      } else if (u.startsWith('/')) {
        full = absUrl(u);
      } else {
        full = absUrl('$host$u');
      }
      images.add(ReaderImage(full, caption));
    }
    if (images.isEmpty) throw Exception('图片列表为空 (aid=$aid)');
    return images;
  }

  Map<String, String> imageHeaders() => headers();
}

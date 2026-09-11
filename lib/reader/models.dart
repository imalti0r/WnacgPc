// 数据模型与 JSON 序列化。

enum ReadingMode { rtl, ltr, vertical }

ReadingMode readingModeOf(String? s) {
  switch (s) {
    case 'ltr':
      return ReadingMode.ltr;
    case 'vertical':
      return ReadingMode.vertical;
    default:
      return ReadingMode.rtl;
  }
}

String readingModeName(ReadingMode m) {
  switch (m) {
    case ReadingMode.rtl:
      return 'rtl';
    case ReadingMode.ltr:
      return 'ltr';
    case ReadingMode.vertical:
      return 'vertical';
  }
}

/// 阅读方向的人类可读名称
String readingModeLabel(ReadingMode m) {
  switch (m) {
    case ReadingMode.rtl:
      return '右开 (日漫)';
    case ReadingMode.ltr:
      return '左开 (西漫)';
    case ReadingMode.vertical:
      return '上下 (条漫)';
  }
}

enum PageFit { contain, fitWidth, fitHeight, original }

/// 页面布局（参考 Mihon 的 PageLayout：SINGLE_PAGE / DOUBLE_PAGES）。
/// 双页仅在翻页模式（左开/右开）下生效，条漫模式忽略。
enum PageLayout { single, double }

PageLayout pageLayoutOf(String? s) {
  switch (s) {
    case 'double':
      return PageLayout.double;
    default:
      return PageLayout.single;
  }
}

String pageLayoutName(PageLayout l) {
  switch (l) {
    case PageLayout.double:
      return 'double';
    case PageLayout.single:
      return 'single';
  }
}

String pageLayoutLabel(PageLayout l) {
  switch (l) {
    case PageLayout.double:
      return '双页';
    case PageLayout.single:
      return '单页';
  }
}

PageFit pageFitOf(String? s) {
  switch (s) {
    case 'fitWidth':
      return PageFit.fitWidth;
    case 'fitHeight':
      return PageFit.fitHeight;
    case 'original':
      return PageFit.original;
    default:
      return PageFit.contain;
  }
}

String pageFitName(PageFit f) {
  switch (f) {
    case PageFit.contain:
      return 'contain';
    case PageFit.fitWidth:
      return 'fitWidth';
    case PageFit.fitHeight:
      return 'fitHeight';
    case PageFit.original:
      return 'original';
  }
}

String pageFitLabel(PageFit f) {
  switch (f) {
    case PageFit.contain:
      return '适应屏幕';
    case PageFit.fitWidth:
      return '适应宽度';
    case PageFit.fitHeight:
      return '适应高度';
    case PageFit.original:
      return '原始大小';
  }
}

class Chapter {
  String id;
  String title;
  String path;
  bool isZip;
  int pageCount;
  int readCount;

  Chapter({
    required this.id,
    required this.title,
    required this.path,
    required this.isZip,
    this.pageCount = 0,
    this.readCount = 0,
  });

  bool get isRead => pageCount > 0 && readCount >= pageCount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'zip': isZip,
        'pages': pageCount,
        'read': readCount,
      };

  factory Chapter.fromJson(Map<String, dynamic> j) => Chapter(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        path: j['path'] as String? ?? '',
        isZip: j['zip'] as bool? ?? false,
        pageCount: (j['pages'] as num?)?.toInt() ?? 0,
        readCount: (j['read'] as num?)?.toInt() ?? 0,
      );
}

class Manga {
  String id;
  String title;
  String author;
  String description;
  String rootPath;
  bool singleZip;
  List<String> categoryIds;
  String? coverPath;
  int addedAtMs;
  int? lastReadAtMs;
  int lastChapter;
  int lastPage;
  List<Chapter> chapters;

  Manga({
    required this.id,
    required this.title,
    this.author = '',
    this.description = '',
    required this.rootPath,
    this.singleZip = false,
    List<String>? categoryIds,
    this.coverPath,
    int? addedAtMs,
    this.lastReadAtMs,
    this.lastChapter = -1,
    this.lastPage = 0,
    List<Chapter>? chapters,
  })  : addedAtMs = addedAtMs ?? DateTime.now().millisecondsSinceEpoch,
        categoryIds = categoryIds ?? [],
        chapters = chapters ?? [];

  bool get hasProgress =>
      lastChapter >= 0 && lastChapter < chapters.length && (lastPage > 0 || lastReadAtMs != null);

  int get totalPages => chapters.fold(0, (s, c) => s + c.pageCount);

  int get readPages =>
      chapters.fold(0, (s, c) => s + c.readCount.clamp(0, c.pageCount > 0 ? c.pageCount : 0));

  int get unreadCount => (totalPages - readPages).clamp(0, 1 << 30);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'description': description,
        'rootPath': rootPath,
        'singleZip': singleZip,
        'categoryIds': categoryIds,
        'coverPath': coverPath,
        'addedAt': addedAtMs,
        'lastReadAt': lastReadAtMs,
        'lastChapter': lastChapter,
        'lastPage': lastPage,
        'chapters': [for (final c in chapters) c.toJson()],
      };

  factory Manga.fromJson(Map<String, dynamic> j) => Manga(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        author: j['author'] as String? ?? '',
        description: j['description'] as String? ?? '',
        rootPath: j['rootPath'] as String? ?? '',
        singleZip: j['singleZip'] as bool? ?? false,
        categoryIds: [
          for (final c in (j['categoryIds'] as List? ?? [])) c as String,
        ],
        coverPath: j['coverPath'] as String?,
        addedAtMs: (j['addedAt'] as num?)?.toInt(),
        lastReadAtMs: (j['lastReadAt'] as num?)?.toInt(),
        lastChapter: (j['lastChapter'] as num?)?.toInt() ?? -1,
        lastPage: (j['lastPage'] as num?)?.toInt() ?? 0,
        chapters: [
          for (final c in (j['chapters'] as List? ?? []))
            Chapter.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
      );
}

class AppSettings {
  List<String> libraryRoots;
  ReadingMode defaultMode;
  PageFit defaultFit;
  PageLayout defaultLayout;
  String themeMode; // system | light | dark

  // ---------- 画质增强（FX）默认参数 ----------
  bool fxA4k; // Anime4K 风格线条增强
  double fxA4kStrength; // 线条增强强度 0..1
  double fxA4kEdge; // 边缘阈值 0..1（越高只对越强的边缘生效）
  bool fxFsr; // FSR 超分
  double fxFsrScale; // 放大倍数 1..3
  double fxRcas; // RCAS 锐化 0..1
  bool fxPhoto; // 照片超分（Lanczos3，照片向；与 fxFsr 互斥，photo 优先）
  double fxPhotoScale; // 照片超分放大倍数 1..3
  double fxPhotoSharp; // 照片超分锐化强度 0..1
  double fxPhotoGate; // 噪点保护 0..1（映射 luma 门限 *0.12，越高平坦区越少锐化）
  bool fxNeural; // 神经超分（ONNX 推理；就绪页替代放大着色器，按分类自动选模型）
  double fxNeuralScale; // 神经超分倍率 0.5..2（1.0=模型原生效果；>1 获得更多细节，上限 12MP）
  int fxNeuralTile; // 推理分块边长（0=跟随模型默认）；越小显存占用越低但越慢、接缝越多
  int fxNeuralOverlap; // 分块重叠像素 0..64，越大接缝过渡越平滑但越慢

  AppSettings({
    List<String>? libraryRoots,
    this.defaultMode = ReadingMode.rtl,
    this.defaultFit = PageFit.contain,
    this.defaultLayout = PageLayout.single,
    this.themeMode = 'dark',
    this.fxA4k = false,
    this.fxA4kStrength = 0.6,
    this.fxA4kEdge = 0.12,
    this.fxFsr = false,
    this.fxFsrScale = 1.6,
    this.fxRcas = 0.35,
    this.fxPhoto = false,
    this.fxPhotoScale = 1.6,
    this.fxPhotoSharp = 0.3,
    this.fxPhotoGate = 0.25,
    this.fxNeural = false,
    this.fxNeuralScale = 1.0,
    this.fxNeuralTile = 0,
    this.fxNeuralOverlap = 16,
  }) : libraryRoots = libraryRoots ?? [];

  Map<String, dynamic> toJson() => {
        'libraryRoots': libraryRoots,
        'defaultMode': readingModeName(defaultMode),
        'defaultFit': pageFitName(defaultFit),
        'defaultLayout': pageLayoutName(defaultLayout),
        'themeMode': themeMode,
        'fxA4k': fxA4k,
        'fxA4kStrength': fxA4kStrength,
        'fxA4kEdge': fxA4kEdge,
        'fxFsr': fxFsr,
        'fxFsrScale': fxFsrScale,
        'fxRcas': fxRcas,
        'fxPhoto': fxPhoto,
        'fxPhotoScale': fxPhotoScale,
        'fxPhotoSharp': fxPhotoSharp,
        'fxPhotoGate': fxPhotoGate,
        'fxNeural': fxNeural,
        'fxNeuralScale': fxNeuralScale,
        'fxNeuralTile': fxNeuralTile,
        'fxNeuralOverlap': fxNeuralOverlap,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        libraryRoots: [
          for (final r in (j['libraryRoots'] as List? ?? [])) r as String,
        ],
        defaultMode: readingModeOf(j['defaultMode'] as String?),
        defaultFit: pageFitOf(j['defaultFit'] as String?),
        defaultLayout: pageLayoutOf(j['defaultLayout'] as String?),
        themeMode: j['themeMode'] as String? ?? 'dark',
        fxA4k: j['fxA4k'] as bool? ?? false,
        fxA4kStrength: (j['fxA4kStrength'] as num?)?.toDouble() ?? 0.6,
        fxA4kEdge: (j['fxA4kEdge'] as num?)?.toDouble() ?? 0.12,
        fxFsr: j['fxFsr'] as bool? ?? false,
        fxFsrScale: (j['fxFsrScale'] as num?)?.toDouble() ?? 1.6,
        fxRcas: (j['fxRcas'] as num?)?.toDouble() ?? 0.35,
        fxPhoto: j['fxPhoto'] as bool? ?? false,
        fxPhotoScale: (j['fxPhotoScale'] as num?)?.toDouble() ?? 1.6,
        fxPhotoSharp: (j['fxPhotoSharp'] as num?)?.toDouble() ?? 0.3,
        fxPhotoGate: (j['fxPhotoGate'] as num?)?.toDouble() ?? 0.25,
        fxNeural: j['fxNeural'] as bool? ?? false,
        fxNeuralScale: (j['fxNeuralScale'] as num?)?.toDouble() ?? 1.0,
        fxNeuralTile: (j['fxNeuralTile'] as num?)?.toInt() ?? 0,
        fxNeuralOverlap: (j['fxNeuralOverlap'] as num?)?.toInt() ?? 16,
      );
}

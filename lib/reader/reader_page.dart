// 阅读器：右开/左开翻页、单/双页布局、条漫连续滚动、页面适应、缩放、进度保存。
// 移植自 mihon_fx（E:\Folders\Trea\mihon_fx），仅做适配 WnacgPc 的最小修改：
// store 换为 ReaderStore 适配层、进度记录附带总页数。
// 双页逻辑参考 Mihon：仅翻页模式生效；连续两竖页配对、横页独占一屏，竖页
// 不落单（无法向后配对时与前一竖页重叠）；RTL 时组内第一页显示在右侧；
// 进度记录组内首页。
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:window_manager/window_manager.dart';

import 'app_log.dart';
import 'fx_engine.dart';
import 'imgsize.dart';
import 'library.dart';
import 'models.dart';
import 'fx_panel.dart';
import 'reader_store.dart';
import '../net/image_bridge.dart';
import '../sr/sr_engine.dart';
import '../state/app_store.dart';

/// 解码上限：本站存在 11656×8742 一类的超大扫描图，全尺寸解码单张就吃
/// ~400MB 纹理，FX 1.6x 上采样后输出纹理再上 GB，连续分配会把系统内存
/// 打穿（应用+整机卡死，2026-09-07 实测事故）。显示端 4K 屏也只需 ~8MP，
/// 限到 12MP、长边 8192（Skia 纹理上限内）对阅读清晰度无感。
const int _maxDecodePixels = 12 * 1000 * 1000;
const int _maxDecodeEdge = 8192;

/// 计算受限解码尺寸（宽高同比缩，不失真）；无需限制时返回 null。
(int, int)? _cappedDecodeSize(int w, int h) {
  double s = 1.0;
  final edge = w > h ? w : h;
  if (edge > _maxDecodeEdge) s = _maxDecodeEdge / edge;
  if (w * h * s * s > _maxDecodePixels) {
    s = math.sqrt(_maxDecodePixels / (w * h));
  }
  if (s >= 1.0) return null;
  return (
    (w * s).round().clamp(1, 1 << 30),
    (h * s).round().clamp(1, 1 << 30),
  );
}

/// 预加载角标数据（不可变，ValueNotifier 驱动）。
/// 双向缓冲：after=向后（当前之后的页），before=向前（当前之前的页）。
class _PreloadBadgeData {
  const _PreloadBadgeData({
    this.online = false,
    this.beforeDone = 0,
    this.beforeTotal = 0,
    this.afterDone = 0,
    this.afterTotal = 0,
    this.cumulative = 0,
  });

  final bool online;
  final int beforeDone;
  final int beforeTotal;
  final int afterDone;
  final int afterTotal;
  final int cumulative;

  bool get finished =>
      beforeDone >= beforeTotal && afterDone >= afterTotal;

  @override
  bool operator ==(Object other) =>
      other is _PreloadBadgeData &&
      other.online == online &&
      other.beforeDone == beforeDone &&
      other.beforeTotal == beforeTotal &&
      other.afterDone == afterDone &&
      other.afterTotal == afterTotal &&
      other.cumulative == cumulative;

  @override
  int get hashCode => Object.hash(
      online, beforeDone, beforeTotal, afterDone, afterTotal, cumulative);
}

/// 左下角"当前页缓存来源"角标数据（null=隐藏）。
class _SrcBadgeData {
  const _SrcBadgeData(
      {required this.pages, required this.hits, required this.misses});

  final String pages; // "第 3 页" / "第 3-4 页"
  final int hits;
  final int misses;
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.store,
    required this.manga,
    required this.chapter,
    required this.page,
  });

  final ReaderStore store;
  final Manga manga;
  final int chapter;
  final int page;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late int _ch;
  List<PageItem> _pages = const [];
  ZipBook? _book;
  late ReadingMode _mode;
  late PageFit _fit;
  late PageLayout _layout;
  int _page = 0;
  bool _loading = true;
  bool _ui = true;
  bool _fullscreen = false;
  FxParams _fx = const FxParams(
    a4k: false, a4kStrength: 0.6, a4kEdge: 0.12,
    fsr: false, fsrScale: 1.6, rcas: 0.35,
    photo: false, photoScale: 1.6, photoSharp: 0.3, photoGate: 0.25,
  );

  /// 双页分组：每个元素是一屏要显示的页面索引（1 或 2 个）。
  List<List<int>> _groups = const [];
  int _groupIndex = 0;

  // ---------- 在线预加载计数（角标） ----------

  /// 双向预取窗口：before=向前（当前之前的页），after=向后（当前之后的页）。
  /// 向后永远比向前多 1（N 奇数 → 前 (N-1)/2 + 后 (N+1)/2）。
  int _winBeforeDone = 0;
  int _winBeforeTotal = 0;
  int _winAfterDone = 0;
  int _winAfterTotal = 0;
  /// 本章打开以来实际加载（非内存缓存命中）的页数。按"去重页"计：
  /// _fetchedSet 记录本章已计数的页，缓存被挤掉后重载的页不重复计数，
  /// 否则回翻时角标"已加载 z 页"会重复累加。
  int _fetchedTotal = 0;
  final Set<int> _fetchedSet = {};
  /// 预取代际：每次 _prefetch 自增。跳页/切布局会立刻再次触发 _prefetch，
  /// 此时旧串行链必须作废（停止加载、停止计数），否则旧窗口的页会继续
  /// 进缓存（实际缓冲超出限制），且回调里过期的窗口标记会把新窗口的
  /// 计数加穿，角标与实际缓冲数不一致。
  int _prefetchGen = 0;
  /// 字节缓存上限：跟随预取窗口放大，避免窗口大于缓存时刚预取的页被挤掉。
  int _cacheLimit = 12;
  bool _onlineChapter = false;
  final ValueNotifier<_PreloadBadgeData> _preload =
      ValueNotifier(const _PreloadBadgeData());
  /// 当前屏各页的磁盘缓存来源（true=命中直接复用，false=联网取回后写入）。
  /// 仅在线章节记录，驱动左下角命中/未命中角标。
  final Map<int, bool> _pageSrc = {};
  final ValueNotifier<_SrcBadgeData?> _srcBadge = ValueNotifier(null);

  PageController? _pc;
  final ItemScrollController _isc = ItemScrollController();
  final ItemPositionsListener _ipl = ItemPositionsListener.create();
  final ValueNotifier<bool> _zoomed = ValueNotifier(false);
  final ValueNotifier<bool> _ctrlDown = ValueNotifier(false);
  final TransformationController _vTc = TransformationController();
  bool _vZoomed = false;
  final Map<int, Uint8List> _cache = {};
  final Map<int, Future<Uint8List>> _inflight = {};
  final Map<int, double> _aspects = {};
  final Map<int, Size> _sizes = {};
  Timer? _applyTimer;

  /// 已解码纹理（按页索引）：pane 拿到即可同步渲染，翻页/双页重排不再闪占位帧。
  /// 所有权归本表：_FxImage 只借用（绝不 dispose），淘汰/换章时由这里统一释放。
  final Map<int, ui.Image> _decoded = {};

  /// 神经超分结果纹理（按页索引）：所有权归本表，与 _decoded 互不重叠——
  /// SR 在树时 pane 直接用 SR 图并跳过放大着色器（不写入 _decoded）。
  final Map<int, ui.Image> _srImages = {};
  /// SR 串行链：prefetch 每页字节到手后追加任务，与 _prefetchGen 对齐作废。
  Future<void> _srChain = Future<void>.value();

  /// 双页分组列表实例池：内容不变时复用同一 List 实例，
  /// 让 _GroupView.didUpdateWidget 的 identical 判断成立、保留子树状态。
  final Map<String, List<int>> _groupPool = {};

  List<int> _internGroup(List<int> g) {
    final k = g.join('-');
    return _groupPool.putIfAbsent(k, () => List<int>.unmodifiable(g));
  }

  ui.Image? _presetFor(int i) => _decoded[i];

  void _onDecoded(int i, ui.Image img) {
    // SR 就绪换图等场景会覆盖同页纹理：旧图立即释放，否则逐页泄漏
    final old = _decoded[i];
    if (old != null && !identical(old, img)) old.dispose();
    _decoded[i] = img;
  }

  /// 只淘汰离当前屏较远的页（±2 屏外不可能挂载），避免释放正在显示的纹理。
  void _evictDecoded() {
    final keep = <int>{};
    if (_mode == ReadingMode.vertical) {
      for (var k = -2; k <= 2; k++) {
        final i = _page + k;
        if (i >= 0 && i < _pages.length) keep.add(i);
      }
    } else {
      for (var g = _groupIndex - 2; g <= _groupIndex + 2; g++) {
        if (g >= 0 && g < _groups.length) keep.addAll(_groups[g]);
      }
    }
    for (final k in _decoded.keys.toList()) {
      if (!keep.contains(k)) _decoded.remove(k)!.dispose();
    }
    for (final k in _srImages.keys.toList()) {
      if (!keep.contains(k)) _srImages.remove(k)!.dispose();
    }
  }

  void _disposeDecoded() {
    for (final img in _decoded.values) {
      img.dispose();
    }
    _decoded.clear();
    for (final img in _srImages.values) {
      img.dispose();
    }
    _srImages.clear();
  }

  @override
  void initState() {
    super.initState();
    _ch = widget.chapter;
    _mode = widget.store.settings.defaultMode;
    _fit = widget.store.settings.defaultFit;
    _layout = widget.store.settings.defaultLayout;
    _fx = FxParams.fromSettings(widget.store.settings);
    // 神经超分默认开启：进阅读器即预热引擎与会话（后台，失败静默）
    if (_fx.neural) {
      unawaited(SrEngine.instance
          .warm([SrModel.pickFor(widget.manga.categoryIds)])
          .then((_) {
        if (mounted) setState(() {});
      }));
    }
    HardwareKeyboard.instance.addHandler(_onHwKey);
    _vTc.addListener(_onVTcChanged);
    _ipl.itemPositions.addListener(_onPositions);
    _open(_ch, widget.page);
  }

  // ---------- 画质增强（FX） ----------

  void _updateFx(FxParams p) {
    final wasNeural = _fx.neural;
    setState(() => _fx = p);
    // 滑杆拖动会连续触发，聚合后只记最终值
    AppLog.throttled('fx', '参数 a4k=${p.a4k}(s=${p.a4kStrength.toStringAsFixed(2)}/e=${p.a4kEdge.toStringAsFixed(2)}) '
        'fsr=${p.fsr}(${p.fsrScale.toStringAsFixed(1)}x/r=${p.rcas.toStringAsFixed(2)}) '
        'photo=${p.photo}(${p.photoScale.toStringAsFixed(1)}x/r=${p.photoSharp.toStringAsFixed(2)}/g=${p.photoGate.toStringAsFixed(2)}) '
        'neural=${p.neural}(${p.neuralScale.toStringAsFixed(2)}x/t=${p.neuralTile}/o=${p.neuralOverlap})');
    final s = widget.store;
    s.setFxA4k(p.a4k);
    s.setFxA4kStrength(p.a4kStrength);
    s.setFxA4kEdge(p.a4kEdge);
    s.setFxFsr(p.fsr);
    s.setFxFsrScale(p.fsrScale);
    s.setFxRcas(p.rcas);
    s.setFxPhoto(p.photo);
    s.setFxPhotoScale(p.photoScale);
    s.setFxPhotoSharp(p.photoSharp);
    s.setFxPhotoGate(p.photoGate);
    s.setFxNeural(p.neural);
    s.setFxNeuralScale(p.neuralScale);
    s.setFxNeuralTile(p.neuralTile);
    s.setFxNeuralOverlap(p.neuralOverlap);
    // 神经超分参数（开关/倍率/分块/重叠）变化：丢弃已出的 SR 纹理并重算当前屏，
    // 磁盘缓存按参数键自动分离，无需清理。
    final srChanged = p.neural != wasNeural ||
        p.neuralScale != _fx.neuralScale ||
        p.neuralTile != _fx.neuralTile ||
        p.neuralOverlap != _fx.neuralOverlap;
    if (srChanged) {
      for (final img in _srImages.values) {
        img.dispose();
      }
      _srImages.clear();
      _kickSr();
    }
  }

  void _showFxSheet() {
    AppLog.i('fx', '打开调参面板');
    // 神经超分：打开面板时顺带初始化引擎，让状态行尽快显示真实设备
    if (_fx.neural) {
      unawaited(SrEngine.instance.ensureInit().then((_) {
        if (mounted) setState(() {});
      }));
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: FxPanel(
              params: _fx,
              srDevice: SrEngine.instance.device,
              onChanged: (p) {
                _updateFx(p);
                setSheetState(() {});
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 条漫缩放状态（Ctrl+滚轮，InteractiveViewer 挂 _vTc）。
  void _onVTcChanged() {
    final z = _vTc.value.getMaxScaleOnAxis() > 1.01;
    if (z != _vZoomed) setState(() => _vZoomed = z);
  }

  /// 跟踪 Ctrl 按键状态：Ctrl+滚轮 → 缩放，普通滚轮 → 翻页。
  bool _onHwKey(KeyEvent e) {
    final v = HardwareKeyboard.instance.isControlPressed;
    if (v != _ctrlDown.value) _ctrlDown.value = v;
    return false;
  }

  @override
  void dispose() {
    _ipl.itemPositions.removeListener(_onPositions);
    HardwareKeyboard.instance.removeHandler(_onHwKey);
    if (_fullscreen) {
      // 退出阅读器时还原窗口（不 await，dispose 不能挂起）
      windowManager.setFullScreen(false);
    }
    _pc?.dispose();
    _applyTimer?.cancel();
    _preload.dispose();
    _srcBadge.dispose();
    _disposeDecoded();
    _book?.close();
    _zoomed.dispose();
    _ctrlDown.dispose();
    _vTc.dispose();
    // 立刻落盘，防止直接关窗口丢进度
    widget.store.flushSave();
    AppLog.i('阅读', '退出阅读器 ${widget.manga.title}');
    super.dispose();
  }

  Future<void> _open(int ch, int startPage) async {
    final m = widget.manga;
    if (ch < 0 || ch >= m.chapters.length) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (mounted) setState(() => _loading = true);
    _book?.close();
    _book = null;
    _cache.clear();
    _inflight.clear();
    _aspects.clear();
    _zoomed.value = false;
    _vTc.value = Matrix4.identity();
    _pc?.dispose();
    _pc = null;

    final ChapterPages cp;
    try {
      cp = await loadChapterPages(m.chapters[ch]);
    } catch (e) {
      AppLog.w('阅读', '章节加载失败 ch=$ch ${m.chapters[ch].title} | $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _pages = const [];
        });
      }
      return;
    }
    if (!mounted) {
      cp.close();
      return;
    }
    AppLog.i('阅读', '打开 ${m.title} ch=${ch + 1}/${m.chapters.length} 起始页=${startPage + 1} 共${cp.pages.length}页');
    _pages = cp.pages;
    _book = cp.book;
    _ch = ch;
    _page = startPage.clamp(0, _pages.isEmpty ? 0 : _pages.length - 1);
    _sizes.clear();
    _groupPool.clear();
    _disposeDecoded();
    _onlineChapter = _pages.isNotEmpty && _pages.first.url != null;
    _pageSrc.clear();
    _srcBadge.value = null;
    _fetchedTotal = 0;
    _fetchedSet.clear();
    _winBeforeDone = 0;
    _winBeforeTotal = 0;
    _winAfterDone = 0;
    _winAfterTotal = 0;
    _pushPreload();
    _groups = _computeGroups();
    _groupIndex = _groupOfPage(_page);
    if (_mode != ReadingMode.vertical) {
      _pc = PageController(initialPage: _groupIndex);
    }
    setState(() => _loading = false);
    if (_mode == ReadingMode.vertical) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isc.isAttached && _pages.isNotEmpty) _isc.jumpTo(index: _page);
      });
    }
    _loadSizes();
    _prefetch();
    _pushProgress();
    // 打开章节后按设置上限做一次缓存自动清理（后台执行，不阻塞阅读）
    unawaited(ImageBridge.instance
        .enforceCacheLimit(AppStore.instance.imageCacheMaxMb * 1048576)
        .catchError((_) => 0));
  }

  // ---------- 双页分组（参考 Mihon PageLayout.DOUBLE_PAGES） ----------

  /// 宽 > 高 的页面（跨页大图）单独占一屏，其余连续两页配对。
  bool _isWide(int i) {
    final s = _sizes[i];
    return s != null && s.width > s.height;
  }

  List<List<int>> _computeGroups() {
    final list = <List<int>>[];
    if (_pages.isEmpty) return list;
    if (_layout == PageLayout.single || _mode == ReadingMode.vertical) {
      for (var i = 0; i < _pages.length; i++) {
        list.add(_internGroup([i]));
      }
      return list;
    }
    // 双页：连续两竖页配对，横页独占一屏；竖页永不落单——当某竖页无法
    // 向后配对时（下一页是横页，或它已是最后一页），与前一竖页重叠成
    // 一屏（该页会重复显示一次）。例：竖1 竖2 竖3 横4 竖5 竖6 竖7 →
    // [1,2] [2,3] [4] [5,6] [6,7]。
    var i = 0;
    while (i < _pages.length) {
      if (_isWide(i)) {
        list.add(_internGroup([i]));
        i++;
        continue;
      }
      final j = i + 1;
      if (j < _pages.length && !_isWide(j)) {
        list.add(_internGroup([i, j]));
        i += 2;
      } else {
        final prev = list.isNotEmpty ? list.last : null;
        if (prev != null && prev.length == 2) {
          list.add(_internGroup([i - 1, i]));
        } else {
          list.add(_internGroup([i]));
        }
        i++;
      }
    }
    return list;
  }

  int _groupOfPageIn(List<List<int>> groups, int p) {
    // 重叠配对时一页可属于两屏：优先取以它为"左页"的那屏，进度/跳页
    // 才能落回用户看到它首页的那一组。
    for (var g = 0; g < groups.length; g++) {
      if (groups[g].isNotEmpty && groups[g].first == p) return g;
    }
    for (var g = 0; g < groups.length; g++) {
      if (groups[g].contains(p)) return g;
    }
    return 0;
  }

  int _groupOfPage(int p) => _groupOfPageIn(_groups, p);

  /// 后台逐页嗅探尺寸（只读文件头），完成后重算双页分组。
  Future<void> _loadSizes() async {
    final pages = _pages;
    for (var i = 0; i < pages.length; i++) {
      if (!mounted || !identical(pages, _pages)) return;
      final s = await probePageSize(pages[i]);
      if (!mounted || !identical(pages, _pages)) return;
      if (s != null) _sizes[i] = s;
    }
    if (!mounted || !identical(pages, _pages)) return;
    if (_layout == PageLayout.double && _mode != ReadingMode.vertical) {
      _applyGroups();
    } else {
      setState(() {});
    }
  }

  /// 用已知的页面尺寸重新分组，并保持当前页可见。
  void _applyGroups() {
    final newGroups = _computeGroups();
    if (_sameGroups(newGroups, _groups)) {
      // 分组未变也必须重建：在线页尺寸是异步到手的，fitHeight 的居中判定
      // 依赖 sizeOf；沉默返回会让页面停在"尺寸未知"的靠左回退布局，
      // 直到翻页触发重建才居中（v1.3.1 修复的在线双页适应高度偏左 bug）。
      setState(() {});
      return;
    }
    AppLog.i('阅读', '双页分组更新 ${_groupsSummary(newGroups)}');
    final gi = _groupOfPageIn(newGroups, _page);
    setState(() {
      _groups = newGroups;
      _groupIndex = gi;
    });
    if (_mode != ReadingMode.vertical && _pc != null && _pc!.hasClients) {
      _pc!.jumpToPage(gi);
    }
    _evictDecoded();
  }

  bool _sameGroups(List<List<int>> a, List<List<int>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (var j = 0; j < a[i].length; j++) {
        if (a[i][j] != b[i][j]) return false;
      }
    }
    return true;
  }

  String _groupsSummary(List<List<int>> groups) {
    var s = '';
    for (final g in groups) {
      s = s.isEmpty ? _groupLabel(g) : '$s,${_groupLabel(g)}';
      if (s.length > 220) return '$s…(${groups.length}屏)';
    }
    return '$s (${groups.length}屏)';
  }

  String _groupLabel(List<int> g) =>
      g.length == 1 ? '${g.first + 1}' : '${g.first + 1}-${g.last + 1}';

  /// 字节陆续到手会连续触发分组重算，聚合到短延迟后一次生效。
  void _scheduleApplyGroups() {
    final pages = _pages;
    _applyTimer?.cancel();
    _applyTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted || !identical(pages, _pages)) return;
      if (_useGroups) {
        _applyGroups();
      } else {
        // 非双页布局无需重算分组，但适应高度分支的居中判定依赖 sizeOf——
        // 尺寸到手后必须重建，否则停留在"尺寸未知"的靠左回退布局直到下次翻页。
        setState(() {});
      }
    });
  }

  /// 顶栏/滑块显示的页码（双页时显示区间）。
  String _pageLabel() {
    if (_pages.isEmpty) return '0 / 0';
    if (_mode != ReadingMode.vertical &&
        _layout == PageLayout.double &&
        _groupIndex < _groups.length) {
      final g = _groups[_groupIndex];
      if (g.length == 2) return '${g.first + 1}-${g.last + 1} / ${_pages.length}';
    }
    return '${_page + 1} / ${_pages.length}';
  }

  // ---------- 进度 ----------

  void _pushProgress() {
    widget.store.updateProgress(widget.manga.id, _ch, _page, _pages.length);
    _updateSrcBadge();
  }

  // ---------- 页面加载 ----------

  Future<Uint8List> _loadBytes(int i) {
    // 命中即刷新插入序（LRU 语义）：回翻时刚用过的页不会被新预取挤出
    // 缓存，避免"已缓存却重新走网络"——那既浪费请求，也会让计数重复。
    final hit = _cache.remove(i);
    if (hit != null) {
      _cache[i] = hit;
      return Future.value(hit);
    }
    // 并发去重：同一页只发起一次读取/下载，多个等待者共享结果
    final pages = _pages;
    final aid = widget.manga.id; // 在线章节即漫画 aid，缓存按漫画分目录
    return _inflight.putIfAbsent(i, () async {
      try {
        final b = await readPageBytes(_pages[i],
            cacheId: aid, page: i, onSource: (hit) {
          if (identical(pages, _pages)) _notePageSource(i, hit);
        });
        _cache[i] = b;
        while (_cache.length > _cacheLimit) {
          _cache.remove(_cache.keys.first);
        }
        // 真实加载（网络/磁盘）计入累计数：每章每页只计一次；换章后
        // 的迟到回调既不计数也不污染去重集合
        if (identical(pages, _pages) && _fetchedSet.add(i)) {
          _fetchedTotal++;
          _pushPreload();
        }
        return b;
      } finally {
        _inflight.remove(i);
      }
    });
  }

  Future<double> _aspectFor(int i) async {
    final s = _sizes[i];
    if (s != null && s.height > 0) return s.width / s.height;
    final hit = _aspects[i];
    if (hit != null) return hit;
    final probed =
          await probePageSize(_pages[i], cacheId: widget.manga.id, page: i);
    if (probed != null && probed.height > 0) {
      _sizes[i] = probed;
      return probed.width / probed.height;
    }
    final bytes = await _loadBytes(i);
    // 兜底解码只为取宽高比，限宽即可，避免超大图全尺寸解码
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1280);
    final frame = await codec.getNextFrame();
    final a = frame.image.width / frame.image.height;
    frame.image.dispose();
    codec.dispose();
    _aspects[i] = a;
    return a;
  }

  void _pushPreload() {
    _preload.value = _PreloadBadgeData(
      online: _onlineChapter,
      beforeDone: _winBeforeDone,
      beforeTotal: _winBeforeTotal,
      afterDone: _winAfterDone,
      afterTotal: _winAfterTotal,
      cumulative: _fetchedTotal,
    );
  }

  void _notePageSource(int i, bool hit) {
    _pageSrc[i] = hit;
    _updateSrcBadge();
  }

  /// 左下角角标：当前屏页码 + 磁盘缓存命中/未命中（仅在线章节）。
  /// 来源未到的页不计入；一页来源都没有时隐藏。
  void _updateSrcBadge() {
    if (!_onlineChapter) {
      _srcBadge.value = null;
      return;
    }
    final idx = <int>[];
    if (_mode == ReadingMode.vertical) {
      if (_page >= 0 && _page < _pages.length) idx.add(_page);
    } else if (_useGroups && _groupIndex >= 0 && _groupIndex < _groups.length) {
      idx.addAll(_groups[_groupIndex]);
    } else if (_page >= 0 && _page < _pages.length) {
      idx.add(_page);
    }
    var hits = 0, misses = 0;
    for (final i in idx) {
      final h = _pageSrc[i];
      if (h == null) continue;
      if (h) {
        hits++;
      } else {
        misses++;
      }
    }
    if (idx.isEmpty || (hits == 0 && misses == 0)) {
      _srcBadge.value = null;
      return;
    }
    final label = idx.length == 1
        ? '第 ${idx.first + 1} 页'
        : '第 ${idx.first + 1}-${idx.last + 1} 页';
    _srcBadge.value = _SrcBadgeData(pages: label, hits: hits, misses: misses);
  }

  /// 双向预取（N=设置里的"在线阅读预加载页数"，奇数，0=仅当前屏）：
  /// 向后（当前之后的页）(N+1)/2 页，向前（当前之前的页）(N-1)/2 页，
  /// 向后永远比向前多 1。字节到手立即嗅探尺寸并按新尺寸重算双页分组。
  /// 在线页的横竖只有等缓存到手才能判定，配对结果随预加载逐步收敛。
  /// 注意：图片桥共用一个隐藏 WebView，并发抓取过多会互相挤压导致
  /// 消息泵阻塞，因此预取串行执行（一次一页），当前屏优先，向后优先于向前。
  void _prefetch() {
    final pages = _pages;
    final gen = ++_prefetchGen;
    final n = widget.store.preloadPages;
    final fwd = n ~/ 2; // 向前（之前）
    final back = n - fwd; // 向后（之后）= 向前 + 1
    final order = <int>[];
    // 窗口归属：0=当前屏（不计角标），1=向前，2=向后
    final win = <int, int>{};
    void add(int i, int w) {
      if (i >= 0 && i < pages.length && !order.contains(i)) {
        order.add(i);
        win[i] = w;
      }
    }

    void addGroup(int g) {
      if (g >= 0 && g < _groups.length) {
        for (final i in _groups[g]) {
          add(i, 0);
        }
      }
    }

    var beforeTotal = 0;
    var afterTotal = 0;
    if (_mode == ReadingMode.vertical) {
      add(_page, 0);
      // 向后（之后的页）优先入队
      for (var k = 1; k <= back; k++) {
        final i = _page + k;
        if (i < pages.length) {
          add(i, 2);
          afterTotal++;
        }
      }
      for (var k = 1; k <= fwd; k++) {
        final i = _page - k;
        if (i >= 0) {
          add(i, 1);
          beforeTotal++;
        }
      }
    } else {
      addGroup(_groupIndex);
      final gFirst =
          _groupIndex < _groups.length ? _groups[_groupIndex].first : _page;
      final gLast =
          _groupIndex < _groups.length ? _groups[_groupIndex].last : _page;
      for (var i = gLast + 1; i < gLast + 1 + back && i < pages.length; i++) {
        add(i, 2);
        afterTotal++;
      }
      for (var k = 1; k <= fwd; k++) {
        final i = gFirst - k;
        if (i >= 0) {
          add(i, 1);
          beforeTotal++;
        }
      }
    }
    _cacheLimit = order.length + 4;
    _winBeforeTotal = beforeTotal;
    _winBeforeDone = 0;
    _winAfterTotal = afterTotal;
    _winAfterDone = 0;
    _pushPreload();
    Future<void> chain = Future<void>.value();
    for (final i in order) {
      final w = win[i] ?? 0;
      chain = chain.then((_) async {
        final stale = gen != _prefetchGen;
        if (!mounted || stale || !identical(pages, _pages)) return;
        final b = await _loadBytes(i);
        if (gen != _prefetchGen || !identical(pages, _pages)) return;
        if (w == 1) {
          _winBeforeDone++;
          _pushPreload();
        } else if (w == 2) {
          _winAfterDone++;
          _pushPreload();
        }
        if (_sizes[i] != null) {
          _enqueueSr(i, b);
          return;
        }
        final s = sniffImageSize(b);
        if (s != null) {
          _sizes[i] = s;
          _scheduleApplyGroups();
        }
        _enqueueSr(i, b);
      }).catchError((e) {
        AppLog.w('阅读', '预取第${i + 1}页失败: $e');
        if (w != 0 &&
            gen == _prefetchGen &&
            identical(pages, _pages)) {
          if (w == 1) {
            _winBeforeDone++;
          } else {
            _winAfterDone++;
          }
          _pushPreload();
        }
      });
    }
  }

  // ---------- 神经超分 ----------

  ui.Image? _srFor(int i) => _srImages[i];

  /// 磁盘缓存键含神经网络超分参数（倍率/分块/重叠），任一改动即换新键——旧键自然失效，
  /// 免于清目录（陈旧文件最终由缓存容量清理回收）。
  String _srCacheName(int i) =>
      '${i.toString().padLeft(5, '0')}_s${_fx.neuralScale.toStringAsFixed(1)}'
      '_t${_fx.neuralTile == 0 ? 'm' : _fx.neuralTile}_o${_fx.neuralOverlap}';

  void _storeSr(int i, ui.Image img) {
    _srImages[i] = img;
    _evictDecoded(); // 同一 keep 集合同时修剪 SR 表
    if (mounted) setState(() {});
  }

  /// 右键页面 → 图片信息菜单：源/显示分辨率、编码格式、文件大小与码率、
  /// 超分模式与超分后分辨率。sync 数据即时可得；字节未命中内存缓存时补拉 2s。
  Future<void> _showImageInfo(int i, Offset screenPos) async {
    AppLog.i('ui', '右键图片信息 p$i');
    var sr = _srImages[i];
    final preset = _decoded[i];
    final srcSize = _sizes[i];
    Uint8List? bytes = _cache[i];
    if (bytes == null) {
      try {
        bytes = await _loadBytes(i).timeout(const Duration(seconds: 2));
      } catch (_) {
        bytes = null;
      }
      sr = _srImages[i]; // 拉字节期间推理可能已就绪
    }
    final device = SrEngine.instance.device;
    final rows = <String>['页面：第 ${i + 1} 页'];
    if (srcSize != null && srcSize.width > 0 && srcSize.height > 0) {
      rows.add('源分辨率：${srcSize.width.round()}×${srcSize.height.round()}');
      final bpp = bytes != null ? bytes.length * 8 / (srcSize.width * srcSize.height) : null;
      rows.add('文件大小：${bytes == null ? '未知' : _fmtBytes(bytes.length)}'
          '${bpp == null ? '' : ' · 码率≈${bpp.toStringAsFixed(2)} bpp'}');
    } else if (bytes != null) {
      rows.add('文件大小：${_fmtBytes(bytes.length)}');
    }
    rows.add('编码格式：${bytes == null ? '未知' : sniffImageFormat(bytes)}');
    if (preset != null) {
      final capped = srcSize != null &&
          (preset.width < srcSize.width.round() || preset.height < srcSize.height.round());
      rows.add('显示分辨率：${preset.width}×${preset.height}${capped ? '（受限解码）' : ''}');
    }
    // 超分模式：SR 纹理已显示（含磁盘缓存命中）> 原始大小禁用 > 排队中 > 着色器 > 关闭。
    if (sr != null) {
      final dev = device == SrDevice.directml ? 'DirectML' : 'CPU';
      rows.add('超分模式：神经超分（$dev）');
      rows.add('超分后分辨率：${sr.width}×${sr.height}');
    } else if (_fit == PageFit.original) {
      rows.add(_fx.neural ? '超分模式：神经超分 · 原始大小模式禁用' : '超分模式：未启用');
    } else if (_fx.neural && device != SrDevice.unavailable) {
      final dev = device == SrDevice.directml ? 'DirectML' : 'CPU';
      rows.add('超分模式：神经超分（$dev）· 推理排队中，就绪后自动换图');
    } else {
      final shader = _fx.fsr ? 'FSR' : _fx.photo ? '照片' : null;
      rows.add('超分模式：${shader == null ? '未启用' : '着色器（$shader）'}'
          '${_fx.neural ? ' · 神经超分引擎不可用' : ''}');
    }

    if (!mounted) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromRect(
        overlay.localToGlobal(screenPos) & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      elevation: 6,
      items: [
        for (final r in rows)
          PopupMenuItem<void>(
            enabled: false,
            height: 30,
            child: Text(r, style: const TextStyle(fontSize: 12.5)),
          ),
      ],
    );
  }

  static String _fmtBytes(int n) {
    if (n >= (1 << 20)) return '${(n / (1 << 20)).toStringAsFixed(2)} MB';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '$n B';
  }

  /// 神经开关切换（或预取未覆盖的时机）后补排当前屏。
  void _kickSr() {
    if (!_fx.neural) return;
    final idx = <int>[];
    if (_mode == ReadingMode.vertical) {
      if (_page >= 0 && _page < _pages.length) idx.add(_page);
    } else if (_useGroups && _groupIndex >= 0 && _groupIndex < _groups.length) {
      idx.addAll(_groups[_groupIndex]);
    } else if (_page >= 0 && _page < _pages.length) {
      idx.add(_page);
    }
    for (final i in idx) {
      _srChain = _srChain.then((_) => _srTask(i));
    }
  }

  void _enqueueSr(int i, Uint8List b) {
    if (!_fx.neural) return;
    _srChain = _srChain.then((_) => _srTask(i, b));
  }

  /// 单页 SR：磁盘缓存 → 推理 → 落盘。任何一步失败静默（继续走现有着色器）。
  /// 代际/换章守卫与预取链同款：过期结果直接丢弃（纹理一并释放）。
  Future<void> _srTask(int i, [Uint8List? bytesIn]) async {
    if (!mounted || !_fx.neural || _fit == PageFit.original) return;
    if (_srImages[i] != null) return;
    final pages = _pages;
    final gen = _prefetchGen;
    final mq = MediaQuery.of(context);
    final b = bytesIn ?? await _loadBytes(i);
    if (!mounted || gen != _prefetchGen || !identical(pages, _pages)) return;
    if (_srImages[i] != null) return;

    // 1) 磁盘缓存命中：直接解码（PNG ≤12MP，构造时已钳制）
    final cached =
        await ImageBridge.instance.readSrCache(widget.manga.id, _srCacheName(i));
    if (!mounted || gen != _prefetchGen || !identical(pages, _pages)) return;
    if (cached != null) {
      final img = await _decodeFull(cached);
      if (!mounted || gen != _prefetchGen || !identical(pages, _pages)) {
        img?.dispose();
        return;
      }
      if (img != null) _storeSr(i, img);
      return;
    }

    // 2) 推理：目标 = min(有效源×模型倍率, 视口×dpr×1.25, 12MP)，不足则不做（白算）。
    //    有效源 = 解码端实际尺寸（超大源已被 _cappedDecodeSize 压到 ≤12MP——
    //    与其比较原始尺寸会让"目标反而小于已显示纹理"的页错误地进入推理）。
    var src = _sizes[i] ?? sniffImageSize(b);
    if (src == null || src.width < 16 || src.height < 16) return;
    final cap = _cappedDecodeSize(src.width.round(), src.height.round());
    if (cap != null) src = Size(cap.$1.toDouble(), cap.$2.toDouble());
    final model = SrModel.pickFor(widget.manga.categoryIds);
    // 倍率系数同时放大"源侧目标"与"视口细节上限"：1.0=原生效果；>1 换更多细节（仍受 12MP 钳制）。
    final mult = _fx.neuralScale.clamp(0.5, 2.0);
    final needW = mq.size.width * mq.devicePixelRatio * 1.25 * mult;
    final needH = mq.size.height * mq.devicePixelRatio * 1.25 * mult;
    var tw = (math.min(src.width * model.expectedScale * mult, needW)).round();
    var th = (tw * src.height / src.width).round();
    if (th > needH) {
      th = needH.round();
      tw = (th * src.width / src.height).round();
    }
    final px = tw * th;
    if (px > SrEngine.maxOutPixels) {
      final f = math.sqrt(SrEngine.maxOutPixels / px);
      tw = (tw * f).round();
      th = (th * f).round();
    }
    if (tw <= src.width || th <= src.height || tw < 16 || th < 16) return;
    final r = await SrEngine.instance.upscale(
      model: model,
      srcBytes: b,
      targetW: tw,
      targetH: th,
      tile: _fx.neuralTile == 0 ? null : _fx.neuralTile,
      overlap: _fx.neuralOverlap,
    );
    if (!mounted || gen != _prefetchGen || !identical(pages, _pages)) {
      r?.image.dispose();
      return;
    }
    if (r == null) return;
    _storeSr(i, r.image);
    unawaited(_persistSr(i, r.image));
  }

  /// SR 结果写盘（PNG）。后台执行、失败静默；重开书可秒读缓存免推理。
  Future<void> _persistSr(int i, ui.Image img) async {
    try {
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bd != null) {
        await ImageBridge.instance
            .writeSrCache(widget.manga.id, _srCacheName(i), bd.buffer.asUint8List());
      }
    } catch (_) {}
  }

  Future<ui.Image?> _decodeFull(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  // ---------- 翻页 ----------

  bool get _useGroups => _mode != ReadingMode.vertical && _layout == PageLayout.double;

  bool get _hasNextPage => _useGroups
      ? _groupIndex < _groups.length - 1
      : _page < _pages.length - 1;

  bool get _hasPrevPage => _useGroups ? _groupIndex > 0 : _page > 0;

  void _onPageChanged(int g) {
    setState(() {
      _groupIndex = g;
      if (g < _groups.length) _page = _groups[g].first;
    });
    AppLog.i('阅读', '翻页 → ${_pageLabel()}');
    _evictDecoded();
    _prefetch();
    _pushProgress();
  }

  void _scrollToPage(int i) {
    _isc.scrollTo(index: i.clamp(0, _pages.length - 1), duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
  }

  void _jumpToPage(int i) {
    if (_pages.isEmpty) return;
    final p = i.clamp(0, _pages.length - 1);
    if (_mode == ReadingMode.vertical) {
      setState(() => _page = p);
      if (_isc.isAttached) _isc.jumpTo(index: p);
    } else {
      _jumpToGroup(_groupOfPage(p));
    }
    _prefetch();
    _pushProgress();
  }

  void _jumpToGroup(int g) {
    if (_groups.isEmpty) return;
    final gi = g.clamp(0, _groups.length - 1);
    setState(() {
      _groupIndex = gi;
      _page = _groups[gi].first;
    });
    if (_pc != null && _pc!.hasClients) {
      _pc!.jumpToPage(gi);
    }
    _prefetch();
    _pushProgress();
  }

  Future<void> _nextPage() async {
    if (_pages.isEmpty) return;
    if (_mode == ReadingMode.vertical) {
      if (_hasNextPage) {
        _scrollToPage(_page + 1);
      } else {
        _endOfChapter();
      }
      return;
    }
    if (_hasNextPage) {
      await _pc?.nextPage(duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    } else {
      _endOfChapter();
    }
  }

  void _prevPage() {
    if (_pages.isEmpty) return;
    if (_mode == ReadingMode.vertical) {
      if (_hasPrevPage) _scrollToPage(_page - 1);
      return;
    }
    if (_hasPrevPage) {
      _pc?.previousPage(duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    } else {
      if (_ch > 0) _snack('已是本章第一页', action: '上一话', onAction: () => _open(_ch - 1, 0));
    }
  }

  void _endOfChapter() {
    if (_ch < widget.manga.chapters.length - 1) {
      _snack('已是本章最后一页', action: '下一话', onAction: () => _open(_ch + 1, 0));
    } else {
      _snack('已经是最后一话了');
    }
  }

  // ---------- 全屏 ----------

  Future<void> _toggleFullscreen() async {
    final fs = await windowManager.isFullScreen();
    final sw = Stopwatch()..start();
    final action = fs ? '退出' : '进入';
    AppLog.i('全屏', '$action全屏开始');
    await windowManager.setFullScreen(!fs);
    sw.stop();
    AppLog.i('全屏', '$action全屏完成 耗时=${sw.elapsedMilliseconds}ms');
    if (mounted) setState(() => _fullscreen = !fs);
  }

  void _snack(String msg, {String? action, VoidCallback? onAction}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
      action: action == null ? null : SnackBarAction(label: action, onPressed: onAction ?? () {}),
    ));
  }

  // ---------- 输入 ----------

  void _onTapUp(TapUpDetails d, double width) {
    if (_zoomed.value || (_mode == ReadingMode.vertical && _vZoomed)) return;
    final dx = d.localPosition.dx;
    if (_mode == ReadingMode.vertical) {
      if (dx < width * 0.3 || dx > width * 0.7) {
        if (_hasNextPage) {
          _scrollToPage(_page + 1);
        } else {
          _endOfChapter();
        }
      } else {
        setState(() => _ui = !_ui);
      }
      return;
    }
    final rtl = _mode == ReadingMode.rtl;
    if (dx < width * 0.3) {
      rtl ? _nextPage() : _prevPage();
    } else if (dx > width * 0.7) {
      rtl ? _prevPage() : _nextPage();
    } else {
      setState(() => _ui = !_ui);
    }
  }

  /// 滚轮：下滑=下一页、上滑=上一页；Ctrl+滚轮不在此处理，交给
  /// InteractiveViewer 缩放（其 scaleEnabled 由 _ctrlDown 控制）。
  void _onWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (HardwareKeyboard.instance.isControlPressed) return;
    if (_mode == ReadingMode.vertical || _zoomed.value) return;
    if (e.scrollDelta.dy > 0) {
      _nextPage();
    } else if (e.scrollDelta.dy < 0) {
      _prevPage();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final rtl = _mode == ReadingMode.rtl;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.arrowRight) {
      rtl ? _prevPage() : _nextPage();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      rtl ? _nextPage() : _prevPage();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.pageDown) {
      _nextPage();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.pageUp) {
      _prevPage();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.home) {
      _jumpToPage(0);
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.end) {
      _jumpToPage(_pages.length - 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onPositions() {
    if (_mode != ReadingMode.vertical || _pages.isEmpty) return;
    final positions = _ipl.itemPositions.value;
    if (positions.isEmpty) return;
    final above = positions.where((p) => p.itemLeadingEdge < 0.5).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final cur = above.isEmpty
        ? positions.reduce((a, b) => a.index < b.index ? a : b).index
        : above.last.index;
    if (cur != _page && cur >= 0 && cur < _pages.length) {
      setState(() => _page = cur);
      AppLog.i('阅读', '滚动 → 第${cur + 1}页');
      _evictDecoded();
      _prefetch();
      _pushProgress();
    }
  }

  void _setMode(ReadingMode m) {
    AppLog.i('阅读', '切换方向 → ${readingModeLabel(m)}');
    widget.store.setDefaultMode(m); // 写入全局偏好（与 _setLayout 同款；原只改会话）
    setState(() {
      _mode = m;
      _pc?.dispose();
      if (m == ReadingMode.vertical) {
        _pc = null;
      } else {
        _groups = _computeGroups();
        _groupIndex = _groupOfPage(_page);
        _pc = PageController(initialPage: _groupIndex);
      }
      _zoomed.value = false;
      _vTc.value = Matrix4.identity();
    });
    if (m == ReadingMode.vertical) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isc.isAttached && _pages.isNotEmpty) _isc.jumpTo(index: _page);
      });
    }
    _prefetch();
    _updateSrcBadge();
  }

  /// 单/双页切换（Mihon：阅读器内切换会写入全局偏好）。
  void _setLayout(PageLayout l) {
    if (_layout == l) return;
    AppLog.i('阅读', '切换布局 → ${pageLayoutLabel(l)}');
    widget.store.setDefaultLayout(l);
    setState(() {
      _layout = l;
      _pc?.dispose();
      if (_mode == ReadingMode.vertical) {
        _pc = null;
      } else {
        _groups = _computeGroups();
        _groupIndex = _groupOfPage(_page);
        _pc = PageController(initialPage: _groupIndex);
      }
      _zoomed.value = false;
    });
    _prefetch();
    _pushProgress();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final m = widget.manga;
    final chapterTitle = (_ch >= 0 && _ch < m.chapters.length) ? m.chapters[_ch].title : '';
    return Scaffold(
      backgroundColor: Colors.black,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _pages.isEmpty
              ? _noPages()
              : Focus(
                  autofocus: true,
                  onKeyEvent: _onKey,
                  child: Stack(
                    children: [
                      Positioned.fill(child: _content()),
                      if (_ui) _topBar(chapterTitle),
                      if (_ui) _bottomBar(),
                      _preloadBadge(),
                      _pageSrcBadge(),
                    ],
                  ),
                ),
    );
  }

  /// 在线预加载计数角标（左上角）：双向缓冲进度（向后/向前各完成数/窗口数）
  /// · 本章累计加载页数。窗口为空的一侧省略。
  Widget _preloadBadge() {
    return Positioned(
      left: 12,
      top: _ui ? 70 : 12,
      child: ValueListenableBuilder<_PreloadBadgeData>(
        valueListenable: _preload,
        builder: (context, info, _) {
          if (!info.online) return const SizedBox.shrink();
          final done = info.finished;
          final parts = <String>[
            if (info.afterTotal > 0) '向后 ${info.afterDone}/${info.afterTotal}',
            if (info.beforeTotal > 0) '向前 ${info.beforeDone}/${info.beforeTotal}',
          ];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              done
                  ? '预加载完成 · 已加载 ${info.cumulative} 页'
                  : '预加载中 ${parts.join(' · ')} · 已加载 ${info.cumulative} 页',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          );
        },
      ),
    );
  }

  /// 左下角：当前页磁盘缓存来源。命中=直接复用磁盘缓存；未命中=联网
  /// 取回（已自动写入缓存，下次命中）。
  Widget _pageSrcBadge() {
    return Positioned(
      left: 12,
      bottom: _ui ? 72 : 12,
      child: ValueListenableBuilder<_SrcBadgeData?>(
        valueListenable: _srcBadge,
        builder: (context, info, _) {
          if (info == null) return const SizedBox.shrink();
          final String status;
          if (info.misses == 0) {
            status = '缓存命中';
          } else if (info.hits == 0) {
            status = '缓存未命中 · 已写入';
          } else {
            status = '命中 ${info.hits} · 未命中 ${info.misses}';
          }
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${info.pages} · $status',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          );
        },
      ),
    );
  }

  Widget _noPages() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_not_supported, size: 48, color: Colors.grey),
          const SizedBox(height: 10),
          const Text('没有找到页面', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () async {
              await widget.store.rescanManga(widget.manga);
              await _open(_ch, 0);
            },
            child: const Text('重新扫描'),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    if (_mode == ReadingMode.vertical) {
      return LayoutBuilder(
        builder: (context, cons) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTapUp(d, cons.maxWidth),
          child: ValueListenableBuilder<bool>(
            valueListenable: _ctrlDown,
            builder: (context, ctrl, _) => InteractiveViewer(
              // 条漫缩放：Ctrl 按住时 Ctrl+滚轮缩放；放大后拖拽平移、列表暂停滚动
              transformationController: _vTc,
              maxScale: 5,
              minScale: 1,
              panEnabled: true,
              scaleEnabled: ctrl,
              child: ScrollablePositionedList.builder(
                key: ValueKey('v-$_ch'),
                physics: _vZoomed ? const NeverScrollableScrollPhysics() : null,
                itemCount: _pages.length,
                itemScrollController: _isc,
                itemPositionsListener: _ipl,
                initialScrollIndex: _page.clamp(0, _pages.isEmpty ? 0 : _pages.length - 1),
                itemBuilder: (context, i) => _WebtoonView(
                  index: i,
                  loader: () => _loadBytes(i),
                  aspectFor: _aspectFor,
                  screenH: cons.maxHeight,
                  fx: _fx,
                  presetFor: _presetFor,
                  onDecoded: _onDecoded,
                  srFor: _srFor,
                  onImageInfo: (i, pos) => _showImageInfo(i, pos),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, cons) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _onTapUp(d, cons.maxWidth),
        child: Listener(
          onPointerSignal: _onWheel,
          child: PageView.builder(
            // 章节/方向/布局变化时强制重建 PageView：切话时不加 key 会
            // 保留旧滚动位置（Scrollable 吸收 oldPosition，忽略新
            // controller 的 initialPage），导致下一话停在上次的页码。
            key: ValueKey('p-$_ch-$_mode-$_layout'),
            reverse: _mode == ReadingMode.rtl,
            controller: _pc,
            itemCount: _groups.isEmpty ? _pages.length : _groups.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, g) {
              if (g >= _groups.length) return const SizedBox.shrink();
              return _GroupView(
                pages: _groups[g],
                fit: _fit,
                rtl: _mode == ReadingMode.rtl,
                loader: _loadBytes,
                sizeOf: (i) => _sizes[i],
                presetFor: _presetFor,
                onDecoded: _onDecoded,
                zoomed: _zoomed,
                ctrlDown: _ctrlDown,
                fx: _fx,
                srFor: _srFor,
                onImageInfo: (i, pos) => _showImageInfo(i, pos),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topBar(String chapterTitle) {
    final m = widget.manga;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                tooltip: '返回',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      m.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '第${_ch + 1}话 $chapterTitle · ${_pageLabel()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<ReadingMode>(
                tooltip: '阅读方向',
                icon: const Icon(Icons.menu_book, color: Colors.white),
                onSelected: _setMode,
                itemBuilder: (context) => [
                  for (final mode in ReadingMode.values)
                    CheckedPopupMenuItem(
                      value: mode,
                      checked: _mode == mode,
                      child: Text(readingModeLabel(mode)),
                    ),
                ],
              ),
              if (_mode != ReadingMode.vertical)
                PopupMenuButton<PageLayout>(
                  tooltip: '页面布局',
                  icon: const Icon(Icons.auto_stories, color: Colors.white),
                  onSelected: _setLayout,
                  itemBuilder: (context) => [
                    for (final l in PageLayout.values)
                      CheckedPopupMenuItem(
                        value: l,
                        checked: _layout == l,
                        child: Text(pageLayoutLabel(l)),
                      ),
                  ],
                ),
              PopupMenuButton<PageFit>(
                tooltip: '页面适应',
                icon: const Icon(Icons.fit_screen, color: Colors.white),
                onSelected: (f) {
                  AppLog.i('阅读', '切换适应 → ${pageFitLabel(f)}');
                  widget.store.setDefaultFit(f); // 写入全局偏好（原只改会话，重启即丢）
                  setState(() => _fit = f);
                },
                itemBuilder: (context) => [
                  for (final f in PageFit.values)
                    CheckedPopupMenuItem(
                      value: f,
                      checked: _fit == f,
                      child: Text(pageFitLabel(f)),
                    ),
                ],
              ),
              IconButton(
                tooltip: _fullscreen ? '退出全屏 (F11)' : '全屏 (F11)',
                icon: Icon(
                  _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  color: Colors.white,
                ),
                onPressed: _toggleFullscreen,
              ),
              IconButton(
                tooltip: _fx.enabled ? '画质增强（已开启）' : '画质增强',
                icon: Icon(
                  Icons.auto_fix_high,
                  color: _fx.enabled ? Theme.of(context).colorScheme.primary : Colors.white,
                ),
                onPressed: _showFxSheet,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final m = widget.manga;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous, color: Colors.white),
                      tooltip: '上一话',
                      onPressed: _ch > 0 ? () => _open(_ch - 1, 0) : null,
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        ),
                        child: Builder(builder: (context) {
                          final byGroup = _useGroups;
                          final count = byGroup ? _groups.length : _pages.length;
                          final maxV = (count - 1).clamp(0, 1 << 30).toDouble();
                          final value = (byGroup ? _groupIndex : _page).clamp(0, maxV).toDouble();
                          return Slider(
                            value: value,
                            min: 0,
                            max: maxV,
                            divisions: count > 1 && count <= 400 ? count - 1 : null,
                            label: _pageLabel(),
                            onChanged: (v) => byGroup ? _jumpToGroup(v.round()) : _jumpToPage(v.round()),
                          );
                        }),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      tooltip: '下一话',
                      onPressed: _ch < m.chapters.length - 1 ? () => _open(_ch + 1, 0) : null,
                    ),
                  ],
                ),
                Text(
                  _pageLabel(),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- 一屏（单页，或双页并排——参考 Mihon DualPageHolder） ----------

class _GroupView extends StatefulWidget {
  const _GroupView({
    required this.pages,
    required this.fit,
    required this.rtl,
    required this.loader,
    required this.sizeOf,
    required this.presetFor,
    required this.onDecoded,
    required this.srFor,
    required this.onImageInfo,
    required this.zoomed,
    required this.ctrlDown,
    required this.fx,
  });

  /// 这一屏要显示的页面索引：1 个（单页/跨页）或 2 个（双页）。
  final List<int> pages;
  final PageFit fit;
  final bool rtl;
  final Future<Uint8List> Function(int index) loader;
  final Size? Function(int index) sizeOf;

  /// 已解码纹理缓存（按页索引）：命中即可同步渲染，重排/翻页零闪烁。
  final ui.Image? Function(int index) presetFor;
  final void Function(int index, ui.Image img) onDecoded;

  /// 神经超分纹理（就绪时优先于 preset 显示，跳过放大着色器）。
  final ui.Image? Function(int index) srFor;
  /// 右键页面 → 显示图片信息菜单（页索引 + 全局屏幕坐标）。
  final void Function(int index, Offset pos) onImageInfo;
  final ValueNotifier<bool> zoomed;
  final ValueListenable<bool> ctrlDown;
  final FxParams fx;

  @override
  State<_GroupView> createState() => _GroupViewState();
}

class _GroupViewState extends State<_GroupView> with TickerProviderStateMixin {
  late Map<int, Future<Uint8List>> _futures;
  TransformationController? _tc;
  bool _zoom = false;
  Offset? _doubleTapPos;
  late final AnimationController _zoomAnim;

  @override
  void initState() {
    super.initState();
    _futures = {for (final i in widget.pages) i: widget.loader(i)};
    _zoomAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _ensureTc();
  }

  void _ensureTc() {
    if (_tc == null) {
      _tc = TransformationController();
      _tc!.addListener(_onZoomChanged);
    }
  }

  void _onZoomChanged() {
    final z = _tc!.value.getMaxScaleOnAxis() > 1.01;
    if (z != _zoom) {
      _zoom = z;
      widget.zoomed.value = z;
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _GroupView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.pages, widget.pages)) {
      _futures = {for (final i in widget.pages) i: widget.loader(i)};
    }
    if (oldWidget.fit != widget.fit) {
      _tc?.removeListener(_onZoomChanged);
      _tc?.dispose();
      _tc = null;
      if (_zoom) widget.zoomed.value = false;
      _zoom = false;
      _ensureTc();
    }
  }

  @override
  void dispose() {
    if (_zoom) widget.zoomed.value = false;
    _tc?.dispose();
    _zoomAnim.dispose();
    super.dispose();
  }

  void _animateZoom(Matrix4 target) {
    final tween = Matrix4Tween(begin: Matrix4.copy(_tc!.value), end: target);
    late final VoidCallback listener;
    listener = () {
      _tc!.value = tween.transform(Curves.easeOut.transform(_zoomAnim.value));
      if (_zoomAnim.isCompleted) _zoomAnim.removeListener(listener);
    };
    _zoomAnim
      ..reset()
      ..addListener(listener)
      ..forward();
  }

  void _handleDoubleTap() {
    if (_tc == null) return;
    if (_zoom) {
      _animateZoom(Matrix4.identity());
      return;
    }
    const s = 2.5;
    final p = _doubleTapPos;
    final m = Matrix4.identity();
    if (p != null) {
      m.translateByDouble(-p.dx * (s - 1), -p.dy * (s - 1), 0, 1);
    }
    m.scaleByDouble(s, s, 1, 1);
    _animateZoom(m);
  }

  /// RTL 时组内第一页显示在右侧（书页顺序）。
  List<int> get _ordered {
    if (widget.pages.length == 2 && widget.rtl) {
      return [widget.pages[1], widget.pages[0]];
    }
    return widget.pages;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.ctrlDown,
      builder: (context, ctrl, _) => _buildFit(context, ctrl),
    );
  }

  Widget _pane(BuildContext context, int pageIdx, {
    BoxFit fit = BoxFit.contain,
    double? w,
    double? h,
    int? cacheWidth,
    bool useSr = true,
  }) {
    // 神经超分就绪：直接出 SR 纹理并跳过放大着色器（防双重放大）。
    if (useSr) {
      final sr = widget.srFor(pageIdx);
      if (sr != null) {
        return _wrapPane(
            _fxImage(pageIdx,
                preset: sr, fit: fit, w: w, h: h, cacheWidth: cacheWidth, skipUpscale: true),
            pageIdx);
      }
    }
    // 已有解码纹理：同步渲染，避免 FutureBuilder/解码占位帧（翻页闪烁的根源）。
    final preset = widget.presetFor(pageIdx);
    if (preset != null) {
      return _wrapPane(
          _fxImage(pageIdx, preset: preset, fit: fit, w: w, h: h, cacheWidth: cacheWidth),
          pageIdx);
    }
    return FutureBuilder<Uint8List>(
      future: _futures[pageIdx],
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(color: Colors.grey));
        }
        if (snap.hasError || snap.data == null) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image, size: 40, color: Colors.grey),
                SizedBox(height: 8),
                Text('页面加载失败', style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }
        return _wrapPane(
            _fxImage(pageIdx,
                bytes: snap.data!, fit: fit, w: w, h: h, cacheWidth: cacheWidth),
            pageIdx);
      },
    );
  }

  Widget _fxImage(int pageIdx, {
    Uint8List? bytes,
    ui.Image? preset,
    BoxFit? fit,
    double? w,
    double? h,
    int? cacheWidth,
    bool skipUpscale = false,
  }) {
    return _FxImage(
      bytes: bytes,
      preset: preset,
      onDecoded: (img) => widget.onDecoded(pageIdx, img),
      fx: widget.fx,
      fit: fit,
      width: w,
      height: h,
      cacheWidth: cacheWidth,
      skipUpscale: skipUpscale,
    );
  }

  Widget _wrapPane(Widget child, int pageIdx) {
    var body = Listener(
      // 抢在内层 SingleChildScrollView 之前注册 pointerSignalResolver，
      // 使滚轮不再滚动内嵌视图，统一交给外层翻页 / Ctrl+滚轮缩放。
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(e, (_) {});
        }
      },
      child: child,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => widget.onImageInfo(pageIdx, d.globalPosition),
      child: body,
    );
  }

  Widget _buildFit(BuildContext context, bool ctrl) {
    final dual = widget.pages.length == 2;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final ordered = _ordered;

    if (widget.fit == PageFit.fitWidth) {
      return LayoutBuilder(
        builder: (context, cons) {
          final w = cons.maxWidth;
          final Widget body;
          if (!dual) {
            body = SingleChildScrollView(
              // 放大后拖拽交给 InteractiveViewer 平移，不再滚动内嵌视图
              physics: _zoom ? const NeverScrollableScrollPhysics() : null,
              child: _pane(context, ordered[0], fit: BoxFit.fitWidth, w: w, cacheWidth: (w * dpr).round()),
            );
          } else {
            // 双页：每页占一半宽度，页间无间距
            body = SingleChildScrollView(
              physics: _zoom ? const NeverScrollableScrollPhysics() : null,
              child: SizedBox(
                width: w,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final i in ordered)
                      SizedBox(
                        width: w / 2,
                        child: _pane(context, i, fit: BoxFit.fitWidth, w: w / 2, cacheWidth: ((w / 2) * dpr).round()),
                      ),
                  ],
                ),
              ),
            );
          }
          return _zoomView(ctrl, body);
        },
      );
    }

    if (widget.fit == PageFit.fitHeight) {
      return LayoutBuilder(
        builder: (context, cons) {
          final h = cons.maxHeight;
          // 适应高度：内容总宽比视口窄时水平居中——SingleChildScrollView
          // 默认把子树靠左排，竖页（宽≈0.7 屏高）会整体偏左。
          double rowW = 0;
          var sized = ordered.isNotEmpty;
          for (final i in ordered) {
            final s = widget.sizeOf(i);
            if (s == null || s.height <= 0) {
              sized = false;
              break;
            }
            rowW += s.width / s.height * h;
          }
          final Widget body;
          if (sized && rowW < cons.maxWidth) {
            body = Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final i in ordered) _pane(context, i, fit: BoxFit.fitHeight, h: h),
                ],
              ),
            );
          } else {
            body = SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: _zoom ? const NeverScrollableScrollPhysics() : null,
              child: Row(
                children: [
                  for (final i in ordered) _pane(context, i, fit: BoxFit.fitHeight, h: h),
                ],
              ),
            );
          }
          return _zoomView(ctrl, body);
        },
      );
    }

    if (widget.fit == PageFit.original) {
      final sizes = [for (final i in ordered) widget.sizeOf(i)];
      if (sizes.every((s) => s != null)) {
        return Center(
          child: InteractiveViewer(
            constrained: false,
            transformationController: _tc,
            maxScale: 8,
            panEnabled: true,
            scaleEnabled: ctrl,
            child: GestureDetector(
              onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
              onDoubleTap: _handleDoubleTap,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var k = 0; k < ordered.length; k++)
                    SizedBox(
                      width: sizes[k]!.width,
                      height: sizes[k]!.height,
                      // 原始大小语义 = 原生像素 1:1，不套超分
                      child: _pane(context, ordered[k], fit: BoxFit.fill, useSr: false),
                    ),
                ],
              ),
            ),
          ),
        );
      }
      // 尺寸未就绪：先按适应屏幕显示
      return _containView(context, ctrl, dual, ordered, dpr);
    }

    return _containView(context, ctrl, dual, ordered, dpr);
  }

  /// 统一的可缩放容器：Ctrl 按住时允许 Ctrl+滚轮缩放。
  Widget _zoomView(bool ctrl, Widget child) {
    return InteractiveViewer(
      transformationController: _tc,
      maxScale: 8,
      panEnabled: true,
      scaleEnabled: ctrl,
      child: child,
    );
  }

  Widget _containView(BuildContext context, bool ctrl, bool dual, List<int> ordered, double dpr) {
    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        maxScale: 5,
        panEnabled: true,
        scaleEnabled: ctrl,
        child: SizedBox.expand(
          child: dual
              ? LayoutBuilder(
                  builder: (context, cons) {
                    // 双页：两页按各自宽高比紧贴排成整体，再整体居中缩放。
                    // 不能每页塞进半个视口各自 contain——窄页会在半格里
                    // 左右留黑边，拼成中间一条大间隔。
                    return FittedBox(
                      fit: BoxFit.contain,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final i in ordered)
                            _pane(context, i, fit: BoxFit.fitHeight, h: cons.maxHeight, cacheWidth: 1100),
                        ],
                      ),
                    );
                  },
                )
              : _pane(context, ordered[0], fit: BoxFit.contain, cacheWidth: 2200),
        ),
      ),
    );
  }
}

// ---------- 条漫页 ----------

class _WebtoonView extends StatefulWidget {
  const _WebtoonView({
    required this.index,
    required this.loader,
    required this.aspectFor,
    required this.screenH,
    required this.fx,
    required this.presetFor,
    required this.onDecoded,
    required this.srFor,
    required this.onImageInfo,
  });

  final int index;
  final Future<Uint8List> Function() loader;
  final Future<double> Function(int) aspectFor;

  /// 视口高度：条漫页按它占满（纵向一页一屏）。
  final double screenH;

  /// 已解码纹理缓存访问（回滚免闪）。
  final ui.Image? Function(int index) presetFor;
  final void Function(int index, ui.Image img) onDecoded;

  /// 神经超分纹理（就绪时优先显示，跳过放大着色器）。
  final ui.Image? Function(int index) srFor;

  /// 右键页面 → 显示图片信息菜单（页索引 + 全局屏幕坐标）。
  final void Function(int index, Offset pos) onImageInfo;

  /// 画质增强参数。
  final FxParams fx;

  @override
  State<_WebtoonView> createState() => _WebtoonViewState();
}

class _WebtoonViewState extends State<_WebtoonView> {
  late Future<(Uint8List, double)> _f;

  /// 右键图片区域 → 页面信息菜单。
  Widget _wrapInfo(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => widget.onImageInfo(widget.index, d.globalPosition),
      child: child,
    );
  }

  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  Future<(Uint8List, double)> _load() async {
    final bytes = await widget.loader();
    final aspect = await widget.aspectFor(widget.index);
    return (bytes, aspect);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // 神经超分就绪：直接出 SR 纹理并跳过放大着色器。
    final sr = widget.srFor(widget.index);
    if (sr != null) {
      return _body(sr, sr.width / sr.height, sr: true);
    }
    // 命中已解码纹理：跳过字节/宽高比的异步链，同步出首帧（回滚不闪）。
    final preset = widget.presetFor(widget.index);
    if (preset != null) {
      return _body(preset, preset.width / preset.height);
    }
    return FutureBuilder<(Uint8List, double)>(
      future: _f,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(height: widget.screenH, child: const Center(child: CircularProgressIndicator(color: Colors.grey)));
        }
        if (snap.hasError || snap.data == null) {
          return SizedBox(
            height: 200,
            child: Center(child: Icon(Icons.broken_image, color: Colors.grey)),
          );
        }
        final (bytes, aspect) = snap.data!;
        return LayoutBuilder(
          builder: (context, cons) {
            final w = cons.maxWidth;
            // 一页占满窗口高度（纵向）；过宽的页退回按宽铺满
            var ih = widget.screenH;
            var iw = ih * aspect;
            if (iw > w) {
              iw = w;
              ih = iw / aspect;
            }
            return _wrapInfo(Listener(
              onPointerSignal: (e) {
                // 按住 Ctrl 时抢先注册 resolver，阻止内层列表滚轮滚动，
                // 让外层 InteractiveViewer 完成缩放；不按 Ctrl 时列表正常滚动。
                if (e is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
                  GestureBinding.instance.pointerSignalResolver.register(e, (_) {});
                }
              },
              child: Center(
                child: SizedBox(
                  width: iw,
                  height: ih,
                  child: _FxImage(
                    bytes: bytes,
                    onDecoded: (img) => widget.onDecoded(widget.index, img),
                    fx: widget.fx,
                    fit: BoxFit.fill,
                    cacheWidth: (iw * dpr).round(),
                  ),
                ),
              ),
            ));
          },
        );
      },
    );
  }

  Widget _body(ui.Image preset, double aspect, {bool sr = false}) {
    return _wrapInfo(LayoutBuilder(
      builder: (context, cons) {
        final w = cons.maxWidth;
        var ih = widget.screenH;
        var iw = ih * aspect;
        if (iw > w) {
          iw = w;
          ih = iw / aspect;
        }
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
              GestureBinding.instance.pointerSignalResolver.register(e, (_) {});
            }
          },
          child: Center(
            child: SizedBox(
              width: iw,
              height: ih,
              child: _FxImage(
                preset: preset,
                // SR 纹理归 _srImages 表所有，这里只借用，不上交 _decoded
                onDecoded: sr ? null : (img) => widget.onDecoded(widget.index, img),
                fx: widget.fx,
                fit: BoxFit.fill,
                skipUpscale: sr,
              ),
            ),
          ),
        );
      },
    ));
  }
}

// ---------- 画质增强（FX）图片 ----------

/// 页面纹理：解码源图后按 [FxParams] 经 FxEngine 做 GPU 滤镜处理。
/// 滤镜关闭时直接显示原解码结果；参数变化自动重处理。
/// [preset] 命中时跳过解码同步出首帧（翻页/重排零闪烁）；
/// [onDecoded] 非空时把解码结果上交状态级缓存——此后本组件只"借用"
/// 该纹理（绝不 dispose），生命周期归缓存表。
class _FxImage extends StatefulWidget {
  const _FxImage({
    this.bytes,
    required this.fx,
    this.preset,
    this.onDecoded,
    this.fit,
    this.width,
    this.height,
    this.cacheWidth,
    this.skipUpscale = false,
  });

  final Uint8List? bytes;
  final ui.Image? preset;
  final void Function(ui.Image img)? onDecoded;
  final FxParams fx;
  /// 纹理已是神经超分结果：跳过放大类着色器（fsr/photo），仅保留 a4k。
  final bool skipUpscale;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final int? cacheWidth;

  @override
  State<_FxImage> createState() => _FxImageState();
}

class _FxImageState extends State<_FxImage> {
  ui.Image? _src;
  ui.Image? _out;
  FxParams? _applied;
  bool _skipApplied = false;
  int _seq = 0;
  bool _busy = false; // 有滤镜处理在途，着色器可能仍引用 _src
  bool _borrowed = false; // _src 是缓存表的（onDecoded 已上交），不能 dispose
  final List<ui.Image> _grave = []; // 待释放源图（在途处理结束后统一 dispose）

  @override
  void initState() {
    super.initState();
    final p = widget.preset;
    if (p != null) {
      _src = p;
      _borrowed = true;
      _process();
    } else {
      _resolve();
    }
  }

  @override
  void didUpdateWidget(covariant _FxImage old) {
    super.didUpdateWidget(old);
    final p = widget.preset;
    if (p != null && !identical(p, _src)) {
      // 缓存表里出现了新的解码结果（如 fit 变化重解码）：换新纹理
      if (!_borrowed && _src != null) _retire(_src!);
      _src = p;
      _borrowed = true;
      _applied = null;
      _process();
    } else if (widget.bytes != null &&
        !identical(old.bytes, widget.bytes)) {
      final s = _src;
      if (s != null) _retire(s);
      // _out 是 FxEngine 缓存的共享输出，绝不 dispose（见 fx_engine.dart 头注释），
      // 只解除引用；缓存上限 + finalizer 负责回收。
      _src = null;
      _out = null;
      _applied = null;
      _resolve();
    } else if (widget.fx != _applied || widget.skipUpscale != _skipApplied) {
      _process();
    }
  }

  @override
  void dispose() {
    final s = _src;
    if (s != null) _retire(s);
    _src = null;
    _out = null; // 共享输出：仅解除引用
    super.dispose();
  }

  /// [img] 不再被展示。若滤镜处理在途则延迟释放；
  /// 借用的纹理（已上交状态缓存）绝不释放。
  void _retire(ui.Image img) {
    if (_borrowed) return;
    if (_busy) {
      _grave.add(img);
    } else {
      img.dispose();
    }
  }

  void _flushGrave() {
    if (_busy || _grave.isEmpty) return;
    for (final g in _grave) {
      g.dispose();
    }
    _grave.clear();
  }

  Future<void> _resolve() async {
    final bytes = widget.bytes;
    if (bytes == null) return;
    // 先用头部解析拿原图尺寸，超大扫描图按上限缩小解码（防止 GB 级纹理）
    int? tw = widget.cacheWidth;
    int? th;
    final sniffed = sniffImageSize(bytes);
    if (sniffed != null) {
      final w = sniffed.width.round();
      final h = sniffed.height.round();
      if (w > 0 && h > 0) {
        var capW = w, capH = h;
        if (tw != null) capH = (h * tw / w).round();
        final cap = _cappedDecodeSize(capW, capH);
        if (cap != null) {
          tw = cap.$1;
          th = cap.$2;
        }
      }
    }
    final codec =
        await ui.instantiateImageCodec(bytes, targetWidth: tw, targetHeight: th);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    codec.dispose();
    if (!mounted || !identical(bytes, widget.bytes)) {
      img.dispose();
      return;
    }
    // 解码结果上交状态缓存（同一页重建/重排时可同步渲染）。
    // 上交后本组件只借用该纹理，dispose 路径不再释放它。
    widget.onDecoded?.call(img);
    if (widget.onDecoded != null) _borrowed = true;
    final old = _src;
    if (old != null) _retire(old);
    setState(() => _src = img);
    _process();
  }

  Future<void> _process() async {
    final seq = ++_seq;
    final src = _src;
    if (src == null) return;
    _busy = true;
    try {
      final fx = widget.skipUpscale ? widget.fx.withoutUpscale : widget.fx;
      final out = await FxEngine.instance.apply(src, fx);
      if (!mounted || seq != _seq) return;
      setState(() {
        _applied = widget.fx;
        _skipApplied = widget.skipUpscale;
        _out = out ?? src; // 引擎不可用时回退原图，阅读器不受影响
      });
    } finally {
      _busy = false;
      _flushGrave(); // 在途处理已结束（着色器工作为同步），此刻释放才是安全的
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _out;
    if (img == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.grey));
    }
    return RawImage(
      image: img,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
    );
  }
}

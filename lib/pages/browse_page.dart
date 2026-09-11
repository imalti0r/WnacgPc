import 'package:flutter/material.dart';

import '../api/wnacg_api.dart';
import '../models/models.dart';
import '../net/download_service.dart';
import '../net/zip_download_service.dart';
import '../state/app_store.dart';
import '../widgets/gallery_card.dart';

/// 可复用的无限滚动画廊网格
class AlbumGrid extends StatefulWidget {
  /// 根据 1 基页码生成列表页路径
  final String Function(int page) urlFor;
  final String sourceKey; // 数据源标识，变化时重置
  final bool Function(GalleryItem item)? filter;
  final String? Function(GalleryItem item)? badgeFor;

  /// 显示右下角列表操作按钮（清空并刷新 / 批量下载），主页列表用；
  /// 搜索结果、标签页等复用场景保持 false。
  final bool showListActions;

  const AlbumGrid({
    super.key,
    required this.urlFor,
    required this.sourceKey,
    this.filter,
    this.badgeFor,
    this.showListActions = false,
  });

  @override
  State<AlbumGrid> createState() => _AlbumGridState();
}

class _AlbumGridState extends State<AlbumGrid> with AutomaticKeepAliveClientMixin {
  final _items = <GalleryItem>[];
  final _scroll = ScrollController();
  bool _loading = false;
  bool _exhausted = false;
  String? _error;
  int _page = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _loadMore();
    });
  }

  @override
  void didUpdateWidget(covariant AlbumGrid old) {
    super.didUpdateWidget(old);
    if (old.sourceKey != widget.sourceKey) _reset();
  }

  void _reset() {
    _items.clear();
    _page = 0;
    _exhausted = false;
    _error = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _exhausted || !mounted) return;
    _loading = true;
    try {
      final next = _page + 1;
      final list = await WnacgApi.instance.fetchList(widget.urlFor(next));
      if (!mounted) return;
      setState(() {
        _page = next;
        _error = null;
        final existing = _items.map((e) => e.aid).toSet();
        final fresh = list
            .where((e) => !existing.contains(e.aid))
            .where((e) => widget.filter?.call(e) ?? true)
            .toList();
        _items.addAll(fresh);
        if (list.isEmpty) _exhausted = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 批量打包下载当前已加载的列表（官方 ZIP 直链，串行队列消化）。
  /// 已下载/进行中的自动跳过；入队前弹确认框显示本数。
  Future<void> _batchDownload() async {
    if (_items.isEmpty || !mounted) return;
    final dl = DownloadService.instance;
    final zdl = ZipDownloadService.instance;
    final pending = <GalleryItem>[];
    var skipped = 0;
    for (final e in _items) {
      final zt = zdl.taskOf(e.aid);
      if (dl.infoOf(e.aid) != null ||
          dl.taskOf(e.aid) != null ||
          (zt != null && zt.status != ZipDownloadStatus.failed)) {
        skipped++; // 已下载或进行中
      } else {
        pending.add(e); // 未下载，或打包下载失败待重试
      }
    }
    final messenger = ScaffoldMessenger.of(context);
    if (pending.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('当前列表已全部下载或在进行中，没有需要下载的漫画')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('批量打包下载'),
        content: Text(
            '将依次下载当前列表的 ${pending.length} 本漫画（站点官方 ZIP）'
            '${skipped > 0 ? '，跳过已下载/进行中的 $skipped 本' : ''}。\n'
            '任务在后台串行进行，可在「书架 → 下载」查看进度或取消。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton.icon(
              key: const ValueKey('btn-batch-confirm'),
              onPressed: () => Navigator.pop(c, true),
              icon: const Icon(Icons.download_outlined),
              label: const Text('开始下载')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final item in pending) {
      // 失败的任务还在队列里，重试即可；否则重新入队
      final zt = zdl.taskOf(item.aid);
      if (zt != null) {
        zdl.retry(item.aid);
      } else {
        await zdl.enqueue(item);
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已加入 ${pending.length} 本到下载队列'
              '${skipped > 0 ? '（跳过 $skipped 本）' : ''}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_items.isEmpty && _error != null) {
      return _ErrorView(error: _error!, onRetry: _reset);
    }
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final store = AppStore.instance;
    final grid = RefreshIndicator(
      onRefresh: () async => _reset(),
      child: GridView.builder(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(16, 8, 16, widget.showListActions ? 100 : 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        itemCount: _items.length + (_exhausted ? 0 : 1),
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            if (_error != null) {
              return Center(
                child: TextButton.icon(
                  onPressed: _loadMore,
                  icon: const Icon(Icons.refresh),
                  label: const Text('加载失败，重试'),
                ),
              );
            }
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            );
          }
          final item = _items[i];
          final h = store.historyOf(item.aid);
          String? badge;
          if (h != null && h.totalPages > 0) {
            badge = '${h.lastPage + 1}/${h.totalPages}';
          }
          return GalleryCard(
              key: ValueKey('grid-${item.aid}'),
              item: item,
              badge: widget.badgeFor?.call(item) ?? badge);
        },
      ),
    );
    if (!widget.showListActions) return grid;
    // 右下角列表操作：清空并刷新 / 批量下载
    return Stack(
      children: [
        grid,
        Positioned(
          right: 16,
          bottom: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.small(
                key: const ValueKey('btn-refresh-list'),
                heroTag: 'btn-refresh-list',
                tooltip: '清空并刷新当前列表',
                onPressed: _reset,
                child: const Icon(Icons.refresh),
              ),
              const SizedBox(height: 10),
              FloatingActionButton.extended(
                key: const ValueKey('btn-batch-download'),
                heroTag: 'btn-batch-download',
                icon: const Icon(Icons.download_outlined),
                label: const Text('批量下载'),
                onPressed: _batchDownload,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('加载失败', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 浏览页：分类筛选 + 最新/热门
class BrowsePage extends StatefulWidget {
  final VoidCallback? onOpenSearch;
  const BrowsePage({super.key, this.onOpenSearch});

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  /// 全站分类（id 对照站点路由 /albums-index-cate-{id}.html，2026-09 实测核对）
  /// id=-1 表示"最新"（/albums.html），0 是站点自己的"未分类"分类
  static const categories = [
    Category(-1, '最新'),
    Category(5, '同人志'),
    Category(1, '同人志-汉化'),
    Category(2, '同人志-CG书籍'),
    Category(12, '同人志-日语'),
    Category(16, '同人志-English（英语）'),
    Category(6, '单行本'),
    Category(9, '单行本-汉化'),
    Category(13, '单行本-日语'),
    Category(17, '单行本-English（英语）'),
    Category(7, '杂志&短篇'),
    Category(10, '杂志&短篇-汉语'),
    Category(14, '杂志&短篇-日语'),
    Category(18, '杂志&短篇-English（英语）'),
    Category(3, '写真&Cosplay'),
    Category(19, '韩漫'),
    Category(20, '韩漫-汉化'),
    Category(21, '韩漫-生肉'),
    Category(22, '3D&漫画'),
    Category(23, '3D&漫画-汉语'),
    Category(24, '3D&漫画-其他'),
    Category(37, 'AI图集'),
    Category(0, '未分类相册'),
  ];

  int _cate = -1;

  @override
  Widget build(BuildContext context) {
    final api = WnacgApi.instance;
    return Column(
      children: [
        // 顶栏：标题 + 线路 + 搜索
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
          child: Row(
            children: [
              Text('紳士漫畫', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(width: 8),
              Tooltip(
                message: '当前线路 ${api.baseUrl}\n点击自动测速切换最佳线路',
                child: ActionChip(
                  avatar: const Icon(Icons.network_check, size: 18),
                  label: Text(Uri.parse(api.baseUrl).host),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    messenger.showSnackBar(const SnackBar(
                        content: Text('正在检测最佳线路…'), duration: Duration(seconds: 1)));
                    final best = await api.resolveBestLine();
                    await AppStore.instance.setBaseUrl(best);
                    if (mounted) {
                      setState(() => _cate = _cate); // 触发重建
                      messenger.hideCurrentSnackBar();
                    }
                  },
                ),
              ),
              const Spacer(),
              IconButton.filledTonal(
                tooltip: '搜索',
                icon: const Icon(Icons.search),
                onPressed: widget.onOpenSearch,
              ),
            ],
          ),
        ),
        // 分类条：Wrap 流式布局 —— 窗口再窄也全部可见（旧版横向 ListView
        // 在桌面端鼠标滚轮无法横向滚动，窗口模式下右侧分类不可达）
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in categories)
                  FilterChip(
                    label: Text(c.name),
                    selected: _cate == c.id,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _cate = c.id),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: AlbumGrid(
            key: ValueKey('browse-$_cate-${api.baseUrl}'),
            sourceKey: 'browse-$_cate-${api.baseUrl}',
            showListActions: true,
            urlFor: _cate == -1
                ? api.latestUrl
                : (p) => api.categoryUrl(_cate, p),
          ),
        ),
      ],
    );
  }
}

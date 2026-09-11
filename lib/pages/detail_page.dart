import 'dart:io';

import 'package:flutter/material.dart';

import '../api/wnacg_api.dart';
import '../models/models.dart';
import '../net/download_service.dart';
import '../net/zip_download_service.dart';
import '../reader/library.dart';
import '../reader/models.dart' as r;
import '../reader/reader_page.dart';
import '../reader/reader_store.dart';
import '../state/app_store.dart';
import '../widgets/net_image.dart';
import 'browse_page.dart';

/// 打开详情页（压栈）
void openDetail(BuildContext context, GalleryItem item) {
  Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: false,
    builder: (_) => DetailPage(item: item),
  ));
}

class DetailPage extends StatefulWidget {
  final GalleryItem item;
  const DetailPage({super.key, required this.item});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late Future<GalleryDetail> _future;
  late GalleryItem _item;

  @override
  void initState() {
    super.initState();
    _item = widget.item;
    _future = WnacgApi.instance.fetchDetail(_item.aid);
  }

  /// 打开 mihonfx 阅读器（移植版）。数据源优先级：
  /// 已下载文件夹 > 已下载 ZIP > 在线（WebView2 图片桥）。
  Future<void> _openReader(BuildContext context, {int? startPage}) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final dl = DownloadService.instance;
    final r.Chapter chapter;
    final info = dl.infoOf(_item.aid);
    if (info != null && !info.isZip && Directory(info.dir).existsSync()) {
      chapter = r.Chapter(
          id: _item.aid, title: _item.title, path: info.dir, isZip: false);
    } else if (info?.isZip == true && File(info!.zipPath!).existsSync()) {
      chapter = r.Chapter(
          id: _item.aid,
          title: _item.title,
          path: info.zipPath!,
          isZip: true);
    } else {
      try {
        messenger.showSnackBar(const SnackBar(
            content: Text('正在获取图片列表…'), duration: Duration(seconds: 2)));
        final images = await WnacgApi.instance.fetchGalleryImages(_item.aid);
        if (!mounted) return;
        chapter = OnlineChapter(
          id: _item.aid,
          title: _item.title,
          pages: [for (final img in images) PageItem.url(img.url)],
        );
      } catch (e) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(content: Text('获取图片失败：$e')));
        return;
      }
    }
    messenger.hideCurrentSnackBar();
    ReaderStore.instance.bind(_item);
    await navigator.push(MaterialPageRoute(
      builder: (_) => ReaderPage(
        store: ReaderStore.instance,
        manga: r.Manga(id: _item.aid, title: _item.title, rootPath: '', chapters: [chapter]),
        chapter: 0,
        page: startPage ?? 0,
      ),
    ));
  }

  /// 下载整本（先取图片列表再入队）——逐页模式
  Future<void> _startDownload() async {
    final messenger = ScaffoldMessenger.of(context);
    final dl = DownloadService.instance;
    if (dl.taskOf(_item.aid) != null) return;
    if (ZipDownloadService.instance.taskOf(_item.aid) != null) return;
    final existing = dl.infoOf(_item.aid);
    if (existing != null) return;
    try {
      messenger.showSnackBar(const SnackBar(
          content: Text('正在准备下载…'), duration: Duration(seconds: 2)));
      final images = await WnacgApi.instance.fetchGalleryImages(_item.aid);
      await dl.enqueue(_item, images);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('下载准备失败：$e')));
    }
  }

  /// 打包下载：站点官方预打包 ZIP 直链，单流下载
  Future<void> _startZipDownload() async {
    final dl = DownloadService.instance;
    if (dl.infoOf(_item.aid) != null) return;
    if (dl.taskOf(_item.aid) != null) return;
    await ZipDownloadService.instance.enqueue(_item);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final store = AppStore.instance;
    return Scaffold(
      body: AnimatedBuilder(
        animation: Listenable.merge(
            [store, DownloadService.instance, ZipDownloadService.instance]),
        builder: (context, _) => CustomScrollView(
          slivers: [
            SliverAppBar.large(
              title: Text(_item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              sliver: SliverList.list(
                children: [
                  FutureBuilder<GalleryDetail>(
                    future: _future,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Card(
                          color: cs.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(Icons.error_outline, color: cs.onErrorContainer),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text('详情加载失败：${snap.error}',
                                      style: TextStyle(color: cs.onErrorContainer)),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      setState(() => _future = WnacgApi.instance
                                          .fetchDetail(_item.aid)),
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      final d = snap.data;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 封面
                          Hero(
                            tag: 'cover-${_item.aid}',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: SizedBox(
                                width: 180,
                                height: 240,
                                child: NetImage(
                                  url: d?.coverUrl.isNotEmpty == true
                                      ? d!.coverUrl
                                      : _item.coverUrl,
                                  cacheId: _item.aid,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          // 信息 + 操作
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (d != null) ...[
                                  if (d.categories.isNotEmpty)
                                    Wrap(
                                      spacing: 6,
                                      children: [
                                        for (final c in d.categories)
                                          Chip(
                                            label: Text(c),
                                            labelStyle: const TextStyle(fontSize: 12),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                      ],
                                    ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${d.pages > 0 ? '${d.pages}P' : (_item.imageCount != null ? '${_item.imageCount}P' : '')}'
                                    '${d.uploader.isEmpty ? '' : ' · 上传：${d.uploader}'}'
                                    '${_item.date != null ? ' · ${_item.date}' : ''}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                  const SizedBox(height: 10),
                                  if (d.tags.isNotEmpty)
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        for (final t in d.tags)
                                          ActionChip(
                                            label: Text(t,
                                                style: const TextStyle(fontSize: 12)),
                                            visualDensity: VisualDensity.compact,
                                            onPressed: () {
                                              // 按标签浏览：回退到列表
                                              Navigator.of(context)
                                                  .push(MaterialPageRoute(
                                                builder: (_) => Scaffold(
                                                  body: SafeArea(
                                                    child: Column(
                                                      children: [
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.all(12),
                                                          child: Row(children: [
                                                            BackButton(
                                                                onPressed: () =>
                                                                    Navigator.pop(
                                                                        context)),
                                                            Text('标签：$t',
                                                                style: Theme.of(context)
                                                                    .textTheme
                                                                    .titleMedium),
                                                          ]),
                                                        ),
                                                        Expanded(
                                                          child: AlbumGrid(
                                                            key: ValueKey('tag-$t'),
                                                            sourceKey: 'tag-$t',
                                                            urlFor: (p) =>
                                                                WnacgApi.instance
                                                                    .tagUrl(t, p),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ));
                                            },
                                          ),
                                      ],
                                    ),
                                  const SizedBox(height: 12),
                                  if (d.description.isNotEmpty)
                                    Text(
                                      d.description,
                                      maxLines: 6,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(height: 1.5),
                                    ),
                                ] else
                                  ...List.generate(
                                    4,
                                    (i) => Container(
                                      margin: const EdgeInsets.only(bottom: 10),
                                      width: double.infinity,
                                      height: 16,
                                      decoration: BoxDecoration(
                                        color: cs.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  // 操作区
                  _ActionBar(
                    aid: _item.aid,
                    favorite: store.isFavorite(_item.aid),
                    onFavorite: () => store.toggleFavorite(_item),
                    history: store.historyOf(_item.aid),
                    onContinue: (page) => _openReader(context, startPage: page),
                    onDownload: _startDownload,
                    onZipDownload: _startZipDownload,
                    onCancelDownload: () =>
                        DownloadService.instance.cancel(_item.aid),
                    onRetryDownload: () =>
                        DownloadService.instance.retry(_item.aid),
                    onCancelZipDownload: () =>
                        ZipDownloadService.instance.cancel(_item.aid),
                    onRetryZipDownload: () =>
                        ZipDownloadService.instance.retry(_item.aid),
                    onDeleteDownload: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('删除离线文件'),
                          content: const Text('将删除已下载的全部图片文件，确定吗？'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('取消')),
                            FilledButton.tonal(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('删除')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await DownloadService.instance.delete(_item.aid);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  final String aid;
  final bool favorite;
  final VoidCallback onFavorite;
  final HistoryEntry? history;
  final void Function(int startPage) onContinue;
  final VoidCallback onDownload;
  final VoidCallback onZipDownload;
  final VoidCallback onCancelDownload;
  final VoidCallback onRetryDownload;
  final VoidCallback onCancelZipDownload;
  final VoidCallback onRetryZipDownload;
  final VoidCallback onDeleteDownload;

  const _ActionBar({
    required this.aid,
    required this.favorite,
    required this.onFavorite,
    required this.history,
    required this.onContinue,
    required this.onDownload,
    required this.onZipDownload,
    required this.onCancelDownload,
    required this.onRetryDownload,
    required this.onCancelZipDownload,
    required this.onRetryZipDownload,
    required this.onDeleteDownload,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dl = DownloadService.instance;
    final task = dl.taskOf(aid);
    final zipTask = ZipDownloadService.instance.taskOf(aid);
    final info = dl.infoOf(aid);
    // 详情页条目可能来自列表而非收藏/历史，用 aid 从外层取
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            FilledButton.icon(
              onPressed: () => onContinue(0),
              icon: const Icon(Icons.menu_book_outlined),
              label: Text(info != null ? '离线阅读' : '从头阅读'),
            ),
            if (history != null) ...[
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: () => onContinue(history!.lastPage),
                icon: const Icon(Icons.play_arrow),
                label: Text('继续 (${history!.lastPage + 1}/${history!.totalPages})'),
              ),
            ],
            const Spacer(),
            // 下载区：逐页任务 / 打包任务 / 已下载 / 双入口菜单
            if (task != null)
              _DownloadProgress(task: task, onCancel: onCancelDownload, onRetry: onRetryDownload)
            else if (zipTask != null)
              _ZipDownloadProgress(task: zipTask, onCancel: onCancelZipDownload, onRetry: onRetryZipDownload)
            else if (info != null) ...[
              Chip(
                avatar: Icon(info.isZip ? Icons.folder_zip_outlined : Icons.offline_pin,
                    size: 16, color: cs.primary),
                label: Text(
                    '已下载 ${info.count}P${info.isZip ? (info.official ? ' · 官方ZIP' : ' · ZIP') : ''}'),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '删除离线文件',
                icon: const Icon(Icons.delete_outline),
                onPressed: onDeleteDownload,
              ),
            ] else
              PopupMenuButton<String>(
                tooltip: '下载整本（离线可读）',
                icon: const Icon(Icons.download_outlined),
                position: PopupMenuPosition.under,
                onSelected: (v) {
                  if (v == 'zip') {
                    onZipDownload();
                  } else {
                    onDownload();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'page',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.filter_1_outlined),
                      title: Text('逐页下载'),
                      subtitle: Text('经图片桥逐页取图 · 文件夹/ZIP 可选'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'zip',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.folder_zip_outlined),
                      title: Text('打包下载'),
                      subtitle: Text('站点官方 ZIP · 单流下载更快'),
                    ),
                  ),
                ],
              ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: favorite ? '取消收藏' : '加入收藏',
              isSelected: favorite,
              icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
              selectedIcon: const Icon(Icons.favorite),
              onPressed: onFavorite,
            ),
          ],
        ),
      ),
    );
  }
}

/// 打包下载进度（按字节）：MB 进度 + 速度，可取消/重试
class _ZipDownloadProgress extends StatelessWidget {
  final ZipDownloadTask task;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  const _ZipDownloadProgress({required this.task, required this.onCancel, required this.onRetry});

  static String _mb(int bytes) =>
      (bytes / 1048576).toStringAsFixed(bytes >= 10485760 ? 0 : 1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (task.status == ZipDownloadStatus.failed) {
      return Row(
        children: [
          Chip(
            avatar: Icon(Icons.error_outline, size: 16, color: cs.error),
            label: const Text('打包下载失败'),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            tooltip: '重试',
            icon: const Icon(Icons.refresh),
            onPressed: onRetry,
          ),
        ],
      );
    }
    final statusText = switch (task.status) {
      ZipDownloadStatus.queued => '排队中',
      ZipDownloadStatus.resolving => '解析下载地址…',
      _ => task.total > 0
          ? '${_mb(task.downloaded)}/${_mb(task.total)} MB'
          : '${_mb(task.downloaded)} MB',
    };
    return SizedBox(
      width: 190,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$statusText'
                  '${task.speed > 0 && task.status == ZipDownloadStatus.running ? ' · ${(task.speed / 1048576).toStringAsFixed(1)} MB/s' : ''}'
                  '${task.attempt > 1 && task.status == ZipDownloadStatus.running ? ' · 重试 ${task.attempt}/${task.attempts}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  tooltip: '取消',
                  iconSize: 16,
                  icon: const Icon(Icons.close),
                  onPressed: onCancel,
                ),
              ),
            ],
          ),
          LinearProgressIndicator(
            value: task.status == ZipDownloadStatus.queued ||
                    task.status == ZipDownloadStatus.resolving ||
                    task.total <= 0
                ? null
                : task.progress,
            minHeight: 5,
            borderRadius: BorderRadius.circular(3),
          ),
        ],
      ),
    );
  }
}

class _DownloadProgress extends StatelessWidget {
  final DownloadTask task;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  const _DownloadProgress({required this.task, required this.onCancel, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (task.status == DownloadStatus.failed) {
      return Row(
        children: [
          Chip(
            avatar: Icon(Icons.error_outline, size: 16, color: cs.error),
            label: const Text('下载失败'),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            tooltip: '重试（已下载页会跳过）',
            icon: const Icon(Icons.refresh),
            onPressed: onRetry,
          ),
        ],
      );
    }
    return SizedBox(
      width: 170,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                task.status == DownloadStatus.queued
                    ? '排队中'
                    : '下载中 ${task.downloaded}/${task.images.length}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const Spacer(),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  tooltip: '取消',
                  iconSize: 16,
                  icon: const Icon(Icons.close),
                  onPressed: onCancel,
                ),
              ),
            ],
          ),
          LinearProgressIndicator(
            value: task.status == DownloadStatus.queued ? null : task.progress,
            minHeight: 5,
            borderRadius: BorderRadius.circular(3),
          ),
        ],
      ),
    );
  }
}

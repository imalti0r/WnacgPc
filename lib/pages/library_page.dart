import 'package:flutter/material.dart';

import '../net/download_service.dart';
import '../net/zip_download_service.dart';
import '../pages/detail_page.dart';
import '../state/app_store.dart';
import '../widgets/gallery_card.dart';
import '../widgets/net_image.dart';

/// 书架页：收藏 + 历史
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final dl = DownloadService.instance;
    final zdl = ZipDownloadService.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([store, dl, zdl, _tab]),
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
            child: Row(
              children: [
                Text('书架', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (_tab.index == 1 && store.history.isNotEmpty)
                  TextButton.icon(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('清空历史'),
                          content: const Text('确定要删除全部阅读历史吗？'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('取消')),
                            FilledButton.tonal(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('清空')),
                          ],
                        ),
                      );
                      if (ok == true) await store.clearHistory();
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('清空历史'),
                  ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '收藏'),
            Tab(text: '历史'),
            Tab(text: '下载'),
          ],
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              // 收藏
              store.favorites.isEmpty
                  ? _Empty(
                      icon: Icons.favorite_border,
                      text: '还没有收藏，去首页添加吧',
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 190,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.62,
                      ),
                      itemCount: store.favorites.length,
                      itemBuilder: (context, i) => GalleryCard(
                        key: ValueKey('fav-${store.favorites[i].aid}'),
                        item: store.favorites[i],
                      ),
                    ),
              // 历史
              store.history.isEmpty
                  ? const _Empty(icon: Icons.history, text: '暂无阅读历史')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: store.history.length,
                      itemBuilder: (context, i) {
                        final h = store.history[i];
                        return _HistoryTile(
                            key: ValueKey('hist-${h.item.aid}'), entry: h);
                      },
                    ),
              // 下载（逐页任务 + 打包任务 + 已完成）
              Builder(builder: (context) {
                final pageTasks = dl.activeTasks;
                final zipTasks = zdl.activeTasks;
                final done = dl.downloads;
                if (pageTasks.isEmpty && zipTasks.isEmpty && done.isEmpty) {
                  return const _Empty(icon: Icons.download_done, text: '暂无下载任务');
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: pageTasks.length + zipTasks.length + done.length,
                  itemBuilder: (context, i) {
                    if (i < pageTasks.length) {
                      final t = pageTasks[i];
                      return _DownloadTile(
                          key: ValueKey('task-${t.item.aid}'), task: t);
                    }
                    if (i < pageTasks.length + zipTasks.length) {
                      final t = zipTasks[i - pageTasks.length];
                      return _ZipDownloadTile(
                          key: ValueKey('ztask-${t.item.aid}'), task: t);
                    }
                    final info = done[i - pageTasks.length - zipTasks.length];
                    return _DownloadedTile(
                        key: ValueKey('dl-${info.item.aid}'), info: info);
                  },
                );
              }),
            ],
          ),
        ),
      ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final HistoryEntry entry;
  const _HistoryTile({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final h = entry;
    final cs = Theme.of(context).colorScheme;
    final progress = h.totalPages > 0 ? (h.lastPage + 1) / h.totalPages : 0.0;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openDetail(context, h.item),
        child: SizedBox(
          height: 92,
          child: Row(
            children: [
              ClipRRect(
                borderRadius:
                    const BorderRadius.horizontal(left: Radius.circular(12)),
                child: SizedBox(
                  width: 68,
                  child: NetImage(
                      url: h.item.coverUrl,
                      cacheId: h.item.aid,
                      fit: BoxFit.cover),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(h.item.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const Spacer(),
                      Text(
                        '读到 ${h.lastPage + 1}/${h.totalPages}P · '
                        '${h.updatedAt.month}/${h.updatedAt.day} '
                        '${h.updatedAt.hour.toString().padLeft(2, '0')}:${h.updatedAt.minute.toString().padLeft(2, '0')}',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: progress.clamp(0, 1),
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Empty({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadTask task;
  const _DownloadTile({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 44,
                height: 60,
                child: NetImage(
                    url: task.item.coverUrl,
                    cacheId: task.item.aid,
                    fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.item.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  if (task.status == DownloadStatus.failed)
                    Text('失败：${task.error ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: cs.error))
                  else
                    Text(
                      task.status == DownloadStatus.queued
                          ? '排队中'
                          : '${task.downloaded}/${task.images.length}P',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: task.status == DownloadStatus.queued
                        ? null
                        : (task.status == DownloadStatus.failed ? 0 : task.progress),
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
              ),
            ),
            if (task.status == DownloadStatus.failed)
              IconButton(
                tooltip: '重试',
                icon: const Icon(Icons.refresh),
                onPressed: () => DownloadService.instance.retry(task.item.aid),
              )
            else
              IconButton(
                tooltip: '取消',
                icon: const Icon(Icons.close),
                onPressed: () => DownloadService.instance.cancel(task.item.aid),
              ),
          ],
        ),
      ),
    );
  }
}

/// 打包下载任务卡片（按字节进度：MB + 速度）
class _ZipDownloadTile extends StatelessWidget {
  final ZipDownloadTask task;
  const _ZipDownloadTile({super.key, required this.task});

  static String _mb(int bytes) =>
      (bytes / 1048576).toStringAsFixed(bytes >= 10485760 ? 0 : 1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final failed = task.status == ZipDownloadStatus.failed;
    final statusText = switch (task.status) {
      ZipDownloadStatus.queued => '排队中 · 打包下载',
      ZipDownloadStatus.resolving => '解析下载地址…',
      ZipDownloadStatus.failed => '失败：${task.error ?? ''}',
      _ => task.total > 0
          ? '${_mb(task.downloaded)}/${_mb(task.total)} MB'
          : '${_mb(task.downloaded)} MB',
    };
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 44,
                height: 60,
                child: NetImage(
                    url: task.item.coverUrl,
                    cacheId: task.item.aid,
                    fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.item.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  Text(
                    task.status == ZipDownloadStatus.running &&
                            task.speed > 0
                        ? '$statusText · ${(task.speed / 1048576).toStringAsFixed(1)} MB/s'
                        : statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(
                            color: failed ? cs.error : cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: task.status == ZipDownloadStatus.queued ||
                            task.status == ZipDownloadStatus.resolving ||
                            task.total <= 0
                        ? null
                        : (failed ? 0 : task.progress),
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
              ),
            ),
            if (failed)
              IconButton(
                tooltip: '重试',
                icon: const Icon(Icons.refresh),
                onPressed: () =>
                    ZipDownloadService.instance.retry(task.item.aid),
              )
            else
              IconButton(
                tooltip: '取消',
                icon: const Icon(Icons.close),
                onPressed: () =>
                    ZipDownloadService.instance.cancel(task.item.aid),
              ),
          ],
        ),
      ),
    );
  }
}

class _DownloadedTile extends StatelessWidget {
  final DownloadedInfo info;
  const _DownloadedTile({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openDetail(context, info.item),
        child: SizedBox(
          height: 76,
          child: Row(
            children: [
              ClipRRect(
                borderRadius:
                    const BorderRadius.horizontal(left: Radius.circular(12)),
                child: SizedBox(
                  width: 56,
                  child: NetImage(
                      url: info.item.coverUrl,
                      cacheId: info.item.aid,
                      fit: BoxFit.cover),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.item.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const Spacer(),
                      Row(
                        children: [
                          Icon(info.isZip ? Icons.folder_zip_outlined : Icons.offline_pin,
                              size: 14, color: cs.primary),
                          const SizedBox(width: 4),
                          Text(
                              '${info.count}P · ${info.isZip ? (info.official ? '官方ZIP' : 'ZIP') : '文件夹'} · 可离线阅读',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              FilledButton.tonal(
                onPressed: () => openDetail(context, info.item),
                child: const Text('阅读'),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '删除离线文件',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('删除离线文件'),
                      content: Text('删除《${info.item.title}》的全部本地文件？'),
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
                    await DownloadService.instance.delete(info.item.aid);
                  }
                },
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../api/wnacg_api.dart';
import '../debug/debug_server.dart';
import '../net/download_service.dart';
import '../net/image_bridge.dart';
import '../reader/app_log.dart';
import '../reader/models.dart' as rd;
import '../reader/reader_store.dart';
import '../state/app_store.dart';
import '../state/data_dirs.dart';
import '../version.dart';

/// 设置页：站点线路（发布页） / 数据目录 / 阅读 / 下载 / 外观 / 调试接口
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 发布页线路测速结果缓存（url → 延迟 ms，null=超时不可用）
  List<({String url, int? ms})>? _lines;

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text('设置', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          _siteSection(context, store),
          const SizedBox(height: 16),
          _dataDirSection(context, store),
          const SizedBox(height: 16),
          _readingSection(store),
          const SizedBox(height: 16),
          _downloadSection(context, store),
          const SizedBox(height: 16),
          const _ImageCacheSection(),
          const SizedBox(height: 16),
          _appearanceSection(context, store),
          const SizedBox(height: 16),
          _debugSection(context, store),
          const SizedBox(height: 16),
          _aboutSection(context),
        ],
      ),
    );
  }

  // ---------------- 站点线路 ----------------

  Widget _siteSection(BuildContext context, AppStore store) {
    return _Section(
      title: '站点线路',
      children: [
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('当前线路'),
          subtitle: Text(WnacgApi.instance.baseUrl),
          trailing: FilledButton.tonal(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              messenger.showSnackBar(const SnackBar(
                  content: Text('正在检测最佳线路…'), duration: Duration(seconds: 1)));
              final best = await WnacgApi.instance.resolveBestLine();
              await AppStore.instance.setBaseUrl(best);
              messenger.hideCurrentSnackBar();
            },
            child: const Text('自动测速'),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.travel_explore_outlined),
          title: const Text('从地址发布页获取线路'),
          subtitle: Text(_lines == null
              ? '发布页：${WnacgApi.releasePage}（点击获取可用线路并测速）'
              : '点击下方线路即可切换'),
          onTap: _lines == null ? () => _loadLines() : null,
        ),
        if (_lines != null)
          for (final l in _lines!)
            ListTile(
              dense: true,
              leading: Icon(
                l.ms == null
                    ? Icons.cancel_outlined
                    : WnacgApi.instance.baseUrl == l.url
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                color: l.ms == null
                    ? Theme.of(context).colorScheme.error
                    : WnacgApi.instance.baseUrl == l.url
                        ? Theme.of(context).colorScheme.primary
                        : null,
                size: 20,
              ),
              title: Text(Uri.parse(l.url).host),
              subtitle: Text(l.ms == null ? '不可用' : '${l.ms} ms'),
              onTap: l.ms == null
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await AppStore.instance.setBaseUrl(l.url);
                      if (mounted) {
                        setState(() {});
                        messenger.showSnackBar(
                            SnackBar(content: Text('已切换到 ${l.url}')));
                      }
                    },
            ),
        if (_lines != null)
          for (final p in _publishPagesCache)
            ListTile(
              dense: true,
              leading: const Icon(Icons.link, size: 20),
              title: Text(Uri.parse(p).host),
              subtitle: const Text('地址发布页（主站失效时浏览器打开它找新地址）'),
            ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('手动指定线路'),
          subtitle: const Text('域名失效时可手动输入新地址'),
          onTap: () => _editBaseUrl(context),
        ),
      ],
    );
  }

  List<String> _publishPagesCache = [];

  Future<void> _loadLines() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在从发布页获取线路并测速…')));
    final info = await WnacgApi.instance.fetchReleaseInfo();
    _publishPagesCache = info.publishPages;
    final out = <({String url, int? ms})>[];
    for (final url in info.lines) {
      final t = await WnacgApi.instance.measure(url);
      out.add((url: url, ms: t?.inMilliseconds));
      if (mounted) setState(() => _lines = out);
    }
    if (mounted) setState(() => _lines = out);
    messenger.hideCurrentSnackBar();
  }

  Future<void> _editBaseUrl(BuildContext context) async {
    final ctl = TextEditingController(text: WnacgApi.instance.baseUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('手动指定线路'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(
              hintText: 'https://www.example.com/', labelText: '主站地址'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok == true && mounted) {
      var url = ctl.text.trim();
      if (url.isNotEmpty) {
        if (!url.startsWith('http')) url = 'https://$url';
        if (!url.endsWith('/')) url += '/';
        await AppStore.instance.setBaseUrl(url);
      }
    }
    ctl.dispose();
  }

  // ---------------- 数据目录 ----------------

  Widget _dataDirSection(BuildContext context, AppStore store) {
    return _Section(
      title: '数据目录',
      children: [
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('数据保存位置'),
          subtitle: Text(DataDirs.instance.isCustom
              ? DataDirs.instance.root
              : '${DataDirs.instance.root}\n（默认位置；收藏/历史/下载/缓存都在这里）'),
          isThreeLine: !DataDirs.instance.isCustom,
          trailing: FilledButton.tonal(
            onPressed: () => _migrateDataDir(),
            child: const Text('更改…'),
          ),
        ),
      ],
    );
  }

  Future<void> _migrateDataDir() async {
    final dl = DownloadService.instance;
    if (dl.activeTasks.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('有下载任务进行中，请等待完成或取消后再迁移')));
      return;
    }
    final ctl = TextEditingController(text: DataDirs.instance.root);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('更改数据目录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('把收藏、历史、下载、缓存整体复制到新目录。原目录文件保留作备份。'),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              decoration: const InputDecoration(
                  labelText: '新目录', hintText: r'D:\WnacgData'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('迁移')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final newPath = ctl.text.trim();
    ctl.dispose();
    if (newPath.isEmpty) return;

    // 进度对话框
    final progress = ValueNotifier<double>(0);
    unawaited(showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在迁移数据…'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, v, _) =>
                Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: v < 0.02 ? null : v),
              const SizedBox(height: 12),
              Text('${(v * 100).clamp(0, 100).toStringAsFixed(0)}%'),
            ]),
          ),
        ),
      ),
    ));

    final res = await DataDirs.instance.migrateTo(newPath,
        onProgress: (v) => progress.value = v);
    if (mounted) Navigator.of(context, rootNavigator: true).pop(); // 关进度框
    if (!res.ok) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('迁移失败：${res.error}')));
      }
      return;
    }
    // 各服务切到新目录并重载（注册表路径已在复制时改写）
    await AppLog.switchDir(Directory(DataDirs.instance.root));
    ImageBridge.instance.setCacheDir(DataDirs.instance.imageCachePath);
    await AppStore.instance.load();
    await ReaderStore.instance.load();
    await DownloadService.instance.load();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '已迁移到 ${res.newPath}（${res.files} 个文件）。原目录数据保留。')));
    }
  }

  // ---------------- 阅读 ----------------

  Widget _readingSection(AppStore store) {
    return _Section(
      title: '阅读',
      children: [
        ListTile(
          leading: const Icon(Icons.auto_stories_outlined),
          title: const Text('阅读方向'),
          subtitle: const Text('右开=日漫从右往左；条漫为上下连续滚动'),
          trailing: SegmentedButton<rd.ReadingMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: rd.ReadingMode.rtl, label: Text('右开')),
              ButtonSegment(value: rd.ReadingMode.ltr, label: Text('左开')),
              ButtonSegment(value: rd.ReadingMode.vertical, label: Text('条漫')),
            ],
            selected: {ReaderStore.instance.settings.defaultMode},
            onSelectionChanged: (s) =>
                ReaderStore.instance.setDefaultMode(s.first),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.book_outlined),
          title: const Text('页面布局'),
          subtitle: const Text('双页仅翻页模式生效，横页自动独占一屏'),
          trailing: SegmentedButton<rd.PageLayout>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: rd.PageLayout.single, label: Text('单页')),
              ButtonSegment(value: rd.PageLayout.double, label: Text('双页')),
            ],
            selected: {ReaderStore.instance.settings.defaultLayout},
            onSelectionChanged: (s) =>
                ReaderStore.instance.setDefaultLayout(s.first),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.skip_next_outlined),
          title: const Text('在线阅读预加载页数'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('双向缓冲：向后比向前多 1 页', style: TextStyle(fontSize: 12)),
              Slider(
                value: store.preloadDistance,
                min: 0,
                max: 19,
                divisions: 19,
                label: store.preloadDistance.round() == 0
                    ? '关闭'
                    : '向后 ${(store.preloadDistance.round() + 1) ~/ 2} 页 · '
                        '向前 ${(store.preloadDistance.round() - 1) ~/ 2} 页',
                onChanged: (v) => store.setPreloadDistance(v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- 下载 ----------------

  Widget _downloadSection(BuildContext context, AppStore store) {
    return _Section(
      title: '下载',
      children: [
        ListTile(
          leading: const Icon(Icons.folder_zip_outlined),
          title: const Text('下载保存格式'),
          subtitle: const Text('ZIP 会把整本打包为单个 .zip 文件；\n对之后的下载生效，进行中任务保持原格式'),
          trailing: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('文件夹')),
              ButtonSegment(value: true, label: Text('ZIP')),
            ],
            selected: {store.zipDownloads},
            onSelectionChanged: (s) => store.setZipDownloads(s.first),
          ),
        ),
      ],
    );
  }

  // ---------------- 外观 ----------------

  Widget _appearanceSection(BuildContext context, AppStore store) {
    return _Section(
      title: '外观',
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.dark_mode_outlined),
          title: const Text('深色模式'),
          value: store.darkMode,
          onChanged: (v) => store.setDarkMode(v),
        ),
      ],
    );
  }

  // ---------------- 调试接口 ----------------

  Widget _debugSection(BuildContext context, AppStore store) {
    final running = DebugServer.instance.running;
    final port = running ? DebugServer.instance.port : store.debugPort;
    return _Section(
      title: '调试接口（本机 127.0.0.1）',
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.terminal_outlined),
          title: const Text('启用本地调试接口'),
          subtitle: Text(running
              ? '运行中：http://127.0.0.1:$port  （GET /help 查看全部端点）'
              : '关闭中。开启后可用 HTTP 控制/查询界面，便于自动化调试'),
          value: store.debugEnabled,
          onChanged: (v) async {
            await store.setDebugEnabled(v);
            if (v) {
              await DebugServer.instance.start(port: store.debugPort);
            } else {
              await DebugServer.instance.stop();
            }
            if (mounted) setState(() {});
          },
        ),
        ListTile(
          leading: const Icon(Icons.pin_outlined),
          title: const Text('端口'),
          subtitle: Text('$port${running ? '（重启生效）' : ''}'),
          onTap: () => _editDebugPort(context),
        ),
        ListTile(
          leading: const Icon(Icons.code_outlined),
          title: const Text('接口说明'),
          subtitle: const Text('ping / tree / find / tap / text / scroll / navigate / back / screenshot / log'),
          onTap: () => _showDebugHelp(context),
        ),
      ],
    );
  }

  Future<void> _editDebugPort(BuildContext context) async {
    final store = AppStore.instance;
    final ctl = TextEditingController(text: '${store.debugPort}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('调试接口端口'),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '端口 (1024-65535)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok == true && mounted) {
      final p = int.tryParse(ctl.text.trim());
      if (p != null && p >= 1024 && p <= 65535) {
        await store.setDebugPort(p);
        if (DebugServer.instance.running) {
          await DebugServer.instance.stop();
          await DebugServer.instance.start(port: p);
        }
        if (mounted) setState(() {});
      }
    }
    ctl.dispose();
  }

  void _showDebugHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('调试接口端点'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in DebugServer.help)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SelectableText(line,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(c), child: const Text('知道了')),
        ],
      ),
    );
  }

  // ---------------- 关于 ----------------

  Widget _aboutSection(BuildContext context) {
    return _Section(
      title: '关于',
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('WNACG $appVersion'),
          subtitle: const Text('wnacg 本地桌面漫画客户端 · Flutter MD3\n阅读器参考 Mihon 交互设计'),
          isThreeLine: true,
        ),
        ListTile(
          leading: const Icon(Icons.memory_outlined),
          title: const Text('画质增强致谢'),
          subtitle: const Text(
              '神经超分：AnimeJaNai（CC BY-NC-SA 4.0）· Real-ESRGAN（BSD-3）· ONNX Runtime\n详见安装目录 data/flutter_assets/assets/sr_models/LICENSE-SR.md'),
          isThreeLine: true,
        ),
      ],
    );
  }
}

/// 图片磁盘缓存区块：位置（可更改，旧文件搬移过去）、大小、手动清理、
/// 大小上限自动清理。独立 State 是为了持有缓存统计的本地状态。
class _ImageCacheSection extends StatefulWidget {
  const _ImageCacheSection();

  @override
  State<_ImageCacheSection> createState() => _ImageCacheSectionState();
}

class _ImageCacheSectionState extends State<_ImageCacheSection> {
  String _sizeText = '统计中…';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  Future<void> _refreshSize() async {
    final s = await ImageBridge.instance.cacheStats();
    if (!mounted) return;
    setState(() {
      _sizeText = s.files == 0
          ? '空'
          : '${s.files} 个文件 · ${(s.bytes / 1048576).toStringAsFixed(1)} MB';
    });
  }

  Future<void> _relocate() async {
    final dl = DownloadService.instance;
    if (dl.activeTasks.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('有下载任务进行中，请等待完成或取消后再更改')));
      return;
    }
    final ctl = TextEditingController(text: DataDirs.instance.imageCachePath);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('更改缓存位置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('把现有缓存文件移动到新目录（原目录文件移走，不留备份）。\n填回默认位置即可恢复跟随数据目录。'),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              decoration: const InputDecoration(
                  labelText: '新目录', hintText: r'D:\WnacgCache'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('移动')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final newPath = ctl.text.trim();
    ctl.dispose();
    if (newPath.isEmpty) return;
    setState(() => _busy = true);
    final moved = await ImageBridge.instance.relocateCache(newPath);
    if (!mounted) return;
    setState(() => _busy = false);
    _refreshSize();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('缓存位置已更改为 $newPath（移动 $moved 个文件）')));
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清理图片缓存'),
        content: const Text('删除磁盘缓存里的全部图片（网页缩略图与阅读页原图）。删除后需要重新联网加载。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('清理')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final n = await ImageBridge.instance.clearCache();
    if (!mounted) return;
    setState(() => _busy = false);
    _refreshSize();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已清理 $n 个缓存文件')));
  }

  Future<void> _setLimit(int mb) async {
    await AppStore.instance.setImageCacheMaxMb(mb);
    if (!mounted) return;
    setState(() {});
    if (mb > 0) {
      final freed =
          await ImageBridge.instance.enforceCacheLimit(mb * 1048576);
      if (mounted && freed > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('超过新上限，已自动清理 ${(freed / 1048576).toStringAsFixed(1)} MB')));
      }
      _refreshSize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return _Section(
      title: '图片缓存',
      children: [
        ListTile(
          leading: const Icon(Icons.folder_special_outlined),
          title: const Text('缓存位置'),
          subtitle: Text(DataDirs.instance.imageCachePath),
          trailing: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : FilledButton.tonal(
                  onPressed: _relocate, child: const Text('更改…')),
        ),
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: const Text('当前大小'),
          subtitle: Text(_sizeText),
          trailing: OutlinedButton(
              onPressed: _busy ? null : _clear, child: const Text('清理')),
        ),
        ListTile(
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('自动清理上限'),
          subtitle: const Text('超过上限时从最旧文件开始自动删除（0=不限制）'),
          isThreeLine: true,
          trailing: DropdownButton<int>(
            value: AppStore.snapImageCacheLimit(store.imageCacheMaxMb),
            items: [
              for (final mb in AppStore.imageCacheLimitOptions)
                DropdownMenuItem(value: mb, child: Text(_limitLabel(mb))),
            ],
            onChanged: (v) => _setLimit(v ?? 0),
          ),
        ),
      ],
    );
  }

  static String _limitLabel(int mb) {
    if (mb == 0) return '不限';
    return mb % 1024 == 0 ? '${mb ~/ 1024} GB' : '$mb MB';
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(title,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
          ...children,
        ],
      ),
    );
  }
}

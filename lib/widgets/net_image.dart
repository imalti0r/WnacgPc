import 'dart:io';

import 'package:flutter/material.dart';

import '../net/image_bridge.dart';

/// 通过 WebView2 桥加载的图片，支持点击重试；
/// [filePath] 直接读本地文件；[zipPath]+[entryName] 从本地 ZIP 按页读取。
class NetImage extends StatefulWidget {
  final String url;
  final String? referer; // 兼容保留；实际由桥内页面提供
  final String? filePath; // 本地文件路径（离线阅读）
  final BoxFit fit;
  final double? width;
  final double? height;

  /// 漫画 aid：磁盘缓存按漫画分目录（`<aid>/cover.ext`）
  final String? cacheId;

  const NetImage({
    super.key,
    required this.url,
    this.referer,
    this.filePath,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheId,
  });

  @override
  State<NetImage> createState() => _NetImageState();
}

class _NetImageState extends State<NetImage> {
  final bridge = ImageBridge.instance;
  int _attempt = 0;
  late String _url = widget.url;

  @override
  void didUpdateWidget(covariant NetImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.filePath != widget.filePath) {
      _url = widget.url;
      _attempt = 0;
    }
  }

  Widget _placeholder(BuildContext context, {Widget? child}) => Container(
        width: widget.width,
        height: widget.height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final empty = _placeholder(
      context,
      child: const Icon(Icons.image_not_supported_outlined),
    );
    // 本地文件
    if (widget.filePath != null) {
      final f = File(widget.filePath!);
      if (!f.existsSync()) return empty;
      return Image.file(
        f,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        filterQuality: FilterQuality.medium,
      );
    }
    if (_url.isEmpty) return empty;
    return Image(
      image: BridgedImageProvider(_url,
          attempt: _attempt, cacheId: widget.cacheId, cacheName: 'cover'),
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      filterQuality: FilterQuality.medium,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        final v = progress.expectedTotalBytes != null
            ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
            : null;
        return _placeholder(
          context,
          child: CircularProgressIndicator(value: v, strokeWidth: 2.5),
        );
      },
      errorBuilder: (context, error, stack) => Container(
        width: widget.width,
        height: widget.height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.all(4),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '加载失败，点击重试\n桥状态: ${bridge.status}\n最近错误: ${bridge.lastError}',
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() => _attempt++),
            ),
            Flexible(
              child: Text(
                (bridge.lastError.isNotEmpty ? bridge.lastError : bridge.status)
                    .replaceAll('\n', ' '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 9,
                    color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

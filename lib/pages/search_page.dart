import 'package:flutter/material.dart';

import '../api/wnacg_api.dart';
import '../pages/browse_page.dart';

/// 搜索页：搜索框 + 结果网格（复用 AlbumGrid）
class SearchPage extends StatefulWidget {
  final VoidCallback? onBack;
  const SearchPage({super.key, this.onBack});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  String? _query;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final api = WnacgApi.instance;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
          child: Row(
            children: [
              BackButton(onPressed: widget.onBack),
              Expanded(
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) => setState(() {
                    _query = v.trim().isEmpty ? null : v.trim();
                  }),
                  decoration: InputDecoration(
                    hintText:
                        '搜索…（支持 ["abc"] 仅标题、tags:a 仅标签、a -b 排除、a OR b）',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => setState(() {
                  _query = _controller.text.trim().isEmpty
                      ? null
                      : _controller.text.trim();
                }),
                child: const Text('搜索'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _query == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search,
                          size: 56,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: 8),
                      Text('输入关键词开始搜索',
                          style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                )
              : AlbumGrid(
                  key: ValueKey('search-$_query'),
                  sourceKey: 'search-$_query',
                  urlFor: (p) => api.searchUrl(_query!, p),
                ),
        ),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/book_source_engine.dart';
import '../models/book_source.dart';
import '../state/app_state.dart';
import '../widgets/book_tile.dart';
import 'detail_page.dart';

class SourceGroupResult {
  final BookSource source;
  List<SearchBook> books = [];
  bool loading = true;
  String? error;

  SourceGroupResult(this.source);
}

class SearchPage extends StatefulWidget {
  final String initialKeyword;
  const SearchPage({super.key, this.initialKeyword = ''});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialKeyword);
  final List<SourceGroupResult> _results = [];
  Set<String> _selectedUrls = {};
  final Set<String> _seenUrls = {};
  int _searchGen = 0;

  @override
  void initState() {
    super.initState();
    _syncSelected();
    if (widget.initialKeyword.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _doSearch(widget.initialKeyword));
    }
  }

  void _syncSelected() {
    // 新导入的书源默认勾选（initState 时书源列表可能还是空的），
    // 仅对首次出现的书源生效，不覆盖用户手动取消的勾选
    final sources = context.read<SourceState>().enabledNovelSources;
    for (final s in sources) {
      if (!_seenUrls.contains(s.bookSourceUrl)) {
        _seenUrls.add(s.bookSourceUrl);
        _selectedUrls.add(s.bookSourceUrl);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickSources() async {
    _syncSelected();
    final all = context.read<SourceState>().enabledNovelSources;
    final selected = {..._selectedUrls};
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: Column(
            children: [
              AppBar(
                title: const Text('选择书源'),
                automaticallyImplyLeading: false,
                actions: [
                  TextButton(onPressed: () {
                    setState(() {
                      if (selected.length == all.length) {
                        selected.clear();
                      } else {
                        selected.addAll(all.map((s) => s.bookSourceUrl));
                      }
                    });
                  }, child: const Text('全选/取消')),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
                ],
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final s in all)
                      CheckboxListTile(
                        title: Text(s.bookSourceName),
                        subtitle: Text(s.bookSourceUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                        value: selected.contains(s.bookSourceUrl),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            selected.add(s.bookSourceUrl);
                          } else {
                            selected.remove(s.bookSourceUrl);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() => _selectedUrls = selected);
  }

  Future<void> _doSearch(String key) async {
    if (key.trim().isEmpty) return;
    _syncSelected();
    final sources = context
        .read<SourceState>()
        .enabledNovelSources
        .where((s) => _selectedUrls.contains(s.bookSourceUrl) && (s.searchUrl?.isNotEmpty ?? false))
        .toList();
    if (sources.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有启用且配置了搜索规则的书源')));
      }
      return;
    }
    setState(() {
      _searchGen++;
      _results
        ..clear()
        ..addAll(sources.map(SourceGroupResult.new));
    });

    final gen = _searchGen;
    for (final group in _results) {
      unawaited(_searchOne(group, key, gen));
    }
  }

  Future<void> _searchOne(SourceGroupResult group, String key, int gen) async {
    final engine = BookSourceEngine(group.source);
    try {
      final books = await engine.search(key).timeout(const Duration(seconds: 25));
      group.books = books;
    } catch (e) {
      group.error = e.toString();
    }
    group.loading = false;
    if (gen != _searchGen) return; // 新一轮搜索已开始，丢弃过期结果
    if (mounted) setState(() {});
    if (group.books.isNotEmpty && group.source.enabled) {
      // 记录成功书源次序 —— 简单实现：不重排
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                onSubmitted: _doSearch,
                decoration: const InputDecoration(
                  hintText: '输入书名/作者搜索',
                  border: InputBorder.none,
                ),
              ),
            ),
            IconButton(icon: const Icon(Icons.tune), tooltip: '选择书源', onPressed: _pickSources),
            IconButton(icon: const Icon(Icons.search), onPressed: () => _doSearch(_controller.text)),
          ],
        ),
      ),
      body: _results.isEmpty
          ? const Center(child: Text('搜索结果将显示在这里'))
          : RefreshIndicator(
              onRefresh: () => _doSearch(_controller.text),
              child: ListView(
                children: [
                  for (final g in _results)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Row(
                            children: [
                              Text(g.source.bookSourceName, style: const TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(width: 8),
                              if (g.loading)
                                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                              else if (g.error != null)
                                Expanded(
                                  child: Text('失败: ${g.error}',
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
                                )
                              else
                                Text('${g.books.length} 条结果', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                            ],
                          ),
                        ),
                        if (!g.loading && g.books.isEmpty && g.error == null)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: Text('无结果', style: TextStyle(color: Colors.grey)),
                          ),
                        for (final b in g.books)
                          BookTile(
                            name: b.name,
                            author: b.author,
                            coverUrl: b.coverUrl,
                            subtitle: [
                              if (b.kind.isNotEmpty) b.kind,
                              if (b.lastChapter.isNotEmpty) b.lastChapter,
                            ].join(' · '),
                            progress: b.intro,
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => DetailPage(result: b, source: g.source),
                            )),
                          ),
                        const Divider(height: 1),
                      ],
                    ),
                ],
              ),
            ),
    );
  }
}

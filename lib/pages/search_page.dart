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

class SearchHit {
  final SearchBook book;
  final BookSource source;

  /// 同名同作者但在其它书源也命中的条数，用于"起点中文 +3 源"这类标注
  final int dupes;

  SearchHit(this.book, this.source, {this.dupes = 0});
}

/// 各源结果按"书名+作者"并成一条：同一本书往往十几个源都返回，
/// 按源分组刷屏只是噪音。保留首次命中的那个源，顺序即返回顺序。
List<SearchHit> mergeSearchResults(List<SourceGroupResult> groups) {
  final order = <String>[];
  final first = <String, SearchHit>{};
  final dupes = <String, int>{};
  for (final g in groups) {
    for (final b in g.books) {
      final key = '${b.name}|${b.author}';
      if (!first.containsKey(key)) {
        first[key] = SearchHit(b, g.source);
        order.add(key);
      } else {
        dupes[key] = (dupes[key] ?? 0) + 1;
      }
    }
  }
  return [for (final k in order) SearchHit(first[k]!.book, first[k]!.source, dupes: dupes[k] ?? 0)];
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _doSearch(widget.initialKeyword);
      });
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
    // 等全部书源返回再 resolve，下拉刷新指示器才能反映真实进度
    await Future.wait(_results.map((group) => _searchOne(group, key, gen)));
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
  }

  // 各源结果按"书名+作者"并成一条：同一本书往往十几个源都返回，分组刷屏只是噪音
  List<SearchHit> _flatten() => mergeSearchResults(_results);

  @override
  Widget build(BuildContext context) {
    final hits = _flatten();
    final returned = _results.where((g) => !g.loading).length;
    final searching = _results.isNotEmpty && returned < _results.length;
    final failed = _results.where((g) => g.error != null).length;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                onSubmitted: _doSearch,
                textInputAction: TextInputAction.search,
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
          ? const Center(child: Text('输入书名或作者，回车搜索全部启用书源'))
          : RefreshIndicator(
              onRefresh: () => _doSearch(_controller.text),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (searching)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      child: Row(
                        children: [
                          const SizedBox(
                              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 10),
                          Text('已返回 $returned/${_results.length} 个书源 · ${hits.length} 本',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                  for (final h in hits)
                    BookTile(
                      name: h.book.name,
                      author: h.book.author,
                      coverUrl: h.book.coverUrl,
                      subtitle: [
                        if (h.book.kind.isNotEmpty) h.book.kind,
                        if (h.book.lastChapter.isNotEmpty) h.book.lastChapter,
                        h.dupes > 0
                            ? '${h.source.bookSourceName} +${h.dupes} 源'
                            : h.source.bookSourceName,
                      ].join(' · '),
                      progress: h.book.intro,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => DetailPage(result: h.book, source: h.source),
                      )),
                    ),
                  if (!searching && hits.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 48, 16, 0),
                      child: Center(
                        child: Text(
                          failed > 0 ? '没有结果，${_results.length} 个书源中 $failed 个请求失败' : '没有找到相关书籍',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

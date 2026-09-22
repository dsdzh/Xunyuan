import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/book_source_engine.dart';
import '../models/book_source.dart';
import '../state/app_state.dart';
import '../widgets/book_tile.dart';
import 'detail_page.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  BookSource? _source;
  List<({String title, String url})> _categories = [];
  ({String title, String url})? _current;
  List<SearchBook> _books = [];
  bool _loading = false;
  String? _error;
  String? _moreError;
  int _page = 1;
  int _loadGen = 0;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    final withExplore = context.read<SourceState>().enabledNovelSources.where((s) => (s.exploreUrl ?? '').isNotEmpty).toList();
    if (withExplore.isNotEmpty) {
      _source = withExplore.first;
      _categories = BookSourceEngine.exploreCategories(withExplore.first);
      if (_categories.isNotEmpty) {
        _current = _categories.first;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
      }
    }
  }

  void _resetList() {
    _loadGen++;
    _books = [];
    _page = 1;
    _finished = false;
    _error = null;
    _moreError = null;
  }

  Future<void> _load({bool more = false}) async {
    final source = _source;
    final cat = _current;
    if (source == null || cat == null) return;
    if (more && (_finished || _loading)) return;
    if (!more) {
      _loadGen++;
      _page = 1;
      _finished = false;
      _error = null;
      _moreError = null;
    }
    final gen = _loadGen;
    setState(() => _loading = true);
    final page = more ? _page + 1 : 1;
    try {
      final books = await BookSourceEngine(source).explore(cat.url, page: page).timeout(const Duration(seconds: 25));
      if (!mounted || gen != _loadGen) return; // 已切换分类/书源，丢弃过期结果
      setState(() {
        // 无 {page} 规则的书源每页返回相同内容，按 bookUrl 去重防无限追加
        final seen = _books.map((b) => b.bookUrl).toSet();
        final fresh = books.where((b) => seen.add(b.bookUrl)).toList();
        _page = page;
        _books = more ? [..._books, ...fresh] : fresh;
        if (fresh.isEmpty) _finished = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        // 已有内容时错误只作页脚提示，不清空已加载列表
        if (more || _books.isNotEmpty) {
          _moreError = e.toString();
        } else {
          _error = e.toString();
        }
        _loading = false;
      });
    }
  }

  Future<void> _pickSource() async {
    final sources = context.read<SourceState>().enabledNovelSources.where((s) => (s.exploreUrl ?? '').isNotEmpty).toList();
    if (sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有配置发现页的书源')));
      return;
    }
    final picked = await showModalBottomSheet<BookSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('选择书源', textAlign: TextAlign.center)),
            for (final s in sources)
              ListTile(
                title: Text(s.bookSourceName),
                onTap: () => Navigator.pop(ctx, s),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _source = picked;
        _categories = BookSourceEngine.exploreCategories(picked);
        _current = _categories.isNotEmpty ? _categories.first : null;
        _resetList();
      });
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    return Scaffold(
      appBar: AppBar(
        title: Text(source?.bookSourceName ?? '发现'),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.swap_horiz), onPressed: _pickSource),
        ],
      ),
      body: source == null || _categories.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.explore_outlined, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  const Text('当前书源没有发现页配置'),
                  const SizedBox(height: 8),
                  const Text('可在书源管理中切换带 exploreUrl 的书源', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            )
          : Column(
              children: [
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final c in _categories)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                          child: ChoiceChip(
                            label: Text(c.title),
                            selected: _current?.title == c.title,
                            onSelected: (_) {
                              setState(() {
                                _current = c;
                                _resetList();
                              });
                              _load();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('加载失败：$_error', textAlign: TextAlign.center),
                                const SizedBox(height: 12),
                                FilledButton.tonal(onPressed: () => _load(), child: const Text('重试')),
                              ],
                            ),
                          ),
                        )
                      : _books.isEmpty && !_loading
                          ? const Center(child: Text('暂无内容'))
                          : NotificationListener<ScrollNotification>(
                              onNotification: (n) {
                                if (n is ScrollEndNotification &&
                                    n.metrics.extentAfter < 600 &&
                                    !_loading &&
                                    !_finished &&
                                    _moreError == null &&
                                    _books.isNotEmpty) {
                                  _load(more: true);
                                }
                                return false;
                              },
                              child: ListView(
                                children: [
                                  for (final b in _books)
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
                                        builder: (_) => DetailPage(result: b, source: source),
                                      )),
                                    ),
                                  if (_moreError != null)
                                    ListTile(
                                      title: Text('加载下一页失败：$_moreError',
                                          style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
                                      trailing: TextButton(
                                        onPressed: () => _load(more: true),
                                        child: const Text('重试'),
                                      ),
                                    ),
                                  if (_finished && _books.isNotEmpty && _moreError == null)
                                    Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Center(child: Text('没有更多了', style: TextStyle(fontSize: 12, color: Colors.grey.shade500))),
                                    ),
                                  if (_loading)
                                    const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))),
                                    ),
                                ],
                              ),
                            ),
                ),
              ],
            ),
    );
  }
}

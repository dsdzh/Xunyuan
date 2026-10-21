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
  final FocusNode _searchFocus = FocusNode();
  double _emptyPull = 0;
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
    _searchFocus.dispose();
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

  void _focusSearch() => _searchFocus.requestFocus();

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
            // 框体收成一颗带底色的胶囊：原来 TextField 平铺整行、无边无距，
            // 看着不像输入框，点哪儿都像在点标题栏
            Expanded(
              child: Container(
                margin: const EdgeInsets.only(left: 12, right: 4, top: 10, bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _searchFocus,
                  onSubmitted: _doSearch,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 15),
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 13),
                    hintText: '输入书名/作者搜索',
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            // IconButton 默认 48x48 命中框加内边距，两个图标之间、图标与屏幕右边
            // 各留一大块空白，把输入框挤得没剩多少宽度
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: '选择书源',
              onPressed: _pickSources,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            ),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => _doSearch(_controller.text),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
      body: _results.isEmpty
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _focusSearch,
              // 空状态整屏都是空白，往下拉一下就该把光标送进搜索框，不用回头去够顶部那颗胶囊。
              // 判据用累计位移而不是松手时的速度：拖够就当场聚焦，也避开测试环境里
              // 恒为 0 的 primaryVelocity
              onVerticalDragStart: (_) => _emptyPull = 0,
              onVerticalDragUpdate: (d) {
                _emptyPull += d.primaryDelta ?? 0;
                if (_emptyPull > 32) _focusSearch();
              },
              child: SizedBox.expand(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text('输入书名或作者，回车搜索全部启用书源',
                        style: TextStyle(fontSize: 15, color: Colors.grey.shade700)),
                    const SizedBox(height: 18),
                    Icon(Icons.keyboard_arrow_down, size: 28, color: Colors.grey.shade500),
                    Text('下拉或点击空白处聚焦搜索框',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  ],
                ),
              ),
            )
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
                      // 源名放最前：点开后详情/正文规则都取自它，被截断就选错源了
                      subtitle: [
                        h.dupes > 0
                            ? '${h.source.bookSourceName} +${h.dupes} 源'
                            : h.source.bookSourceName,
                        if (h.book.kind.isNotEmpty) h.book.kind,
                        if (h.book.lastChapter.isNotEmpty) h.book.lastChapter,
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

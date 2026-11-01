import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/book_source_engine.dart';
import '../models/book_source.dart';
import '../services/storage_service.dart';
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

  /// MainPage 用 IndexedStack 常驻各页，切走不会 dispose，所以要靠这个信号
  /// 在「可见→不可见」那一下把页面收回空态。独立 push 出来的搜索页恒为 true，
  /// 从详情页返回不该把结果清掉。
  final bool visible;
  const SearchPage({super.key, this.initialKeyword = '', this.visible = true});

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
  List<String> _history = const [];

  /// 空态只摆最近这几条，其余进「全部」面板看
  static const _inlineHistoryCount = 10;

  @override
  void initState() {
    super.initState();
    _history = StorageService.instance.searchHistory;
    _syncSelected();
    if (widget.initialKeyword.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _doSearch(widget.initialKeyword);
      });
    }
  }

  @override
  void didUpdateWidget(SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible || !oldWidget.visible) return;
    _resetToIdle();
  }

  /// 切走 tab 就当作"没搜过"：结果、输入框、焦点全部收回，回来只剩搜索记录。
  /// 就地清而不是回来时清，省得一进搜索页先闪一下旧结果。
  /// didUpdateWidget 之后必然跟着本元素重建，所以这里只改字段不 setState；
  /// build 期间动 FocusManager 会撞上「setState() called during build」断言，
  /// 取消焦点得推到本帧渲染完。
  void _resetToIdle() {
    if (_results.isEmpty && _controller.text.isEmpty) return;
    // 在飞的请求靠 gen 作废，不然它们回来后又把空态填回结果
    _searchGen++;
    _results.clear();
    _controller.clear();
    _history = StorageService.instance.searchHistory;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.unfocus();
    });
  }

  void _reloadHistory() {
    if (mounted) setState(() => _history = StorageService.instance.searchHistory);
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

  /// 点记录=用这个词再搜一次
  void _searchFromHistory(String kw) {
    _controller.text = kw;
    _doSearch(kw);
  }

  Future<void> _deleteHistoryEntry(String kw) async {
    await StorageService.instance.removeSearchHistory(kw);
    _reloadHistory();
  }

  Future<void> _clearHistory() async {
    await StorageService.instance.clearSearchHistory();
    _reloadHistory();
  }

  Widget _historyChip(String kw) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _searchFromHistory(kw),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(kw,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 15),
                tooltip: '删除这条记录',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                onPressed: () => _deleteHistoryEntry(kw),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 全部搜索记录：点一条就地收起面板并搜它，右侧单删，右上角清空
  Future<void> _showAllHistory() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.55,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
                  child: Row(
                    children: [
                      Text('搜索记录（${_history.length}）',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton(
                        onPressed: _history.isEmpty
                            ? null
                            : () async {
                                await _clearHistory();
                                setSheet(() {});
                              },
                        child: const Text('清空'),
                      ),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                    ],
                  ),
                ),
                Expanded(
                  child: _history.isEmpty
                      ? Center(
                          child: Text('没有搜索记录', style: TextStyle(color: Colors.grey.shade600)))
                      : ListView(
                          children: [
                            for (final kw in _history)
                              ListTile(
                                dense: true,
                                leading: const Icon(Icons.history, size: 20),
                                title: Text(kw, maxLines: 1, overflow: TextOverflow.ellipsis),
                                trailing: IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  tooltip: '删除这条记录',
                                  onPressed: () async {
                                    await _deleteHistoryEntry(kw);
                                    setSheet(() {});
                                  },
                                ),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _searchFromHistory(kw);
                                },
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    // 先切到结果态再落盘：搜索记录的写要走真实事件循环，
    // 排在前面会让点下搜索后空屏一瞬
    setState(() {
      _searchGen++;
      _results
        ..clear()
        ..addAll(sources.map(SourceGroupResult.new));
    });

    final gen = _searchGen;
    final pending = Future.wait(
        _results.map((group) => _searchOne(group, key, gen)));
    // 发起就记下，不等结果：全部书源都失败也算"搜过这个词"，下次回来该能一键再来一次
    await StorageService.instance.addSearchHistory(key);
    if (mounted) _reloadHistory();
    // 等全部书源返回再 resolve，下拉刷新指示器才能反映真实进度
    await pending;
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
                    if (_history.isNotEmpty) ...[
                      const SizedBox(height: 32),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text('搜索记录',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey.shade700)),
                                const Spacer(),
                                // 空态只摆最近几条，其余进面板看全部
                                InkWell(
                                  onTap: _showAllHistory,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Text('全部 ${_history.length} 条 ›',
                                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final kw in _history.take(_inlineHistoryCount)) _historyChip(kw),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
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

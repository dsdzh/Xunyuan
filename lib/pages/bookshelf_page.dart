import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/storage_service.dart';
import '../state/app_state.dart';
import '../widgets/book_tile.dart';
import 'history_page.dart';
import 'reader_page.dart';
import 'search_page.dart';

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  bool _selecting = false;
  bool _grid = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _grid = StorageService.instance.setting('shelfGrid', def: false) as bool;
  }

  void _toggleGrid() {
    setState(() => _grid = !_grid);
    StorageService.instance.putSetting('shelfGrid', _grid);
  }

  void _enterSelect() => setState(() {
        _selecting = true;
        _selected.clear();
      });

  void _exitSelect() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _toggle(String key) => setState(() {
        if (!_selected.remove(key)) _selected.add(key);
        if (_selected.isEmpty) _selecting = false;
      });

  Future<void> _confirmDelete(ShelfState shelf) async {
    if (_selected.isEmpty) return;
    final names = _selected
        .map((k) => shelf.books.firstWhere((b) => b['key']?.toString() == k, orElse: () => const {})['name'] ?? '')
        .where((n) => '$n'.isNotEmpty)
        .join('、');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('移出书架（${_selected.length} 本）'),
        content: Text('确定将 $names 移出书架吗？阅读进度将保留在浏览记录中。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final key in _selected.toList()) {
      await shelf.remove(key);
    }
    if (!mounted) return;
    _exitSelect();
  }

  void _onBookTap(Map<String, dynamic> book, String key) {
    if (_selecting) {
      _toggle(key);
      return;
    }
    final source = context.read<AppServices>().findSource(book['sourceUrl']?.toString() ?? '');
    if (source == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('书源已删除，无法阅读')));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderPage(book: book, source: source),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final shelf = context.watch<ShelfState>();

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelect),
              title: Text('已选 ${_selected.length} 本'),
              centerTitle: true,
              actions: [
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == shelf.books.length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(shelf.books.map((b) => b['key'].toString()));
                    }
                  }),
                  child: Text(_selected.length == shelf.books.length ? '取消全选' : '全选'),
                ),
                IconButton(
                  icon: Icon(Icons.delete, color: _selected.isEmpty ? Colors.grey : Colors.red),
                  tooltip: '删除所选',
                  onPressed: _selected.isEmpty ? null : () => _confirmDelete(shelf),
                ),
              ],
            )
          : AppBar(
              title: const Text('书架'),
              centerTitle: true,
              actions: [
                IconButton(
                  icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view),
                  tooltip: _grid ? '列表视图' : '宫格视图',
                  onPressed: _toggleGrid,
                ),
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: '浏览记录',
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryPage())),
                ),
                IconButton(
                  icon: const Icon(Icons.checklist),
                  tooltip: '批量删除',
                  onPressed: shelf.books.isEmpty ? null : _enterSelect,
                ),
              ],
            ),
      body: shelf.books.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.library_add_outlined, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  const Text('书架空空如也，去搜索添加书籍吧'),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchPage())),
                    child: const Text('去搜索'),
                  ),
                ],
              ),
            )
          : _grid
              ? _buildGrid(shelf)
              : _buildList(shelf),
    );
  }

  Widget _buildList(ShelfState shelf) {
    return ListView.separated(
      itemCount: shelf.books.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final book = shelf.books[i];
        final key = book['key'].toString();
        final tile = BookTile(
          name: (book['name'] ?? '').toString(),
          author: (book['author'] ?? '').toString(),
          coverUrl: (book['coverUrl'] ?? '').toString(),
          subtitle: (book['lastChapter'] ?? '').toString(),
          progress: _progressText(book),
          trailing: _selecting
              ? Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    _selected.contains(key) ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: _selected.contains(key) ? const Color(0xFF2E7D5B) : Colors.grey.shade400,
                  ),
                )
              : null,
          onLongPress: _selecting ? null : _enterSelect,
          onTap: () => _onBookTap(book, key),
        );
        if (_selecting) return tile;
        return Dismissible(
          key: ValueKey(key),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red.shade300,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (_) => _confirmRemove(context, shelf, book),
          onDismissed: (_) => shelf.remove(key),
          child: tile,
        );
      },
    );
  }

  Widget _buildGrid(ShelfState shelf) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 3;
        const spacing = 12.0;
        final tileWidth = (constraints.maxWidth - 24 - spacing * (columns - 1)) / columns;
        final coverHeight = tileWidth * 1.38;
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: tileWidth / (coverHeight + 62),
          ),
          itemCount: shelf.books.length,
          itemBuilder: (context, i) {
            final book = shelf.books[i];
            final key = book['key'].toString();
            final selected = _selected.contains(key);
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onLongPress: _selecting ? null : _enterSelect,
              onTap: () => _onBookTap(book, key),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: tileWidth,
                    height: coverHeight,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          BookCover(
                            coverUrl: (book['coverUrl'] ?? '').toString(),
                            name: (book['name'] ?? '').toString(),
                            width: tileWidth,
                            height: coverHeight,
                          ),
                          if (_selecting)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Icon(
                                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                                color: selected ? const Color(0xFF2E7D5B) : Colors.white70,
                              ),
                            ),
                          if (_selecting && selected)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2E7D5B).withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      (book['name'] ?? '').toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.25),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<bool> _confirmRemove(BuildContext context, ShelfState shelf, Map<String, dynamic> book) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('移出书架'),
            content: Text('确定将《${book['name']}》移出书架吗？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('移除')),
            ],
          ),
        ) ??
        false;
  }

  String _progressText(Map<String, dynamic> book) {
    final dur = (book['durChapterTitle'] ?? '').toString();
    if (dur.isEmpty) return '尚未开始阅读';
    final idx = book['durChapterIndex'];
    final total = book['tocCount'];
    final pos = (idx is int && total is int && total > 0) ? '第 ${idx + 1}/$total 章 · ' : '';
    return '$pos$dur';
  }
}

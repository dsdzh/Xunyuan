import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/storage_service.dart';
import '../state/app_state.dart';
import '../widgets/book_tile.dart';
import 'reader_page.dart';
import 'search_page.dart';

class BookshelfPage extends StatelessWidget {
  const BookshelfPage({super.key});

  @override
  Widget build(BuildContext context) {
    final shelf = context.watch<ShelfState>();
    final services = context.read<AppServices>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: '清空章节缓存',
            onPressed: () async {
              await StorageService.instance.clearChapterCache();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('章节缓存已清空')));
              }
            },
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
          : ListView.separated(
              itemCount: shelf.books.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final book = shelf.books[i];
                final source = services.findSource(book['sourceUrl']?.toString() ?? '');
                return Dismissible(
                  key: ValueKey(book['key']),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red.shade300,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) async {
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
                  },
                  onDismissed: (_) => shelf.remove(book['key'].toString()),
                  child: BookTile(
                    name: (book['name'] ?? '').toString(),
                    author: (book['author'] ?? '').toString(),
                    coverUrl: (book['coverUrl'] ?? '').toString(),
                    subtitle: (book['lastChapter'] ?? '').toString(),
                    progress: _progressText(book),
                    onTap: () {
                      if (source == null) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('书源已删除，无法阅读')));
                        return;
                      }
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ReaderPage(book: book, source: source),
                      ));
                    },
                  ),
                );
              },
            ),
    );
  }

  String _progressText(Map<String, dynamic> book) {
    final dur = (book['durChapterTitle'] ?? '').toString();
    final idx = book['durChapterIndex'];
    if (dur.isEmpty) return '';
    if (idx == 0) return '尚未开始阅读';
    final total = book['tocCount'];
    final pos = (idx is int && total is int && total > 0) ? '第 ${idx + 1}/$total 章 · ' : '';
    return '$pos$dur';
  }
}

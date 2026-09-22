import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../widgets/book_tile.dart';
import 'reader_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  // Dismissible 要求回调同步移出组件树，removeHistory 是异步的，先本地记账
  final Set<String> _dismissed = {};

  @override
  Widget build(BuildContext context) {
    final shelf = context.watch<ShelfState>();
    final services = context.read<AppServices>();
    if (_dismissed.isNotEmpty) {
      // 仅清理已真正离开 history 的键；仍在库里（removeHistory 异步未落库）的键须继续压住，
      // 防止刚滑掉的记录本帧被重建触发 Dismissible 断言/闪回
      final live = shelf.history.map((b) => '${b['key']}').toSet();
      _dismissed.removeWhere((k) => !live.contains(k));
    }
    final history =
        shelf.history.where((b) => !_dismissed.contains('${b['key']}')).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览记录'),
        centerTitle: true,
        actions: [
          if (history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空记录',
              onPressed: () async {
                final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('清空浏览记录'),
                        content: const Text('仅清空记录列表，不影响书架和阅读进度。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
                        ],
                      ),
                    ) ??
                    false;
                if (ok) await shelf.clearHistory();
              },
            ),
        ],
      ),
      body: history.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  const Text('还没有浏览记录'),
                ],
              ),
            )
          : ListView.separated(
              itemCount: history.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final book = history[i];
                final key = book['key'].toString();
                final source = services.findSource(book['sourceUrl']?.toString() ?? '');
                return Dismissible(
                  key: ValueKey('h::$key'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red.shade300,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) {
                    setState(() => _dismissed.add(key));
                    shelf.removeHistory(key);
                  },
                  child: BookTile(
                    name: (book['name'] ?? '').toString(),
                    author: (book['author'] ?? '').toString(),
                    coverUrl: (book['coverUrl'] ?? '').toString(),
                    subtitle: book['durChapterTitle']?.toString(),
                    progress: _timeAgo(book['lastReadTime']),
                    onTap: () {
                      if (source == null) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('书源已删除，无法阅读')));
                        return;
                      }
                      final idx = book['durChapterIndex'];
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ReaderPage(
                          book: Map<String, dynamic>.of(book),
                          source: source,
                          startIndex: idx is int ? idx : int.tryParse('$idx') ?? 0,
                        ),
                      ));
                    },
                  ),
                );
              },
            ),
    );
  }

  static String _timeAgo(dynamic v) {
    final ms = v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
    if (ms == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

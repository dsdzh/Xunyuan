import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/book_source_engine.dart';
import '../models/book_source.dart';
import '../services/storage_service.dart';
import '../state/app_state.dart';
import 'reader_page.dart';

class DetailPage extends StatefulWidget {
  final SearchBook result;
  final BookSource source;

  const DetailPage({super.key, required this.result, required this.source});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final BookSourceEngine _engine = BookSourceEngine(widget.source);
  BookDetail? _detail;
  List<Chapter> _chapters = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await _engine.bookInfo(widget.result.bookUrl,
          name: widget.result.name, author: widget.result.author);
      List<Chapter>? chapters;
      if (!force) {
        chapters = StorageService.instance.getCachedToc(detail.tocUrl);
      }
      if (chapters == null || chapters.isEmpty) {
        chapters = await _engine.toc(detail.tocUrl);
        if (chapters.isNotEmpty) {
          unawaited(StorageService.instance.putCachedToc(detail.tocUrl, chapters));
        }
      }
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _chapters = chapters!;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openReader(int index, {bool resume = true}) async {
    final detail = _detail;
    if (detail == null || _chapters.isEmpty) return;
    final shelf = context.read<ShelfState>();
    // 不再自动加入书架：在架用书架条目，不在架用临时条目（只记浏览历史）
    final book = shelf.byKey(StorageKeys.keyOf(detail)) ??
        {
          'key': StorageKeys.keyOf(detail),
          'name': detail.name,
          'author': detail.author,
          'coverUrl': detail.coverUrl,
          'intro': detail.intro,
          'lastChapter': detail.lastChapter,
          'bookUrl': detail.bookUrl,
          'tocUrl': detail.tocUrl,
          'sourceUrl': detail.sourceUrl,
          'sourceName': detail.sourceName,
        };
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderPage(
        book: Map<String, dynamic>.from(book),
        source: widget.source,
        chapters: _chapters,
        startIndex: index,
        resumeFromSaved: resume,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(d?.name.isNotEmpty == true ? d!.name : '书籍详情')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('加载失败：$_error', textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.tonal(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(force: true),
                  child: ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _cover(d),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(d?.name ?? widget.result.name,
                                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 6),
                                  Text(
                                    [
                                      if ((d?.author ?? '').isNotEmpty) d!.author,
                                      if ((d?.kind ?? '').isNotEmpty) d!.kind,
                                    ].join(' · '),
                                    style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                                  ),
                                  if ((d?.lastChapter ?? '').isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text('最新：${d!.lastChapter}',
                                        maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                                  ],
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      FilledButton.icon(
                                        icon: const Icon(Icons.menu_book, size: 18),
                                        label: const Text('阅读'),
                                        onPressed: _chapters.isEmpty ? null : () => _openReader(_startIndex()),
                                      ),
                                      const SizedBox(width: 12),
                                      OutlinedButton.icon(
                                        icon: Icon(
                                          context.watch<ShelfState>().isInShelf(
                                              d?.name ?? '', d?.author ?? '', widget.source.bookSourceUrl)
                                              ? Icons.check
                                              : Icons.add,
                                          size: 18,
                                        ),
                                        label: const Text('书架'),
                                        onPressed: () async {
                                          await context.read<ShelfState>().addFromDetail(d!);
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(const SnackBar(content: Text('已加入书架')));
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if ((d?.intro ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('简介', style: TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 6),
                              ExpandableText(d!.intro),
                            ],
                          ),
                        ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('目录（${_chapters.length} 章）', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      if (_chapters.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('目录解析为空，可能是书源规则含不支持的语法')),
                        )
                      else
                        for (final c in _chapters)
                          ListTile(
                            dense: true,
                            title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () => _openReader(c.index, resume: false),
                          ),
                    ],
                  ),
                ),
    );
  }

  int _startIndex() {
    final book = context.read<ShelfState>().byKey(StorageKeys.keyOf(_detail!));
    final idx = book?['durChapterIndex'];
    return (idx is int && idx < _chapters.length) ? idx : 0;
  }

  Widget _cover(BookDetail? d) {
    const w = 84.0, h = 112.0;
    final url = d?.coverUrl ?? '';
    if (url.isEmpty || !url.startsWith('http')) {
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: const Color(0xFF2E7D5B).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: Text(() {
          final n = d?.name ?? widget.result.name;
          return n.length <= 2 ? n : n.substring(0, 2);
        }(),
            style: const TextStyle(fontSize: 22, color: Color(0xFF2E7D5B), fontWeight: FontWeight.bold)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(url, width: w, height: h, fit: BoxFit.cover,
          errorBuilder: (_, _, _) => SizedBox(
                width: w,
                height: h,
                child: Container(color: Colors.grey.shade300),
              )),
    );
  }
}

class StorageKeys {
  static String keyOf(BookDetail d) => '${d.name}|${d.author}|${d.sourceUrl}';
}

class ExpandableText extends StatefulWidget {
  final String text;
  const ExpandableText(this.text, {super.key});

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Text(
        widget.text,
        maxLines: _expanded ? null : 3,
        overflow: _expanded ? null : TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14, color: Colors.grey.shade700, height: 1.5),
      ),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/book_source_engine.dart';
import '../models/book_source.dart';
import '../services/storage_service.dart';
import '../state/app_state.dart';

class ReaderPage extends StatefulWidget {
  final Map<String, dynamic> book;
  final BookSource source;
  final List<Chapter>? chapters;
  final int? startIndex;

  const ReaderPage({super.key, required this.book, required this.source, this.chapters, this.startIndex});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late final BookSourceEngine _engine = BookSourceEngine(widget.source);
  late final ShelfState _shelf = context.read<ShelfState>();

  List<Chapter> _chapters = [];
  bool _loadingToc = true;
  String? _error;

  // 滚动模式状态
  final List<String> _paragraphs = [];
  final List<int> _paragraphChapter = [];
  final Map<int, int> _chapterStart = {};
  int _firstLoadedChapter = 0;
  int _lastLoadedChapter = -1;
  bool _loadingContent = false;
  final ScrollController _scrollController = ScrollController();

  // 翻页模式状态
  List<String> _chapterParagraphs = [];
  int _currentChapter = 0;
  int _readPage = 0;

  bool _menuVisible = true;
  late bool _scrollMode = context.read<ReaderSettings>().scrollMode;

  double _progress = 0;
  int _progressChapter = 0;
  String _progressTitle = '';

  @override
  void initState() {
    super.initState();
    _progressChapter = (widget.startIndex ?? _intOf(widget.book['durChapterIndex'])).clamp(0, 1 << 30);
    _currentChapter = _progressChapter;
    if (widget.chapters != null && widget.chapters!.isNotEmpty) {
      _chapters = widget.chapters!;
      _loadingToc = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
    } else {
      unawaited(_loadToc());
    }
  }

  static int _intOf(dynamic v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;

  @override
  void dispose() {
    final key = widget.book['key']?.toString();
    if (key != null && _progressTitle.isNotEmpty) {
      unawaited(_shelf.updateProgress(key, _progressChapter, _progressTitle, _progress));
    }
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadToc({bool force = false}) async {
    setState(() {
      _loadingToc = true;
      _error = null;
    });
    try {
      final tocUrl = (widget.book['tocUrl'] ?? widget.book['bookUrl'] ?? '').toString();
      var chapters = force ? null : StorageService.instance.getCachedToc(tocUrl);
      if (chapters == null || chapters.isEmpty) {
        chapters = await _engine.toc(tocUrl);
        if (chapters.isNotEmpty) {
          unawaited(StorageService.instance.putCachedToc(tocUrl, chapters));
        }
      }
      if (!mounted) return;
      if (chapters.isEmpty) {
        setState(() {
          _error = '目录解析失败：书源规则可能含不支持的语法';
          _loadingToc = false;
        });
        return;
      }
      setState(() {
        _chapters = chapters!;
        _loadingToc = false;
      });
      _prepare();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '目录加载失败: $e';
        _loadingToc = false;
      });
    }
  }

  void _prepare() {
    _currentChapter = math.min(_currentChapter, _chapters.length - 1);
    _progressChapter = _currentChapter;
    if (_scrollMode) {
      unawaited(_loadAround(_currentChapter));
    } else {
      unawaited(_loadChapterForPaged(_currentChapter));
    }
  }

  // ---------- 内容 ----------

  Future<String> _chapterContent(int idx) async {
    final chapter = _chapters[idx];
    // 缓存键带上书籍标识与章节序号，避免同书源不同书、或 url 为空的章节互相覆盖
    final bookId = widget.book['key']?.toString() ?? widget.source.bookSourceUrl;
    final cacheKey = 'ch::$bookId::$idx::${chapter.url}';
    final cached = StorageService.instance.getCachedChapter(cacheKey);
    if (cached != null) return cached;
    final content = await _engine.content(chapter.url, title: chapter.title);
    unawaited(StorageService.instance.putCachedChapter(cacheKey, content));
    return content;
  }

  List<String> _splitParagraphs(String content) {
    final parts = content
        .split(RegExp(r'\n+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? ['　'] : parts;
  }

  // ---------- 滚动模式 ----------

  Future<void> _loadAround(int chapterIdx) async {
    _paragraphs.clear();
    _paragraphChapter.clear();
    _chapterStart.clear();
    _firstLoadedChapter = chapterIdx;
    _lastLoadedChapter = chapterIdx - 1;
    for (var i = chapterIdx; i < math.min(chapterIdx + 2, _chapters.length); i++) {
      await _appendChapter(i);
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _appendChapter(int idx) async {
    if (_chapterStart.containsKey(idx) || idx >= _chapters.length) return;
    _chapterStart[idx] = _paragraphs.length;
    List<String> paras;
    try {
      paras = _splitParagraphs(await _chapterContent(idx));
    } catch (e) {
      paras = ['【本章加载失败：$e】'];
    }
    if (!mounted) return;
    _paragraphChapter.addAll(List.filled(paras.length, idx));
    _paragraphs.addAll(paras);
    _lastLoadedChapter = math.max(_lastLoadedChapter, idx);
  }

  Future<void> _prependChapter() async {
    if (_loadingContent || _firstLoadedChapter <= 0) return;
    _loadingContent = true;
    final idx = _firstLoadedChapter - 1;
    List<String> paras;
    try {
      paras = _splitParagraphs(await _chapterContent(idx));
    } catch (e) {
      paras = ['【本章加载失败：$e】'];
    }
    if (!mounted) {
      _loadingContent = false;
      return;
    }
    final before = _scrollController.hasClients ? _scrollController.position.pixels : 0.0;
    _paragraphs.insertAll(0, paras);
    _paragraphChapter.insertAll(0, List.filled(paras.length, idx));
    for (final k in _chapterStart.keys.toList()) {
      _chapterStart[k] = _chapterStart[k]! + paras.length;
    }
    _chapterStart[idx] = 0;
    _firstLoadedChapter = idx;
    _loadingContent = false;
    setState(() {});
    // 保持视觉位置（近似）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(before + paras.length * _avgParagraphHeight());
      }
    });
  }

  double _avgParagraphHeight() {
    final settings = context.read<ReaderSettings>();
    return settings.fontSize * settings.lineHeight * 3;
  }

  void _onScroll(ScrollNotification n) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    _progress = pos.maxScrollExtent <= 0 ? 0 : (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
    if (n is ScrollUpdateNotification) {
      if (n.metrics.extentAfter < 1500) {
        _appendNextIfNeed();
      }
      if (n.metrics.extentBefore < 600) {
        unawaited(_prependChapter());
      }
    }
  }

  void _appendNextIfNeed() {
    if (_loadingContent) return;
    final next = _lastLoadedChapter + 1;
    if (next >= _chapters.length) return;
    _loadingContent = true;
    _appendChapter(next).then((_) {
      _loadingContent = false;
      if (mounted) setState(() {});
    });
  }

  int _visibleChapter() {
    if (_paragraphChapter.isEmpty || !_scrollController.hasClients) return _currentChapter;
    final approxPara = _avgParagraphHeight();
    var paraIdx = (_scrollController.position.pixels / approxPara).floor();
    paraIdx = paraIdx.clamp(0, _paragraphChapter.length - 1);
    return _paragraphChapter[paraIdx];
  }

  // ---------- 翻页模式 ----------

  Future<void> _loadChapterForPaged(int idx) async {
    if (idx < 0 || idx >= _chapters.length) return;
    List<String> paras;
    try {
      paras = _splitParagraphs(await _chapterContent(idx));
    } catch (e) {
      paras = ['【本章加载失败：$e】'];
    }
    if (!mounted) return;
    setState(() {
      _currentChapter = idx;
      _chapterParagraphs = paras;
      _readPage = 0;
    });
  }

  // ---------- 跳转 ----------

  void _jumpToChapter(int i) {
    setState(() {
      _currentChapter = i;
      _progressChapter = i;
    });
    if (_scrollMode) {
      unawaited(_loadAround(i));
    } else {
      unawaited(_loadChapterForPaged(i));
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReaderSettings>();
    if (settings.scrollMode != _scrollMode) {
      _scrollMode = settings.scrollMode;
      WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
    }
    final theme = settings.theme;
    final bg = Color(theme.bg);
    final fg = Color(theme.fg);

    return Scaffold(
      backgroundColor: bg,
      body: _loadingToc
          ? Center(child: CircularProgressIndicator(color: fg))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: fg)),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: () => _loadToc(force: true), child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _menuVisible = !_menuVisible),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: SafeArea(
                          child: _scrollMode ? _buildScrollReader(fg, settings) : _buildPagedReader(fg, settings),
                        ),
                      ),
                      if (_menuVisible) _buildTopBar(bg, fg),
                      if (_menuVisible) _buildBottomBar(bg, fg, settings),
                    ],
                  ),
                ),
    );
  }

  Widget _buildScrollReader(Color fg, ReaderSettings settings) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        _onScroll(n);
        return false;
      },
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(20, 48, 20, 48),
        itemCount: _paragraphs.length + 1,
        itemBuilder: (context, i) {
          if (i == _paragraphs.length) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: _lastLoadedChapter + 1 >= _chapters.length
                    ? Text('已读到目录末尾', style: TextStyle(color: fg.withValues(alpha: 0.6)))
                    : SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: fg.withValues(alpha: 0.5))),
              ),
            );
          }
          final chapterIdx = _paragraphChapter[i];
          final isFirst = _chapterStart[chapterIdx] == i;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isFirst)
                Padding(
                  padding: EdgeInsets.fromLTRB(0, i == 0 ? 0 : 32, 0, 16),
                  child: Text(_chapters[chapterIdx].title,
                      style: TextStyle(color: fg, fontSize: settings.fontSize + 4, fontWeight: FontWeight.bold)),
                ),
              Text(
                _paragraphs[i],
                style: TextStyle(color: fg, fontSize: settings.fontSize, height: settings.lineHeight),
              ),
              SizedBox(height: settings.fontSize * 0.7),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPagedReader(Color fg, ReaderSettings settings) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 48),
      child: _chapterParagraphs.isEmpty
          ? Center(child: Text('加载中…', style: TextStyle(color: fg)))
          : LayoutBuilder(
              key: ValueKey('${settings.fontSize}|${settings.lineHeight}'),
              builder: (context, constraints) {
                final pages = _paginate(chapterParagraphs: _chapterParagraphs, constraints: constraints, settings: settings);
                if (_readPage >= pages.length) _readPage = pages.length - 1;
                _progress = pages.length <= 1
                    ? 0.0
                    : (_readPage / (pages.length - 1)).clamp(0.0, 1.0);
                _progressChapter = _currentChapter;
                _progressTitle = _chapters[_currentChapter].title;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragEnd: (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -200) _pagedTurn(pages.length, 1);
                    if (v > 200) _pagedTurn(pages.length, -1);
                  },
                  onTapUp: (d) {
                    final w = constraints.maxWidth;
                    if (d.localPosition.dx < w / 3) {
                      _pagedTurn(pages.length, -1);
                    } else if (d.localPosition.dx > w * 2 / 3) {
                      _pagedTurn(pages.length, 1);
                    } else {
                      setState(() => _menuVisible = !_menuVisible);
                    }
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_chapters[_currentChapter].title,
                          style: TextStyle(color: fg, fontSize: settings.fontSize + 4, fontWeight: FontWeight.bold)),
                      SizedBox(height: settings.fontSize),
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: Text(pages[_readPage],
                              style: TextStyle(fontSize: settings.fontSize, height: settings.lineHeight, color: fg)),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text('${_readPage + 1}/${pages.length}',
                            style: TextStyle(color: fg.withValues(alpha: 0.5), fontSize: 12)),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  void _pagedTurn(int totalPages, int dir) {
    final target = _readPage + dir;
    if (target < 0) {
      if (_currentChapter > 0) {
        unawaited(_loadChapterForPaged(_currentChapter - 1).then((_) {
          // 上一章：跳到最后一页近似处理
          if (mounted) setState(() {});
        }));
      }
      return;
    }
    if (target >= totalPages) {
      if (_currentChapter + 1 < _chapters.length) {
        unawaited(_loadChapterForPaged(_currentChapter + 1));
      }
      return;
    }
    setState(() => _readPage = target);
  }

  // _paginate 记忆化：段落列表 / 字号 / 行距 / 页面尺寸任一变化才重算
  List<String>? _pagesCache;
  List<String>? _pagesSrc;
  double _pagesKey1 = -1, _pagesKey2 = -1, _pagesKey3 = -1, _pagesKey4 = -1;

  List<String> _paginate({
    required List<String> chapterParagraphs,
    required BoxConstraints constraints,
    required ReaderSettings settings,
  }) {
    if (_pagesCache != null &&
        identical(_pagesSrc, chapterParagraphs) &&
        _pagesKey1 == settings.fontSize &&
        _pagesKey2 == settings.lineHeight &&
        _pagesKey3 == constraints.maxWidth &&
        _pagesKey4 == constraints.maxHeight) {
      return _pagesCache!;
    }
    final pageWidth = constraints.maxWidth;
    final pageHeight = constraints.maxHeight - settings.fontSize * 2.5;
    final style = TextStyle(fontSize: settings.fontSize, height: settings.lineHeight);
    final pages = <String>[];
    var current = <String>[];
    var currentHeight = 0.0;

    double paraHeight(String p) {
      final tp = TextPainter(text: TextSpan(text: p, style: style), maxLines: null, textDirection: TextDirection.ltr)
        ..layout(maxWidth: pageWidth);
      final h = tp.height + settings.fontSize * 0.7;
      tp.dispose();
      return h;
    }

    for (final p in chapterParagraphs) {
      final h = paraHeight(p);
      if (currentHeight + h > pageHeight && current.isNotEmpty) {
        pages.add(current.join('\n\n'));
        current = [];
        currentHeight = 0;
      }
      current.add(p);
      currentHeight += h;
    }
    if (current.isNotEmpty) pages.add(current.join('\n\n'));
    if (pages.isEmpty) pages.add('　');
    _pagesCache = pages;
    _pagesSrc = chapterParagraphs;
    _pagesKey1 = settings.fontSize;
    _pagesKey2 = settings.lineHeight;
    _pagesKey3 = constraints.maxWidth;
    _pagesKey4 = constraints.maxHeight;
    return pages;
  }

  Widget _buildTopBar(Color bg, Color fg) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: bg.withValues(alpha: 0.94),
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
        child: Row(
          children: [
            IconButton(icon: Icon(Icons.arrow_back, color: fg), onPressed: () => Navigator.of(context).pop()),
            Expanded(
              child: Text(
                '${widget.book['name'] ?? ''}${(widget.book['author'] ?? '').toString().isNotEmpty ? ' · ${widget.book['author']}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, fontSize: 15),
              ),
            ),
            IconButton(icon: Icon(Icons.list, color: fg), tooltip: '目录', onPressed: _showTocSheet),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(Color bg, Color fg, ReaderSettings settings) {
    final shownChapter = _scrollMode ? _visibleChapter() : _currentChapter;
    final chapterTitle = _chapters.isEmpty ? '' : _chapters[shownChapter.clamp(0, _chapters.length - 1)].title;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        color: bg.withValues(alpha: 0.96),
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Text('${shownChapter + 1}/${_chapters.length}', style: TextStyle(color: fg, fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: _progress,
                      onChanged: (v) {
                        if (_scrollMode && _scrollController.hasClients) {
                          _scrollController.jumpTo(v * _scrollController.position.maxScrollExtent);
                        }
                        setState(() => _progress = v);
                      },
                    ),
                  ),
                  Text('${(_progress * 100).round()}%', style: TextStyle(color: fg, fontSize: 12)),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  icon: Icon(Icons.text_decrease, color: fg, size: 18),
                  label: Text('字号', style: TextStyle(color: fg, fontSize: 13)),
                  onPressed: () => _showSettings(settings),
                ),
                TextButton.icon(
                  icon: Icon(_scrollMode ? Icons.menu_book : Icons.auto_stories, color: fg, size: 18),
                  label: Text(_scrollMode ? '滚动' : '翻页', style: TextStyle(color: fg, fontSize: 13)),
                  onPressed: () async {
                    _progressChapter = shownChapter;
                    _currentChapter = shownChapter;
                    await settings.set(scrollMode: !_scrollMode);
                  },
                ),
                TextButton.icon(
                  icon: Icon(Icons.palette_outlined, color: fg, size: 18),
                  label: Text(settings.theme.name, style: TextStyle(color: fg, fontSize: 13)),
                  onPressed: () => _showSettings(settings),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  void _showTocSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        builder: (ctx, controller) => Material(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('目录（${_chapters.length} 章）', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: _chapters.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    selected: i == (_scrollMode ? _visibleChapter() : _currentChapter),
                    title: Text(_chapters[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      Navigator.pop(ctx);
                      _jumpToChapter(i);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSettings(ReaderSettings settings) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('字号（${settings.fontSize.round()}）', style: const TextStyle(fontWeight: FontWeight.bold)),
              Slider(
                value: settings.fontSize.clamp(14.0, 32.0),
                min: 14,
                max: 32,
                divisions: 18,
                onChanged: (v) {
                  settings.set(fontSize: v);
                  setSheet(() {});
                },
              ),
              Text('行距（${settings.lineHeight.toStringAsFixed(1)}）', style: const TextStyle(fontWeight: FontWeight.bold)),
              Slider(
                value: settings.lineHeight,
                min: 1.2,
                max: 2.4,
                divisions: 12,
                onChanged: (v) {
                  settings.set(lineHeight: v);
                  setSheet(() {});
                },
              ),
              const Text('主题', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                children: [
                  for (var i = 0; i < ReaderSettings.themes.length; i++)
                    GestureDetector(
                      onTap: () {
                        settings.set(themeIndex: i);
                        setSheet(() {});
                      },
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: Color(ReaderSettings.themes[i].bg),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: settings.themeIndex == i ? const Color(0xFF2E7D5B) : Colors.grey.shade400,
                            width: settings.themeIndex == i ? 2.5 : 1,
                          ),
                        ),
                        child: Center(
                          child: Text('文', style: TextStyle(color: Color(ReaderSettings.themes[i].fg), fontSize: 18)),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

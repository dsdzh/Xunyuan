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

class _ReaderPageState extends State<ReaderPage> with SingleTickerProviderStateMixin {
  late final BookSourceEngine _engine = BookSourceEngine(widget.source);
  late final ShelfState _shelf;

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
  int _pagesTotal = 1;

  bool _menuVisible = true;
  late bool _scrollMode = context.read<ReaderSettings>().scrollMode;

  // 翻页动画状态
  late final AnimationController _turnCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  ({String text, int pageNo, int total, bool showTitle})? _turnFrom;
  int _turnDir = 1;
  bool _dragTurnActive = false;
  double _dragAccum = 0;

  double _progress = 0;
  int _progressChapter = 0;

  // 断点恢复：章内进度比例（仅对打开时的起始章节生效一次）
  double? _restoreRatio;
  int _restoreChapter = 0;
  double _lastChapterRatio = 0;
  ReaderSettings? _lastSettings;

  @override
  void initState() {
    super.initState();
    _shelf = context.read<ShelfState>();
    _turnCtrl.addListener(() {
      if (_turnFrom == null) {
        if (_turnCtrl.status == AnimationStatus.completed ||
            _turnCtrl.status == AnimationStatus.dismissed) {
          _dragTurnActive = false;
        }
        return;
      }
      if (_turnCtrl.status == AnimationStatus.completed) {
        setState(() {
          _turnFrom = null;
          _dragTurnActive = false;
        });
      } else if (_turnCtrl.status == AnimationStatus.dismissed && _dragTurnActive) {
        // 拖到一半松手回弹：退回原页
        setState(() {
          _readPage = _turnFrom!.pageNo - 1;
          _turnFrom = null;
          _dragTurnActive = false;
        });
      }
    });
    _progressChapter = (widget.startIndex ?? _intOf(widget.book['durChapterIndex'])).clamp(0, 1 << 30);
    _currentChapter = _progressChapter;
    _restoreChapter = _progressChapter;
    final rp = widget.book['durChapterProgress'];
    if (rp is num && rp > 0) {
      _restoreRatio = rp.toDouble().clamp(0.0, 1.0);
      _lastChapterRatio = _restoreRatio!;
    }
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
    if (_chapters.isNotEmpty) {
      final ch = _progressChapter.clamp(0, _chapters.length - 1);
      final title = _chapters[ch].title;
      if (title.isNotEmpty) {
        unawaited(_shelf.recordRead(widget.book, ch, title, _scrollMode ? _lastChapterRatio : _progress));
      }
    }
    _turnCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 章内进度比例（0~1）
  double _chapterProgressRatio(int chapter) {
    if (!_scrollMode) return _progress;
    if (!_scrollController.hasClients || _paragraphs.isEmpty) return 0;
    final start = _chapterStart[chapter] ?? 0;
    var end = start;
    while (end < _paragraphChapter.length && _paragraphChapter[end] == chapter) {
      end++;
    }
    final count = end - start;
    if (count <= 1) return 0;
    final paraIdx = (_scrollController.position.pixels / _avgParagraphHeight()).floor().clamp(start, end - 1);
    return ((paraIdx - start) / (count - 1)).clamp(0.0, 1.0);
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
    if (_restoreRatio != null && chapterIdx == _restoreChapter) {
      final ratio = _restoreRatio!;
      _restoreRatio = null;
      final start = _chapterStart[chapterIdx] ?? 0;
      var end = start;
      while (end < _paragraphChapter.length && _paragraphChapter[end] == chapterIdx) {
        end++;
      }
      final paraIdx = start + ratio * math.max(end - start - 1, 0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo((paraIdx * _avgParagraphHeight()).clamp(0.0, _scrollController.position.maxScrollExtent));
        }
      });
    }
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
    final settings = _lastSettings ?? context.read<ReaderSettings>();
    return settings.fontSize * settings.lineHeight * 3;
  }

  void _onScroll(ScrollNotification n) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    _progress = pos.maxScrollExtent <= 0 ? 0 : (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
    if (n is ScrollUpdateNotification) {
      final ch = _visibleChapter();
      _progressChapter = ch;
      _lastChapterRatio = _chapterProgressRatio(ch);
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
    _stopTurnAnim();
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
      _turnFrom = null;
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
    _lastSettings = settings;
    if ((settings.pageAnimIndex == 3) != _scrollMode) {
      _scrollMode = settings.pageAnimIndex == 3;
      WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
    }
    final theme = settings.theme;
    final bg = Color(theme.bg);
    final fg = Color(theme.fg);

    final content = _loadingToc
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
                        child: _scrollMode ? _buildScrollReader(fg, settings) : _buildPagedReader(bg, fg, settings),
                      ),
                    ),
                    if (_menuVisible) _buildTopBar(bg, fg),
                    if (_menuVisible) _buildBottomBar(bg, fg, settings),
                  ],
                ),
              );

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          Positioned.fill(child: content),
          if (settings.brightness < 1.0)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(color: Colors.black.withValues(alpha: (1 - settings.brightness) * 0.85)),
              ),
            ),
          if (settings.eyeProtect)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(color: const Color(0x14FF9A3C)),
              ),
            ),
        ],
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

  Widget _buildPagedReader(Color bg, Color fg, ReaderSettings settings) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 48),
      child: _chapterParagraphs.isEmpty
          ? Center(child: Text('加载中…', style: TextStyle(color: fg)))
          : LayoutBuilder(
              key: ValueKey('${settings.fontSize}|${settings.lineHeight}'),
              builder: (context, constraints) {
                final pages = _paginate(chapterParagraphs: _chapterParagraphs, constraints: constraints, settings: settings);
                if (_restoreRatio != null && _currentChapter == _restoreChapter) {
                  _readPage = (_restoreRatio! * (pages.length - 1)).round().clamp(0, pages.length - 1);
                  _restoreRatio = null;
                  // LayoutBuilder 在 layout 阶段执行，底部进度条 build 时读到的是旧 _progress，补一次重建
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {});
                  });
                }
                if (_readPage >= pages.length) _readPage = pages.length - 1;
                _pagesTotal = pages.length;
                _progress = pages.length <= 1
                    ? 0.0
                    : (_readPage / (pages.length - 1)).clamp(0.0, 1.0);
                _progressChapter = _currentChapter;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (d) {
                    _dragAccum = 0;
                    if (_turnCtrl.isAnimating) {
                      _dragTurnActive = false;
                      _turnCtrl.stop();
                      setState(() => _turnFrom = null);
                    }
                  },
                  onHorizontalDragUpdate: (d) {
                    if (_menuVisible || settings.pageAnimIndex == 4) return;
                    _dragAccum += d.primaryDelta ?? 0;
                    if (!_dragTurnActive) {
                      if (_dragAccum.abs() < 12) return;
                      final dir = _dragAccum < 0 ? 1 : -1;
                      final target = _readPage + dir;
                      if (target < 0 || target >= pages.length) return;
                      setState(() {
                        _turnFrom = (
                          text: pages[_readPage],
                          pageNo: _readPage + 1,
                          total: pages.length,
                          showTitle: _readPage == 0
                        );
                        _turnDir = dir;
                        _readPage = target;
                        _dragTurnActive = true;
                      });
                    }
                    final frac = (_dragAccum.abs() / constraints.maxWidth).clamp(0.0, 0.999);
                    _turnCtrl.value = math.max(frac, 0.01);
                  },
                  onHorizontalDragEnd: (d) {
                    if (_menuVisible) return;
                    final v = d.primaryVelocity ?? 0;
                    if (_dragTurnActive) {
                      final val = _turnCtrl.value;
                      // 甩速与翻页同向为正，投影最终位置决定继续翻还是回弹
                      final fling = -v * _turnDir;
                      final projected = val + fling / 4000;
                      if (projected > 0.5) {
                        final remain = (1 - val).clamp(0.05, 1.0);
                        _turnCtrl.animateTo(1,
                            duration: Duration(milliseconds: (260 * remain).round().clamp(90, 260)),
                            curve: Curves.easeOutCubic);
                      } else {
                        _turnCtrl.animateTo(0,
                            duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
                      }
                      return;
                    }
                    // 章边界/无动画模式下拖拽未激活：按甩速或位移判定翻页，
                    // 慢速拖到底再松手（甩速≈0）也要能翻章
                    final crossed = _dragAccum.abs() > constraints.maxWidth * 0.35;
                    if (v < -200 || (crossed && _dragAccum < 0)) _pagedTurn(pages, 1);
                    if (v > 200 || (crossed && _dragAccum > 0)) _pagedTurn(pages, -1);
                  },
                  onHorizontalDragCancel: () {
                    // 手势被系统打断（返回手势/下拉栏）时回弹，避免页面卡在半翻状态
                    if (_dragTurnActive && _turnCtrl.value > 0) {
                      _turnCtrl.animateTo(0,
                          duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
                    }
                  },
                  onTapUp: (d) {
                    // 菜单/功能栏打开时点击只关闭菜单，不翻页
                    if (_menuVisible) {
                      setState(() => _menuVisible = false);
                      return;
                    }
                    final w = constraints.maxWidth;
                    if (d.localPosition.dx < w / 3) {
                      _pagedTurn(pages, -1);
                    } else if (d.localPosition.dx > w * 2 / 3) {
                      _pagedTurn(pages, 1);
                    } else {
                      setState(() => _menuVisible = !_menuVisible);
                    }
                  },
                  child: ClipRect(
                    child: _turnFrom == null
                        ? _pageView(pages[_readPage], _readPage + 1, pages.length, _readPage == 0, fg, settings)
                        : AnimatedBuilder(
                            animation: _turnCtrl,
                            builder: (context, _) {
                              final t = _turnCtrl.value;
                              final w = constraints.maxWidth;
                              final dir = _turnDir;
                              final from = _turnFrom!;
                              final newPage = _pageView(
                                  pages[_readPage], _readPage + 1, pages.length, _readPage == 0, fg, settings);
                              final oldPage =
                                  _pageView(from.text, from.pageNo, from.total, from.showTitle, fg, settings);
                              // 动画期间给每页垫不透明底色，防止新旧页文字互相透出叠影
                              Widget mask(Widget c) => ColoredBox(color: bg, child: c);
                              Widget slideIn(Widget child, double dx) =>
                                  Transform.translate(offset: Offset(dx, 0), child: child);
                              Widget slideOut(Widget child, double dx) =>
                                  Transform.translate(offset: Offset(dx, 0), child: child);
                              switch (settings.pageAnimIndex) {
                                case 1:
                                  // 覆盖：旧页轻微视差退让并压暗，新页盖上来
                                  return Stack(children: [
                                    slideOut(oldPage, -t * w * 0.3 * dir),
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: ColoredBox(
                                            color: Colors.black.withValues(alpha: 0.18 * (1 - t))),
                                      ),
                                    ),
                                    slideIn(mask(newPage), (1 - t) * w * dir),
                                  ]);
                                case 2:
                                  // 平移：新旧页一起移动
                                  return Stack(children: [
                                    slideOut(mask(oldPage), -t * w * dir),
                                    slideIn(mask(newPage), (1 - t) * w * dir),
                                  ]);
                                default:
                                  // 仿真：平移 + 透视旋转 + 边缘阴影近似卷页
                                  return Stack(children: [
                                    slideOut(mask(oldPage), -t * w * dir),
                                    Transform(
                                      alignment: dir == 1 ? Alignment.centerLeft : Alignment.centerRight,
                                      transform: Matrix4.identity()
                                        ..setEntry(3, 2, 0.0012)
                                        ..translateByDouble((1 - t) * w * dir, 0, 0, 1)
                                        ..rotateY((1 - t) * 0.35 * (dir == 1 ? -1 : 1)),
                                      child: mask(newPage),
                                    ),
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: dir == 1 ? Alignment.centerRight : Alignment.centerLeft,
                                              end: dir == 1 ? Alignment.centerLeft : Alignment.centerRight,
                                              colors: [
                                                Colors.transparent,
                                                Colors.black.withValues(alpha: 0.28 * (1 - t)),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ]);
                              }
                            },
                          ),
                  ),
                );
              },
            ),
    );
  }

  Widget _pageView(String text, int pageNo, int total, bool showTitle, Color fg, ReaderSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle) ...[
          Text(_chapters[_currentChapter].title,
              style: TextStyle(color: fg, fontSize: settings.fontSize + 4, fontWeight: FontWeight.bold)),
          SizedBox(height: settings.fontSize),
        ],
        Expanded(
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Text(text, style: TextStyle(fontSize: settings.fontSize, height: settings.lineHeight, color: fg)),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Text('$pageNo/$total',
              style: TextStyle(color: fg.withValues(alpha: 0.5), fontSize: 12)),
        ),
      ],
    );
  }

  void _pagedTurn(List<String> pages, int dir) {
    final target = _readPage + dir;
    if (target < 0) {
      if (_currentChapter > 0) {
        _stopTurnAnim();
        unawaited(_loadChapterForPaged(_currentChapter - 1).then((_) {
          // 上一章：跳到最后一页近似处理
          if (mounted) setState(() {});
        }));
      }
      return;
    }
    if (target >= pages.length) {
      if (_currentChapter + 1 < _chapters.length) {
        _stopTurnAnim();
        unawaited(_loadChapterForPaged(_currentChapter + 1));
      }
      return;
    }
    // 动画未播完又翻页：立即结束上一次动画，直接落到新页，避免两页文字叠影
    final noAnim = (_lastSettings?.pageAnimIndex ?? 0) == 4 || _turnCtrl.isAnimating;
    if (noAnim) {
      _stopTurnAnim();
      setState(() => _readPage = target);
      return;
    }
    setState(() {
      _turnFrom = (text: pages[_readPage], pageNo: _readPage + 1, total: pages.length, showTitle: _readPage == 0);
      _turnDir = dir;
      _readPage = target;
    });
    _turnCtrl.animateTo(1, duration: const Duration(milliseconds: 320), curve: Curves.easeInOutCubic);
  }

  void _stopTurnAnim() {
    _dragTurnActive = false;
    if (_turnCtrl.isAnimating) _turnCtrl.stop();
    _turnFrom = null;
    _turnCtrl.value = 0;
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
    final pageHeight = constraints.maxHeight - settings.fontSize * 1.2 - 4;
    final style = TextStyle(fontSize: settings.fontSize, height: settings.lineHeight);
    final pages = <String>[];
    var current = <String>[];
    // 章标题只占首页顶部空间
    var currentHeight = settings.fontSize * 2.5;
    // 页面文本用 \n\n 连接，段间实际占一整空行，测量必须与渲染一致，否则底部文字被裁
    final sepH = settings.fontSize * settings.lineHeight;

    double paraHeight(String p) {
      final tp = TextPainter(text: TextSpan(text: p, style: style), maxLines: null, textDirection: TextDirection.ltr)
        ..layout(maxWidth: pageWidth);
      final h = tp.height;
      tp.dispose();
      return h;
    }

    for (final p in chapterParagraphs) {
      final ph = paraHeight(p);
      final withSep = ph + (current.isEmpty ? 0 : sepH);
      if (currentHeight + withSep > pageHeight && current.isNotEmpty) {
        pages.add(current.join('\n\n'));
        current = [p];
        currentHeight = ph;
      } else {
        current.add(p);
        currentHeight += withSep;
      }
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
            IconButton(
              icon: Icon(_inShelf ? Icons.bookmark_added : Icons.bookmark_add_outlined, color: fg),
              tooltip: _inShelf ? '移出书架' : '加入书架',
              onPressed: _toggleShelf,
            ),
            IconButton(icon: Icon(Icons.list, color: fg), tooltip: '目录', onPressed: _showTocSheet),
          ],
        ),
      ),
    );
  }

  bool get _inShelf {
    final key = widget.book['key']?.toString() ??
        StorageService.bookKey('${widget.book['name'] ?? ''}', '${widget.book['author'] ?? ''}',
            '${widget.book['sourceUrl'] ?? ''}');
    return _shelf.byKey(key) != null;
  }

  Future<void> _toggleShelf() async {
    if (_inShelf) {
      final key = widget.book['key']?.toString() ??
          StorageService.bookKey('${widget.book['name'] ?? ''}', '${widget.book['author'] ?? ''}',
              '${widget.book['sourceUrl'] ?? ''}');
      await _shelf.remove(key);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已移出书架，进度保留在浏览记录')));
      return;
    }
    final added = await _shelf.addFromReader(Map<String, dynamic>.of(widget.book));
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(added ? '已加入书架' : '加入书架失败：书信息不完整')));
  }

  Widget _buildBottomBar(Color bg, Color fg, ReaderSettings settings) {
    final shownChapter = _scrollMode ? _visibleChapter() : _currentChapter;
    final chapterTitle = _chapters.isEmpty ? '' : _chapters[shownChapter.clamp(0, _chapters.length - 1)].title;
    final isNight = settings.theme.name == '夜间';
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
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: shownChapter > 0 ? () => _jumpToChapter(shownChapter - 1) : null,
                    child: Text('上一章', style: TextStyle(color: fg, fontSize: 13)),
                  ),
                  Expanded(
                    child: Slider(
                      value: _progress,
                      onChanged: (v) {
                        if (_scrollMode) {
                          if (_scrollController.hasClients) {
                            _scrollController.jumpTo(v * _scrollController.position.maxScrollExtent);
                          }
                          setState(() => _progress = v);
                        } else {
                          _stopTurnAnim();
                          setState(() {
                            _readPage = (_pagesTotal <= 1)
                                ? 0
                                : (v * (_pagesTotal - 1)).round().clamp(0, _pagesTotal - 1);
                            _progress = v;
                          });
                        }
                      },
                    ),
                  ),
                  TextButton(
                    onPressed: shownChapter + 1 < _chapters.length
                        ? () => _jumpToChapter(shownChapter + 1)
                        : null,
                    child: Text('下一章', style: TextStyle(color: fg, fontSize: 13)),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  icon: Icon(Icons.toc, color: fg, size: 18),
                  label: Text('目录', style: TextStyle(color: fg, fontSize: 13)),
                  onPressed: _showTocSheet,
                ),
                TextButton.icon(
                  icon: Icon(isNight ? Icons.light_mode : Icons.dark_mode, color: fg, size: 18),
                  label: Text('夜间', style: TextStyle(color: fg, fontSize: 13)),
                  onPressed: () {
                    final nightIdx = ReaderSettings.themes.indexWhere((t) => t.name == '夜间');
                    settings.set(themeIndex: isNight ? 0 : nightIdx);
                  },
                ),
                TextButton.icon(
                  icon: Icon(Icons.settings_outlined, color: fg, size: 18),
                  label: Text('设置', style: TextStyle(color: fg, fontSize: 13)),
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text('目录（${_chapters.length} 章）',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('返回'),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
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
        builder: (ctx, setSheet) {
          void apply(void Function() fn) {
            setSheet(() {
              fn();
            });
          }

          Widget label(String text) => SizedBox(
                width: 44,
                child: Text(text, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
              );

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      label('亮度'),
                      Expanded(
                        child: Slider(
                          value: settings.brightness,
                          min: 0.3,
                          max: 1.0,
                          onChanged: (v) => apply(() => settings.set(brightness: v)),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.visibility_outlined,
                            color: settings.eyeProtect ? const Color(0xFF2E7D5B) : Colors.grey.shade600),
                        tooltip: '护眼模式',
                        onPressed: () => apply(() => settings.set(eyeProtect: !settings.eyeProtect)),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                  Row(
                    children: [
                      label('字号'),
                      IconButton(
                        icon: const Icon(Icons.text_decrease),
                        onPressed: settings.fontSize > 14
                            ? () => apply(() => settings.set(fontSize: settings.fontSize - 1))
                            : null,
                      ),
                      SizedBox(
                        width: 40,
                        child: Text('${settings.fontSize.round()}', textAlign: TextAlign.center),
                      ),
                      IconButton(
                        icon: const Icon(Icons.text_increase),
                        onPressed: settings.fontSize < 32
                            ? () => apply(() => settings.set(fontSize: settings.fontSize + 1))
                            : null,
                      ),
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      label('颜色'),
                      const SizedBox(width: 4),
                      for (var i = 0; i < ReaderSettings.themes.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: GestureDetector(
                            onTap: () => apply(() => settings.set(themeIndex: i)),
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(ReaderSettings.themes[i].bg),
                                border: Border.all(
                                  color: settings.themeIndex == i
                                      ? const Color(0xFF2E7D5B)
                                      : Colors.grey.shade400,
                                  width: settings.themeIndex == i ? 2.5 : 1,
                                ),
                              ),
                              child: Center(
                                child: Text('文',
                                    style: TextStyle(
                                        color: Color(ReaderSettings.themes[i].fg), fontSize: 15)),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      label('翻页'),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            for (var i = 0; i < ReaderSettings.pageAnims.length; i++)
                              ChoiceChip(
                                visualDensity: VisualDensity.compact,
                                label: Text(ReaderSettings.pageAnims[i]),
                                selected: settings.pageAnimIndex == i,
                                onSelected: (_) {
                                  _progressChapter = _scrollMode ? _visibleChapter() : _currentChapter;
                                  _currentChapter = _progressChapter;
                                  apply(() => settings.set(pageAnimIndex: i));
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      label('行距'),
                      Expanded(
                        child: Slider(
                          value: settings.lineHeight,
                          min: 1.2,
                          max: 2.4,
                          divisions: 12,
                          label: settings.lineHeight.toStringAsFixed(1),
                          onChanged: (v) => apply(() => settings.set(lineHeight: v)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

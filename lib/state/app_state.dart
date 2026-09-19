import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/book_source_engine.dart';
import '../core/http_client.dart';
import '../core/source_health.dart';
import '../models/book_source.dart';
import '../services/storage_service.dart';

class SourceState extends ChangeNotifier {
  final List<BookSource> sources = [];
  final Map<String, SourceHealth> health = {};
  int _healthJobs = 0;
  bool get healthChecking => _healthJobs > 0;

  List<BookSource> get enabledNovelSources =>
      sources.where((s) => s.enabled && s.isNovel).toList();

  Future<void> load() async {
    sources
      ..clear()
      ..addAll(StorageService.instance.sources);
    health.clear();
    for (final s in sources) {
      final h = SourceHealth.fromJson(StorageService.instance.getSourceHealth(s.bookSourceUrl));
      if (h != null) health[s.bookSourceUrl] = h;
    }
    notifyListeners();
  }

  /// 导入书源文本（JSON 数组 / JSONL）。返回导入数量。
  Future<int> importText(String text) async {
    final list = parseBookSources(text);
    if (list.isEmpty) return 0;
    await StorageService.instance.importSources(list);
    await load();
    return list.length;
  }

  Future<int> importFromUrl(String url) async {
    final resp = await HttpClient.instance.get(url.trim());
    return importText(resp.body);
  }

  Future<void> toggle(String url, bool enabled) async {
    await StorageService.instance.setSourceEnabled(url, enabled);
    await load();
  }

  Future<void> remove(String url) async {
    await StorageService.instance.removeSource(url);
    await StorageService.instance.removeSourceHealth(url);
    await load();
  }

  String exportAll() => StorageService.instance.exportAllSources();

  /// 健康度检测：并发 3 路逐个探测，结果实时刷新并持久化。
  Future<void> checkHealth(List<BookSource> targets) async {
    // 检测中仅允许单源重测（如详情弹窗里点"重新检测此书源"）
    if (_healthJobs > 0 && targets.length != 1) return;
    _healthJobs++;
    notifyListeners();
    try {
      final checker = SourceHealthChecker();
      final queue = List<BookSource>.from(targets);
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          final s = queue.removeAt(0);
          final h = await checker.check(s);
          health[s.bookSourceUrl] = h;
          await StorageService.instance.putSourceHealth(s.bookSourceUrl, h.toJson());
          notifyListeners();
        }
      }

      await Future.wait([worker(), worker(), worker()]);
    } finally {
      _healthJobs--;
      notifyListeners();
    }
  }
}

class ShelfState extends ChangeNotifier {
  List<Map<String, dynamic>> books = [];

  Future<void> load() async {
    books = StorageService.instance.shelf;
    notifyListeners();
  }

  Map<String, dynamic>? byKey(String key) => StorageService.instance.getBook(key);

  Future<void> addFromSearch(SearchBook b, {String? tocUrl}) async {
    final key = StorageService.bookKey(b.name, b.author, b.sourceUrl);
    final existing = StorageService.instance.getBook(key);
    if (existing != null) return;
    final entry = <String, dynamic>{
      'key': key,
      'name': b.name,
      'author': b.author,
      'coverUrl': b.coverUrl,
      'intro': b.intro,
      'kind': b.kind,
      'lastChapter': b.lastChapter,
      'bookUrl': b.bookUrl,
      'tocUrl': tocUrl ?? b.bookUrl,
      'sourceUrl': b.sourceUrl,
      'sourceName': b.sourceName,
      'durChapterIndex': 0,
      'durChapterTitle': '',
      'durChapterTime': DateTime.now().millisecondsSinceEpoch,
      'lastAddTime': DateTime.now().millisecondsSinceEpoch,
    };
    await StorageService.instance.putBook(entry);
    await load();
  }

  Future<void> addFromDetail(BookDetail d) async {
    final key = StorageService.bookKey(d.name, d.author, d.sourceUrl);
    final existing = StorageService.instance.getBook(key);
    final entry = <String, dynamic>{
      'key': key,
      'name': d.name,
      'author': d.author,
      'coverUrl': d.coverUrl,
      'intro': d.intro,
      'kind': d.kind,
      'lastChapter': d.lastChapter,
      'bookUrl': d.bookUrl,
      'tocUrl': d.tocUrl,
      'sourceUrl': d.sourceUrl,
      'sourceName': d.sourceName,
      'durChapterIndex': existing?['durChapterIndex'] ?? 0,
      'durChapterTitle': existing?['durChapterTitle'] ?? '',
      'durChapterTime': DateTime.now().millisecondsSinceEpoch,
      'lastAddTime': existing?['lastAddTime'] ?? DateTime.now().millisecondsSinceEpoch,
    };
    await StorageService.instance.putBook(entry);
    await load();
  }

  Future<void> updateProgress(String key, int chapterIndex, String chapterTitle, double progress) async {
    final book = StorageService.instance.getBook(key);
    if (book == null) return;
    book['durChapterIndex'] = chapterIndex;
    book['durChapterTitle'] = chapterTitle;
    book['readProgress'] = progress;
    book['durChapterTime'] = DateTime.now().millisecondsSinceEpoch;
    await StorageService.instance.putBook(book);
    await load();
  }

  Future<void> remove(String key) async {
    await StorageService.instance.removeBook(key);
    await load();
  }

  bool isInShelf(String name, String author, String sourceUrl) =>
      StorageService.instance.getBook(StorageService.bookKey(name, author, sourceUrl)) != null;
}

class ReaderSettings extends ChangeNotifier {
  static const themes = [
    ReaderTheme(name: '默认', bg: 0xFFFDF6E3, fg: 0xFF3A3226),
    ReaderTheme(name: '纯白', bg: 0xFFFFFFFF, fg: 0xFF222222),
    ReaderTheme(name: '护眼', bg: 0xFFC7EDCC, fg: 0xFF2C3324),
    ReaderTheme(name: '夜间', bg: 0xFF17181A, fg: 0xFF8A8F99),
    ReaderTheme(name: '羊皮纸', bg: 0xFFEEDCB3, fg: 0xFF4B3A1E),
  ];

  double fontSize = 20;
  double lineHeight = 1.6;
  int themeIndex = 0;
  bool scrollMode = true; // true 滚动 false 翻页

  Future<void> load() async {
    final s = StorageService.instance;
    fontSize = (s.setting('fontSize', def: 20) as num).toDouble();
    lineHeight = (s.setting('lineHeight', def: 1.6) as num).toDouble();
    themeIndex = s.setting('themeIndex', def: 0) as int;
    scrollMode = s.setting('scrollMode', def: true) as bool;
    notifyListeners();
  }

  Future<void> set({double? fontSize, double? lineHeight, int? themeIndex, bool? scrollMode}) async {
    if (fontSize != null) this.fontSize = fontSize;
    if (lineHeight != null) this.lineHeight = lineHeight;
    if (themeIndex != null) this.themeIndex = themeIndex;
    if (scrollMode != null) this.scrollMode = scrollMode;
    final s = StorageService.instance;
    if (fontSize != null) await s.putSetting('fontSize', fontSize);
    if (lineHeight != null) await s.putSetting('lineHeight', lineHeight);
    if (themeIndex != null) await s.putSetting('themeIndex', themeIndex);
    if (scrollMode != null) await s.putSetting('scrollMode', scrollMode);
    notifyListeners();
  }

  ReaderTheme get theme => themes[themeIndex % themes.length];
}

class ReaderTheme {
  final String name;
  final int bg;
  final int fg;
  const ReaderTheme({required this.name, required this.bg, required this.fg});
}

/// 全局依赖容器
class AppServices {
  final SourceState sourceState = SourceState();
  final ShelfState shelfState = ShelfState();
  final ReaderSettings readerSettings = ReaderSettings();

  Future<void> init() async {
    await StorageService.instance.init();
    await sourceState.load();
    await shelfState.load();
    await readerSettings.load();
  }

  BookSourceEngine engineFor(BookSource source) => BookSourceEngine(source);

  BookSource? findSource(String url) {
    for (final s in sourceState.sources) {
      if (s.bookSourceUrl == url) return s;
    }
    return null;
  }
}

String encodeJson(Object? o) => jsonEncode(o);

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
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('仅支持 http/https 书源链接');
    }
    final resp = await HttpClient.instance.get(trimmed);
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
  List<Map<String, dynamic>> history = [];

  Future<void> load() async {
    books = StorageService.instance.shelf;
    history = StorageService.instance.readHistory;
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

  Future<void> updateProgress(String key, int chapterIndex, String chapterTitle, double progress, double chapterProgress) async {
    final book = StorageService.instance.getBook(key);
    if (book == null) return;
    book['durChapterIndex'] = chapterIndex;
    book['durChapterTitle'] = chapterTitle;
    book['readProgress'] = progress;
    book['durChapterProgress'] = chapterProgress;
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

  /// 阅读页内手动"加入书架"：仅在用户点击时调用，阅读本身不再自动加架。
  /// 返回 true 表示本次新增成功，false 表示已在书架。
  Future<bool> addFromReader(Map<String, dynamic> book) async {
    final key = book['key']?.toString() ??
        StorageService.bookKey('${book['name'] ?? ''}', '${book['author'] ?? ''}', '${book['sourceUrl'] ?? ''}');
    if (StorageService.instance.getBook(key) != null) return false;
    final entry = Map<String, dynamic>.of(book)..['key'] = key;
    entry['durChapterIndex'] ??= 0;
    entry['durChapterTitle'] ??= '';
    entry['lastAddTime'] = DateTime.now().millisecondsSinceEpoch;
    await StorageService.instance.putBook(entry);
    await load();
    return true;
  }

  /// 退出阅读时记录浏览历史；书在书架则同步书架进度。
  /// [chapterProgress] 为章内进度比例（0~1），用于下次直接回到上次阅读位置。
  Future<void> recordRead(Map<String, dynamic> book, int chapterIndex, String chapterTitle, double chapterProgress) async {
    var entry = Map<String, dynamic>.of(book);
    final key = entry['key']?.toString() ??
        StorageService.bookKey('${entry['name'] ?? ''}', '${entry['author'] ?? ''}', '${entry['sourceUrl'] ?? ''}');
    entry['key'] = key;
    if (StorageService.instance.getBook(key) != null) {
      await updateProgress(key, chapterIndex, chapterTitle, chapterProgress, chapterProgress);
      entry = StorageService.instance.getBook(key)!;
    }
    entry['durChapterIndex'] = chapterIndex;
    entry['durChapterProgress'] = chapterProgress;
    entry['lastReadTime'] = DateTime.now().millisecondsSinceEpoch;
    await StorageService.instance.putReadHistory(entry);
    history = StorageService.instance.readHistory;
    notifyListeners();
  }

  Future<void> removeHistory(String key) async {
    await StorageService.instance.removeReadHistory(key);
    history = StorageService.instance.readHistory;
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await StorageService.instance.clearReadHistory();
    history = [];
    notifyListeners();
  }
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
  int pageAnimIndex = 0; // 0 仿真 1 覆盖 2 平移 3 上下(滚动) 4 无动画
  double brightness = 1.0; // 阅读页亮度遮罩 0.3~1.0
  bool eyeProtect = false;

  static const pageAnims = ['仿真', '覆盖', '平移', '上下', '无动画'];

  bool get scrollMode => pageAnimIndex == 3;

  Future<void> load() async {
    final s = StorageService.instance;
    fontSize = (s.setting('fontSize', def: 20) as num).toDouble();
    lineHeight = (s.setting('lineHeight', def: 1.6) as num).toDouble();
    themeIndex = s.setting('themeIndex', def: 0) as int;
    var anim = s.setting('pageAnimIndex', def: 3) as int;
    final legacyScroll = s.setting('scrollMode');
    if (legacyScroll != null) {
      // 旧版只有 仿真/覆盖/平移 三档 + scrollMode 开关，一次性迁移
      anim = (legacyScroll as bool) ? 3 : (s.setting('pageAnimIndex', def: 0) as int).clamp(0, 2);
      await s.putSetting('pageAnimIndex', anim);
    }
    pageAnimIndex = anim;
    brightness = (s.setting('brightness', def: 1.0) as num).toDouble();
    eyeProtect = s.setting('eyeProtect', def: false) as bool;
    notifyListeners();
  }

  Future<void> set({
    double? fontSize,
    double? lineHeight,
    int? themeIndex,
    int? pageAnimIndex,
    double? brightness,
    bool? eyeProtect,
  }) async {
    if (fontSize != null) this.fontSize = fontSize;
    if (lineHeight != null) this.lineHeight = lineHeight;
    if (themeIndex != null) this.themeIndex = themeIndex;
    if (pageAnimIndex != null) this.pageAnimIndex = pageAnimIndex;
    if (brightness != null) this.brightness = brightness;
    if (eyeProtect != null) this.eyeProtect = eyeProtect;
    final s = StorageService.instance;
    if (fontSize != null) await s.putSetting('fontSize', fontSize);
    if (lineHeight != null) await s.putSetting('lineHeight', lineHeight);
    if (themeIndex != null) await s.putSetting('themeIndex', themeIndex);
    if (pageAnimIndex != null) await s.putSetting('pageAnimIndex', pageAnimIndex);
    if (brightness != null) await s.putSetting('brightness', brightness);
    if (eyeProtect != null) await s.putSetting('eyeProtect', eyeProtect);
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

import 'dart:convert';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../core/book_source_engine.dart';
import '../models/book_source.dart';

/// 本地存储：书源、书架、阅读进度、章节缓存、设置。
class StorageService {
  static final StorageService instance = StorageService._();
  StorageService._();

  late Box<String> _sources; // key: bookSourceUrl, value: 书源 JSON
  late Box<String> _books; // key: 书唯一键, value: 书架条目 JSON
  late Box<String> _cache; // key: 章节键, value: 正文
  late Box<dynamic> _settings;

  /// 读-改-写操作（历史列表整存整取、书源 enabled 回写）必须串行，
  /// 否则两次 await 交叠会让后写覆盖先写，丢失更新
  Future<void> _rmwChain = Future<void>.value();
  Future<T> _serialized<T>(Future<T> Function() body) {
    final next = _rmwChain.then((_) => body());
    _rmwChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> init() async {
    await Hive.initFlutter();
    _sources = await Hive.openBox<String>('sources');
    _books = await Hive.openBox<String>('books');
    _cache = await Hive.openBox<String>('chapter_cache');
    _settings = await Hive.openBox<dynamic>('settings');
  }

  // ---------- 书源 ----------
  List<BookSource> get sources {
    final list = <BookSource>[];
    for (final key in _sources.keys) {
      try {
        final j = jsonDecode(_sources.get(key)!);
        if (j is Map) {
          final s = BookSource.fromJson(j.cast<String, dynamic>());
          list.add(s);
        }
      } catch (_) {}
    }
    list.sort((a, b) => a.customOrder.compareTo(b.customOrder));
    return list;
  }

  Future<void> saveSource(BookSource source) async {
    final j = Map<String, dynamic>.from(source.raw);
    j['enabled'] = source.enabled;
    await _sources.put(source.bookSourceUrl, jsonEncode(j));
  }

  Future<int> importSources(List<BookSource> incoming) => _serialized(() async {
        var count = 0;
        for (final s in incoming) {
          final j = Map<String, dynamic>.from(s.raw);
          // 更新导入不带 enabled 时沿用旧值，避免用户逐条关闭的源被整批重置
          if (!j.containsKey('enabled')) {
            final old = _sources.get(s.bookSourceUrl);
            if (old != null) {
              try {
                final oj = jsonDecode(old);
                if (oj is Map && oj.containsKey('enabled')) j['enabled'] = oj['enabled'];
              } catch (_) {}
            }
          }
          await _sources.put(s.bookSourceUrl, jsonEncode(j));
          count++;
        }
        return count;
      });

  Future<void> removeSource(String url) => _sources.delete(url);

  Future<void> clearSources() => _sources.clear();

  bool sourceExists(String url) => _sources.containsKey(url);

  Future<void> setSourceEnabled(String url, bool enabled) => _serialized(() async {
        final raw = _sources.get(url);
        if (raw == null) return;
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) return; // 缓存条目损坏时静默跳过，调用方不 catch
        decoded['enabled'] = enabled;
        await _sources.put(url, jsonEncode(decoded));
      });

  String exportAllSources() {
    final list = <dynamic>[];
    for (final v in _sources.values) {
      // 单条损坏不能拖垮整个导出
      try {
        list.add(jsonDecode(v));
      } catch (_) {}
    }
    return const JsonEncoder.withIndent('  ').convert(list);
  }

  // ---------- 书源健康度 ----------
  // 按完整源 URL 记：同站常有多个书源，规则不同健康度互不相干
  static String _healthKey(String sourceUrl) => 'health::$sourceUrl';

  Map<String, dynamic>? getSourceHealth(String sourceUrl) {
    final v = _settings.get(_healthKey(sourceUrl));
    if (v is! String) return null;
    try {
      return (jsonDecode(v) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<void> putSourceHealth(String sourceUrl, Map<String, dynamic> data) =>
      _settings.put(_healthKey(sourceUrl), jsonEncode(data));

  Future<void> removeSourceHealth(String sourceUrl) => _settings.delete(_healthKey(sourceUrl));

  // ---------- 书籍 / 书架 ----------
  static String bookKey(String name, String author, String sourceUrl) => '$name|$author|$sourceUrl';

  List<Map<String, dynamic>> get shelf {
    final list = <Map<String, dynamic>>[];
    for (final v in _books.values) {
      try {
        list.add((jsonDecode(v) as Map).cast<String, dynamic>());
      } catch (_) {}
    }
    list.sort((a, b) => (b['lastAddTime'] ?? 0).compareTo(a['lastAddTime'] ?? 0));
    return list;
  }

  Map<String, dynamic>? getBook(String key) {
    final v = _books.get(key);
    if (v == null) return null;
    try {
      return (jsonDecode(v) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<void> putBook(Map<String, dynamic> book) => _books.put(book['key'] as String, jsonEncode(book));

  Future<void> removeBook(String key) => _books.delete(key);

  // ---------- 浏览记录 ----------
  static const _historyKey = 'readHistory';

  List<Map<String, dynamic>> get readHistory {
    final v = _settings.get(_historyKey);
    if (v is! String) return [];
    try {
      final j = jsonDecode(v);
      if (j is List) return j.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (_) {}
    return [];
  }

  Future<void> putReadHistory(Map<String, dynamic> entry) => _serialized(() async {
        final list = readHistory..removeWhere((e) => e['key'] == entry['key']);
        list.insert(0, entry);
        if (list.length > 100) list.removeRange(100, list.length);
        await _settings.put(_historyKey, jsonEncode(list));
      });

  Future<void> removeReadHistory(String key) => _serialized(() async {
        final list = readHistory..removeWhere((e) => e['key'] == key);
        await _settings.put(_historyKey, jsonEncode(list));
      });

  Future<void> clearReadHistory() => _serialized(() async {
        await _settings.delete(_historyKey);
      });

  // ---------- 章节缓存 ----------
  String? getCachedChapter(String chapterKey) => _cache.get(chapterKey);

  Future<void> putCachedChapter(String chapterKey, String content) async {
    await _cache.put(chapterKey, content);
    // 简单容量控制：超过 2000 条删最旧一半（hive 无时间戳则按 key 迭代顺序）
    if (_cache.length > 2000) {
      final drop = _cache.keys.take(800).toList();
      await _cache.deleteAll(drop);
    }
  }

  Future<void> clearChapterCache() => _cache.clear();

  // ---------- 目录缓存 ----------
  static String _tocKey(String tocUrl) => 'toc::$tocUrl';

  List<Chapter>? getCachedToc(String tocUrl) {
    final raw = _cache.get(_tocKey(tocUrl));
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      if (j is List) return j.whereType<Map>().map(Chapter.fromJson).toList();
    } catch (_) {}
    return null;
  }

  Future<void> putCachedToc(String tocUrl, List<Chapter> chapters) =>
      _cache.put(_tocKey(tocUrl), jsonEncode(chapters.map((c) => c.toJson()).toList()));

  Future<void> removeCachedToc(String tocUrl) => _cache.delete(_tocKey(tocUrl));

  // ---------- 设置 ----------
  dynamic setting(String key, {dynamic def}) => _settings.get(key) ?? def;

  Future<void> putSetting(String key, dynamic value) => _settings.put(key, value);

  Future<void> removeSetting(String key) => _settings.delete(key);
}

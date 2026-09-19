import 'dart:convert';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/book_source.dart';

/// 本地存储：书源、书架、阅读进度、章节缓存、设置。
class StorageService {
  static final StorageService instance = StorageService._();
  StorageService._();

  late Box<String> _sources; // key: bookSourceUrl, value: 书源 JSON
  late Box<String> _books; // key: 书唯一键, value: 书架条目 JSON
  late Box<String> _cache; // key: 章节键, value: 正文
  late Box<dynamic> _settings;

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

  Future<int> importSources(List<BookSource> incoming) async {
    var count = 0;
    for (final s in incoming) {
      await _sources.put(s.bookSourceUrl, jsonEncode(s.raw));
      count++;
    }
    return count;
  }

  Future<void> removeSource(String url) => _sources.delete(url);

  Future<void> clearSources() => _sources.clear();

  Future<void> setSourceEnabled(String url, bool enabled) async {
    final raw = _sources.get(url);
    if (raw == null) return;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    j['enabled'] = enabled;
    await _sources.put(url, jsonEncode(j));
  }

  String exportAllSources() {
    final list = _sources.values.map((v) => jsonDecode(v)).toList();
    return const JsonEncoder.withIndent('  ').convert(list);
  }

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

  // ---------- 设置 ----------
  dynamic setting(String key, {dynamic def}) => _settings.get(key) ?? def;

  Future<void> putSetting(String key, dynamic value) => _settings.put(key, value);
}

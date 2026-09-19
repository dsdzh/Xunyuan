import 'dart:async';

import 'package:dio/dio.dart';

import '../models/book_source.dart';
import 'book_source_engine.dart';

/// 书源健康度检测：搜索 → 详情 → 目录 → 正文 四级探测。
class HealthLevel {
  static const unknown = -1;
  static const dead = 0; // 不可用
  static const searchOnly = 1; // 仅搜索可用
  static const ok = 2; // 书源可用
  static const tocNoContent = 3; // 目录缺正文

  static String label(int level) => switch (level) {
        dead => '不可用',
        searchOnly => '仅搜索',
        ok => '可用',
        tocNoContent => '目录缺正文',
        _ => '未检测',
      };
}

class SourceHealth {
  final int level;
  final int latencyMs;
  final String message; // 失败原因或命中的书名
  final int checkedAt; // millisecondsSinceEpoch

  SourceHealth(this.level, this.latencyMs, this.message, this.checkedAt);

  Map<String, dynamic> toJson() =>
      {'level': level, 'latency': latencyMs, 'message': message, 'at': checkedAt};

  static SourceHealth? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return SourceHealth(
      (j['level'] as num?)?.toInt() ?? HealthLevel.unknown,
      (j['latency'] as num?)?.toInt() ?? 0,
      (j['message'] ?? '').toString(),
      (j['at'] as num?)?.toInt() ?? 0,
    );
  }
}

class SourceHealthChecker {
  static const keywords = ['我的', '天尊', '都市'];
  static const _timeout = Duration(seconds: 20);

  Future<SourceHealth> check(BookSource source) async {
    final start = DateTime.now();
    try {
      final health = await _probe(source).timeout(_timeout);
      // 探测内部各阶段各自计时，统一回填总耗时
      return SourceHealth(health.level, _ms(start), health.message, start.millisecondsSinceEpoch);
    } on TimeoutException {
      return _dead(start, '检测超时（20秒）');
    } on DioException catch (e) {
      return _dead(start, _describeDio(e));
    } catch (e) {
      return _dead(start, e.toString().split('\n').first);
    }
  }

  SourceHealth _dead(DateTime start, String msg) =>
      SourceHealth(HealthLevel.dead, _ms(start), msg, start.millisecondsSinceEpoch);

  int _ms(DateTime start) =>
      DateTime.now().difference(start).inMilliseconds;

  Future<SourceHealth> _probe(BookSource source) async {
    final start = DateTime.now();
    if ((source.searchUrl ?? '').trim().isEmpty) {
      return SourceHealth(HealthLevel.dead, 0, '书源没有搜索规则', start.millisecondsSinceEpoch);
    }
    final engine = BookSourceEngine(source);
    List<SearchBook> books = [];
    for (final kw in keywords) {
      books = await engine.search(kw);
      books = books.where((b) => b.bookUrl.isNotEmpty).toList();
      if (books.isNotEmpty) break;
    }
    if (books.isEmpty) {
      return SourceHealth(HealthLevel.dead, _ms(start), '搜索无结果（规则失效或反爬拦截）',
          start.millisecondsSinceEpoch);
    }
    final b = books.first;
    final searchOnly = SourceHealth(HealthLevel.searchOnly, _ms(start), '搜索命中《${b.name}》',
        start.millisecondsSinceEpoch);

    final BookDetail detail;
    try {
      detail = await engine.bookInfo(b.bookUrl, name: b.name, author: b.author);
    } catch (_) {
      return searchOnly;
    }
    final tocUrl = detail.tocUrl.isNotEmpty ? detail.tocUrl : b.bookUrl;
    final List<Chapter> chapters;
    try {
      chapters = await engine.toc(tocUrl);
    } catch (_) {
      return searchOnly;
    }
    if (chapters.isEmpty) return searchOnly;
    final mid = chapters[chapters.length ~/ 2];
    final probe = chapters.length > 6
        ? [mid, chapters.first, chapters.last]
        : chapters;
    for (final ch in probe) {
      if (ch.isVip) continue;
      try {
        final content = await engine.content(ch.url, title: ch.title);
        if (content.trim().length >= 50) {
          return SourceHealth(HealthLevel.ok, _ms(start),
              '《${b.name}》${chapters.length}章 正文正常', start.millisecondsSinceEpoch);
        }
      } catch (_) {
        // 换下一章节再试
      }
    }
    return SourceHealth(HealthLevel.tocNoContent, _ms(start),
        '《${b.name}》${chapters.length}章 正文获取失败', start.millisecondsSinceEpoch);
  }

  static String _describeDio(DioException e) {
    final err = e.error;
    if (err is DioException) return _describeDio(err);
    final s = err?.toString() ?? e.message ?? e.type.name;
    if (s.contains('CERTIFICATE_VERIFY_FAILED')) return '证书握手失败';
    if (s.contains('Failed host lookup')) return '域名无法解析（站点可能已失效）';
    if (s.contains('Connection') && s.contains('refused')) return '连接被拒绝';
    return s.split('\n').first;
  }
}

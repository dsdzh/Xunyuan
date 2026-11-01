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
    // 健康度记录存在 settings 盒里，坏盒逐帧抢救后可能留下类型不对的字段
    // （'level':"ok"、latency 是字符串等）。这里强转 num 会抛 TypeError，
    // 而 SourceState.load() 是逐个源直接调用的，一条脏记录能打断整个书源页加载。
    return SourceHealth(
      _asInt(j['level'], HealthLevel.unknown),
      _asInt(j['latency'], 0),
      j['message']?.toString() ?? '',
      _asInt(j['at'], 0),
    );
  }

  static int _asInt(dynamic v, int def) => v is num ? v.toInt() : int.tryParse('$v') ?? def;
}

class SourceHealthChecker {
  static const keywords = ['我的', '天尊', '都市'];
  // 探测链含 search+详情+目录+正文多次请求，单请求 receiveTimeout 就有 20s，
  // 整体预算必须显著大于单请求，否则慢站会被误判为不可用
  static const _timeout = Duration(seconds: 40);

  /// 探测走的四级链路全靠引擎的返回值判断，测试要钉住"搜索空→发现兜底"这种
  /// 分支就只能把引擎换掉，否则非得架一台假站点服务器。
  SourceHealthChecker({BookSourceEngine Function(BookSource source)? engineFactory})
      : _engineFor = engineFactory ?? BookSourceEngine.new;

  final BookSourceEngine Function(BookSource source) _engineFor;

  Future<SourceHealth> check(BookSource source) async {
    final start = DateTime.now();
    SourceHealth? reached; // 探测过程中已确认到的最高阶段
    try {
      final health = await _probe(source, (h) => reached = h).timeout(_timeout);
      // 探测内部各阶段各自计时，统一回填总耗时
      return SourceHealth(health.level, _ms(start), health.message, start.millisecondsSinceEpoch);
    } on TimeoutException {
      // 慢但已确认到某阶段：按已确认结果记分，不误判为整体不可用
      final r = reached;
      if (r != null) {
        return SourceHealth(r.level, _ms(start), '${r.message}（后续检测超时）', start.millisecondsSinceEpoch);
      }
      return _dead(start, '检测超时（${_timeout.inSeconds}秒）');
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

  Future<SourceHealth> _probe(BookSource source, void Function(SourceHealth) mark) async {
    final start = DateTime.now();
    final engine = _engineFor(source);
    List<SearchBook> books = [];
    var hitBy = '';
    String? searchFail;
    if (source.hasRunnableSearch) {
      for (final kw in keywords) {
        try {
          books = (await engine.search(kw)).where((b) => b.bookUrl.isNotEmpty).toList();
        } on DioException catch (e) {
          // 搜索页被反爬/证书拦下不代表整源不能用（403 那种站发现页常常是直连的）。
          // 也不再换关键词硬试：单个请求的 receiveTimeout 就有 20s，三次都超时
          // 会把 40s 的整体预算吃光，发现页还没探就到点判死了。
          searchFail = _describeDio(e);
          break;
        } catch (e) {
          searchFail = e.toString().split('\n').first;
          break;
        }
        if (books.isNotEmpty) {
          hitBy = '搜索';
          break;
        }
      }
    }
    if (books.isEmpty && source.supportsExplore) {
      // 一批真实书源的搜索页靠 JS 反爬、发现页却是直连的。只探搜索会把这类源判死，
      // 而判死就等于进了「删除不可用书源」的名单——用户好不容易攒下的源会被误删。
      for (final cat in BookSourceEngine.exploreCategories(source).take(3)) {
        try {
          final found = (await engine.explore(cat.url))
              .where((b) => b.bookUrl.isNotEmpty)
              .toList();
          if (found.isEmpty) continue;
          books = found;
          hitBy = '发现';
          break;
        } catch (_) {
          // 换下一个发现分类
        }
      }
    }
    if (books.isEmpty) {
      if (!source.hasRunnableSearch && !source.supportsExplore) {
        return _noRule(start, source);
      }
      return SourceHealth(
          HealthLevel.dead,
          _ms(start),
          searchFail == null
              ? '搜索与发现页都拿不到结果（规则失效或反爬拦截）'
              : '搜索失败（$searchFail），发现页也没拿到结果',
          start.millisecondsSinceEpoch);
    }
    final b = books.first;
    final onlyList = SourceHealth(HealthLevel.searchOnly, _ms(start), '$hitBy命中《${b.name}》',
        start.millisecondsSinceEpoch);
    mark(onlyList); // 书单已通，后续详情/目录/正文再慢再挂也不应回落到"不可用"

    final BookDetail detail;
    try {
      detail = await engine.bookInfo(b.bookUrl, name: b.name, author: b.author);
    } catch (_) {
      return onlyList;
    }
    final tocUrl = detail.tocUrl.isNotEmpty ? detail.tocUrl : b.bookUrl;
    final List<Chapter> chapters;
    try {
      chapters = await engine.toc(tocUrl);
    } catch (_) {
      return onlyList;
    }
    if (chapters.isEmpty) return onlyList;
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

  /// 一条请求都发不出去时的实话：区分「压根没写规则」和「规则要执行 JS，而本 App
  /// 不带 JS 引擎」，也别把后者说成站点失效——用户会白折腾。
  SourceHealth _noRule(DateTime start, BookSource s) {
    final why = <String>[];
    if (!s.hasRunnableSearch) {
      why.add((s.searchUrl ?? '').trim().isEmpty
          ? '没有搜索规则'
          : '搜索规则要先执行 JS，本 App 不执行');
    }
    final explore = (s.exploreUrl ?? '').trim();
    if (!s.supportsExplore && explore.isNotEmpty) {
      why.add(!s.enabledExplore ? '发现页已被书源作者关闭' : '发现规则要先执行 JS，本 App 不执行');
    }
    return _dead(start, '无法探测：${why.join('，')}');
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

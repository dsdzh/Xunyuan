import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'package:xunyuan/core/book_source_engine.dart';
import 'package:xunyuan/core/source_health.dart';
import 'package:xunyuan/models/book_source.dart';
import 'package:xunyuan/services/storage_service.dart';
import 'package:xunyuan/state/app_state.dart';

/// 假引擎：只记录调用、按表返回结果，用来钉住探测的分支走向
/// （真实引擎要联网，测试里不可能靠它判出"搜索空 → 发现兜底"这类结论）。
class _FakeEngine extends BookSourceEngine {
  _FakeEngine(
    super.source, {
    this.searchHits = const {},
    this.exploreHits = const {},
    this.chapters = const [],
    this.contentText = '',
    this.failDetail = false,
    this.failToc = false,
    this.searchThrows = false,
  });

  final Map<String, List<SearchBook>> searchHits;
  final Map<String, List<SearchBook>> exploreHits;
  final List<Chapter> chapters;
  final String contentText;
  final bool failDetail;
  final bool failToc;
  final bool searchThrows;
  final List<String> calls = [];

  @override
  Future<List<SearchBook>> search(String key, {int page = 1}) async {
    calls.add('search:$key');
    if (searchThrows) throw Exception('HTTP 403：站点拒绝或页面不存在');
    return searchHits[key] ?? const [];
  }

  @override
  Future<List<SearchBook>> explore(String urlTemplate, {int page = 1}) async {
    calls.add('explore:$urlTemplate');
    return exploreHits[urlTemplate] ?? const [];
  }

  @override
  Future<BookDetail> bookInfo(String bookUrl, {String? name, String? author}) async {
    calls.add('detail');
    if (failDetail) throw Exception('详情解析失败');
    return BookDetail()
      ..name = name ?? ''
      ..bookUrl = bookUrl
      ..tocUrl = 'https://site.com/toc';
  }

  @override
  Future<List<Chapter>> toc(String tocUrl) async {
    calls.add('toc');
    if (failToc) throw Exception('目录解析失败');
    return chapters;
  }

  @override
  Future<String> content(String chapterUrl, {String? title}) async {
    calls.add('content');
    return contentText;
  }
}

SearchBook _book(String name) => SearchBook(
      name: name,
      author: '作者',
      bookUrl: 'https://site.com/book/1',
      sourceUrl: 'https://site.com',
      sourceName: '甲源',
    );

List<Chapter> _chapters(int n) =>
    [for (var i = 1; i <= n; i++) Chapter('第$i章', 'https://site.com/ch/$i', i)];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('探测链路：搜索打不通就用发现页兜底', () {
    BookSource src({String? searchUrl, String? exploreUrl, bool enabledExplore = true}) =>
        BookSource.fromJson({
          'bookSourceUrl': 'https://site.com',
          'bookSourceName': '甲源',
          'searchUrl': searchUrl,
          'exploreUrl': exploreUrl,
          'enabledExplore': enabledExplore,
        });

    SourceHealthChecker checker(_FakeEngine Function(BookSource) f) =>
        SourceHealthChecker(engineFactory: f);

    test('搜索是 @js: 的源，发现页命中后按命中记分，不判死', () async {
      final s = src(searchUrl: '@js:\nresult;', exploreUrl: '月票榜::/rank/page{page}');
      final fake = _FakeEngine(
        s,
        exploreHits: const {'/rank/page{page}': []},
        failDetail: true,
      );
      // 先验一次空命中确实会落到判死，再给命中
      final empty = await checker((b) => fake).check(s);
      expect(empty.level, HealthLevel.dead);
      expect(fake.calls, ['explore:/rank/page{page}']); // @js: 搜索一条请求都不该发

      final hit = _FakeEngine(
        s,
        exploreHits: {'/rank/page{page}': [_book('甲书')]},
        failDetail: true,
      );
      final h = await checker((b) => hit).check(s);
      expect(h.level, HealthLevel.searchOnly);
      expect(h.message, '发现命中《甲书》');
      expect(hit.calls, ['explore:/rank/page{page}', 'detail']);
    });

    test('发现页命中 + 目录正文都通 → 可用', () async {
      final s = src(searchUrl: '', exploreUrl: '榜单::/top.html');
      final miss = _FakeEngine(s);
      final withBook = _FakeEngine(
        s,
        exploreHits: {'/top.html': [_book('乙书')]},
        chapters: _chapters(3),
        contentText: '正文正文正文' * 20,
      );
      expect((await checker((b) => miss).check(s)).level, HealthLevel.dead);
      final h = await checker((b) => withBook).check(s);
      expect(h.level, HealthLevel.ok);
      expect(h.message, '《乙书》3章 正文正常');
    });

    test('搜索命中仍按"搜索"记，不会串到发现口径', () async {
      final s = src(searchUrl: 'https://site.com/s?q={key}', exploreUrl: '榜单::/top.html');
      final fake = _FakeEngine(s, searchHits: const {'我的': []}, failDetail: true);
      final probe = _FakeEngine(s, searchHits: {'我的': [_book('丙书')]}, failDetail: true);
      expect((await checker((b) => fake).check(s)).level, HealthLevel.dead);
      final h = await checker((b) => probe).check(s);
      expect(h.level, HealthLevel.searchOnly);
      expect(h.message, '搜索命中《丙书》');
      expect(probe.calls.first, 'search:我的');
    });

    test('两条路都试过仍无结果 → 判死说的是实话', () async {
      final s = src(searchUrl: 'https://site.com/s?q={key}', exploreUrl: '榜单::/top.html');
      final fake = _FakeEngine(s);
      final h = await checker((b) => fake).check(s);
      expect(h.level, HealthLevel.dead);
      expect(h.message, '搜索与发现页都拿不到结果（规则失效或反爬拦截）');
      expect(fake.calls, containsAllInOrder(['search:我的', 'explore:/top.html']));
    });

    test('搜索页抛 403 也要给发现页一次机会，不再换关键词硬试', () async {
      final s = src(searchUrl: 'https://site.com/s?q={key}', exploreUrl: '榜单::/top.html');
      final hit = _FakeEngine(s,
          searchThrows: true, exploreHits: {'/top.html': [_book('丁书')]}, failDetail: true);
      final h = await checker((b) => hit).check(s);
      expect(h.level, HealthLevel.searchOnly);
      expect(h.message, '发现命中《丁书》');
      expect(hit.calls, ['search:我的', 'explore:/top.html', 'detail']);
    });

    test('搜索抛错、发现页又空 → 报的是搜索的错，不是笼统的"规则失效"', () async {
      final s = src(searchUrl: 'https://site.com/s?q={key}', exploreUrl: '榜单::/top.html');
      final f = _FakeEngine(s, searchThrows: true);
      final h = await checker((b) => f).check(s);
      expect(h.level, HealthLevel.dead);
      expect(h.message, '搜索失败（Exception: HTTP 403：站点拒绝或页面不存在），发现页也没拿到结果');
    });

    test('压根发不出请求时按原因说话，别推给"站点失效"', () async {
      final jsSearch = src(searchUrl: '@js:\nresult;');
      final h1 = await checker(_FakeEngine.new).check(jsSearch);
      expect(h1.level, HealthLevel.dead);
      expect(h1.message, '无法探测：搜索规则要先执行 JS，本 App 不执行');

      final noRule = src();
      expect((await checker(_FakeEngine.new).check(noRule)).message, '无法探测：没有搜索规则');

      final exploreOff = src(exploreUrl: '榜单::/top.html', enabledExplore: false);
      expect((await checker(_FakeEngine.new).check(exploreOff)).message,
          '无法探测：没有搜索规则，发现页已被书源作者关闭');
    });

    test('发现页解析不出分类（JSON 数组全是分组标题）也走不到兜底请求', () async {
      final s = src(searchUrl: '', exploreUrl: r'[{"title":"榜单","url":""}]');
      final fake = _FakeEngine(s);
      final h = await checker((b) => fake).check(s);
      expect(h.level, HealthLevel.dead);
      expect(fake.calls, isEmpty);
    });
  });

  group('删除名单口径与探测口径一致', () {
    BookSource src({String? searchUrl, String? exploreUrl, bool enabledExplore = true}) =>
        BookSource.fromJson({
          'bookSourceUrl': 'https://site.com',
          'bookSourceName': '甲源',
          'searchUrl': searchUrl,
          'exploreUrl': exploreUrl,
          'enabledExplore': enabledExplore,
        });

    test('只有发现页能用的源不该进"不可用"', () {
      expect(SourceState.hasRunnableRule(src(exploreUrl: '榜单::/top.html')), true);
      expect(SourceState.hasRunnableRule(src(searchUrl: '@js:\nx;')), false);
      expect(
          SourceState.hasRunnableRule(src(exploreUrl: '榜单::/top.html', enabledExplore: false)), false);
      expect(SourceState.hasRunnableRule(src(searchUrl: 'https://site.com/s?q={key}')), true);
    });
  });

  group('SourceHealth.fromJson 脏值', () {
    test('类型不对的字段降级成缺省值，不抛', () {
      final h = SourceHealth.fromJson({'level': 'ok', 'latency': '12.5', 'message': null, 'at': <String, dynamic>{}});
      expect(h!.level, HealthLevel.unknown);
      expect(h.latencyMs, 0);
      expect(h.message, '');
      expect(h.checkedAt, 0);
    });

    test('数字字符串照收，正常记录语义不变', () {
      expect(SourceHealth.fromJson({'level': '2', 'latency': '30', 'at': '123'})!.level, 2);
      expect(SourceHealth.fromJson({'level': '2', 'latency': '30', 'at': '123'})!.latencyMs, 30);
      expect(SourceHealth.fromJson({'level': 2, 'latency': 30.7, 'message': '《甲》', 'at': 5})!.level, 2);
      expect(SourceHealth.fromJson(null), isNull);
    });
  });

  test('一条脏健康度记录不会打断书源页 load()', () async {
    final dir = await Directory.systemTemp.createTemp('health');
    addTearDown(() async {
      await Hive.close();
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    await StorageService.instance.init();

    final ok = BookSource.fromJson({'bookSourceUrl': 'https://a/1', 'bookSourceName': '甲源'});
    final dirty = BookSource.fromJson({'bookSourceUrl': 'https://b/2', 'bookSourceName': '乙源'});
    await StorageService.instance.saveSource(ok);
    await StorageService.instance.saveSource(dirty);
    await StorageService.instance.putSourceHealth('https://a/1', {'level': 2, 'latency': 88, 'message': '正常', 'at': 111});
    // 模拟逐帧抢救回来的坏记录：level 是字符串、latency 是对象
    await StorageService.instance.putSourceHealth('https://b/2', {'level': '可用', 'latency': {'x': 1}});

    final state = SourceState();
    await state.load();

    expect(state.sources.length, 2);
    expect(state.health['https://a/1']?.level, 2);
    expect(state.health['https://b/2']?.level, HealthLevel.unknown);
  });
}

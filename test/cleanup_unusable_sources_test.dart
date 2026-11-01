import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:xunyuan/core/source_health.dart';
import 'package:xunyuan/models/book_source.dart';
import 'package:xunyuan/pages/source_page.dart';
import 'package:xunyuan/services/storage_service.dart';
import 'package:xunyuan/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SourceState state;

  /// [searchUrl] 给默认值：没有可跑规则的源本身就落在"不可用"里，
  /// 想让某条留在列表里就得给它一条真能发请求的规则。传 '' 才当"没规则"。
  Future<void> setUpSources(
    Map<String, ({bool enabled, String searchUrl, Map<String, dynamic>? health})> bySource,
  ) async {
    final dir = await Directory.systemTemp.createTemp('deadsrc');
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
    for (final e in bySource.entries) {
      await StorageService.instance.saveSource(BookSource.fromJson({
        'bookSourceUrl': e.key,
        'bookSourceName': e.key,
        'searchUrl': e.value.searchUrl,
        'enabled': e.value.enabled,
      }));
      if (e.value.health != null) {
        await StorageService.instance.putSourceHealth(e.key, e.value.health!);
      }
    }
    state = SourceState();
    await state.load();
  }

  ({bool enabled, String searchUrl, Map<String, dynamic>? health}) src({
    bool enabled = true,
    String searchUrl = '/search?kw={{key}}',
    Map<String, dynamic>? health,
  }) =>
      (enabled: enabled, searchUrl: searchUrl, health: health);

  Map<String, dynamic> health(int level) =>
      {'level': level, 'latency': 10, 'message': 'x', 'at': 1};

  test('判死的删掉，其余档位和未检测但有规则的原样留着', () async {
    await setUpSources({
      'https://dead/1': src(health: health(HealthLevel.dead)),
      'https://ok/2': src(health: health(HealthLevel.ok)),
      'https://searchonly/3': src(health: health(HealthLevel.searchOnly)),
      'https://toc/4': src(health: health(HealthLevel.tocNoContent)),
      'https://unchecked/5': src(),
      // 坏盒抢救回来的脏记录：level 读不成数字 → 徽章是灰的「记录异常」，不该按判死删掉
      'https://dirty/6': src(health: {'level': '可用', 'latency': 3}),
    });

    expect(state.unusableSources.map((s) => s.bookSourceUrl), ['https://dead/1']);
    expect(await state.removeUnusableSources(), 1);

    expect(state.sources.map((s) => s.bookSourceUrl), unorderedEquals([
      'https://ok/2',
      'https://searchonly/3',
      'https://toc/4',
      'https://unchecked/5',
      'https://dirty/6',
    ]));
    expect(StorageService.instance.sourceExists('https://dead/1'), false);
  });

  test('关着的源也算不可用：是真删，不是把开关关掉', () async {
    await setUpSources({
      // 书源文件里带 enabled:false 的那一批（多为需要 JS 规则的），
      // 健康度检测只探已启用的，永远轮不到它们 → 只能靠清理口径覆盖
      'https://off/1': src(enabled: false),
      'https://off/2': src(enabled: false),
      'https://on/3': src(),
    });

    expect(state.unusableSources.map((s) => s.bookSourceUrl),
        unorderedEquals(['https://off/1', 'https://off/2']));
    expect(await state.removeUnusableSources(), 2);

    // 列表里不是"多了一排关着的"，而是整条记录连同健康度都没了
    expect(state.sources.map((s) => s.bookSourceUrl), ['https://on/3']);
    expect(StorageService.instance.sourceExists('https://off/1'), false);
    expect(StorageService.instance.getSourceHealth('https://off/1'), isNull);
  });

  test('没有可跑规则的算不可用：空规则与只有 JS 规则都算', () async {
    await setUpSources({
      'https://norule/1': src(searchUrl: ''),
      'https://js/2': src(searchUrl: '@js:\nresult = baseUrl + "/s?kw=" + key'),
      'https://js/3': src(searchUrl: '<js>java.put("x")</js>/modules/article/search'),
      'https://good/4': src(searchUrl: '/modules/article/search?kw={{key}}'),
    });

    expect(state.unusableSources.map((s) => s.bookSourceUrl),
        unorderedEquals(['https://norule/1', 'https://js/2', 'https://js/3']));
    expect(await state.removeUnusableSources(), 3);
    expect(state.sources.map((s) => s.bookSourceUrl), ['https://good/4']);
  });

  test('只有发现页规则、没有搜索页规则的留着：能发现就能用', () async {
    await setUpSources({
      'https://explore/1': src(searchUrl: ''),
      'https://nothing/2': src(searchUrl: ''),
    });
    // 给第一条补上 exploreUrl（走导入路径才带得上这个字段）
    await StorageService.instance.importSources([
      BookSource.fromJson({
        'bookSourceUrl': 'https://explore/1',
        'bookSourceName': 'https://explore/1',
        'exploreUrl': '/top/{{key}}',
      }),
    ]);
    state = SourceState();
    await state.load();

    expect(state.unusableSources.map((s) => s.bookSourceUrl), ['https://nothing/2']);
  });

  test('一个源只归一档，分档条数与总数同口径', () async {
    await setUpSources({
      'https://dead/1': src(enabled: false, health: health(HealthLevel.dead)),
      'https://off/2': src(enabled: false),
      'https://norule/3': src(searchUrl: ''),
      'https://good/4': src(),
    });

    expect(state.unusableCounts, {
      '检测判定不可用': 1, // 判死优先于关闭，不重复计数
      '处于关闭状态': 1,
      '没有可用的搜索/发现规则': 1,
    });
    expect(state.unusableCounts.values.reduce((a, b) => a + b), state.unusableSources.length);
  });

  test('删掉的源连同健康度记录一起清掉，重导同一本书源不会复活旧的「不可用」', () async {
    await setUpSources({
      'https://dead/1': src(health: health(HealthLevel.dead)),
      'https://ok/2': src(health: health(HealthLevel.ok)),
    });
    await state.removeUnusableSources();
    expect(StorageService.instance.getSourceHealth('https://dead/1'), isNull);
    expect(StorageService.instance.getSourceHealth('https://ok/2'), isNotNull);

    final reloaded = SourceState();
    await reloaded.load();
    expect(reloaded.sources.length, 1);
    expect(reloaded.unusableSources, isEmpty);
  });

  test('没有不可用源时返回 0 且不动任何数据', () async {
    await setUpSources({'https://ok/2': src(health: health(HealthLevel.ok)), 'https://free/3': src()});
    expect(await state.removeUnusableSources(), 0);
    expect(state.sources.length, 2);
    expect(StorageService.instance.sourceExists('https://ok/2'), true);
  });

  test('全部不可用则清空列表，重复调用不会二次删除', () async {
    await setUpSources({
      'https://dead/1': src(health: health(HealthLevel.dead)),
      'https://off/2': src(enabled: false),
    });
    expect(await state.removeUnusableSources(), 2);
    expect(state.sources, isEmpty);
    expect(await state.removeUnusableSources(), 0);
  });

  testWidgets('书源页菜单项的条数与不可用口径一致，取消不会动任何数据', (tester) async {
    // Hive 的读写要真实事件循环才能回来，fake-async 区里 await 会永久卡住（实测把测试挂满超时），
    // 所以造数据必须整段放进 runAsync
    await tester.runAsync(() => setUpSources({
          'https://ok/2': src(),
          'https://dead/1': src(health: health(HealthLevel.dead)),
          'https://off/3': src(enabled: false),
          'https://norule/4': src(searchUrl: ''),
        }));
    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider.value(value: state)],
      child: const MaterialApp(home: SourcePage()),
    ));

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // 判死 1 + 关着 1 + 没规则 1 = 3，正常那条不该被算进去
    expect(find.text('删除不可用书源（3）'), findsOneWidget);

    await tester.tap(find.text('删除不可用书源（3）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('删除 3 个不可用书源？'), findsOneWidget);
    expect(find.textContaining('检测判定不可用 1 个'), findsOneWidget);
    expect(find.textContaining('处于关闭状态 1 个'), findsOneWidget);
    expect(find.textContaining('没有可用的搜索/发现规则 1 个'), findsOneWidget);

    // 确认框里的「删除」会走真实落盘的 removeUnusableSources()，fake-async 区等不到它返回，
    // 删除行为交给上面几个纯逻辑用例验；这里只验取消是无害的
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.sources.length, 4);
    expect(state.unusableSources.length, 3);
  });
}

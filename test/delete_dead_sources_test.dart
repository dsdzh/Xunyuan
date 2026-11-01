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

  Future<void> setUpSources(
      Map<String, Map<String, dynamic>?> healthBySource) async {
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
    for (final e in healthBySource.entries) {
      await StorageService.instance
          .saveSource(BookSource.fromJson({'bookSourceUrl': e.key, 'bookSourceName': e.key}));
      if (e.value != null) {
        await StorageService.instance.putSourceHealth(e.key, e.value!);
      }
    }
    state = SourceState();
    await state.load();
  }

  Map<String, dynamic> health(int level) =>
      {'level': level, 'latency': 10, 'message': 'x', 'at': 1};

  test('只删探测明确判死的源，其余档位和未检测的原样留着', () async {
    await setUpSources({
      'https://dead/1': health(HealthLevel.dead),
      'https://ok/2': health(HealthLevel.ok),
      'https://searchonly/3': health(HealthLevel.searchOnly),
      'https://toc/4': health(HealthLevel.tocNoContent),
      'https://unchecked/5': null,
      // 坏盒抢救回来的脏记录：level 读不成数字 → 徽章是灰的「记录异常」，不该被当成不可用
      'https://dirty/6': {'level': '可用', 'latency': 3},
    });

    expect(state.deadSources.map((s) => s.bookSourceUrl), ['https://dead/1']);
    expect(await state.removeDeadSources(), 1);

    expect(state.sources.map((s) => s.bookSourceUrl), unorderedEquals([
      'https://ok/2',
      'https://searchonly/3',
      'https://toc/4',
      'https://unchecked/5',
      'https://dirty/6',
    ]));
    expect(state.health.containsKey('https://dead/1'), false);
    expect(StorageService.instance.sourceExists('https://dead/1'), false);
  });

  test('删掉的源连同健康度记录一起清掉，重导同一本书源不会复活旧的「不可用」', () async {
    await setUpSources({'https://dead/1': health(HealthLevel.dead), 'https://ok/2': health(HealthLevel.ok)});
    await state.removeDeadSources();
    expect(StorageService.instance.getSourceHealth('https://dead/1'), isNull);
    expect(StorageService.instance.getSourceHealth('https://ok/2'), isNotNull);

    final reloaded = SourceState();
    await reloaded.load();
    expect(reloaded.sources.length, 1);
    expect(reloaded.deadSources, isEmpty);
  });

  test('没有不可用源时返回 0 且不动任何数据', () async {
    await setUpSources({'https://ok/2': health(HealthLevel.ok), 'https://free/3': null});
    expect(await state.removeDeadSources(), 0);
    expect(state.sources.length, 2);
    expect(StorageService.instance.sourceExists('https://ok/2'), true);
  });

  test('全部判定不可用则清空列表，重复调用不会二次删除', () async {
    await setUpSources({
      'https://dead/1': health(HealthLevel.dead),
      'https://dead/2': health(HealthLevel.dead),
    });
    expect(await state.removeDeadSources(), 2);
    expect(state.sources, isEmpty);
    expect(await state.removeDeadSources(), 0);
  });

  testWidgets('书源页菜单项的条数与红标一致，取消不会动任何数据', (tester) async {
    // Hive 的读写要真实事件循环才能回来，fake-async 区里 await 会永久卡住（实测把测试挂满超时），
    // 所以造数据必须整段放进 runAsync
    await tester.runAsync(() => setUpSources({
          'https://ok/2': health(HealthLevel.ok),
          'https://dead/1': health(HealthLevel.dead),
          'https://dead/2': health(HealthLevel.dead),
        }));
    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider.value(value: state)],
      child: const MaterialApp(home: SourcePage()),
    ));

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('删除不可用书源（2）'), findsOneWidget);
    expect(find.text('不可用'), findsNWidgets(2)); // 入口条数和列表红标同一个口径

    await tester.tap(find.text('删除不可用书源（2）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('删除 2 个不可用书源？'), findsOneWidget);

    // 确认框里的「删除」会走真实落盘的 removeDeadSources()，fake-async 区等不到它返回，
    // 删除行为交给上面几个纯逻辑用例验；这里只验取消是无害的
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.sources.length, 3);
    expect(state.deadSources.length, 2);
  });
}

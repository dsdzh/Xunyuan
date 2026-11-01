import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:xunyuan/models/book_source.dart';
import 'package:xunyuan/pages/search_page.dart';
import 'package:xunyuan/services/storage_service.dart';
import 'package:xunyuan/state/app_state.dart';

import 'storage_harness.dart';

/// 搜索记录：落盘规则 + 空态展示 + 点选即搜 + 单删/清空，以及切走 tab 退回空态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => initTempStorage('searchhist'));

  // Mock 书源：searchUrl 以 @js: 开头，引擎解出空 URL 就直接返回空结果，
  // UI 用例能跑到"搜完了"这一态而不碰网络
  Future<void> seedMockSource() => StorageService.instance.saveSource(
      BookSource.fromJson({
        'bookSourceUrl': 'https://mock/1',
        'bookSourceName': 'Mock源',
        'searchUrl': '@js:search()',
      }));

  Future<void> seedHistory(List<String> words) async {
    for (final w in words) {
      await StorageService.instance.addSearchHistory(w);
    }
  }

  Future<SourceState> seededState() async {
    await seedMockSource();
    final state = SourceState();
    await state.load();
    return state;
  }

  Future<void> pumpSearch(WidgetTester tester, SourceState state,
      {bool visible = true}) async {
    await tester.pumpWidget(ChangeNotifierProvider<SourceState>.value(
      value: state,
      child: MaterialApp(home: SearchPage(visible: visible)),
    ));
    await tester.pump();
  }

  TextField searchField(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField));

  // ---------- 存储层 ----------

  test('搜索记录去重置顶，只留最近 50 条，空词不记', () async {
    for (var i = 1; i <= 55; i++) {
      await StorageService.instance.addSearchHistory('词$i');
    }
    final list = StorageService.instance.searchHistory;
    expect(list.length, StorageService.searchHistoryCap);
    expect(list.first, '词55');
    expect(list.contains('词1'), isFalse); // 挤出上限的是最旧那条

    await StorageService.instance.addSearchHistory('词30');
    expect(StorageService.instance.searchHistory.first, '词30');
    expect(StorageService.instance.searchHistory.where((e) => e == '词30').length, 1);

    await StorageService.instance.addSearchHistory('  星渊纪元1  ');
    expect(StorageService.instance.searchHistory.first, '星渊纪元1'); // 存的是 trim 过的
    await StorageService.instance.addSearchHistory('   ');
    expect(StorageService.instance.searchHistory.first, '星渊纪元1');
    expect(StorageService.instance.searchHistory.length, StorageService.searchHistoryCap);
  });

  test('删除单条只抹掉那条，清空抹掉整段', () async {
    await seedHistory(['甲', '乙', '丙']);
    await StorageService.instance.removeSearchHistory('乙');
    expect(StorageService.instance.searchHistory, ['丙', '甲']);

    await StorageService.instance.removeSearchHistory('不存在的词');
    expect(StorageService.instance.searchHistory, ['丙', '甲']);

    await StorageService.instance.clearSearchHistory();
    expect(StorageService.instance.searchHistory, isEmpty);
  });

  test('坏盒救回来的脏记录不会把搜索记录读崩', () async {
    // 键名必须与 StorageService._searchHistoryKey 一致
    await StorageService.instance.putSetting('searchHistory', '{不是 JSON');
    expect(StorageService.instance.searchHistory, isEmpty);

    await StorageService.instance.putSetting(
        'searchHistory', jsonEncode([
      {'bookSourceUrl': 'x'},
      '好词',
      7
    ]));
    expect(StorageService.instance.searchHistory, ['好词']);

    await StorageService.instance.addSearchHistory('新词');
    expect(StorageService.instance.searchHistory, ['新词', '好词']);
  });

  // ---------- 页面 ----------

  testWidgets('空态列出最近 10 条记录，每条自带删除叉，多余的进「全部」面板',
      (tester) async {
    late SourceState state;
    await tester.runAsync(() async {
      await seedHistory([for (var i = 1; i <= 12; i++) '词$i']);
      state = await seededState();
    });
    await pumpSearch(tester, state);

    expect(find.text('搜索记录'), findsOneWidget);
    expect(find.text('全部 12 条 ›'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNWidgets(10)); // 一条记录一个叉
    // 记录是最新在前：词12…词3 摆空态，词2、词1 只进面板
    expect(find.widgetWithText(InkWell, '词12'), findsOneWidget);
    expect(find.widgetWithText(InkWell, '词3'), findsOneWidget);
    expect(find.widgetWithText(InkWell, '词2'), findsNothing);

    await tester.tap(find.text('全部 12 条 ›'));
    await tester.pumpAndSettle();
    expect(find.text('搜索记录（12）'), findsOneWidget);
    expect(find.widgetWithIcon(ListTile, Icons.history), findsWidgets);
    // 面板不是只给最近 10 条：滚到底能看到最旧的词1
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '词1'), findsOneWidget);

    // 面板里点一条：面板收起，词进输入框并就地开搜。
    // 搜索会写搜索记录，fake-async 区里那条写永远回不来，
    // 会把本用例的盒写队列吊死（下一个用例的 Hive.close() 直接挂住），所以点击放 runAsync
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(ListTile, '词1'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(find.widgetWithIcon(ListTile, Icons.history), findsNothing);
    expect(searchField(tester).controller!.text, '词1');
    expect(find.text('没有找到相关书籍'), findsOneWidget);
  });

  testWidgets('点空态记录芯片直接搜这个词', (tester) async {
    late SourceState state;
    await tester.runAsync(() async {
      await seedHistory(['星渊纪元1']);
      state = await seededState();
    });
    await pumpSearch(tester, state);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(InkWell, '星渊纪元1'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    await tester.pump();
    expect(searchField(tester).controller!.text, '星渊纪元1');
    expect(find.text('没有找到相关书籍'), findsOneWidget);
  });

  testWidgets('记录叉删掉一条，「全部」面板能清空', (tester) async {
    late SourceState state;
    await tester.runAsync(() async {
      await seedHistory(['甲', '乙']);
      state = await seededState();
    });
    await pumpSearch(tester, state);
    expect(find.byIcon(Icons.close), findsNWidgets(2));

    // 删除要真实落盘，点击得放进 runAsync 再等一小段真时间
    await tester.runAsync(() async {
      await tester.tap(find.descendant(
          of: find.widgetWithText(InkWell, '乙'), matching: find.byIcon(Icons.close)));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    expect(find.widgetWithText(InkWell, '乙'), findsNothing);
    expect(StorageService.instance.searchHistory, ['甲']);

    await tester.tap(find.text('全部 1 条 ›'));
    await tester.pumpAndSettle();
    expect(find.text('搜索记录（1）'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '清空'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(StorageService.instance.searchHistory, isEmpty);
    expect(find.text('没有搜索记录'), findsOneWidget);
  });

  testWidgets('切走搜索 tab 退回未搜索状态：结果、输入框、焦点全部收回',
      (tester) async {
    late SourceState state;
    await tester.runAsync(() async {
      await seedHistory(['星渊纪元1']);
      state = await seededState();
    });
    await pumpSearch(tester, state);
    final node = searchField(tester).focusNode!;

    await tester.enterText(find.byType(TextField), '星渊');
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.search));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    expect(find.text('没有找到相关书籍'), findsOneWidget);

    // 换成别的 tab：IndexedStack 不销毁页面，靠 visible 收回空态
    await pumpSearch(tester, state, visible: false);
    await tester.pump();
    expect(searchField(tester).controller!.text, isEmpty);
    expect(find.text('没有找到相关书籍'), findsNothing);
    expect(find.text('下拉或点击空白处聚焦搜索框'), findsOneWidget);
    expect(find.widgetWithText(InkWell, '星渊纪元1'), findsOneWidget);
    expect(node.hasFocus, isFalse);

    // 回到搜索页也不该把旧结果带回来
    await pumpSearch(tester, state, visible: true);
    await tester.pump();
    expect(find.text('没有找到相关书籍'), findsNothing);
  });
}

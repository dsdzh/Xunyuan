import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:xunyuan/pages/source_page.dart';
import 'package:xunyuan/services/storage_service.dart';
import 'package:xunyuan/state/app_state.dart';

/// 「从 URL 导入」这一步原来只认裸的 http(s) 链接，粘分享文案或正文就直接
/// `FormatException: 仅支持 http/https 书源链接`。这里钉住页面接线后的两条路：
/// 认得出正文就走正文导入，什么都认不出来只给提示、不发请求。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SourceState state;

  Future<void> setUpStore() async {
    final dir = await Directory.systemTemp.createTemp('urlimport');
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
    state = SourceState();
    await state.load();
  }

  Future<void> openUrlDialogAndPaste(WidgetTester tester, String text) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('从 URL 导入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('导入'));
    // 落盘/发请求都走真实事件循环，runAsync 里得让出真时间而不是只 pump 帧
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider.value(value: state)],
      child: const MaterialApp(home: SourcePage()),
    ));
  }

  testWidgets('粘进来的是书源正文：当正文导入，不再报"仅支持 http/https"', (tester) async {
    // 落盘要真实事件循环，整段交互放进 runAsync
    await tester.runAsync(() async {
      await setUpStore();
      await pumpPage(tester);
      await openUrlDialogAndPaste(
          tester, '[{"bookSourceUrl":"https://pasted/1","bookSourceName":"粘进来的源"}]');
    });

    expect(state.sources.map((s) => s.bookSourceUrl), ['https://pasted/1']);
    expect(find.textContaining('导入完成'), findsOneWidget);
  });

  testWidgets('什么都没认出来：给可操作的提示，不动任何数据', (tester) async {
    await tester.runAsync(() async {
      await setUpStore();
      await pumpPage(tester);
      await openUrlDialogAndPaste(tester, '这个书源很好用 长期更新');
    });

    expect(state.sources, isEmpty);
    expect(find.textContaining('没有链接'), findsOneWidget);
  });
}

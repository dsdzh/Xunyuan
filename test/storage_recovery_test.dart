import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'package:xunyuan/pages/main_page.dart';
import 'package:xunyuan/services/storage_service.dart';
import 'hive_forge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sources = {
    'https://a/1': '{"bookSourceUrl":"https://a/1","bookSourceName":"甲源"}',
    'https://b/2': '{"bookSourceUrl":"https://b/2","bookSourceName":"乙源"}',
    'https://c/3': '{"bookSourceUrl":"https://c/3","bookSourceName":"丙源"}',
    'https://d/4': '{"bookSourceUrl":"https://d/4","bookSourceName":"丁源"}',
  };

  test('启动时坏书源盒被逐帧抢救，其余源照常可用', () async {
    final dir = await Directory.systemTemp.createTemp('boot');
    addTearDown(() async {
      await Hive.close();
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    });
    // path_provider 在测试里没有真插件，打到临时目录让 StorageService.init 走真实实现
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );

    // 用别的盒名造好文件，改名成 sources.hive —— 免得本进程的盒缓存干扰启动
    Hive.init(dir.path);
    final forge = await Hive.openBox<String>('forge');
    await forge.putAll(sources);
    await forge.close();
    final bytes = await File('${dir.path}/forge.hive').readAsBytes();
    await File('${dir.path}/sources.hive')
        .writeAsBytes(forgeUnknownTypeId(bytes, sources['https://b/2']!));

    await StorageService.instance.init();

    expect(StorageService.instance.recoveryNotes, hasLength(1));
    expect(StorageService.instance.recoveryNotes.single, contains('已恢复 3 条'));
    expect(
      StorageService.instance.sources.map((s) => s.bookSourceName).toSet(),
      {'甲源', '丙源', '丁源'},
    );
    // 修好后继续写盘，确认新盒是真能用的
    await StorageService.instance.saveSource(StorageService.instance.sources.first);
    expect(StorageService.instance.sourceExists('https://a/1'), isTrue);
  });

  testWidgets('修复说明弹窗展示后清空列表，关闭不再重复', (tester) async {
    final notes = ['本地书源数据文件损坏，已恢复 3 条，丢弃 1 条'];
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        WidgetsBinding.instance.addPostFrameCallback((_) => showRecoveryNotes(ctx, notes));
        return const Scaffold(body: SizedBox.shrink());
      }),
    ));
    await tester.pumpAndSettle();
    expect(find.text('本地数据已尽量修复'), findsOneWidget);
    expect(find.textContaining('已恢复 3 条'), findsOneWidget);
    expect(notes, isEmpty);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('本地数据已尽量修复'), findsNothing);
  });
}

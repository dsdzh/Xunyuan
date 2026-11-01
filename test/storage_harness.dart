import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'package:xunyuan/services/storage_service.dart';

/// 把 StorageService 指到临时目录：path_provider 在测试里没有真插件，
/// 得先打桩再 init，否则页面层读盒会撞上未初始化的 late 字段。
/// 纯 test 里直接 await 就行；testWidgets 必须整段塞进 tester.runAsync，
/// fake-async 区里等真实文件 IO 是等不回来的。
Future<Directory> initTempStorage(String tag) async {
  final dir = await Directory.systemTemp.createTemp(tag);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => dir.path,
  );
  await StorageService.instance.init();
  addTearDown(() async {
    await Hive.close();
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  });
  return dir;
}

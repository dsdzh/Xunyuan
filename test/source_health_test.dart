import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'package:xunyuan/core/source_health.dart';
import 'package:xunyuan/models/book_source.dart';
import 'package:xunyuan/services/storage_service.dart';
import 'package:xunyuan/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

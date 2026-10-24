import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'package:xunyuan/core/source_health.dart';
import 'package:xunyuan/models/book_source.dart';
import 'package:xunyuan/services/storage_service.dart';
import 'package:xunyuan/state/app_state.dart';

/// 假探测器：started 记录每个源被探测的次数，release 门住完成时机，
/// 这样测试能稳稳站住「批量检测正在跑」的那个窗口。
class _FakeChecker extends SourceHealthChecker {
  _FakeChecker(this.started, this.release);
  final List<String> started;
  final Completer<void> release;

  @override
  Future<SourceHealth> check(BookSource s) async {
    started.add(s.bookSourceUrl);
    await release.future;
    return SourceHealth(HealthLevel.ok, 10, '假检测', DateTime.now().millisecondsSinceEpoch);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> started;
  late Completer<void> release;
  late SourceState state;

  Future<void> setUpState() async {
    final dir = await Directory.systemTemp.createTemp('healthq');
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
    for (final url in ['https://a/1', 'https://b/2', 'https://c/3', 'https://d/4']) {
      await StorageService.instance
          .saveSource(BookSource.fromJson({'bookSourceUrl': url, 'bookSourceName': url}));
    }
    started = [];
    release = Completer<void>();
    state = SourceState(
        checkerFactory: () => _FakeChecker(started, release));
  }

  Future<void> waitIdle() async {
    if (!state.healthChecking) return;
    final done = Completer<void>();
    void listener() {
      if (!state.healthChecking) {
        state.removeListener(listener);
        done.complete();
      }
    }

    state.addListener(listener);
    await done.future;
  }

  BookSource src(String url) => BookSource.fromJson({'bookSourceUrl': url});

  test('批量检测在跑时，单源「重新检测」排队而不是被静丢掉', () async {
    await setUpState();
    await state.checkHealth([src('https://a/1'), src('https://b/2'), src('https://c/3')]);
    expect(started.length, 3); // 3 路 worker 全被门住
    expect(state.healthChecking, true);

    await state.checkHealth([src('https://d/4')]);
    expect(state.healthChecking, true);

    release.complete();
    await waitIdle();
    expect(started..sort(), ['https://a/1', 'https://b/2', 'https://c/3', 'https://d/4']);
    expect(state.health.containsKey('https://d/4'), true);
  });

  test('同一源已在队列里就不重复探，跑完后再点才会重新探', () async {
    await setUpState();
    await state.checkHealth([src('https://a/1'), src('https://b/2')]);
    await state.checkHealth([src('https://a/1')]); // 去重：不该多出一次
    await state.checkHealth([src('https://c/3')]);
    release.complete();
    await waitIdle();
    expect(started.where((u) => u == 'https://a/1').length, 1);
    expect(started.length, 3);

    started.clear();
    final release2 = Completer<void>()..complete();
    state = SourceState(checkerFactory: () => _FakeChecker(started, release2));
    await state.checkHealth([src('https://a/1')]);
    await waitIdle();
    expect(started, ['https://a/1']);
  });

  test('空目标和空 URL 的书源都不起 worker', () async {
    await setUpState();
    await state.checkHealth([]);
    await state.checkHealth([src('')]);
    expect(started, isEmpty);
    expect(state.healthChecking, false);
  });
}

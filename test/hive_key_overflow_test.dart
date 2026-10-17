import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:xunyuan/models/book_source.dart';
import 'package:xunyuan/services/box_salvage.dart';
import 'package:xunyuan/services/storage_service.dart';
import 'hive_forge.dart';

/// 真机"寻源启动失败 / HiveError: Cannot read, unknown typeId: 46"的根因回归：
/// hive 把字符串键的 UTF-8 长度写进一个字节，超过 255 就 mod 256，
/// 于是读回来的键被截短，紧接着把键文本里的 '.'(0x2E=46) 当成值的 typeId。
/// 我们的键全是 URL 拼出来的，长度不可控，所以落盘前统一过 boxKeyOf。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List boxBytes(String dir, String name) =>
      File('$dir/$name.hive').readAsBytesSync();

  Future<void> deleteDir(Directory dir) async {
    await Hive.close();
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  test('boxKeyOf 短键原样、超长键压成定长且幂等', () {
    final short = 'https://a/1';
    expect(StorageService.boxKeyOf(short), short);

    final long = 'https://x/${'p' * 400}'; // 412 字节 > 255
    final key = StorageService.boxKeyOf(long);
    expect(utf8.encode(key).length, lessThanOrEqualTo(255));
    expect(StorageService.boxKeyOf(key), key); // 已是安全键，不再二次哈希
    expect(StorageService.boxKeyOf(long), key); // 同输入同键
    expect(StorageService.boxKeyOf('${long}a'), isNot(key)); // 不同输入不同键

    // 中文按 UTF-8 计：200 个汉字 600 字节，必须压
    expect(utf8.encode(StorageService.boxKeyOf('字' * 200)).length, lessThanOrEqualTo(255));
  });

  test('bookKey / 健康度 / 目录 / 章节缓存键超长时一律落到安全键', () {
    final longUrl = 'https://t/${'u' * 300}';
    expect(utf8.encode(StorageService.bookKey('书名', '作者', longUrl)).length,
        lessThanOrEqualTo(255));
    expect(StorageService.bookKey('书名', '作者', 'https://ok/1'), '书名|作者|https://ok/1');
    // 幂等：已经压过的键再压一次不变
    final k = StorageService.bookKey('书名', '作者', longUrl);
    expect(StorageService.boxKeyOf(k), k);
  });

  test('超长键写坏整盒：hive 报 unknown typeId: 46，逐帧扫描只丢这一条', () async {
    final dir = await Directory.systemTemp.createTemp('overflow');
    addTearDown(() => deleteDir(dir));
    Hive.init(dir.path);
    final box = await Hive.openBox<String>('sources');
    await box.putAll({'https://ok/1': '{"a":1}', 'https://ok/2': '{"a":2}'});
    await box.close();

    // 260 字节、下标 4 是 '.'：长度字节截成 4，读键只吃掉 "xxxx"，
    // 下一个字节 '.' 被当成值类型 → 46
    final longKey = 'xxxx.${'y' * (260 - 5)}';
    expect(utf8.encode(longKey).length, 260);
    final original = boxBytes(dir.path, 'sources');
    final bad = forgeFrame(longKey, '{"a":3}');
    final patched = Uint8List(original.length + bad.length)
      ..setRange(0, original.length, original)
      ..setRange(original.length, original.length + bad.length, bad);
    File('${dir.path}/sources.hive').writeAsBytesSync(patched);

    // 手工拼出来的帧 CRC 合法，所以 hive 不会当成尾部截断跳过，而是解码时抛异常，
    // openBox 是整盒语义 —— 一条坏键让所有书源一起打不开
    await expectLater(
      Hive.openBox<String>('sources'),
      throwsA(isA<HiveError>()
          .having((e) => e.message, 'message', contains('unknown typeId: 46'))),
    );

    final s = salvageFrames(patched);
    // 键长只是被写坏了一个字节，键和值本身完好，按 mod 256 反推能整条还原
    expect(s.dropped, 0);
    expect(s.repaired, 1);
    expect(s.entries.keys.toList(), ['https://ok/1', 'https://ok/2', longKey]);
    expect(s.entries[longKey], '{"a":3}');
    expect(s.unreadTail, 0);
  });

  test('坏盒启动时超长键条目也一并救回，并写成安全键', () async {
    final dir = await Directory.systemTemp.createTemp('repair');
    addTearDown(() => deleteDir(dir));
    Hive.init(dir.path);
    final box = await Hive.openBox<String>('sources');
    await box.putAll({'https://ok/1': '{"a":1}', 'https://ok/2': '{"a":2}'});
    await box.close();

    final longKey = 'https://${'d' * 300}';
    expect(utf8.encode(longKey).length, greaterThan(255));
    final original = boxBytes(dir.path, 'sources');
    final bad = forgeFrame(longKey, '{"bookSourceUrl":"$longKey","bookSourceName":"超长源"}');
    File('${dir.path}/sources.hive').writeAsBytesSync(
        Uint8List(original.length + bad.length)
          ..setRange(0, original.length, original)
          ..setRange(original.length, original.length + bad.length, bad));

    final r = await openBoxWithRecovery<String>('sources', '书源',
        path: dir.path, keySanitizer: StorageService.boxKeyOf);
    expect(r.note, contains('已恢复 3 条'));
    expect(r.note, isNot(contains('丢弃')));
    final keys = r.box.keys.cast<String>().toList();
    expect(keys, containsAll(['https://ok/1', 'https://ok/2']));
    expect(keys, contains(StorageService.boxKeyOf(longKey)));
    for (final k in keys) {
      expect(utf8.encode(k).length, lessThanOrEqualTo(255), reason: '写回后仍会截断');
    }
    expect(jsonDecode(r.box.get(StorageService.boxKeyOf(longKey))!)['bookSourceName'], '超长源');

    // 重建后的文件 hive 自己能开，不会再触发第二次抢救
    await r.box.close();
    final reopened = await Hive.openBox<String>('sources', path: dir.path);
    expect(reopened.length, 3);
  });

  test('写入路径不再产出超长键：重启后各盒都能被 hive 正常打开', () async {
    final dir = await Directory.systemTemp.createTemp('keystack');
    addTearDown(() => deleteDir(dir));
    // path_provider 在测试里没有真插件，打到临时目录让 init 走真实实现
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );

    await StorageService.instance.init();
    expect(StorageService.instance.recoveryNotes, isEmpty);

    final longUrl = 'https://very-long-source.example/${'q' * 400}';
    final src = BookSource.fromJson({'bookSourceUrl': longUrl, 'bookSourceName': '超长源'});
    await StorageService.instance.saveSource(src);
    await StorageService.instance.setSourceEnabled(longUrl, false);
    expect(StorageService.instance.sourceExists(longUrl), isTrue);

    final bookKey = StorageService.bookKey('星渊纪元超长超长超长' * 20, '某作者', longUrl);
    expect(utf8.encode(bookKey).length, lessThanOrEqualTo(255));
    await StorageService.instance.putBook({'key': bookKey, 'name': '超长书名', 'lastAddTime': 1});

    final tocUrl = 'https://toc.example/${'w' * 400}';
    await StorageService.instance.putSourceHealth(longUrl, {'okCount': 1});
    final chapterKey = 'ch::$bookKey::7::$tocUrl';
    await StorageService.instance.putCachedChapter(chapterKey, '第一章 正文');
    expect(StorageService.instance.getCachedChapter(chapterKey), '第一章 正文');

    // 每盒落盘的键都必须落在一个字节表示得下的范围内
    for (final name in ['sources', 'books', 'settings', 'chapter_cache']) {
      final scan = salvageFrames(boxBytes(dir.path, name));
      expect(scan.dropped, 0, reason: '$name 有坏帧');
      for (final key in scan.entries.keys) {
        expect(utf8.encode(key as String).length, lessThanOrEqualTo(255), reason: '$name 键超长');
      }
    }

    // 换一次开盒（模拟重启）：数据还在，且没有任何抢救说明
    await Hive.close();
    final sources = await Hive.openBox<String>('sources', path: dir.path);
    expect(sources.containsKey(StorageService.boxKeyOf(longUrl)), isTrue);
    final books = await Hive.openBox<String>('books', path: dir.path);
    expect(books.containsKey(bookKey), isTrue);
    expect(jsonDecode(books.get(bookKey)!)['name'], '超长书名');
  });
}

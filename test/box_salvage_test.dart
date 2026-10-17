import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'package:xunyuan/services/box_salvage.dart';
import 'hive_forge.dart';

/// 用 hive 真写一个盒，拿回原始文件字节和它所在的目录
Future<(Uint8List, String)> forgeBox(String name, Map<String, String> entries) async {
  final dir = await Directory.systemTemp.createTemp('salvage');
  addTearDown(() async {
    await Hive.close();
    // Windows 上刚释放的文件锁会让递归删除偶发 ENOENT，临时目录留档无害
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  });
  Hive.init(dir.path);
  final box = await Hive.openBox<String>(name);
  await box.putAll(entries);
  await box.close();
  return (await File('${dir.path}/$name.hive').readAsBytes(), dir.path);
}

void main() {
  const entries = {
    'https://a/1': '{"bookSourceUrl":"https://a/1","n":"甲源"}',
    'https://b/2': '{"bookSourceUrl":"https://b/2","n":"乙源"}',
    'https://c/3': '{"bookSourceUrl":"https://c/3","n":"丙源"}',
    'https://d/4': '{"bookSourceUrl":"https://d/4","n":"丁源"}',
  };

  test('完好文件逐帧读出全部条目', () async {
    final (bytes, _) = await forgeBox('intact_box', entries);
    final got = salvageFrames(bytes);
    expect(got.entries.length, entries.length);
    expect(got.dropped, 0);
    expect(got.unreadTail, 0);
    expect(got.entries['https://c/3'], entries['https://c/3']);
  });

  test('未知 typeId 的坏帧只丢这一条，其后的条目照样恢复', () async {
    final (bytes, dir) = await forgeBox('badtype_box', entries);
    final broken = forgeUnknownTypeId(bytes, entries['https://b/2']!);

    // 前提：hive 自己的 openBox 面对这个文件确实起不来（用户看到的启动失败）
    await File('$dir/patched_box.hive').writeAsBytes(broken);
    await expectLater(
      Hive.openBox<String>('patched_box'),
      throwsA(isA<HiveError>().having((e) => e.message, 'message', contains('unknown typeId'))),
    );

    final got = salvageFrames(broken);
    expect(got.entries.length, entries.length - 1);
    expect(got.entries.containsKey('https://b/2'), isFalse);
    expect(got.entries['https://d/4'], entries['https://d/4'], reason: '坏帧之后的内容不能丢');
    expect(got.dropped, 1);
    expect(got.unreadTail, 0);
  });

  test('CRC 被打破时向后重找帧头，保住后面的帧', () async {
    final (bytes, _) = await forgeBox('crc_box', entries);
    final broken = Uint8List.fromList(bytes);
    final first = frameSpans(broken)[0];
    broken[first[0] + 6] ^= 0xFF; // 打在键体上，CRC 从此不符

    final got = salvageFrames(broken);
    expect(got.entries.length, entries.length - 1);
    expect(got.entries['https://d/4'], entries['https://d/4']);
    expect(got.dropped, 1);
    expect(got.unreadTail, 0);
  });

  test('尾部截断（掉电/半次写入）保住已完整的帧', () async {
    final (bytes, _) = await forgeBox('tail_box', entries);
    final got = salvageFrames(bytes.sublist(0, bytes.length - 3));
    expect(got.entries.length, entries.length - 1);
    expect(got.dropped, 1);
    expect(got.unreadTail, greaterThan(0));
  });

  test('整盒是垃圾时不崩，返回空结果', () async {
    final junk = Uint8List.fromList(List.generate(4096, (i) => (i * 37) & 0xFF));
    final got = salvageFrames(junk);
    expect(got.entries, isEmpty);
    expect(got.unreadTail, junk.length);
  });

  test('启动期真的打开坏盒：留下坏文件、新盒能读、给出人话说明', () async {
    final (bytes, dir) = await forgeBox('sources', entries);
    final broken = forgeUnknownTypeId(bytes, entries['https://b/2']!);
    await File('$dir/sources.hive').writeAsBytes(broken);

    final r = await openBoxWithRecovery<String>('sources', '书源', path: dir);
    expect(r.note, isNotNull);
    expect(r.note, allOf(contains('书源'), contains('已恢复 ${entries.length - 1} 条')));
    expect(r.box.length, entries.length - 1);
    expect(r.box.get('https://d/4'), entries['https://d/4']);
    expect(r.box.get('https://b/2'), isNull);
    await r.box.close();

    // 原文件必须留档，不能就地销毁
    final archived = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('sources.hive.broken-'))
        .toList();
    expect(archived, hasLength(1));
    expect(await archived.first.length(), broken.length);
  });

  test('完好的盒一次打开成功，不写说明也不留档', () async {
    final (_, dir) = await forgeBox('clean_sources', entries);
    final r = await openBoxWithRecovery<String>('clean_sources', '书源', path: dir);
    expect(r.note, isNull);
    expect(r.box.length, entries.length);
    expect(Directory(dir).listSync().where((e) => e.path.contains('.broken-')), isEmpty);
    await r.box.close();
  });

  test('缓存盒不抢救内容，只重建并留档', () async {
    final (bytes, dir) = await forgeBox('chapter_cache', entries);
    final broken = forgeUnknownTypeId(bytes, entries['https://b/2']!);
    await File('$dir/chapter_cache.hive').writeAsBytes(broken);

    final r = await openBoxWithRecovery<String>(
      'chapter_cache',
      '章节缓存',
      path: dir,
      salvage: false,
    );
    expect(r.box.length, 0);
    expect(r.note, '章节缓存已重建（内容可重新获取）');
    await r.box.close();
  });
}

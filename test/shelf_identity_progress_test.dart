import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/book_source_engine.dart';
import 'package:xunyuan/pages/detail_page.dart';
import 'package:xunyuan/services/storage_service.dart';
import 'package:xunyuan/state/app_state.dart';

import 'storage_harness.dart';

BookDetail detail({String name = '星渊纪元', String author = '甲', String src = 'https://a.com'}) =>
    BookDetail()
      ..name = name
      ..author = author
      ..sourceUrl = src
      ..tocUrl = '$src/toc/1'
      ..bookUrl = '$src/book/1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('书架条目身份', () {
    /// 键直接拼 `名|作者|源`，超长书名会超出 hive 的 255 字节字符串键上限被截断
    /// mod 256。详情页/浏览记录少过一次 bookKey，同一本书就裂成两个身份不同的行。
    test('keyOf 与 addFromDetail 落在同一个键，且该键能安全写进 hive', () async {
      await initTempStorage('shelfkey');
      final shelf = ShelfState();
      final d = detail(name: '名'.padRight(300, '星'));
      await shelf.addFromDetail(d);

      final key = StorageKeys.keyOf(d);
      expect(key, StorageService.bookKey(d.name, d.author, d.sourceUrl));
      expect(utf8.encode(key).length, lessThanOrEqualTo(255));
      expect(shelf.byKey(key), isNotNull);
      expect(shelf.books.length, 1);
    });

    test('普通书名不受影响：键仍是可读的原文拼接', () async {
      await initTempStorage('shortkey');
      final shelf = ShelfState();
      final d = detail();
      await shelf.addFromDetail(d);
      expect(StorageKeys.keyOf(d), '星渊纪元|甲|https://a.com');
    });
  });

  group('整本阅读进度', () {
    test('readProgress 由章序号 + 章内进度除以总章数得出，不是章内进度本身', () async {
      await initTempStorage('progress');
      final shelf = ShelfState();
      final d = detail();
      await shelf.addFromDetail(d);
      final key = StorageKeys.keyOf(d);

      await shelf.updateProgress(key, 49, '第50章', 0.5, tocCount: 100);
      final book = shelf.byKey(key)!;
      expect(book['readProgress'], closeTo(0.495, 1e-9));
      // 章内进度单独存一个字段，两者不能互相顶替
      expect(book['durChapterProgress'], 0.5);
      expect(book['tocCount'], 100);
      expect(book['durChapterIndex'], 49);
    });

    test('读到最后一章末尾时封顶 1.0，越界值也钳在 0~1', () async {
      await initTempStorage('clamp');
      final shelf = ShelfState();
      final d = detail();
      await shelf.addFromDetail(d);
      final key = StorageKeys.keyOf(d);

      await shelf.updateProgress(key, 99, '第100章', 1.0, tocCount: 100);
      expect(shelf.byKey(key)!['readProgress'], 1.0);

      await shelf.updateProgress(key, 250, '越界', 1.5, tocCount: 100);
      expect(shelf.byKey(key)!['readProgress'], 1.0);

      await shelf.updateProgress(key, 0, '开头', 0.0, tocCount: 100);
      expect(shelf.byKey(key)!['readProgress'], 0.0);
    });

    /// 总章数未知时如果照旧把章内进度当整本进度落库，书架上"读了 80%"
    /// 其实只读了某一章的 80%
    test('拿不到总章数时不猜整本进度', () async {
      await initTempStorage('nototal');
      final shelf = ShelfState();
      final d = detail();
      await shelf.addFromDetail(d);
      final key = StorageKeys.keyOf(d);

      await shelf.updateProgress(key, 3, '第4章', 0.8);
      final book = shelf.byKey(key)!;
      expect(book['readProgress'], 0.0);
      expect(book['durChapterProgress'], 0.8);

      // 总章数为 0（目录空/解析失败）也不能除出 Infinity 或 NaN
      await shelf.updateProgress(key, 0, '第1章', 0.5, tocCount: 0);
      expect(shelf.byKey(key)!['readProgress'], 0.0);
    });
  });
}

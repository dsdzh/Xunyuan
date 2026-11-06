import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/book_source_engine.dart';
import 'package:xunyuan/models/book_source.dart';
import 'package:xunyuan/services/storage_service.dart';

import 'storage_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('章节缓存的容量闸门', () {
    /// 目录单条能到几百 KB，且和正文共用 `chapter_cache` 一个盒。
    /// 只给正文 putCachedChapter 设上限的话，光刷详情页就能把盒撑到几百 MB。
    test('正文写满 2000 条后再存一份目录，最旧的一批必须被清掉', () async {
      await initTempStorage('cachecap');
      for (var i = 0; i < 2000; i++) {
        await StorageService.instance.putCachedChapter('c$i', '正文 $i');
      }
      expect(StorageService.instance.getCachedChapter('c0'), '正文 0');

      await StorageService.instance
          .putCachedToc('https://a.com/toc', [Chapter('第1章', 'https://a.com/1', 0)]);
      expect(StorageService.instance.getCachedChapter('c0'), isNull);
      expect(StorageService.instance.getCachedChapter('c1000'), '正文 1000');
      expect(StorageService.instance.getCachedToc('https://a.com/toc'), isNotNull);
    });

    test('正文自己越线也一样收手，越新的内容留着', () async {
      await initTempStorage('chapcap');
      for (var i = 0; i < 2050; i++) {
        await StorageService.instance.putCachedChapter('k$i', '内容 $i');
      }
      expect(StorageService.instance.getCachedChapter('k0'), isNull);
      expect(StorageService.instance.getCachedChapter('k1500'), '内容 1500');
    });

    /// 淘汰必须按写入顺序，而不是 hive 的 `keys`（跳表出来的字典序）。
    /// 按字典序的话每次删的都是同一批"名字最靠前"的章节——第一章永远命中不了缓存，
    /// 而真正没人看的陈旧条目一直占着位置。
    test('重写过同一章就把它挪到队尾，不被当最旧的先删', () async {
      await initTempStorage('rewrite');
      for (var i = 0; i < 2000; i++) {
        await StorageService.instance.putCachedChapter('w$i', '内容 $i');
      }
      // 把最早写的那条重写一遍：它现在是最新的，越线时不该被删
      await StorageService.instance.putCachedChapter('w0', '重写的 0');
      await StorageService.instance.putCachedChapter('extra', '挤出去');

      expect(StorageService.instance.getCachedChapter('w0'), '重写的 0');
      expect(StorageService.instance.getCachedChapter('w1'), isNull);
      expect(StorageService.instance.getCachedChapter('extra'), '挤出去');
    });

    /// 内存态的写入顺序记录重启即丢，这时不能再放弃容量控制
    test('重启后年龄未知：按字典序补位压回上限，且不误删刚写的那条', () async {
      final dir = await initTempStorage('restartcap');
      String k(int i) => 'k${i.toString().padLeft(5, '0')}';
      for (var i = 0; i < 2000; i++) {
        await StorageService.instance.putCachedChapter(k(i), '内容 $i');
      }
      await reopenTempStorage(dir);
      await StorageService.instance.putCachedChapter(k(2000), '内容 2000');

      expect(StorageService.instance.getCachedChapter(k(0)), isNull);
      expect(StorageService.instance.getCachedChapter(k(799)), isNull);
      expect(StorageService.instance.getCachedChapter(k(800)), '内容 800');
      expect(StorageService.instance.getCachedChapter(k(2000)), '内容 2000');
    });
  });

  group('书源导入的键卫生', () {
    BookSource srcWithUrl(String url) =>
        BookSource.fromJson({'bookSourceUrl': url, 'bookSourceName': '源$url'});

    /// 空白地址以前会写成 hive 键 `"   "`：导入 N 条垃圾源互相覆盖成 1 条，
    /// 还共用同一条 `health::   ` 健康度记录（一个源的检测结果被所有垃圾源显示）
    test('bookSourceUrl 全空白的条目一律跳过，不落键', () async {
      await initTempStorage('blankurl');
      final r = await StorageService.instance
          .importSources([srcWithUrl('   '), srcWithUrl(''), srcWithUrl('\t\t')]);
      expect(r.added, 0);
      expect(r.updated, 0);
      expect(r.skipped, 3);
      expect(StorageService.instance.sources, isEmpty);
    });

    test('空白条目不影响正常源，按 URL 去重仍然生效', () async {
      await initTempStorage('mixurl');
      final r = await StorageService.instance.importSources([
        srcWithUrl('https://a.com'),
        srcWithUrl('  '),
        srcWithUrl('https://a.com'),
        srcWithUrl('https://b.com'),
      ]);
      expect(r.added, 2);
      expect(r.updated, 1);
      expect(r.skipped, 1);
      expect(StorageService.instance.sources.length, 2);
    });
  });
}

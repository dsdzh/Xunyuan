import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/models/book_source.dart';

void main() {
  group('parseBookSources', () {
    test('顶层 JSON 数组', () {
      const text = '[{"bookSourceUrl":"https://a.com","bookSourceName":"A"},'
          '{"bookSourceUrl":"https://b.com","bookSourceName":"B"}]';
      final list = parseBookSources(text);
      expect(list.map((s) => s.bookSourceUrl), ['https://a.com', 'https://b.com']);
    });

    test('bookSourceList 包装', () {
      const text = '{"bookSourceList":[{"bookSourceUrl":"https://a.com","bookSourceName":"A"}]}';
      final list = parseBookSources(text);
      expect(list.length, 1);
      expect(list.first.bookSourceName, 'A');
    });

    test('sourceList / bookSources 包装', () {
      final l1 = parseBookSources('{"sourceList":[{"bookSourceUrl":"https://a"}]}');
      final l2 = parseBookSources('{"bookSources":[{"bookSourceUrl":"https://b"}]}');
      expect(l1.length, 1);
      expect(l2.length, 1);
    });

    test('单对象导入', () {
      final list = parseBookSources('{"bookSourceUrl":"https://a.com","bookSourceName":"A"}');
      expect(list.single.bookSourceUrl, 'https://a.com');
    });

    test('按 URL 去重，后出现的覆盖先前', () {
      const text = '[{"bookSourceUrl":"https://a.com","bookSourceName":"旧"},'
          '{"bookSourceUrl":"https://a.com","bookSourceName":"新"}]';
      final list = parseBookSources(text);
      expect(list.length, 1);
      expect(list.single.bookSourceName, '新');
    });

    test('丢弃缺 bookSourceUrl 的条目，不影响其余', () {
      const text = '[{"bookSourceName":"无URL"},{"bookSourceUrl":"https://a.com"}]';
      final list = parseBookSources(text);
      expect(list.length, 1);
      expect(list.single.bookSourceUrl, 'https://a.com');
    });

    test('UTF-8 BOM 前缀可解析', () {
      const text = '﻿[{"bookSourceUrl":"https://a.com"}]';
      final list = parseBookSources(text);
      expect(list.length, 1);
    });

    test('enabled:false 保留', () {
      final list = parseBookSources('[{"bookSourceUrl":"https://a","enabled":false}]');
      expect(list.single.enabled, false);
    });

    test('非小说 bookSourceType 归类', () {
      final list = parseBookSources('[{"bookSourceUrl":"https://a","bookSourceType":3}]');
      expect(list.single.isNovel, false);
      expect(list.single.sourceType, 3);
    });

    test('单引号 header 伪 JSON 原样保留在 raw', () {
      final list = parseBookSources(
          '[{"bookSourceUrl":"https://a","header":"{\'User-Agent\':\'x\'}"}]');
      expect(list.single.header, '{\'User-Agent\':\'x\'}');
      expect(list.single.raw['header'], '{\'User-Agent\':\'x\'}');
    });

    test('JSONL 逐行解析', () {
      const text = '{"bookSourceUrl":"https://a"}\n{"bookSourceUrl":"https://b"}\n\n';
      final list = parseBookSources(text);
      expect(list.map((s) => s.bookSourceUrl).toList(), ['https://a', 'https://b']);
    });

    test('非法文本返回空列表', () {
      expect(parseBookSources('not json at all'), isEmpty);
      expect(parseBookSources(''), isEmpty);
    });
  });

  group('ImportResult', () {
    test('summary 拼接新增/更新/跳过', () {
      const r = ImportResult(added: 90, updated: 6, skipped: 2);
      expect(r.summary, '新增 90，更新 6，跳过 2');
      expect(r.changed, 96);
      expect(r.isEmpty, false);
    });

    test('空结果 summary', () {
      const r = ImportResult();
      expect(r.isEmpty, true);
      expect(r.summary, '未导入有效书源');
    });

    test('仅有跳过', () {
      const r = ImportResult(skipped: 3);
      expect(r.isEmpty, true);
      expect(r.summary, '未导入有效书源（3 条无法解析）');
    });
  });
}

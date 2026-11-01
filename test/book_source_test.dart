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
      expect(r.summary, '未导入有效书源（内容需包含书源定义）');
    });

    test('仅有跳过', () {
      const r = ImportResult(skipped: 3);
      expect(r.isEmpty, true);
      expect(r.summary, '未导入有效书源（3 条无法解析）');
    });
  });

  group('bookSourceType（Legado 序：0 文本 1 音频 2 图片 3 文件 4 视频）', () {
    BookSource of(String? type) => BookSource.fromJson({
          'bookSourceUrl': 'https://a',
          'bookSourceName': '甲',
          'bookSourceType': type,
        });

    test('只有 0 是小说源，缺字段按 0 处理', () {
      expect(of(null).isNovel, true);
      expect(of('0').isNovel, true);
      expect(of('1').isNovel, false);
      expect(of('4').sourceType, 4);
      expect(of('音频').sourceType, 0); // 脏值退回 0，别抛
    });
  });

  group('enabledExplore / 可跑规则', () {
    BookSource src({String? searchUrl, String? exploreUrl, Object? enabledExplore}) =>
        BookSource.fromJson({
          'bookSourceUrl': 'https://a',
          'bookSourceName': '甲',
          'searchUrl': searchUrl,
          'exploreUrl': exploreUrl,
          'enabledExplore': ?enabledExplore,
        });

    test('脏值形态一律按字面意思认，缺失才默认启用', () {
      expect(src().enabledExplore, true);
      expect(src(enabledExplore: false).enabledExplore, false);
      expect(src(enabledExplore: 0).enabledExplore, false);
      expect(src(enabledExplore: 'false').enabledExplore, false);
      expect(src(enabledExplore: '0').enabledExplore, false);
      expect(src(enabledExplore: 1).enabledExplore, true);
      expect(src(enabledExplore: const <String, dynamic>{'x': 1}).enabledExplore, true);
    });

    test('作者关掉发现 → 发现页不认它，规则解析照样在', () {
      final s = src(exploreUrl: '榜单::/top/{page}.html', enabledExplore: false);
      expect(s.hasRunnableExplore, true);
      expect(s.supportsExplore, false);
    });

    test('@js: 开头等于一条请求都发不出去', () {
      expect(src(searchUrl: '@js:\nresult = ok();').hasRunnableSearch, false);
      expect(src(exploreUrl: '@js:\nJSON.stringify(kinds);').supportsExplore, false);
    });

    test('<js> 整包剥完什么都不剩才算发不出；混在正常地址里剥掉还能发', () {
      expect(src(searchUrl: '<js>getUrl();</js>').hasRunnableSearch, false);
      expect(src(searchUrl: 'https://a.com/<js>x()</js>book/{key}').hasRunnableSearch, true);
      expect(src(searchUrl: 'https://a.com/s?q={key}').hasRunnableSearch, true);
    });

    test('空串与纯空白都不算规则', () {
      expect(src(searchUrl: '', exploreUrl: '   ').hasRunnableSearch, false);
      expect(src(searchUrl: '', exploreUrl: '   ').supportsExplore, false);
    });
  });
}

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/source_format_adapter.dart';
import 'package:xunyuan/models/book_source.dart';

/// 只带最小特征的一条"像书源"的记录
String src(String extra) => '[{"bookSourceUrl":"https://a.com","bookSourceName":"A"$extra}]';

void main() {
  group('A 导入内容更宽容', () {
    test('注释 + 尾逗号', () {
      const text = '''
[
  // 起点书源
  {"bookSourceUrl": "https://qd.com", "bookSourceName": "起点"},
  /* 多行
     注释 */
  {"bookSourceUrl": "https://b.com", "bookSourceName": "乙"},
]
''';
      final list = parseBookSources(text);
      expect(list.map((s) => s.bookSourceUrl).toList(), ['https://qd.com', 'https://b.com']);
      expect(list.last.bookSourceName, '乙');
    });

    test('单引号串 + 裸键', () {
      const text = "[{bookSourceUrl: 'https://q.com', bookSourceName: '奇书'}]";
      final list = parseBookSources(text);
      expect(list.single.bookSourceUrl, 'https://q.com');
      expect(list.single.bookSourceName, '奇书');
    });

    test('尾逗号后面还夹着注释', () {
      const text = '[{"bookSourceUrl":"https://a.com","bookSourceName":"A", // 备用字段已删\n}]';
      expect(parseBookSources(text).single.bookSourceName, 'A');
      const block = '[{"bookSourceUrl":"https://b.com","bookSourceName":"乙", /* 尾注释 */}]';
      expect(parseBookSources(block).single.bookSourceName, '乙');
    });

    test('宽松 JSON 里的规则串不被字符串内容带偏', () {
      // 值里含 `https://`（冒号）与正则，修复器绝不能改字符串内部
      const text = "[{bookSourceUrl: 'https://a.com', ruleBookInfo: {name: 'tag.h1##https://x##'}}]";
      final list = parseBookSources(text);
      expect(list.single.ruleBookInfo.name, 'tag.h1##https://x##');
    });

    test('base64 包装', () {
      final text = base64Encode(utf8.encode(src('')));
      expect(decodeSourceJson(text), isA<List>());
      expect(parseBookSources(text).single.bookSourceUrl, 'https://a.com');
    });

    test('base64(gzip) 包装', () {
      final text = base64Encode(gzip.encode(utf8.encode(src(''))));
      expect(parseBookSources(text).length, 1);
    });

    test('URL 编码包装', () {
      final text = Uri.encodeFull(src(''));
      expect(parseBookSources(text).single.bookSourceName, 'A');
    });

    test('base64 套 base64', () {
      final one = base64Encode(utf8.encode(src('')));
      final text = base64Encode(utf8.encode(one));
      expect(parseBookSources(text).length, 1);
    });

    test('整份内容被双重编码成 JSON 字符串', () {
      final text = jsonEncode({'code': 0, 'data': src('')});
      expect(parseBookSources(text).single.bookSourceUrl, 'https://a.com');
    });

    test('任意包装键：深度找，不认死名字', () {
      const text = '{"code":0,"msg":"ok","result":{"books":'
          '[{"bookSourceUrl":"https://a.com","bookSourceName":"A"}]}}';
      expect(parseBookSources(text).single.bookSourceName, 'A');
    });

    test('base64 塞在 JSON 字段里', () {
      // 分享站常见形态：外层是正常的 JSON 响应，书源数组 base64 后放在 data 里
      final text = jsonEncode({'code': 0, 'data': base64Encode(utf8.encode(src('')))});
      expect(parseBookSources(text).single.bookSourceUrl, 'https://a.com');
    });

    test('gzip 后的 base64 塞在 JSON 字段里', () {
      final text = jsonEncode({'bookSource': base64Encode(gzip.encode(utf8.encode(src(''))))});
      expect(parseBookSources(text).length, 1);
    });

    test('字段里的双重编码还带注释尾逗号', () {
      const loose = '[{"bookSourceUrl":"https://a.com", // 名字缺省用域名\n}]';
      final text = jsonEncode({'data': base64Encode(utf8.encode(loose))});
      expect(parseBookSources(text).single.bookSourceUrl, 'https://a.com');
    });

    test('普通规则串不会被误当包装内容解', () {
      // 值里全是 { } 与正则的短串不该触发递归，结果只有那一条书源
      const text = '{"bookSourceUrl":"https://a.com","bookSourceName":"A",'
          '"ruleSearch":{"bookList":"class.novels;;tag.ul","name":"text()##\\\\s+##"}}';
      expect(parseBookSources(text).length, 1);
    });

    test('「书源名 → 对象」的 map 形态用键名补名字', () {
      const text = '{"起点": {"url": "https://qd.com", "searchUrl": "/s?kw={{key}}"}}';
      final s = parseBookSources(text).single;
      expect(s.bookSourceName, '起点');
      expect(s.bookSourceUrl, 'https://qd.com');
    });

    test('连 URL 特征都没有的裸 url 不当书源', () {
      // 业务数据里的一条 {"url": ...} 被当书源收进来，列表会多出一排打不开的假源
      expect(parseBookSources('{"url":"https://a.com"}'), isEmpty);
    });

    test('书籍分享码算条数，不当书源，也不报"无法解析"', () {
      const text = '[{"bookName":"星渊纪元","author":"张三","origin":"https://a.com",'
          '"tocUrl":"https://a.com/1/chapters.html"}]';
      final r = parseBookSourcesDetailed(text);
      expect(r.sources, isEmpty);
      expect(r.bookShares, 1);
      expect(r.dropped, 0);
      expect(ImportResult(bookShares: r.bookShares).summary, '内容是书籍分享码（1 条），不是书源');
    });

    test('坏 JSON 不抛异常，只得到空结果', () {
      expect(parseBookSources('<html><body>不存在</body></html>'), isEmpty);
      expect(parseBookSources('{"bookSourceUrl": [1,2]}'), isEmpty);
      expect(parseBookSources('{'), isEmpty);
    });

    test('深层嵌套的畸形结构不炸、不误收', () {
      final text = '${'[' * 300}[]${']' * 300}';
      expect(parseBookSources(text), isEmpty);
    });

    test('订阅列表（一串 URL）不会被当成书源，也不崩', () {
      expect(parseBookSources('["https://a/1.json","https://b/2.json"]'), isEmpty);
    });
  });

  group('B 字段别名对齐', () {
    test('url / name / group / type 别名各取第一个非空', () {
      const text = '[{"baseUrl":"https://x.com","sourceName":"小站",'
          '"group":"网络小说","sourceType":1}]';
      final s = parseBookSources(text).single;
      expect(s.bookSourceUrl, 'https://x.com');
      expect(s.bookSourceName, '小站');
      expect(s.bookSourceGroup, '网络小说');
      expect(s.isNovel, false);
    });

    test('已有规范值绝不被别名覆盖', () {
      const text = '{"bookSourceUrl":"https://canonical","url":"https://alias",'
          '"bookSourceName":"实名","name":"别名"}';
      final j = extractSourceCandidates(text).candidates.single;
      expect(j['bookSourceUrl'], 'https://canonical');
      expect(j['bookSourceName'], '实名');
    });

    test('缺名字时用域名兜底，不留一排未命名', () {
      final s = parseBookSources('[{"bookSourceUrl":"https://www.qd.com/books"}]').single;
      expect(s.bookSourceName, 'www.qd.com');
    });

    test('header 是对象时存成合法 JSON 文本', () {
      const text = '[{"bookSourceUrl":"https://a","header":{"User-Agent":"okhttp/4"}}]';
      final s = parseBookSources(text).single;
      expect(s.header, '{"User-Agent":"okhttp/4"}');
      expect((jsonDecode(s.header!) as Map).cast<String, dynamic>(), {'User-Agent': 'okhttp/4'});
    });

    test('searchUrl 在 ruleSearch 里也认', () {
      const text = '[{"bookSourceUrl":"https://a",'
          '"ruleSearch":{"bookList":"class.item","searchUrl":"/api?kw={{key}}"}}]';
      final s = parseBookSources(text).single;
      expect(s.searchUrl, '/api?kw={{key}}');
      expect(s.ruleSearch.bookList, 'class.item');
    });

    test('searchUrl 数组形态取第一条，不拼成一坨', () {
      const text = '[{"bookSourceUrl":"https://a","searchUrl":'
          '[{"name":"PC","url":"https://x/s?kw={{key}}"},{"url":"https://y/s"}]}]';
      final s = parseBookSources(text).single;
      expect(s.searchUrl, 'https://x/s?kw={{key}}');
    });

    test('exploreUrl 数组拼回 名称::url 换行格式', () {
      const text = '[{"bookSourceUrl":"https://a","exploreUrl":'
          '[{"title":"玄幻","url":"https://x/fantasy"},{"name":"都市","url":"https://x/city"}]}]';
      final s = parseBookSources(text).single;
      expect(s.exploreUrl, '玄幻::https://x/fantasy\n都市::https://x/city');
    });

    test('enabled 的 0/1 与 enable 别名', () {
      expect(parseBookSources('[{"bookSourceUrl":"https://a","enabled":0}]').single.enabled, false);
      expect(parseBookSources('[{"bookSourceUrl":"https://a","enable":1}]').single.enabled, true);
      expect(parseBookSources('[{"bookSourceUrl":"https://a","enable":"false"}]')
          .single
          .enabled, false);
    });

    test('customOrder / weight 的字符串数字', () {
      final s = parseBookSources('[{"bookSourceUrl":"https://a","customOrder":"5","weight":"100"}]')
          .single;
      expect(s.customOrder, 5);
      expect(s.weight, '100');
    });

    test('规则子对象别名 searchRule → ruleSearch，字段别名 booklist/bookName', () {
      const text = '[{"bookSourceUrl":"https://a","searchRule":{"booklist":"class.item",'
          '"bookName":"{{..}}","authorName":"甲"}}]';
      final s = parseBookSources(text).single;
      expect(s.ruleSearch.bookList, 'class.item');
      expect(s.ruleSearch.name, '{{..}}');
      expect(s.ruleSearch.author, '甲');
    });

    test('规则里认不出的键保留，导出不丢 Legado 其它字段', () {
      const text = '[{"bookSourceUrl":"https://a","ruleToc":{"chapterList":"tag.li",'
          '"chapterName":"tag.a@text","updateTime":"7"}}]';
      final s = parseBookSources(text).single;
      expect(s.ruleToc.chapterList, 'tag.li');
      expect(s.ruleToc.updateTime, '7');
      final rawToc = s.toJson()['ruleToc'] as Map;
      expect(rawToc['chapterList'], 'tag.li');
      expect(rawToc['updateTime'], '7');
    });

    test('扁平写法只在主字段真在顶层时建组，不凭空造出 ruleToc', () {
      const text = '[{"bookSourceUrl":"https://a","name":"某书","author":"甲"}]';
      final s = parseBookSources(text).single;
      expect(s.ruleBookInfo.name, '某书');
      expect(s.ruleBookInfo.author, '甲');
      // chapterList 为空会让目录解析退化成"整页每个节点都是一章"
      expect(s.ruleToc.chapterList, isEmpty);
      expect(s.ruleSearch.bookList, isEmpty);
    });

    test('书源导出再导入不需要第二次修复，字段完全一致', () {
      const legacy = '[{bookSourceUrl: \'https://a.com\', sourceName: \'旧格式站\','
          ' enable: 1, header: {"User-Agent":"x"},'
          ' searchRule: {booklist: \'class.item\', searchUrl: \'/s?kw={{key}}\'},'
          ' tocRule: {chapterList: \'tag.li\', chapterName: \'tag.a@text\'}}]';
      final first = parseBookSources(legacy).single;
      final again = BookSource.fromJson(jsonDecode(jsonEncode(first.toJson())));
      expect(again.bookSourceUrl, first.bookSourceUrl);
      expect(again.bookSourceName, '旧格式站');
      expect(again.enabled, first.enabled);
      expect(again.header, first.header);
      expect(again.searchUrl, first.searchUrl);
      expect(again.ruleSearch.bookList, 'class.item');
      expect(again.ruleToc.chapterList, 'tag.li');
      expect(again.ruleToc.chapterName, 'tag.a@text');
    });
  });

  group('统计口径', () {
    test('缺 URL 的条目计入 dropped', () {
      const text = '[{"bookSourceName":"无URL"},{"bookSourceUrl":"https://a"}]';
      final r = parseBookSourcesDetailed(text);
      expect(r.sources.length, 1);
      expect(r.dropped, 1);
    });

    test('ImportResult 把分享码与超长一并如实告知', () {
      const r = ImportResult(added: 2, bookShares: 3, truncated: true);
      expect(r.summary, '新增 2，另有 3 条书籍分享码不是书源，内容过长，超出部分未解析');
    });
  });
}

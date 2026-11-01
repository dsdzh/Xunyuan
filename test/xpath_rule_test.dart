import 'package:html/dom.dart' as h;
import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/rule_engine.dart';

const html = '''
<html><head><title>书栈网</title>
<meta property="og:novel:category" content="玄幻奇幻">
</head><body>
<div id="s1" class="box">
  <ul>
    <li class="item"><a href="/book/1.html" title="星渊纪元 第一卷">星渊纪元</a><span class="num">12万字</span></li>
    <li class="item"><a href="/book/2.html" title="归途">归途</a><span class="num">8万字</span></li>
    <li class="item"><a href="/book/3.html">断章</a></li>
  </ul>
  <p class="ad">广告位</p>
</div>
<div class="pager"><a href="/list_2.html">下一页</a></div>
</body></html>
''';

void main() {
  setUp(() => RuleEngine.warnings.clear());

  List<String> get(String rule) => RuleEngine.getStringList(html, rule);

  group('C @xpath: 子集', () {
    test('节点集：bookList 用 //li[@class=...] 取到元素', () {
      final nodes = RuleEngine.getElements(html, '@xpath://li[@class="item"]');
      expect(nodes.length, 3);
      expect(RuleEngine.getStringList(html, '@xpath://li[@class="item"]/a/text()'),
          ['星渊纪元', '归途', '断章']);
    });

    test('属性步：XPath 写法与 Legado 尾缀写法同结果', () {
      final a = get('@xpath://li[@class="item"]/a/@href');
      final b = get('@xpath://li[@class="item"]/a@href');
      expect(a, ['/book/1.html', '/book/2.html', '/book/3.html']);
      expect(b, a);
    });

    test('尾缀 @text 取元素全文本', () {
      expect(get('@xpath://div[@class="pager"]/a@text'), ['下一页']);
    });

    test('位置谓词：[n] / [last()] / [position()<n]', () {
      expect(get('@xpath://ul/li[2]/a/text()'), ['归途']);
      expect(get('@xpath://ul/li[last()]/a/text()'), ['断章']);
      expect(get('@xpath://ul/li[position()<3]/a/text()'), ['星渊纪元', '归途']);
      expect(get('@xpath://ul/li[1]/a/@title'), ['星渊纪元 第一卷']);
    });

    test('函数谓词：contains / starts-with', () {
      expect(get('@xpath://a[contains(@href,"book")]/text()'), ['星渊纪元', '归途', '断章']);
      expect(get('@xpath://a[starts-with(@href,"/book/1")]/text()'), ['星渊纪元']);
      expect(get('@xpath://span[contains(.,"万字")]'), ['12万字', '8万字']);
    });

    test('属性存在与文本相等', () {
      expect(get('@xpath://a[@title]/text()'), ['星渊纪元', '归途']);
      expect(get('@xpath://span[text()="8万字"]'), ['8万字']);
      expect(get('@xpath://p[.="广告位"]/text()'), ['广告位']);
    });

    test('and / or / not()', () {
      expect(get('@xpath://li[@class="item" and position()>1]/a/text()'), ['归途', '断章']);
      expect(get('@xpath://li[@class="ad" or @class="item"]/a/text()'),
          ['星渊纪元', '归途', '断章']);
      expect(get('@xpath://li[not(@class)]/a/text()'), isEmpty);
      expect(get('@xpath://a[not(@title)]/text()'), ['断章', '下一页']);
    });

    test('串联谓词', () {
      expect(get('@xpath://li[@class="item"][1]/a/@href'), ['/book/1.html']);
    });

    test('绝对路径与后代', () {
      expect(get('@xpath:/html/body/div[@id="s1"]/ul/li[1]/a/text()'), ['星渊纪元']);
      expect(get('@xpath://div[@class="box"]//text()'),
          containsAllInOrder(['星渊纪元', '归途', '断章', '广告位']));
    });

    test('meta 属性值（含冒号的属性值）', () {
      expect(get('@xpath://meta[@property="og:novel:category"]/@content'), ['玄幻奇幻']);
    });

    test('节点测试 * 与 node()', () {
      expect(get('@xpath://head/*'), ['书栈网', '']);
      expect(get('@xpath://title/node()'), ['书栈网']);
    });

    test('并集 |', () {
      expect(get('@xpath://title | //div[@class="pager"]/a'), ['书栈网', '下一页']);
    });

    test('与正则段组合仍生效', () {
      expect(get('@xpath://span/text()###(\\d+)'), ['12', '8']);
      expect(get(r'@xpath://span/text()##(\d+)(\D+)##$1'), ['12', '8']);
    });

    test('回退 ;; 让 xpath 与 css 混写', () {
      expect(get('@xpath://li[@class="nope"]/a/text();;class.item@tag.a@text'),
          ['星渊纪元', '归途', '断章']);
    });

    test('选不中就是空，不猜', () {
      expect(get('@xpath://div[@class="不存在"]/a'), isEmpty);
      expect(get('@xpath://li[9]'), isEmpty);
      expect(get('@xpath://li[@class="item"]/a/@data-nothing'), isEmpty);
    });

    test('超出子集：记警告并返回空', () {
      for (final bad in [
        '@xpath://p/following-sibling::div', // 轴
        '@xpath://*[normalize-space()="星渊纪元"]', // 不认识的函数
        '@xpath://ns:title', // 命名空间前缀
        '@xpath://div[@href="x', // 括号不配对
        '@xpath://a/@href/text()', // 属性后面还有步
      ]) {
        expect(get(bad), isEmpty, reason: bad);
      }
      expect(RuleEngine.warnings.where((w) => w.startsWith('暂不支持 XPath')).length, 5);
    });

    test('脏数据里 xpath 不会把整页当结果', () {
      // bookList 命不中时上层拿到空列表，而不是 body 的每个节点
      expect(RuleEngine.getElements(html, '@xpath://ul[@class="nope"]/li'), isEmpty);
    });

    test('按 _parseBookList 的两步用法：列表节点 + 条目内字段规则', () {
      final items = RuleEngine.getElements(html, '@xpath://li[@class="item"]');
      expect(items, hasLength(3));
      final names = <String>[];
      final urls = <String>[];
      for (final it in items) {
        // 上层把每个条目摊成片段，再在片段上跑字段规则
        final frag = (it as h.Element).outerHtml;
        names.add(RuleEngine.getString(frag, '@xpath://a/text()'));
        urls.add(RuleEngine.getString(frag, '@xpath://a/@href'));
      }
      expect(names, ['星渊纪元', '归途', '断章']);
      expect(urls, ['/book/1.html', '/book/2.html', '/book/3.html']);
      expect(names.every((n) => !RuleEngine.containsMarkup(n)), true);
    });
  });
}

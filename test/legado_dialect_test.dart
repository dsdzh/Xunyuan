import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/rule_engine.dart';

/// 第十四轮：真实书源里的 Legado/jsoup 方言。
/// 每条用例都对应线上书源的一条原句（注释里标了来源写法）。
const html = '''
<!DOCTYPE html><html><head>
<meta property="og:novel:author" content="张三">
<meta property="og:novel:category" content="玄幻">
<meta property="og:novel:status" content="连载">
<meta property="og:novel:update_time" content="2026-11-05 10:00">
</head><body>
<div class="prenext"><span><a href="/p1">上一页</a></span><span><a href="/p3">下一页</a></span></div>
<dl class="ml"><dt>章节</dt><dd><a href="/c1">第一章</a></dd><dd>更新时间：2026-11-05</dd></dl>
<dl class="b0"><dt>书封</dt><dd><img src="/cover.jpg"></dd><dd>更新<a href="/c1">第一章</a></dd></dl>
<span>类别：玄幻</span>
<div class="box">正文段落<span>标签</span>尾巴</div>
<div class="booklist"><a href="/b1">书一</a><a href="/b2">书二</a><a href="/b3">书三</a></div>
<div class="chapter-table"><a href="/c1">第一章</a><a href="/c2">第二章</a></div>
<div class="tag"><a href="/t1">玄幻</a><a href="/t2">连载</a></div>
<table id="author"><tbody><tr><td>作　者：张三</td></tr><tr><td>类别：玄幻</td></tr></tbody></table>
</body></html>
''';

const jsonBody = '''
{"data":{"book_data":[{"book_name":"A","score":9.1}],"list":[{"title":"B"}]},
 "items":[{"articlename":"C","author":"甲"},{"articlename":"D","author":"乙"}]}
''';

const jsonArrayRoot = '''
[{"articlename":"甲书","author":"作者A"},{"articlename":"乙书","author":"作者B"}]
''';

void main() {
  setUp(() => RuleEngine.warnings.clear());

  List<String> get(String rule) => RuleEngine.getStringList(html, rule);

  group('jsoup 专有筛选（package:html 不认）', () {
    test(':contains() / :containsOwn() 对 text()/ownText() 生效', () {
      // 来看文学：span:contains(类别：)@text
      expect(get('span:contains(类别：)@text'), ['类别：玄幻']);
      expect(get('span:contains(类别)@text'), ['类别：玄幻']);
      // 来看文学的 `:contains()` 写法
      expect(get('class.box:contains(正文段落)@ownText'), ['正文段落 尾巴']);
      expect(get('class.box:contains(标签尾巴)@text'), ['正文段落标签尾巴']);
      expect(get('class.box:containsOwn(尾巴)'), ['正文段落标签尾巴']);
      // :containsOwn 只看 ownText：后代元素里的文字不算
      expect(get('class.box:containsOwn(标签)'), isEmpty);
      expect(get('span:containsOwn(标签)'), ['标签']);
      expect(get('span:contains(不存在)@text'), isEmpty);
    });

    test(':matches() / :matchesOwn() 是正则', () {
      expect(get(r'a:matches(第[一二]组)'), isEmpty);
      expect(get('class.chapter-table@tag.a:matches(^第[一二]章)'), ['第一章', '第二章']);
      expect(get('class.box:matches(正文段落)'), ['正文段落标签尾巴']);
      // 非法正则：不猜，整条出空
      expect(get(r'a:matches(第[一二)'), isEmpty);
    });

    test('[attr~=正则] 按 jsoup 的正则 find，不是 CSS 词匹配', () {
      // 艾途/来看文学：[property~=category|update_time]@content
      expect(get(r'[property~=category|update_time]@content'), ['玄幻', '2026-11-05 10:00']);
      // CSS 词匹配写法（空格分隔的值）不受影响
      const rel = '<a href="/a.html" rel="nofollow me">A</a><a href="/b.htm" rel="bookmark">B</a>';
      expect(RuleEngine.getStringList(rel, r'[rel~=nofollow]@href'), ['/a.html']);
      expect(RuleEngine.getStringList(rel, r'[href$=".html"]@href'), ['/a.html']);
    });

    test('@ownText 只取直属文本', () {
      expect(get('class.box@ownText'), ['正文段落 尾巴']);
      expect(get('class.box@text'), ['正文段落标签尾巴']);
    });
  });

  group('下标方言', () {
    test('负数下标：.-1 / .-2 / [-1] / .!-1', () {
      expect(get('class.booklist.0@tag.a.-1@text'), ['书三']);
      expect(get('class.booklist.0@tag.a.-2@text'), ['书二']);
      expect(get('class.booklist.0@tag.a[-1]@text'), ['书三']);
      expect(get('class.booklist.0@tag.a.!-1@text'), ['书三']);
      // 真实源：来看文学 class.b0@dd.-1@a@text
      expect(get('class.b0@dd.-1@a@text'), ['第一章']);
      expect(get('class.prenext.0@tag.span.-1@text'), ['下一页']);
    });

    test('越界负数出空，不钳到首元素', () {
      expect(get('class.booklist.0@tag.a[-9]@text'), isEmpty);
      expect(get('class.booklist.0@tag.a.-9@text'), isEmpty);
    });

    test('[] 是闭区间，两端可为负且能倒序', () {
      expect(get('class.booklist.0@tag.a[1:2]@text'), ['书二', '书三']);
      expect(get('class.booklist.0@tag.a[-1:0]@text'), ['书三', '书二', '书一']);
      expect(get('class.booklist.0@tag.a[0:9]@text'), ['书一', '书二', '书三']);
      expect(get('class.booklist.0@tag.a[9:9]@text'), isEmpty);
      expect(get('class.booklist.0@tag.a[0:2:2]@text'), ['书一', '书三']);
      expect(get('class.booklist.0@tag.a[0:2:0]@text'), isEmpty);
    });

    test('! 也是下标分隔符（真实源 tag.tr!0、tag.a.!0:1）', () {
      expect(get('#author@tbody@tr!0@text'), ['作　者：张三']);
      expect(get('class.tag.0@tag.a.!0:1@text'), ['玄幻', '连载']);
      expect(get('class.tag.0@tag.a.!1@text'), ['连载']);
    });

    test('@ 与 . 都是步骤分隔符：@ 后裸标签不再被当 class 吞掉', () {
      // 来看文学 class.b0@img@src
      expect(get('class.b0@img@src'), ['/cover.jpg']);
      // 就爱文学 #author@tbody@tr!0
      expect(get('#author@tbody@tr!0@text'), ['作　者：张三']);
      // 原生 CSS 段 + Legado 下标混排（真实源 lastChapter）
      expect(get('.chapter-table a.0@text'), ['第一章']);
      expect(get('class.chapter-table@tag.a@text'), ['第一章', '第二章']);
      // 对照：老写法不变
      expect(get('class.booklist@tag.a@text'), ['书一', '书二', '书三']);
      expect(get('class.booklist.0@tag.a.0@text'), ['书一']);
    });
  });

  group('组合分隔符、@@ 标志与 {{}} 模板', () {
    test('|| 取第一个非空分支', () {
      expect(get('class.nosuch@text||class.booklist@tag.a.0@text'), ['书一']);
      expect(get('class.booklist@tag.a.0@text||class.nosuch@text'), ['书一']);
      expect(get('class.nosuch@text||class.alsoNoSuch@text'), isEmpty);
    });

    test('分隔符按「字符串里最先出现」的算，没有优先级', () {
      // && 在前：先整体拼接，|| 只是拼接项内部的分隔符
      expect(get('class.booklist@tag.a.0@text&&class.nosuch@text||class.tag.0@tag.a.0@text'),
          ['书一', '玄幻']);
      expect(get('class.booklist@tag.a[0:0]@text&&class.tag@tag.a@text'), ['书一', '玄幻', '连载']);
      expect(get('class.tag@tag.a@text%%class.booklist@tag.a@text'), ['玄幻', '连载']);
    });

    test('@@ 是模式标志，剥掉后按默认规则解析', () {
      expect(get('@@class.ml@text##更新时间：'), ['章节第一章2026-11-05']);
      expect(get('@@dd.-1@a@text'), ['第一章']);
    });

    test('{{子规则}} 插值：字面量保留，子规则结果以换行连接', () {
      expect(get('https://x.com/book/{{class.booklist@tag.a.0@text}}'),
          ['https://x.com/book/书一']);
      // 来看文学 ruleBookInfo 的原句形态：模板内部的 ## 属于子规则
      expect(get('{{class.ml@text##更新时间：}} • {{span:contains(类别：)@text##^类别：}}'),
          ['章节第一章2026-11-05 • 玄幻']);
      // 多条子结果以换行连接成一个字符串（Legado 语义）
      expect(get('{{class.booklist@tag.a@text}}'), ['书一\n书二\n书三']);
      // 来看文学 kind 的原句：两个模板块以换行分隔，块内的 ## 不参与外层切分
      expect(
          get('{{@@span:contains(类别：)@text##^类别：}}\n{{@@dd:contains(更新时间：)@text##.*更新时间：}}'),
          ['玄幻\n2026-11-05']);
      // 模板结果上的单个外层 ## 仍是「删除匹配」（Legado 语义），
      // 且 `{1}` 这种正则量词的花括号不会被误认成模板起点
      expect(get('{{class.booklist@tag.a@text}}##书'), ['一\n二\n三']);
      expect(get('{{class.booklist@tag.a@text}}##书{1}(.)'), ['\n\n']);
      // JSON 模板（真实源的 bookUrl 写法）
      expect(
          RuleEngine.getStringList(
              jsonBody, r'https://x.com/book/{{$.data.book_data[0].book_name}}', isJson: true),
          ['https://x.com/book/A']);
      // 子规则命中 Map/List 时留空：不能把 Dart 字面量拼进 URL
      expect(RuleEngine.getStringList(jsonBody, r'/book/{{$.data}}', isJson: true), ['/book/']);
    });
  });

  group('JSON 方言', () {
    test('searchUrl 直接返回数组根时 \$[*] 可用', () {
      expect(RuleEngine.getStringList(jsonArrayRoot, r'$[*].articlename', isJson: true), ['甲书', '乙书']);
      expect(RuleEngine.getStringList(jsonArrayRoot, r'$[0].author', isJson: true), ['作者A']);
    });

    test('对象根写法不受影响', () {
      expect(RuleEngine.getStringList(jsonBody, r'$.items[*].articlename', isJson: true), ['C', 'D']);
      expect(RuleEngine.getStringList(jsonBody, r'$..score', isJson: true), ['9.1']);
    });
  });

  test('暂不支持的 JS 规则：记警告出空，不猜', () {
    expect(get('class.booklist@tag.a@text<js>result;</js>'), isEmpty);
    expect(RuleEngine.warnings.any((w) => w.contains('暂不支持 JS 规则')), true);
  });
}

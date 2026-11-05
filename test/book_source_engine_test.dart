import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/book_source_engine.dart';
import 'package:xunyuan/models/book_source.dart';

BookSource src({String? header, String? exploreUrl, String? url = 'https://site.com'}) =>
    BookSource.fromJson({
      'bookSourceUrl': url,
      'bookSourceName': '甲',
      'header': header,
      'exploreUrl': exploreUrl,
    });

void main() {
  group('书源 header 三种真实形态', () {
    test('合法 JSON 对象', () {
      expect(
        BookSourceEngine(src(header: '{"User-Agent":"okhttp","Referer":"https://site.com"}')).headers,
        {'User-Agent': 'okhttp', 'Referer': 'https://site.com'},
      );
    });

    test('合法 JSON 数组 [{key,value}]', () {
      expect(
        BookSourceEngine(src(header: '[{"key":"User-Agent","value":"UA"},{"key":"X","value":null}]')).headers,
        {'User-Agent': 'UA', 'X': ''},
      );
    });

    /// 转换站和手写书源都爱这么写。以前掉进裸文本分支，切出 `{'cookie'` 这种
    /// 带花括号的 header 名，dio 直接抛 Invalid HTTP header field name 打死整源。
    test('单引号伪 JSON', () {
      final h = BookSourceEngine(src(header: "{'cookie':'abc=1','User-Agent':'Mozilla/5.0'}")).headers;
      expect(h['cookie'], 'abc=1');
      expect(h['User-Agent'], 'Mozilla/5.0');
      expect(h.keys.toList(), ['cookie', 'User-Agent']);
    });

    test('裸文本 User-Agent: xxx 换行 Referer: yyy', () {
      expect(BookSourceEngine(src(header: 'User-Agent: Mozilla\nReferer: https://site.com')).headers,
          {'User-Agent': 'Mozilla', 'Referer': 'https://site.com'});
    });

    test('名字不合法的项丢掉（dio 会抛），值带 CR/LF 的丢掉（响应头注入）', () {
      final h = BookSourceEngine(
              src(header: '{"a b":"x","cookie":"y","ok":"1","bad":"v\r\nX-Injected: 1","":"z"}'))
          .headers;
      expect(h, {'cookie': 'y', 'ok': '1'});
    });

    test('空/纯空白/无冒号junk 都是空头', () {
      expect(BookSourceEngine(src()).headers, isEmpty);
      expect(BookSourceEngine(src(header: '   ')).headers, isEmpty);
      expect(BookSourceEngine(src(header: 'not a header')).headers, isEmpty);
    });
  });

  group('exploreCategories 方言', () {
    test('名称::url 换行分段', () {
      final c = BookSourceEngine.exploreCategories(src(exploreUrl: '玄幻::/x/{page}.html\n都市::/y.html'));
      expect(c.map((e) => (e.title, e.url)).toList(), [('玄幻', '/x/{page}.html'), ('都市', '/y.html')]);
    });

    test('&& 也要分段（Legado 按 (&&|\n)+ 切，以前一行多类整条丢掉）', () {
      final c = BookSourceEngine.exploreCategories(src(exploreUrl: 'A::/a&&B::/b\nC::/c'));
      expect(c.map((e) => e.title).toList(), ['A', 'B', 'C']);
    });

    /// 起点中文、番茄这类大站源的写法（22 个真实源里占 6 个）。url 为空的是分组标题，
    /// 不是一页可请求的列表；url 可以是站内相对路径。
    test('JSON 数组写法', () {
      const raw = r'''
[
{"title": "男生榜单","url": "","style": {"layout_flexGrow": 0}},
{"title": "月票榜","url": "/rank/yuepiao/page{{page}}/","style": {"layout_flexGrow": 1}},
{"title": "推荐榜","url": "https://m.site.com/rank/rec/page{{page}}/"}
]
''';
      final c = BookSourceEngine.exploreCategories(src(exploreUrl: raw));
      expect(c.length, 2);
      expect(c.first.title, '月票榜');
      expect(c.first.url, '/rank/yuepiao/page{{page}}/');
      expect(c.last.url, 'https://m.site.com/rank/rec/page{{page}}/');
    });

    test('JSON 数组里标题缺失时用 url 顶上，元素形态不对就跳过', () {
      final c = BookSourceEngine.exploreCategories(
          src(exploreUrl: r'''[{"url":"/a/1"},{"title":"乙"},{"title":"丙","url":"/c/1"}]'''));
      expect(c.map((e) => (e.title, e.url)).toList(), [('/a/1', '/a/1'), ('丙', '/c/1')]);
    });

    test('JS 写法解析不出分类（发现页据此不列它，免得点进去空白）', () {
      expect(BookSourceEngine.exploreCategories(src(exploreUrl: '@js:\nsort=[];')).toList(), isEmpty);
      expect(BookSourceEngine.exploreCategories(src(exploreUrl: '<js>x()</js>')).toList(), isEmpty);
      expect(BookSourceEngine.exploreCategories(src()).toList(), isEmpty);
    });

    test('数组写法解析失败（截断的 JSON）退回名称::url 那条路，不抛', () {
      final c = BookSourceEngine.exploreCategories(src(exploreUrl: '[{"title":"甲","url":'));
      expect(c, isEmpty);
    });

    test('名称为空::url 不算分类', () {
      expect(BookSourceEngine.exploreCategories(src(exploreUrl: '::/a.html')).toList(), isEmpty);
    });
  });

  group('书源凭证只发同站', () {
    const cred = '{"cookie":"sid=SECRET","Authorization":"Bearer t",'
        '"User-Agent":"UA","Referer":"https://www.qidian.com"}';
    BookSourceEngine qidian() => BookSourceEngine(src(header: cred, url: 'https://www.qidian.com/'));

    test('同主机与自己的子域：一个 header 都不脱', () {
      for (final u in ['https://www.qidian.com/book/1', 'https://m.qidian.com/query']) {
        expect(qidian().headersFor(u).keys.toList(),
            ['cookie', 'Authorization', 'User-Agent', 'Referer'],
            reason: u);
      }
    });

    test('页面里塞别人域名：cookie/Authorization 脱掉，UA/Referer 留着', () {
      expect(qidian().headersFor('https://attacker.example/x').keys.toList(),
          ['User-Agent', 'Referer']);
    });

    test('二级公有后缀多取一段：a.co.uk 的 cookie 不给 b.co.uk', () {
      final e = BookSourceEngine(
          src(header: '{"cookie":"x=1","User-Agent":"UA"}', url: 'https://www.a.co.uk'));
      expect(e.headersFor('https://www.b.co.uk/x').keys.toList(), ['User-Agent']);
      expect(e.headersFor('https://m.a.co.uk/x').keys.toList(), ['cookie', 'User-Agent']);
    });

    test('com.cn 同理', () {
      final e = BookSourceEngine(
          src(header: '{"cookie":"x=1","User-Agent":"UA"}', url: 'https://a.com.cn'));
      expect(e.headersFor('https://b.com.cn/x').keys.toList(), ['User-Agent']);
      expect(e.headersFor('https://m.a.com.cn/x').keys.toList(), ['cookie', 'User-Agent']);
    });

    test('IP 书源按整串比：本机端口的凭证不给局域网另一台', () {
      final e = BookSourceEngine(
          src(header: '{"cookie":"x=1","User-Agent":"UA"}', url: 'http://127.0.0.1:8931'));
      expect(e.headersFor('http://127.0.0.1:8931/book/1').length, 2);
      expect(e.headersFor('http://192.168.0.9:8931/book/1').keys.toList(), ['User-Agent']);
    });

    test('书源主页解析不出主机时不设限（老源别被误伤）', () {
      final e = BookSourceEngine(src(header: '{"cookie":"x=1"}', url: '未命名'));
      expect(e.headersFor('https://anything.example/'), {'cookie': 'x=1'});
    });

    test('规则 options 里的 header 走同一道闸：值带 CR/LF 的直接丢', () {
      final e = BookSourceEngine(src(header: '{"User-Agent":"UA"}'));
      expect(
          e.headersFor('https://site.com/s',
                  extra: {'X-A': 'v\r\nX-Injected: 1', 'ok': '1'})
              .keys
              .toList(),
          ['User-Agent', 'ok']);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/rule_engine.dart';

void main() {
  test('CSS 选择器 + 属性抽取', () {
    const html = '<div class="bookitem"><a href="/book/1.html">书名一</a></div>'
        '<div class="bookitem"><a href="/book/2.html">书名二</a></div>';
    final names = RuleEngine.getStringList(html, 'class.bookitem.tag.a@text');
    expect(names, ['书名一', '书名二']);
    final urls = RuleEngine.getStringList(html, 'class.bookitem.tag.a@href');
    expect(urls, ['/book/1.html', '/book/2.html']);
  });

  test('正则替换', () {
    const html = '<div id="content">正文<script>x</script>结尾</div>';
    final text = RuleEngine.getString(html, 'id.content@html##<script.*?>.*?</script>####');
    expect(text.contains('x'), false);
  });

  test('JSONPath', () {
    const json = '{"data":{"list":[{"name":"A"},{"name":"B"}]}}';
    final names = RuleEngine.getStringList(json, r'$.data.list[*].name', isJson: true);
    expect(names, ['A', 'B']);
  });

  test('回退规则 ;;', () {
    const html = '<div class="other">x</div>';
    final r = RuleEngine.getString(html, 'class.missing@text;;class.other@text');
    expect(r, 'x');
  });
}

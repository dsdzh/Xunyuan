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

  test('CSS 伪类原生回退（nth-child 按 Legado 1 起算）', () {
    const html = '<ul><li>甲</li><li>乙</li><li>丙</li></ul>';
    expect(RuleEngine.getString(html, 'tag.li:nth-child(2)@text'), '乙');
    expect(RuleEngine.getString(html, 'tag.li:nth-child(1)@text'), '甲');
    expect(RuleEngine.getString(html, 'tag.li:last-child@text'), '丙');
  });

  test('CSS 属性选择器原生回退', () {
    const html = '<div><a href="/x/1.html">一</a><a>二</a></div>';
    final r = RuleEngine.getStringList(html, 'tag.a[href]@text');
    expect(r, ['一']);
  });

  test('引号不配对时 ;; 回退仍可拆分', () {
    const html = '<p class="hit">正文它\'s here</p><p class="fb">兜底</p>';
    final r = RuleEngine.getStringList(html, "text.它's here&&class.hit@text;;class.fb@text");
    expect(r.first.contains('它'), true);
  });

  test('[n] 下标与 [attr] 属性选择器区分', () {
    const html = '<ul><li>甲</li><li>乙</li></ul>';
    expect(RuleEngine.getString(html, 'tag.li[0]@text'), '甲');
    expect(RuleEngine.getString(html, 'tag.li[last]@text'), '乙');
  });

  test('畸形书源：超 64 位数字下标/伪类不抛异常', () {
    const html = '<ul><li>甲</li><li>乙</li><li>丙</li></ul>';
    // int.parse 会 FormatException，必须走 tryParse 兜底返回空
    expect(RuleEngine.getString(html, 'tag.li[0-99999999999999999999]@text'), '');
    expect(RuleEngine.getString(html, 'tag.li[last-99999999999999999999]@text'), '');
    expect(RuleEngine.getString(html, 'tag.li[99999999999999999999]@text'), '');
    expect(RuleEngine.getString(html, 'tag.li:nth-child(99999999999999999999)@text'), '');
    // 合法范围仍是原语义
    expect(RuleEngine.getString(html, 'tag.li[0-1]@text'), '甲');
  });

  test(r'JSONPath $..key 递归下降穿数组', () {
    const json = '{"data":{"chapters":[{"title":"第一章"},{"sub":{"title":"第二章"}}]}}';
    final t = RuleEngine.getStringList(json, r'$..title', isJson: true);
    expect(t, containsAll(<String>['第一章', '第二章']));
    // 末尾悬空点不能再 RangeError
    expect(RuleEngine.getStringList(json, r'$.data.', isJson: true), isNotEmpty);
  });

  test('纯文本以 [ 开头不得误判为 JSON', () {
    expect(ContentAnalyzer.isJsonContent('[第一卷] 从前有座山\n正文……'), false);
    expect(ContentAnalyzer.isJsonContent('{"a":1}'), true);
    expect(ContentAnalyzer.isJsonContent('[1,2]'), true);
  });
}

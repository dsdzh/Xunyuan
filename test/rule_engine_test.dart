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

  test('nth-child 只数元素、1 起算：缩进排版的页面不能选错条目', () {
    // 真实书源页面几乎都是这种带换行缩进的排版，元素之间夹着空白文本节点。
    // package:html 的 nth-child 按「全部子节点」0 起算，会把空白节点算进下标，
    // 直接透传等于选出隔壁那一条（错书名/错章节比选不到更坏）。
    const html = '''
<ul>
  <li>甲</li>
  <li>乙</li>
  <li>丙</li>
  <li>丁</li>
</ul>''';
    expect(RuleEngine.getString(html, 'tag.li:nth-child(2)@text'), '乙');
    expect(RuleEngine.getString(html, 'tag.li:nth-child(3)@text'), '丙');
    expect(RuleEngine.getString(html, 'tag.li:nth-child(5)@text'), '');
    expect(RuleEngine.getStringList(html, 'tag.li:nth-child(odd)@text'), ['甲', '丙']);
    expect(RuleEngine.getStringList(html, 'tag.li:nth-child(even)@text'), ['乙', '丁']);
    expect(RuleEngine.getStringList(html, 'tag.li:nth-child(2n+1)@text'), ['甲', '丙']);
    expect(RuleEngine.getStringList(html, 'tag.li:nth-child(2n)@text'), ['乙', '丁']);
    expect(RuleEngine.getStringList(html, 'tag.li:nth-child(-n+2)@text'), ['甲', '乙']);
    expect(RuleEngine.getString(html, 'tag.li:nth-last-child(1)@text'), '丁');
    expect(RuleEngine.getString(html, 'tag.li:nth-last-child(2)@text'), '丙');
    // nth 挂在前一段时无法保证下标算在它自己的父节点上，维持原样（不接管、也不误报）
    expect(RuleEngine.getStringList(html, 'tag.li:nth-child(2) tag.b:nth-child(1)@text'), isEmpty);
  });

  test('nth-child 走 @css: 直路时同样按元素序', () {
    const html = '''
<ol>
  <li>一</li>
  <li>二</li>
  <li>三</li>
</ol>''';
    expect(RuleEngine.getString(html, '@css:li:nth-child(2)@text'), '二');
    expect(RuleEngine.getStringList(html, '@css:li:nth-child(2n+1)@text'), ['一', '三']);
    // nth 表达式解析不了（括号不配对）不能让整条规则抛异常
    expect(RuleEngine.getString(html, '@css:li:nth-child(2@text'), '');
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

  test(r'JSONPath $..["key"] 括号式递归下降', () {
    const json = '{"data":{"chapters":[{"title":"第一章"},{"sub":{"title":"第二章"}}]}}';
    final t = RuleEngine.getStringList(json, r'''$..['title']''', isJson: true);
    expect(t, containsAll(<String>['第一章', '第二章']));
  });

  test(r'正则替换 $N 单次展开：组值含 "$0" 字面量不被二次替换', () {
    // 旧下行循环：先替 $1 得到 "$0"，再在 i=0 把 "$0" 又替成正文 → 内容被复制（"$0y"）
    final r = RuleEngine.getStringList(r'$0y', r'$##(\$0)(y)##$1');
    expect(r, [r'$0']);
  });

  test(r'畸形 $..[ 规则不抛 RangeError', () {
    expect(RuleEngine.getStringList('{"a":[1,2]}', r'$..[', isJson: true), isEmpty);
    expect(RuleEngine.getStringList('{"a":[1,2]}', r'$..[title', isJson: true), isEmpty);
  });

  test('选择器未命中：HTML 内容不得被当成文本返回（独步小说网脏搜索结果）', () {
    // bookList=tag.tbody.0@tag.tr，无结果行里没有 <a>；旧实现把整段 <tr> 喂给 ##《|》
    // 后原样返回，书名变成一屏 markup，点进详情必失败。
    const empty = '<tr><td>没有找到包含：xingyuan的小说</td></tr>';
    expect(RuleEngine.getString(empty, r'tag.a.0@text##《|》'), isEmpty);
    expect(RuleEngine.getString(empty, r'tag.a.0@html##<[^>]*>##'), isEmpty);
    // 正常行不受影响
    const row = '<tr><td><a href="/book/1.html">《星渊纪元1》</a></td><td>作者甲</td></tr>';
    expect(RuleEngine.getString(row, r'tag.a.0@text##《|》'), '星渊纪元1');
    expect(RuleEngine.getString(row, 'tag.a.0@href'), '/book/1.html');
  });

  test('选择器未命中：纯文本内容仍保留正则兜底', () {
    const plain = '本章未完\n书名：星渊纪元1\n作者：甲';
    expect(RuleEngine.getString(plain, r'class.never@text###书名：\S+'), '书名：星渊纪元1');
    expect(RuleEngine.getString(plain, r'class.never@text##本章未完\n##'), '书名：星渊纪元1\n作者：甲');
  });

  test('containsMarkup 判定', () {
    expect(RuleEngine.containsMarkup('<tr><td>x</td></tr>'), true);
    expect(RuleEngine.containsMarkup('<!DOCTYPE html>'), true);
    expect(RuleEngine.containsMarkup('　　正文里没有标签，只有《书名》'), false);
  });

  test(r'深层嵌套 JSON 的 $..key 不 StackOverflow', () {
    final deep = '[' * 20000 + ']' * 20000; // 递归下降深度护栏须拦截
    expect(() => RuleEngine.getStringList(deep, r'$..title', isJson: true), returnsNormally);
  });
}

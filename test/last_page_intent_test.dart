import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/last_page_intent.dart';

void main() {
  test('请求上一章末页：只有那一章落地才算数，且只消费一次', () {
    final intent = LastPageIntent()..request(3);
    expect(intent.matches(3), true);
    expect(intent.take(3), true);
    expect(intent.take(3), false); // 后续 build 不能再把用户拽回末页
  });

  test('意图被后发跳章顶掉后，不得串到新章的末页', () {
    // 复现：第 4 章首页点「上一章」（请求 3 的末页，加载在途）→ 立刻点「下一章」
    // → 第 3 章那次加载作废、第 5 章落地。旧实现用单个 bool，第 5 章会被判成"该落末页"。
    final intent = LastPageIntent()..request(3);
    expect(intent.matches(5), false);
    expect(intent.take(5), false);
    expect(intent.take(3), false); // 已经作废，不能等第 3 章以后再冒出来
  });

  test('没有待处理意图时任何章都从首页开始', () {
    final intent = LastPageIntent();
    expect(intent.matches(0), false);
    expect(intent.take(0), false);
  });

  test('目录跳转清掉意图', () {
    final intent = LastPageIntent()
      ..request(3)
      ..clear();
    expect(intent.take(3), false);
  });
}

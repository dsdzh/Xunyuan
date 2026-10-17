import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/widgets/tab_switcher.dart';

/// 换页过渡的回归：IndexedStack 本身是瞬时替换，动画全靠 TabSwitcher 这一层
void main() {
  late StateSetter set;
  int index = 0;

  Future<void> pumpApp(WidgetTester tester, {Duration? duration}) async {
    index = 0;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          set = setState;
          return Scaffold(
            body: TabSwitcher(
              index: index,
              duration: duration ?? const Duration(milliseconds: 320),
              children: const [Text('甲'), Text('乙'), Text('丙')],
            ),
          );
        },
      ),
    ));
    await tester.pump();
  }

  // 限定在 TabSwitcher 子树里找：Scaffold/Navigator 自己也在祖先链上放了
  // IgnorePointer / Opacity，按祖先匹配会串台
  Finder layer<T>() =>
      find.descendant(of: find.byType(TabSwitcher), matching: find.byType(T));

  double opacity(WidgetTester tester) => tester.widgetList<Opacity>(layer<Opacity>()).single.opacity;

  double dx(WidgetTester tester) =>
      tester.widgetList<Transform>(layer<Transform>()).single.transform.getTranslation().x;

  bool ignoring(WidgetTester tester) =>
      tester.widgetList<IgnorePointer>(layer<IgnorePointer>()).first.ignoring;

  testWidgets('静止时完全不透明不偏移，动画期间挡住点击', (tester) async {
    await pumpApp(tester);
    expect(opacity(tester), 1.0, reason: '首屏不能停在半透明/偏移的中间帧');
    expect(dx(tester), 0.0);
    expect(ignoring(tester), isFalse);

    set(() => index = 2);
    await tester.pump();
    expect(opacity(tester), lessThan(1.0), reason: '换页必须真的在过渡');
    expect(ignoring(tester), isTrue);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 2);

    await tester.pumpAndSettle();
    expect(opacity(tester), 1.0);
    expect(dx(tester), 0.0);
    expect(ignoring(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('往后翻从右进、往前回退从左进', (tester) async {
    await pumpApp(tester);
    set(() => index = 2);
    await tester.pump(const Duration(milliseconds: 60));
    expect(dx(tester), greaterThan(0));
    await tester.pumpAndSettle();

    set(() => index = 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(dx(tester), lessThan(0));
    await tester.pumpAndSettle();
    expect(dx(tester), 0.0);
  });

  testWidgets('过渡曲线前快后慢，前 1/4 时间就走完大半', (tester) async {
    await pumpApp(tester, duration: const Duration(milliseconds: 400));
    set(() => index = 1);
    // 先给一帧让 didUpdateWidget 里的 forward(from: 0) 生效，再推 100ms
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 线性到此刻只走完 0.82~1.0 区间的 1/4（≈0.865），easeOutQuart 应已到 0.94 左右
    expect(opacity(tester), greaterThan(0.90), reason: '前快后慢才显得顺');
    await tester.pumpAndSettle();
    expect(opacity(tester), 1.0);
  });

  testWidgets('连点两次不会把画面卡在中间帧', (tester) async {
    await pumpApp(tester);
    set(() => index = 1);
    await tester.pump(const Duration(milliseconds: 80));
    set(() => index = 2);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpAndSettle();
    expect(opacity(tester), 1.0);
    expect(dx(tester), 0.0);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 2);
  });
}

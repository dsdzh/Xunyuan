import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:xunyuan/pages/search_page.dart';
import 'package:xunyuan/state/app_state.dart';

/// 搜索页顶栏与空状态的回归：输入框收成带边距的胶囊，空白处下拉/点击都能聚焦。
void main() {
  late FocusNode node;

  Future<void> pumpSearch(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<SourceState>(
        create: (_) => SourceState(),
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await tester.pumpAndSettle();
    node = tester.widget<TextField>(find.byType(TextField)).focusNode!;
  }

  testWidgets('搜索框收成胶囊，左右都留出边距', (tester) async {
    await pumpSearch(tester);
    final field = tester.getRect(find.byType(TextField));
    expect(field.left, greaterThan(0));
    // 默认 800 宽画布：右边还要放下两个 44 的图标，胶囊不该贴到屏幕右边缘
    expect(field.right, lessThan(800 - 44));
  });

  testWidgets('空状态下拉空白处聚焦搜索框', (tester) async {
    await pumpSearch(tester);
    expect(node.hasFocus, isFalse);
    await tester.drag(find.text('下拉或点击空白处聚焦搜索框'), const Offset(0, 120));
    await tester.pump();
    expect(node.hasFocus, isTrue);
  });

  testWidgets('空状态横向拖拽不该聚焦', (tester) async {
    await pumpSearch(tester);
    await tester.drag(find.text('下拉或点击空白处聚焦搜索框'), const Offset(120, 0));
    await tester.pump();
    expect(node.hasFocus, isFalse);
  });

  testWidgets('点空白处也聚焦搜索框', (tester) async {
    await pumpSearch(tester);
    // 空白处 = body 右下角，离提示文字很远的地方也得能点着
    await tester.tapAt(const Offset(700, 520));
    await tester.pump();
    expect(node.hasFocus, isTrue);
  });
}

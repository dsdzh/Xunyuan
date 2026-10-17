import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/widgets/display_scale.dart';

/// DisplayScale 自己造画布：给子树一个缩放后的逻辑尺寸，再等比画回满屏。
/// 关键是子树看到的 MediaQuery / 约束 / 命中坐标三者必须一致，否则
/// 阅读页分页会按错的宽度排版、点按钮会点偏。
void main() {
  const device = Size(800, 600);
  // 模拟雷电那台设备：dpr=3，逻辑 800x600
  const dpr = 3.0;

  Future<void> boot(
    WidgetTester tester, {
    required double dpi,
    required double screen,
    required void Function(MediaQueryData mq, BoxConstraints c) probe,
    Widget? child,
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: device,
          devicePixelRatio: dpr,
          padding: EdgeInsets.only(top: 24),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: DisplayScale(
            dpi: dpi,
            screenWidthDp: screen,
            child: child ??
                Builder(
                  builder: (context) {
                    final mq = MediaQuery.of(context);
                    return LayoutBuilder(
                      builder: (context, c) {
                        probe(mq, c);
                        return const ColoredBox(color: Colors.white);
                      },
                    );
                  },
                ),
          ),
        ),
      ),
    );
  }

  MediaQueryData capturedMq = const MediaQueryData();
  BoxConstraints capturedC = const BoxConstraints();
  void capture(MediaQueryData mq, BoxConstraints c) {
    capturedMq = mq;
    capturedC = c;
  }

  testWidgets('默认不缩放：子树看到的还是设备尺寸', (tester) async {
    await boot(tester, dpi: 1, screen: 0, probe: capture);
    expect(capturedMq.size, device);
    expect(capturedC.maxWidth, device.width);
    expect(capturedMq.padding.top, 24);
  });

  testWidgets('DPI 2 倍：画布减半，padding 同步换算，绘制再放大回去', (tester) async {
    await boot(tester, dpi: 2, screen: 0, probe: capture);
    expect(capturedMq.size, const Size(400, 300));
    expect(capturedC.maxWidth, 400);
    expect(capturedMq.padding.top, 12);
    expect(capturedMq.devicePixelRatio, dpr * 2);
    final t = tester.widgetList<Transform>(find.byType(Transform)).last.transform;
    expect(t.getMaxScaleOnAxis(), closeTo(2.0, 1e-9));
  });

  testWidgets('屏幕尺寸改画布宽度，高度按屏幕比例跟随', (tester) async {
    await boot(tester, dpi: 1, screen: 500, probe: capture);
    expect(capturedMq.size.width, 500);
    // k = 800/500 = 1.6 → 600/1.6 = 375，画布宽高比必须和设备一致，否则页面被拉扁
    expect(capturedMq.size.height, closeTo(375, 1e-6));
  });

  testWidgets('两个旋钮叠加：先按屏幕尺寸再按 DPI', (tester) async {
    await boot(tester, dpi: 2, screen: 500, probe: capture);
    expect(capturedMq.size.width, 250);
    expect(capturedMq.size.height, closeTo(187.5, 1e-6));
  });

  testWidgets('脏配置不能把画布压成 0 或抛异常', (tester) async {
    await boot(tester, dpi: 0, screen: 0, probe: capture);
    expect(capturedMq.size, device);
    await boot(tester, dpi: double.nan, screen: 0, probe: capture);
    expect(tester.takeException(), isNull);
    expect(capturedMq.size.width, greaterThan(0));
    await boot(tester, dpi: 1, screen: 999999, probe: capture);
    expect(capturedMq.size.width, lessThanOrEqualTo(4000));
  });

  testWidgets('canvasHeight 读数必须等于子树真正看到的画布高度', (tester) async {
    // 面板里那行「当前画布 W × H」以前自己另写了一遍公式还把比例搞反，
    // 所以这里把两者钉在一起：读数错了用户会以为缩放没生效。
    for (final (dpi, screen) in [(1.0, 0.0), (2.0, 0.0), (1.0, 500.0), (0.7, 640.0)]) {
      await boot(tester, dpi: dpi, screen: screen, probe: capture);
      final w = DisplayScale.canvasWidth(
        dpi: dpi,
        screenWidthDp: screen,
        realWidth: device.width,
      );
      expect(
        DisplayScale.canvasHeight(
          canvasWidth: w,
          realWidth: device.width,
          realHeight: device.height,
        ),
        closeTo(capturedMq.size.height, 1e-6),
        reason: 'dpi=$dpi screen=$screen',
      );
    }
  });

  testWidgets('缩放后点击仍然落在该落的控件上', (tester) async {
    var hits = 0;
    await boot(
      tester,
      dpi: 2,
      screen: 0,
      probe: capture,
      child: Stack(
        children: [
          Positioned(
            left: 100,
            top: 50,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => hits++,
              child: const SizedBox(width: 60, height: 40, child: ColoredBox(color: Colors.red)),
            ),
          ),
        ],
      ),
    );
    // 画布 (130, 70) × DPI 2 = 设备 (260, 140)
    expect(hits, 0);
    await tester.tapAt(const Offset(260, 140));
    expect(hits, 1);
    // 画布外（右侧留白）不该被算命中
    await tester.tapAt(const Offset(60, 140));
    expect(hits, 1);
  });
}

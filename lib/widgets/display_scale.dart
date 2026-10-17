import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// 全局显示缩放：DPI 把整个 App 连文字带控件一起放大缩小，
/// 屏幕尺寸则把 App 画在指定宽度的逻辑画布上（等效换设备尺寸）。
///
/// Flutter 里没法真的改 density，所以这里自己造画布：给子树一个 w×h 的 SizedBox，
/// 再用 Transform.scale 等比画回满屏。MediaQuery 必须同步改成画布尺寸，
/// 连 padding/viewInsets 也要按同一比例换算，否则刘海和键盘高度会错位。
class DisplayScale extends StatelessWidget {
  const DisplayScale({
    super.key,
    required this.dpi,
    required this.screenWidthDp,
    required this.child,
  });

  final double dpi;

  /// 逻辑画布宽度；<=0 表示跟随设备
  final double screenWidthDp;
  final Widget child;

  static const double minDpi = 0.7;
  static const double maxDpi = 1.6;
  static const double minScreenDp = 280;
  static const double maxScreenDp = 640;

  /// 画布宽度：先按选定的屏幕尺寸，再按 DPI 收放。
  /// NaN/Infinity 一律当没设置——比较运算对 NaN 恒 false，不先挡掉会一路传染到布局。
  static double canvasWidth({
    required double dpi,
    required double screenWidthDp,
    required double realWidth,
  }) {
    if (!realWidth.isFinite || realWidth <= 0) return 0;
    final base = screenWidthDp.isFinite && screenWidthDp > 0 ? screenWidthDp : realWidth;
    if (!dpi.isFinite || dpi <= 0) return base;
    return (base / dpi).clamp(120.0, 4000.0);
  }

  /// 画布高度：必须和宽度用同一个缩放系数，否则画面要么留白要么溢出。
  /// 和 canvasWidth 放在一起，是为了让面板里的读数不会再各算各的。
  static double canvasHeight({
    required double canvasWidth,
    required double realWidth,
    required double realHeight,
  }) {
    if (!canvasWidth.isFinite || canvasWidth <= 0) return 0;
    if (!realWidth.isFinite || realWidth <= 0 || !realHeight.isFinite) return 0;
    return realHeight * canvasWidth / realWidth;
  }

  @override
  Widget build(BuildContext context) {
    final real = MediaQuery.sizeOf(context);
    return ScaledCanvas(
      targetWidth: canvasWidth(
        dpi: dpi,
        screenWidthDp: screenWidthDp,
        realWidth: real.width,
      ),
      child: child,
    );
  }
}

/// 把子树画在 [targetWidth] 宽的逻辑画布上，相对它当前看到的画布。
/// 全局缩放和阅读页缩放各套一层这个，两层相乘就是总缩放，所以谁都不用知道自己
/// 在第几层——只要 targetWidth 一律用「真实设备 dp」表达。
class ScaledCanvas extends StatelessWidget {
  const ScaledCanvas({super.key, required this.targetWidth, required this.child});

  final double targetWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final real = mq.size;
    final w = targetWidth;
    // 首帧尺寸未知、配置是脏值、或者本来就不用缩放：原样渲染
    if (!w.isFinite || w <= 0 || real.width <= 0 || real.height <= 0 || w == real.width) {
      return child;
    }
    final k = real.width / w;
    final h = DisplayScale.canvasHeight(
      canvasWidth: w,
      realWidth: real.width,
      realHeight: real.height,
    );
    if (!h.isFinite || h <= 0) return child;
    return MediaQuery(
      data: mq.copyWith(
        size: Size(w, h),
        padding: mq.padding / k,
        viewPadding: mq.viewPadding / k,
        viewInsets: mq.viewInsets / k,
        devicePixelRatio: mq.devicePixelRatio * k,
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Transform.scale(
          scale: k,
          alignment: Alignment.topLeft,
          child: SizedBox(width: w, height: h, child: child),
        ),
      ),
    );
  }
}

/// 阅读页专属缩放：readerDpiScale / readerScreenWidthDp 为 0 时整页跟随全局。
/// 放在阅读页 Scaffold 外面，正文、顶栏底栏和翻页动画一起缩放，
/// 而目录/设置这些弹层走根 Navigator 的 Overlay，仍然只吃全局缩放。
class ReaderScale extends StatelessWidget {
  const ReaderScale({super.key, required this.child});

  final Widget child;

  /// 阅读页想要的画布宽度（真实设备 dp）
  static double targetWidthOf(ReaderSettings s, double realWidth) {
    return DisplayScale.canvasWidth(
      dpi: s.readerDpiScale > 0 ? s.readerDpiScale : s.dpiScale,
      screenWidthDp: s.readerScreenWidthDp > 0
          ? s.readerScreenWidthDp
          : s.screenWidthDp,
      realWidth: realWidth,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<ReaderSettings>();
    // 自己就在缩放画布里，设备真实宽度只能问 View
    final device = MediaQueryData.fromView(View.of(context));
    return ScaledCanvas(
      targetWidth: targetWidthOf(s, device.size.width),
      child: child,
    );
  }
}

/// 标题+数值一行、滑杆独占一行：面板自己也可能被缩放画布压窄，横排会把滑杆
/// 挤到几十 dp，十几格刻度根本对不准。全局面板和阅读页设置共用这一种排布。
class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.slider,
    this.trailing,
  });

  final String label;
  final String value;
  final Widget slider;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const Spacer(),
              Text(value, style: const TextStyle(fontSize: 13)),
              ?trailing,
            ],
          ),
          slider,
        ],
      ),
    );
  }
}

/// 显示设置面板：从书架顶栏的「显示设置」进来
Future<void> showDisplaySettings(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => const _DisplaySettingsSheet(),
  );
}

class _DisplaySettingsSheet extends StatelessWidget {
  const _DisplaySettingsSheet();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReaderSettings>();
    // 面板自己也在缩放画布里，取设备真实尺寸必须问 View
    final device = MediaQueryData.fromView(View.of(context));
    final w = DisplayScale.canvasWidth(
      dpi: settings.dpiScale,
      screenWidthDp: settings.screenWidthDp,
      realWidth: device.size.width,
    );
    final h = DisplayScale.canvasHeight(
      canvasWidth: w,
      realWidth: device.size.width,
      realHeight: device.size.height,
    );
    final following = settings.screenWidthDp <= 0;
    final screenValue = (following ? device.size.width : settings.screenWidthDp).clamp(
      DisplayScale.minScreenDp,
      DisplayScale.maxScreenDp,
    );

    void setDpi(double v) => settings.set(dpiScale: double.parse(v.toStringAsFixed(2)));
    void setScreen(double v) => settings.set(screenWidthDp: v.roundToDouble());

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('显示设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                TextButton(
                  onPressed: () {
                    setDpi(1.0);
                    settings.set(screenWidthDp: 0);
                  },
                  child: const Text('恢复默认'),
                ),
              ],
            ),
            SliderRow(
              label: 'DPI',
              value: '${settings.dpiScale.toStringAsFixed(2)}×',
              slider: Slider(
                value: settings.dpiScale.clamp(DisplayScale.minDpi, DisplayScale.maxDpi),
                min: DisplayScale.minDpi,
                max: DisplayScale.maxDpi,
                divisions: 18,
                label: '${settings.dpiScale.toStringAsFixed(2)}×',
                onChanged: setDpi,
              ),
            ),
            SliderRow(
              label: '屏幕',
              value: '${screenValue.round()} dp',
              trailing: IconButton(
                icon: Icon(
                  Icons.smartphone,
                  color: following ? const Color(0xFF2E7D5B) : Colors.grey.shade600,
                ),
                tooltip: '跟随设备尺寸',
                onPressed: () => settings.set(screenWidthDp: 0),
              ),
              slider: Slider(
                value: screenValue,
                min: DisplayScale.minScreenDp,
                max: DisplayScale.maxScreenDp,
                divisions: 18,
                label: '${screenValue.round()} dp',
                onChanged: setScreen,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '当前画布 ${w.round()} × ${h.round()} dp'
                '${following ? '（屏幕尺寸跟随设备 ${device.size.width.round()} dp）' : ''}\n'
                'DPI 连字带控件整体缩放；屏幕尺寸只改画布宽度，宽了字就小、窄了字就大。',
                style: TextStyle(fontSize: 12, height: 1.5, color: Colors.grey.shade600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

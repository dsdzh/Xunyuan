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
    final mq = MediaQuery.of(context);
    final real = mq.size;
    final w = canvasWidth(
      dpi: dpi,
      screenWidthDp: screenWidthDp,
      realWidth: real.width,
    );
    final h = canvasHeight(
      canvasWidth: w,
      realWidth: real.width,
      realHeight: real.height,
    );
    // 首帧尺寸未知、配置是脏值、或者本来就不用缩放：原样渲染
    if (h <= 0 || w == real.width) return child;
    final k = real.width / w;
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
            _row(
              'DPI',
              '${settings.dpiScale.toStringAsFixed(2)}×',
              null,
              Slider(
                value: settings.dpiScale.clamp(DisplayScale.minDpi, DisplayScale.maxDpi),
                min: DisplayScale.minDpi,
                max: DisplayScale.maxDpi,
                divisions: 18,
                label: '${settings.dpiScale.toStringAsFixed(2)}×',
                onChanged: setDpi,
              ),
            ),
            _row(
              '屏幕',
              '${screenValue.round()} dp',
              IconButton(
                icon: Icon(
                  Icons.smartphone,
                  color: following ? const Color(0xFF2E7D5B) : Colors.grey.shade600,
                ),
                tooltip: '跟随设备尺寸',
                onPressed: () => settings.set(screenWidthDp: 0),
              ),
              Slider(
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

  /// 标题和数值一行、滑杆独占下一行：面板自己也被缩放，DPI 拉到 1.6 时
  /// 画布只剩 225dp，横向并排的话滑杆会被挤到四十多 dp，刻度根本对不准。
  Widget _row(String label, String value, Widget? trailing, Slider slider) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey)),
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

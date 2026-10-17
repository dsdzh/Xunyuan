import 'package:flutter/material.dart';

/// 底部换页用的滑动淡入容器。
/// IndexedStack 保留各页状态但换页是瞬时替换，看着一跳一跳；这里在外层补一段
/// 带方向的进场动画：往后翻从右边进，往前回退从左边进。
class TabSwitcher extends StatefulWidget {
  const TabSwitcher({
    super.key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 320),
    this.slideDistance = 18,
  });

  final int index;
  final List<Widget> children;
  final Duration duration;
  final double slideDistance;

  @override
  State<TabSwitcher> createState() => _TabSwitcherState();
}

class _TabSwitcherState extends State<TabSwitcher> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration, value: 1);
  double _dir = 1;

  @override
  void didUpdateWidget(TabSwitcher old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    _dir = widget.index > old.index ? 1 : -1;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      // 初值 1：首屏必须完全不透明、不偏移，只有换页时才从 0 跑一次
      child: IndexedStack(index: widget.index, children: widget.children),
      builder: (context, child) {
        final t = Curves.easeOutQuart.transform(_c.value);
        return IgnorePointer(
          // 动画期间挡住点击，避免连点两下把状态停在中间帧
          ignoring: _c.isAnimating,
          child: Transform.translate(
            offset: Offset(_dir * widget.slideDistance * (1 - t), 0),
            // 下限取高一点：透出背景空白就不再像换页，而像闪屏
            child: Opacity(opacity: 0.82 + 0.18 * t, child: child),
          ),
        );
      },
    );
  }
}

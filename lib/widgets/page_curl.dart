import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// iBooks 风格仿真卷页。
///
/// [curlingImage] 是正在被卷起的那一页（手势开始时从屏幕上的 RepaintBoundary
/// 同步抓取的位图，设备像素）；[revealed] 是下方逐渐露出的目标页（普通 widget）。
/// 卷起页绕一根竖直柱面弯卷：折边左侧仍平铺、折边处卷成半圆柱（正面显示旧内容、
/// 背面显示纸背），脊线打高光、折边在目标页上投下柔和接触阴影。
class PageCurl extends StatelessWidget {
  const PageCurl({
    super.key,
    required this.curlingImage,
    required this.revealed,
    required this.progress,
    required this.forward,
    required this.background,
    this.pixelRatio = 1.0,
  });

  final ui.Image curlingImage;
  final Widget revealed;
  final double progress;
  final bool forward;
  final Color background;
  final double pixelRatio;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return Stack(
          children: [
            Positioned.fill(child: revealed),
            Positioned.fill(
              child: CustomPaint(
                size: size,
                painter: PageCurlPainter(
                  image: curlingImage,
                  t: progress.clamp(0.0, 1.0),
                  forward: forward,
                  background: background,
                  pixelRatio: pixelRatio,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class PageCurlPainter extends CustomPainter {
  PageCurlPainter({
    required this.image,
    required this.t,
    required this.forward,
    required this.background,
    required this.pixelRatio,
  });

  final ui.Image image;
  final double t;
  final bool forward;
  final Color background;
  final double pixelRatio;

  // 折边在“卷曲坐标系”里从 w 扫到 -R（forward）；backward 通过镜像复用同一套几何。
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final R = (w * 0.28).clamp(30.0, 160.0);
    // 卷起页折边位置（卷曲空间），t=0 在最右、t=1 越过左边界完全翻走
    final p = w - t * (w + R);
    final pr = pixelRatio;

    // 平铺的卷起页：卷曲空间 [0, p]
    if (p > 0.5) {
      final flatW = math.min(p, w);
      _drawSlice(
        canvas,
        from: 0,
        to: flatW,
        image: image,
        pr: pr,
        forward: forward,
        w: w,
        h: h,
      );
    }

    // 柱面卷曲（只画正面，避免背面覆盖导致半透明）：卷曲空间 [p, ridge] 的
    // 旧页内容绕半径 R 的柱面翻起，折边在 p、脊线在 ridge。
    final step = 2.0;
    final frontPaint = Paint()..filterQuality = FilterQuality.medium;
    final ridge = p + R;
    final maxPhi = math.min(math.pi / 2, (w - p) / R); // 不超过 90°，超出部分视为已翻走
    final uEnd = p + maxPhi * R;
    for (var u = p; u < uEnd; u += step) {
      final u2 = math.min(u + step, uEnd);
      final x0 = p + R * math.sin((u - p) / R);
      final x1 = p + R * math.sin((u2 - p) / R);
      final dw = (x1 - x0).abs();
      if (dw <= 0.05) continue;
      _drawSliceRange(
        canvas,
        curlFrom: u,
        curlTo: u2,
        destLeft: x0,
        destWidth: dw,
        image: image,
        pr: pr,
        forward: forward,
        w: w,
        h: h,
        paint: frontPaint,
      );
    }

    // 柱面明暗：折边处转暗 → 中段透明 → 脊线前高光 → 脊线收暗，形成圆卷立体感
    if (p < w) {
      final fl = forward ? p : w - ridge;
      final fr = forward ? ridge : w - p;
      if (fr > fl) {
        final rect = Rect.fromLTWH(fl, 0, fr - fl, h);
        final grad = LinearGradient(
          begin: forward ? Alignment.centerLeft : Alignment.centerRight,
          end: forward ? Alignment.centerRight : Alignment.centerLeft,
          colors: [
            Colors.black.withValues(alpha: 0.34 * (1 - t)),
            Colors.black.withValues(alpha: 0.02),
            Colors.white.withValues(alpha: 0.22),
            Colors.black.withValues(alpha: 0.20),
          ],
          stops: const [0.0, 0.5, 0.9, 1.0],
        );
        canvas.drawRect(rect, Paint()..shader = grad.createShader(rect));
      }
    }

    // 接触阴影：落在目标页上、紧贴脊线外侧，随翻页移动并收放
    final shadowStrength = (math.sin(t * math.pi) * 0.5).clamp(0.0, 0.5);
    if (shadowStrength > 0.01) {
      final band = R * 1.2;
      final startX = forward ? ridge : w - ridge;
      final endX = (forward ? ridge + band : w - ridge - band).clamp(0.0, w);
      if (endX != startX) {
        final rect = Rect.fromLTWH(
          math.min(startX, endX),
          0,
          (endX - startX).abs(),
          h,
        );
        final sg = LinearGradient(
          begin: forward ? Alignment.centerLeft : Alignment.centerRight,
          end: forward ? Alignment.centerRight : Alignment.centerLeft,
          colors: [
            Colors.black.withValues(alpha: shadowStrength),
            Colors.black.withValues(alpha: 0),
          ],
        );
        canvas.drawRect(rect, Paint()..shader = sg.createShader(rect));
      }
    }
  }

  // 把卷曲空间 [from,to]（绝对 x）映射到真实屏幕并绘制整段平铺内容
  void _drawSlice(
    Canvas canvas, {
    required double from,
    required double to,
    required ui.Image image,
    required double pr,
    required bool forward,
    required double w,
    required double h,
  }) {
    final srcX = (forward ? from : w - to) * pr;
    final srcW = (to - from) * pr;
    final dstX = forward ? from : w - to;
    if (srcX < 0 || srcX + srcW > image.width + 0.5) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        srcX.clamp(0.0, image.width.toDouble()),
        0,
        srcW.clamp(0.0, image.width.toDouble()),
        image.height.toDouble(),
      ),
      Rect.fromLTWH(dstX, 0, to - from, h),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  // 柱面切片：源取卷曲空间 [curlFrom,curlTo]，目标画在 destLeft..destLeft+destWidth
  void _drawSliceRange(
    Canvas canvas, {
    required double curlFrom,
    required double curlTo,
    required double destLeft,
    required double destWidth,
    required ui.Image image,
    required double pr,
    required bool forward,
    required double w,
    required double h,
    required Paint paint,
  }) {
    final srcX = (forward ? curlFrom : w - curlTo) * pr;
    final srcW = (curlTo - curlFrom) * pr;
    final dstX = forward ? destLeft : w - (destLeft + destWidth);
    if (srcX < 0 || srcX + srcW > image.width + 0.5 || srcW <= 0) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        srcX.clamp(0.0, image.width.toDouble()),
        0,
        srcW,
        image.height.toDouble(),
      ),
      Rect.fromLTWH(dstX, 0, destWidth, h),
      paint,
    );
  }

  @override
  bool shouldRepaint(PageCurlPainter old) =>
      old.t != t ||
      old.forward != forward ||
      old.image != image ||
      old.background != background;
}

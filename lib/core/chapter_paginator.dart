import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'text_boundary.dart';

/// 章节正文分页装箱（纯函数）。
///
/// 页面是固定高度的，放不下的行会被直接裁掉（读者既看不到也翻不到），
/// 所以装箱必须保证**每一页的内容高度都不超过 pageHeight**：
/// - `titleReserve` 只有首页顶部为章标题预留，其余页不留；
/// - `sepH` 是页内段落用 `\n\n` 连接时段间真实占的一整行高度，
///   测量必须与渲染一致，否则页底被裁；
/// - 单段装不进当前页时先换页重试，换页后仍装不下才就地拆分。
class ChapterPaginator {
  /// 返回每页的文本（页内段落以 `\n\n` 连接）。
  static List<String> paginate({
    required List<String> paragraphs,
    required double fontSize,
    required double lineHeight,
    required double pageWidth,
    required double pageHeight,
    required double titleReserve,
  }) {
    final style = TextStyle(fontSize: fontSize, height: lineHeight);
    final sepH = fontSize * lineHeight;
    // 单行都放不下整页时（极端字号），至少给片段留两行，避免拆分循环不前进
    final minChunk = fontSize * 2;

    double paraHeight(String p) {
      final tp = TextPainter(
        text: TextSpan(text: p, style: style),
        maxLines: null,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: pageWidth);
      final h = tp.height;
      tp.dispose();
      return h;
    }

    /// 把 p 切成若干片，每片高度都不超过 limit
    List<String> split(String p, double limit) {
      final chunks = <String>[];
      var remaining = p;
      var guard = 0;
      while (remaining.isNotEmpty && guard++ < 5000) {
        final tp = TextPainter(
          text: TextSpan(text: remaining, style: style),
          maxLines: null,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: pageWidth);
        if (tp.height <= limit) {
          tp.dispose();
          chunks.add(remaining);
          break;
        }
        var cut = tp.getPositionForOffset(Offset(0, limit)).offset;
        tp.dispose();
        if (cut <= 0) cut = 1; // 防超大字号/单行超页死循环
        if (cut >= remaining.length) {
          chunks.add(remaining);
          break;
        }
        // 断点落在码点边界，别把代理对劈成两个乱码方块
        cut = TextBoundary.floor(remaining, cut);
        chunks.add(remaining.substring(0, cut));
        remaining = remaining.substring(cut);
      }
      return chunks;
    }

    final pages = <String>[];
    var current = <String>[];
    var currentHeight = titleReserve;

    void flush() {
      if (current.isEmpty) return;
      pages.add(current.join('\n\n'));
      current = [];
      currentHeight = 0;
    }

    // 待放置队列：拆分产生的片段插回队首，保证按原文顺序落页
    final queue = paragraphs.map((p) => (p, paraHeight(p))).toList();
    while (queue.isNotEmpty) {
      final (text, h) = queue.removeAt(0);
      final withSep = h + (current.isEmpty ? 0 : sepH);
      if (currentHeight + withSep <= pageHeight) {
        current.add(text);
        currentHeight += withSep;
        continue;
      }
      if (current.isNotEmpty) {
        // 换一页就腾得出整页空间，整段挪到下一页
        flush();
        queue.insert(0, (text, h));
        continue;
      }
      // 当前页只有章标题占位，换页也变不出空间：按剩余高度就地拆首片
      final limit = math.max(pageHeight - currentHeight, minChunk);
      final chunks = split(text, limit);
      if (chunks.length == 1) {
        // 拆不动（页面比两行还矮之类的极端设置），硬放进去保证循环推进
        current.add(text);
        currentHeight += withSep;
        continue;
      }
      queue.insertAll(0, chunks.map((c) => (c, paraHeight(c))));
    }

    flush();
    if (pages.isEmpty) pages.add('　');
    return pages;
  }
}

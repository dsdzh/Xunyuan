import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/chapter_paginator.dart';

const _style = TextStyle(fontSize: 20, height: 1.5);
const _pageWidth = 300.0;
const _pageHeight = 300.0;
const _titleReserve = 50.0;
const _sepH = 30.0; // fontSize * lineHeight

double _height(String text) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: _style),
    maxLines: null,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: _pageWidth);
  final h = tp.height;
  tp.dispose();
  return h;
}

List<String> _run(List<String> paragraphs) => ChapterPaginator.paginate(
      paragraphs: paragraphs,
      fontSize: 20,
      lineHeight: 1.5,
      pageWidth: _pageWidth,
      pageHeight: _pageHeight,
      titleReserve: _titleReserve,
    );

/// 页面上真正占的高度：正文各段 + 段间空行（首页再加章标题预留）
double _pageContentHeight(List<String> parasOnPage, {required bool first}) {
  var h = first ? _titleReserve : 0.0;
  for (var i = 0; i < parasOnPage.length; i++) {
    if (i > 0) h += _sepH;
    h += _height(parasOnPage[i]);
  }
  return h;
}

void main() {
  // flutter test 用的是 Ahem 字体：每个字宽=fontSize、行高=fontSize*height，
  // 所以 20px 字、1.5 行距下每行 15 个字、高 30px。
  group('ChapterPaginator', () {
    test('首页首段落进 (pageHeight-titleReserve, pageHeight] 时不再被裁', () {
      // 9 行 = 270px：整页装得下，但首页扣掉章标题预留后只剩 250px
      final p = '字' * 135;
      expect(_height(p), 270);
      final pages = _run([p]);
      expect(pages.length, 2);
      expect(_pageContentHeight([pages[0]], first: true), lessThanOrEqualTo(_pageHeight));
      expect(_pageContentHeight([pages[1]], first: false), lessThanOrEqualTo(_pageHeight));
      expect(pages[0].length + pages[1].length, p.length);
    });

    test('整章只有一段超长文本：不裁字、不丢字', () {
      final p = '文' * 1234;
      final pages = _run([p]);
      for (var i = 0; i < pages.length; i++) {
        expect(_pageContentHeight([pages[i]], first: i == 0), lessThanOrEqualTo(_pageHeight + 0.01),
            reason: '第 $i 页溢出');
      }
      expect(pages.map((pg) => pg.split('\n\n').join()).join(), p);
    });

    test('多段装箱：每页不超页高，段序与内容不变', () {
      final paras = [
        '甲' * 15, // 1 行
        '乙' * 120, // 8 行
        '丙' * 45, // 3 行
        '丁' * 200, // 14 行，必须拆
        '戊' * 60,
      ];
      final pages = _run(paras);
      var lost = '';
      for (var i = 0; i < pages.length; i++) {
        final onPage = pages[i].split('\n\n');
        expect(_pageContentHeight(onPage, first: i == 0), lessThanOrEqualTo(_pageHeight + 0.01),
            reason: '第 $i 页溢出：${onPage.map(_height).toList()}');
        lost += onPage.join();
      }
      expect(lost, paras.join());
    });

    test('拆分点不落在代理对中间', () {
      // 𠮷 占两个 UTF-16 码元，按码元切页最容易踩
      final p = '𠮷' * 400;
      final pages = _run([p]);
      expect(pages.length, greaterThan(1));
      for (final page in pages) {
        for (var i = 0; i < page.length; i++) {
          final c = page.codeUnitAt(i);
          if (c >= 0xD800 && c <= 0xDBFF) {
            expect(i + 1 < page.length && page.codeUnitAt(i + 1) >= 0xDC00 && page.codeUnitAt(i + 1) <= 0xDFFF,
                isTrue,
                reason: '页尾留下孤立高代理');
            i++;
          } else {
            expect(c < 0xDC00 || c > 0xDFFF, isTrue, reason: '页首出现孤立低代理');
          }
        }
      }
      expect(pages.map((pg) => pg.split('\n\n').join()).join(), p);
    });

    test('空章节占一页，避免除零/空列表', () {
      expect(_run([]), ['　']);
    });

    test('页面比两行还矮时不死循环', () {
      final pages = ChapterPaginator.paginate(
        paragraphs: ['字' * 60],
        fontSize: 20,
        lineHeight: 1.5,
        pageWidth: _pageWidth,
        pageHeight: 25, // 连一行都放不下
        titleReserve: 50,
      );
      expect(pages, isNotEmpty);
      expect(pages.join().replaceAll('\n\n', ''), '字' * 60);
    });
  });
}

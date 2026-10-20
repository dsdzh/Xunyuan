import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/text_boundary.dart';

void main() {
  // 𠮷 = U+20BB7，中日韩扩展 B 区，正文里真会出现；😀 同理
  const pair = '𠮷';

  group('TextBoundary', () {
    test('朴素 substring 劈开代理对：字符被静默换成 U+FFFD', () {
      const s = '正文$pair结尾';
      final split = s.substring(0, s.indexOf(pair) + 1); // 只取到高半代理
      expect(split.length, s.indexOf(pair) + 1);
      // utf8 / Uri 通路不报错，直接把孤立代理项压成乱码方块
      expect(utf8.encode(split), containsAllInOrder([239, 191, 189]));
      expect(Uri.encodeQueryComponent(split).contains('%EF%BF%BD'), true);
      // 后半截掉在下一段开头，继续是坏字符
      expect(s.substring(split.length).codeUnits.first, 0xDFB7); // 𠮷 的低半代理
    });

    test('floor 把断点退回码点边界，UTF-8 往返无损', () {
      const s = '正文$pair结尾';
      final fixed = s.substring(0, TextBoundary.floor(s, s.indexOf(pair) + 1));
      expect(fixed, '正文');
      expect(utf8.decode(utf8.encode(fixed)), fixed);
      expect(s.substring(TextBoundary.floor(s, s.indexOf(pair) + 1)).startsWith(pair), true);
    });

    test('非代理对位置保持原断点', () {
      const s = '正文汉字abc';
      for (var i = 1; i < s.length; i++) {
        expect(TextBoundary.floor(s, i), i);
      }
      expect(TextBoundary.floor(s, 0), 0);
      expect(TextBoundary.floor(s, s.length), s.length);
      expect(TextBoundary.floor(s, s.length + 9), s.length);
      expect(TextBoundary.floor('', 3), 0);
    });

    test('断点退无可退时前进一个码元，保证循环能推进', () {
      const s = '$pair后续内容';
      // 代理对正好在开头，floor(1) 若退回 0 会让分页死循环
      expect(TextBoundary.floor(s, 1), 2);
      expect(s.substring(0, 2), pair);
      expect(s.substring(2), '后续内容');
      expect(() => utf8.encode(s.substring(0, TextBoundary.floor(s, 1))), returnsNormally);
    });

    test('truncate 不超上限且不劈开', () {
      const s = 'abc$pair';
      expect(TextBoundary.truncate(s, 100), s);
      expect(TextBoundary.truncate(s, 3), 'abc');
      expect(TextBoundary.truncate(s, 4), 'abc'); // 4 会劈开，退回 3
      expect(TextBoundary.truncate(s, 5), s);
      expect(TextBoundary.truncate('abcdef', 0), '');
    });
  });
}

/// 文本截断的码点边界工具。
///
/// Dart 的 `String.length` / `substring` 按 UTF-16 码元计数，中日韩扩展 B 区
/// 字符（𠮷 等）和 emoji 都是代理对，占两个码元。按码元截断会把一对劈开：
/// 半个代理项经任何 UTF-8 通路（`utf8.encode`、`Uri` 编码、写缓存）都会被静默
/// 换成 U+FFFD 乱码方块，后半截还留在下一段开头继续显示成方块。
class TextBoundary {
  /// 把截断点 index 退到码点边界；退无可退时改为前进一个码元，保证结果 > 0
  /// （调用方靠它推进循环，返回 0 会死循环）。
  static int floor(String s, int index) {
    if (index <= 0) return 0;
    if (index >= s.length) return s.length;
    if (_splitsPair(s, index)) return index == 1 ? 2 : index - 1;
    return index;
  }

  /// 截到 maxUnits 个码元，且不劈开代理对。
  static String truncate(String s, int maxUnits) {
    if (s.length <= maxUnits) return s;
    return s.substring(0, floor(s, maxUnits));
  }

  static bool _splitsPair(String s, int index) =>
      _isHigh(s.codeUnitAt(index - 1)) && _isLow(s.codeUnitAt(index));

  static bool _isHigh(int c) => c >= 0xD800 && c <= 0xDBFF;
  static bool _isLow(int c) => c >= 0xDC00 && c <= 0xDFFF;
}

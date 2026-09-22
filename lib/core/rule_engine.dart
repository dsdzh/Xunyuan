import 'dart:convert';

import 'package:html/dom.dart' as h;
import 'package:html/parser.dart' as html_parser;

/// 规则引擎结果：可能是元素/对象列表，也可能是字符串。
class RuleResult {
  final List<dynamic> elements;
  final String text;
  RuleResult(this.elements, this.text);
  bool get isEmpty => elements.isEmpty && text.isEmpty;
}

/// Legado 规则子集解析器（v1，纯 Dart 自研实现）。
///
/// 支持：
/// - `&&` 组合（多规则结果拼接）、`;;` 回退（前一规则为空时使用后一规则）
/// - CSS/JSoup 风格选择器：`class.x`、`id.x`、`tag.x`、`text.x`、`@css:...`
/// - 属性读取：`@text`、`@textNodes`、`@html`、`@innerHtml`、`@src`、`@href`、
///   `@id`、`@class`、`@tag` 或任意属性名
/// - 列表下标：`[0]`、`[1-3]`、`[last]`、`[last-2]`
/// - 正则处理：`##pattern##replacement`（无 replacement 时为匹配提取）、`###pattern`（过滤）
/// - JSON 模式 JSONPath 子集：`$.a.b[0]`、`$..key`、`[*]`
/// - 不支持的规则（`@js:`、`@xpath:`）返回空并记录警告
class RuleEngine {
  static final List<String> warnings = <String>[];
  static void _warn(String w) {
    if (warnings.length < 200) warnings.add(w); // 上限防逐条×逐字段累积泄漏
  }

  /// content: 原始内容（html 字符串 / json 字符串）
  /// rule: 规则字符串
  /// 返回匹配到的字符串列表（对元素取文本或指定属性）。
  static List<String> getStringList(String content, String rule, {bool isJson = false}) {
    final res = _analyze(content, rule, isJson: isJson);
    return res.map((e) => e is String ? e : e?.toString() ?? '').toList();
  }

  static String getString(String content, String rule, {bool isJson = false}) {
    final list = getStringList(content, rule, isJson: isJson);
    return list.isEmpty ? '' : list.first;
  }

  /// 返回"节点"列表（元素 Element 或字符串或原始 json 值），供上层逐条抽取字段。
  static List<dynamic> getElements(String content, String rule, {bool isJson = false}) {
    if (rule.trim().isEmpty) {
      return isJson ? [if (content.isNotEmpty) _tryJson(content)] : _parseHtml(content).body!.nodes;
    }
    return _analyze(content, rule, nodes: true, isJson: isJson);
  }

  static h.Document _parseHtml(String content) {
    // _analyze 对 ;;/&& 递归时同一 content 会被反复解析，单条目缓存防大页卡顿
    if (!identical(content, _lastHtmlSrc) && content != _lastHtmlSrc) {
      _lastHtmlDoc = html_parser.parse(content);
      _lastHtmlSrc = content;
    }
    return _lastHtmlDoc!;
  }

  static String? _lastHtmlSrc;
  static h.Document? _lastHtmlDoc;

  static dynamic _tryJson(String content) {
    try {
      return jsonDecode(content);
    } catch (_) {
      return null;
    }
  }

  /// 核心规则解析。返回元素/字符串混合列表。
  static List<dynamic> _analyze(String content, String rule, {bool nodes = false, bool isJson = false}) {
    rule = rule.trim();
    if (rule.isEmpty) return [];
    if (content.isEmpty && isJson == false && rule != '@' && !rule.startsWith('@put')) return [];

    // 组合规则 ;; 回退
    final fallbackParts = _splitTopLevel(rule, ';;');
    if (fallbackParts.length > 1) {
      for (final p in fallbackParts) {
        final r = _analyze(content, p, nodes: nodes, isJson: isJson);
        if (r.isNotEmpty) return r;
      }
      return [];
    }

    // && 组合
    final andParts = _splitTopLevel(rule, '&&');
    if (andParts.length > 1) {
      final out = <dynamic>[];
      for (final p in andParts) {
        out.addAll(_analyze(content, p, nodes: nodes, isJson: isJson));
      }
      return out;
    }

    // %% 随机 —— v1 取第一个
    final randParts = rule.split('%%');
    if (randParts.length > 1) {
      return _analyze(content, randParts.first, nodes: nodes, isJson: isJson);
    }

    // 正则段：查找第一个 ##，剩余部分为替换
    String core = rule;
    String? regexPattern;
    String? regexRepl;
    bool regexFilter = false;
    final idx = rule.indexOf('##');
    if (idx >= 0) {
      core = rule.substring(0, idx).trim();
      var rest = rule.substring(idx + 2);
      if (rest.startsWith('#')) {
        // ###pattern —— 仅保留匹配的内容
        regexPattern = rest.substring(1);
        regexFilter = true;
        regexRepl = null;
      } else {
        final idx2 = rest.indexOf('##');
        if (idx2 >= 0) {
          regexPattern = rest.substring(0, idx2);
          regexRepl = rest.substring(idx2 + 2);
        } else {
          regexPattern = rest;
          regexRepl = '';
        }
      }
    }

    // $ 开头 → 表示"对内容本身"执行正则（Legado: `##xx##` 直接作用于内容时 core 为空）
    List<dynamic> results;
    if (core.isEmpty) {
      results = [content];
    } else if (core == r'$' || core == '@') {
      results = [content];
    } else if (core.startsWith('@css:')) {
      results = _cssSelectAll(_parseHtml(content), core.substring(5));
    } else if (core.startsWith('@xpath:')) {
      _warn('暂不支持 XPath 规则: $core');
      return [];
    } else if (core.startsWith('@js:') || core.contains('<js>')) {
      _warn('暂不支持 JS 规则: ${core.length > 60 ? '${core.substring(0, 60)}…' : core}');
      return [];
    } else if (isJson) {
      results = _jsonPath(_asJsonValue(content), core);
    } else if (core.startsWith('{{') && core.endsWith('}}')) {
      // 模板规则 —— v1 不支持复杂模板
      _warn('暂不支持模板规则');
      return [];
    } else {
      results = _cssChain(_parseHtml(content), core);
    }

    if (results.isEmpty && nodes == false && regexPattern != null && core.isNotEmpty && !isJson) {
      // 元素未命中时，允许对全文执行正则兜底（部分书源写法）
      results = [content];
    }

    if (nodes) return results;

    var texts = results.map(_nodeToText).toList();

    // 正则处理（nodes 模式在上方已返回，正则只作用于文本）
    if (regexPattern == null) return texts;
    RegExp re;
    try {
      re = RegExp(regexPattern, dotAll: true);
    } catch (e) {
      _warn('非法正则: $regexPattern');
      return texts;
    }
    final out = <dynamic>[];
    for (final t in texts) {
      final matches = re.allMatches(t);
      if (regexFilter) {
        for (final m in matches) {
          out.add(m.group(0));
        }
      } else {
        if (regexRepl == null) {
          for (final m in matches) {
            out.add(m.group(1) ?? m.group(0));
          }
        } else {
          out.add(t.replaceAllMapped(re, (m) => _expand(m, regexRepl!)));
        }
      }
    }
    return out;
  }

  static String _expand(Match m, String template) {
    var r = template;
    for (var i = m.groupCount; i >= 0; i--) {
      r = r.replaceAll('\$$i', m.group(i) ?? '');
    }
    return r;
  }

  static dynamic _asJsonValue(String content) {
    final v = _tryJson(content);
    return v;
  }

  /// 拆分顶层分隔符（跳过引号内的部分）。
  /// 引号不配对（奇数个）时视为规则里的普通字符，按纯深度拆分，避免状态机吞掉分隔符。
  static List<String> _splitTopLevel(String s, String sep) {
    var sq = 0, dq = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == "'") {
        sq++;
      } else if (s[i] == '"') {
        dq++;
      }
    }
    final honorQuotes = sq % 2 == 0 && dq % 2 == 0;

    final out = <String>[];
    var depth = 0;
    String? quote;
    var buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (honorQuotes && quote != null) {
        buf.write(c);
        if (c == quote) quote = null;
        continue;
      }
      if (honorQuotes && (c == '"' || c == "'")) {
        quote = c;
        buf.write(c);
        continue;
      }
      if (c == '{' || c == '[' || c == '(') depth++;
      if (c == '}' || c == ']' || c == ')') depth--;
      if (depth == 0 && i + sep.length <= s.length && s.substring(i, i + sep.length) == sep) {
        out.add(buf.toString());
        buf = StringBuffer();
        i += sep.length - 1;
        continue;
      }
      buf.write(c);
    }
    out.add(buf.toString());
    return out.map((e) => e.trim()).toList();
  }

  /// JSoup 风格选择器链：class.x / id.x / tag.x / text.x / 原生标签，
  /// 可带末尾属性（@text/@href...）与下标 [n]。
  static List<dynamic> _cssChain(h.Document doc, String rule) {
    var work = rule;

    // 末尾属性：@text、@href 等。属性名不含 `.`；`class.a@tag.li` 这类 @ 后接选择器的是级联分隔符
    String? attr;
    final atIdx = _lastUnbracketed(work, '@');
    if (atIdx > 0) {
      final maybeAttr = work.substring(atIdx + 1).trim();
      if (!maybeAttr.contains('@') && !maybeAttr.contains('.') && !_looksLikeSelectorStep(maybeAttr)) {
        work = work.substring(0, atIdx).trimRight();
        attr = maybeAttr;
      }
    }
    // 剩余的 @ 视为步骤分隔符（Legado: class.a@tag.b@text）
    work = _replaceAtOutsideBrackets(work);

    // 末尾下标：[0] [1-3] [last] [*]（仅识别下标形态，避免误吞 [href^="..."] 属性选择器）
    String? indexExpr;
    final indexMatch = RegExp(r'\[(.+)\]$').firstMatch(work);
    if (indexMatch != null &&
        _looksLikeIndex(indexMatch.group(1)!) &&
        _lastUnbracketed(work, '[') == work.length - indexMatch.group(0)!.length) {
      indexExpr = indexMatch.group(1);
      work = work.substring(0, work.length - indexMatch.group(0)!.length);
    }

    List<dynamic> elements = [];
    // 伪类 / 属性选择器 / 子组合符：分步匹配无法处理，先转成原生 CSS 尝试
    if (work.contains(':') || work.contains('[') || work.contains('>')) {
      elements = _selectNative(doc, work);
    }
    if (elements.isEmpty) elements = _select(doc, work);

    if (attr == 'textNodes') {
      final texts = elements.map((e) => _getAttr(e, 'textNodes')).where((s) => (s as String).isNotEmpty).toList();
      return indexExpr == null ? texts : _applyIndex(texts, indexExpr);
    }
    if (indexExpr != null) elements = _applyIndex(elements, indexExpr);
    if (attr != null) return elements.map((e) => _getAttr(e, attr!)).toList();
    return elements;
  }

  static bool _looksLikeIndex(String e) =>
      e == '*' || e == 'last' || RegExp(r'^\d+(-\d+)?$').hasMatch(e) || RegExp(r'^last-\d+$').hasMatch(e);

  static bool _looksLikeSelectorStep(String e) =>
      e.startsWith('class.') || e.startsWith('id.') || e.startsWith('tag.') || e.startsWith('text.');

  static String _replaceAtOutsideBrackets(String s) {
    final sb = StringBuffer();
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '[' || c == '(') depth++;
      if (c == ']' || c == ')') depth--;
      sb.write(c == '@' && depth == 0 ? '.' : c);
    }
    return sb.toString();
  }

  /// Legado 步骤链 → 原生 CSS：class.x→.x、id.x→#x、tag.x→x，步骤间按后代组合。
  /// 含 text. 前缀或数字下标时无法直译，返回 null 交给分步匹配。
  static List<dynamic> _selectNative(h.Document doc, String work) {
    var css = _legadoToCss(work);
    if (css == null || css.isEmpty) return [];
    // package:html 的 :nth-child 以 0 起算，Legado/jsoup 惯例以 1 起算，需平移
    css = css.replaceAllMapped(RegExp(r':nth-child\((\d+)\)'), (m) {
      final n = int.tryParse(m.group(1)!) ?? 0; // 超长数字直译让下面 try 兜住
      if (n <= 0) return m.group(0)!;
      return n == 1 ? ':first-child' : ':nth-child(${n - 1})';
    });
    try {
      return doc.querySelectorAll(css).toList();
    } catch (_) {
      return [];
    }
  }

  static String? _legadoToCss(String work) {
    final tokens = _splitDotOutsideBrackets(work);
    if (tokens.isEmpty) return null;
    final parts = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (t == 'class') {
        if (i + 1 >= tokens.length) return null;
        var sel = '.${tokens[++i]}';
        while (i + 1 < tokens.length && !_isKeyword(tokens[i + 1]) && int.tryParse(tokens[i + 1]) == null) {
          sel += '.${tokens[++i]}';
        }
        parts.add(sel);
      } else if (t == 'id') {
        if (i + 1 >= tokens.length) return null;
        parts.add('#${tokens[++i]}');
      } else if (t == 'tag') {
        if (i + 1 >= tokens.length) return null;
        parts.add(tokens[++i]);
      } else if (t == 'text' || t == 'matches' || t == 'match' || int.tryParse(t) != null) {
        return null;
      } else {
        parts.add(t);
      }
    }
    return parts.join(' ');
  }

  /// 按 `.` 切分，但跳过 `[]`/`()` 内部的点（属性选择器值可能含点）
  static List<String> _splitDotOutsideBrackets(String s) {
    final out = <String>[];
    var buf = StringBuffer();
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '[' || c == '(') {
        depth++;
      } else if (c == ']' || c == ')') {
        depth--;
      } else if (c == '.' && depth == 0) {
        out.add(buf.toString());
        buf = StringBuffer();
        continue;
      }
      buf.write(c);
    }
    out.add(buf.toString());
    return out.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  static int _lastUnbracketed(String s, String ch) {
    var depth = 0;
    for (var i = s.length - 1; i >= 0; i--) {
      final c = s[i];
      if (c == ']' || c == ')') depth++;
      if (c == '[' || c == '(') depth--;
      if (depth == 0 && c.toString() == ch && i > 0) return i;
    }
    return -1;
  }

  static List<dynamic> _applyIndex(List<dynamic> list, String expr) {
    if (expr == '*') return list;
    if (expr == 'last') return list.isEmpty ? [] : [list.last];
    final range = RegExp(r'^(\d+)-(\d+)$').firstMatch(expr);
    if (range != null) {
      final s = int.tryParse(range.group(1)!);
      final e = int.tryParse(range.group(2)!);
      if (s == null || e == null || s < 0 || e < 0) return [];
      final from = s > list.length ? list.length : s;
      // e+1 先与长度比较，避免巨大 e 加法回绕
      final to = e >= list.length - 1 ? list.length : e + 1;
      return from <= to ? list.sublist(from, to) : [];
    }
    final lastMinus = RegExp(r'^last-(\d+)$').firstMatch(expr);
    if (lastMinus != null) {
      final k = int.tryParse(lastMinus.group(1)!);
      if (k == null || k < 0 || k >= list.length) return [];
      return [list[list.length - 1 - k]];
    }
    final n = int.tryParse(expr);
    if (n != null) return (n >= 0 && n < list.length) ? [list[n]] : [];
    // 未识别的 [...]（过滤器/切片/函数等）不能整表放行，否则错源产出假书目
    return [];
  }

  /// 顺序步骤选择：class./id./tag./text. 与裸标签名、数字下标逐步收窄。
  static List<dynamic> _select(h.Document doc, String selector) {
    final tokens = selector.split('.').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (tokens.isEmpty) return <h.Element>[];

    List<dynamic> level = <dynamic>[doc.documentElement!]; // 虚拟根

    bool matchClass(dynamic el, String c) => el is h.Element && _hasClass(el, c);
    bool matchTag(dynamic el, String t) => el is h.Element && el.localName == t;
    bool matchId(dynamic el, String id) => el is h.Element && el.attributes['id'] == id;
    bool matchText(dynamic el, String t) => el is h.Element && el.text.trim().contains(t);

    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      String? next() => i + 1 < tokens.length ? tokens[++i] : null;

      List<dynamic> narrowed;
      if (t == 'class') {
        final v = next();
        if (v == null) return [];
        // class.a.b —— 连续非前缀 token 视为多个 class
        narrowed = _descendants(level).where((e) => matchClass(e, v)).toList();
        while (i + 1 < tokens.length && !_isKeyword(tokens[i + 1]) && int.tryParse(tokens[i + 1]) == null) {
          final v2 = tokens[++i];
          narrowed = narrowed.where((e) => matchClass(e, v2)).toList();
        }
      } else if (t == 'id') {
        final v = next();
        if (v == null) return [];
        narrowed = _descendants(level).where((e) => matchId(e, v)).toList();
      } else if (t == 'tag') {
        final v = next();
        if (v == null) return [];
        narrowed = _descendants(level).where((e) => matchTag(e, v)).toList();
      } else if (t == 'text') {
        final v = next();
        if (v == null) return [];
        narrowed = _descendants(level).where((e) => matchText(e, v)).toList();
      } else if (t == 'matches' || t == 'match') {
        // text.matches.xxx 已被 text 分支吞掉，这里防御
        return [];
      } else if (int.tryParse(t) != null) {
        final n = int.parse(t);
        // Legado/jsoup：数字步骤对“当前匹配列表”取第 n 个（如 class.newbox.0），而非后代
        narrowed = (n >= 0 && n < level.length) ? [level[n]] : [];
      } else {
        // 裸 token：当作标签名
        narrowed = _descendants(level).where((e) => matchTag(e, t)).toList();
        if (narrowed.isEmpty) {
          // 兜底当 class 处理
          narrowed = _descendants(level).where((e) => matchClass(e, t)).toList();
        }
      }
      if (narrowed.isEmpty) return [];
      level = narrowed;
    }
    return level;
  }

  static bool _isKeyword(String t) => t == 'class' || t == 'id' || t == 'tag' || t == 'text';

  static Iterable<dynamic> _descendants(List<dynamic> level) {
    final out = <dynamic>[];
    for (final node in level) {
      if (node is h.Element) {
        _collectElements(node, out);
      }
    }
    return out;
  }

  static void _collectElements(h.Element parent, List<dynamic> out) {
    for (final child in parent.children) {
      out.add(child);
      _collectElements(child, out);
    }
  }

  static bool _hasClass(h.Element el, String cls) {
    final c = el.attributes['class'];
    if (c == null) return false;
    return c.split(RegExp(r'\s+')).contains(cls);
  }

  static List<dynamic> _cssSelectAll(h.Document doc, String css) {
    try {
      return doc.querySelectorAll(css).toList();
    } catch (_) {
      return [];
    }
  }

  static dynamic _getAttr(dynamic node, String attr) {
    if (node is! h.Element) return node;
    switch (attr) {
      case 'text':
        return node.text.trim();
      case 'textNodes':
        return node.nodes
            .whereType<h.Text>()
            .map((t) => t.text.trim())
            .where((s) => s.isNotEmpty)
            .join('\n');
      case 'html':
      case 'outerHtml':
        return node.outerHtml;
      case 'innerHtml':
      case 'innerHtmlNodes':
        return node.innerHtml;
      case 'tag':
        return node.localName ?? '';
      case 'href':
        return node.attributes['href'] ?? '';
      case 'src':
        return node.attributes['src'] ?? node.attributes['data-src'] ?? '';
      default:
        return node.attributes[attr] ?? '';
    }
  }

  static String _nodeToText(dynamic node) {
    if (node == null) return '';
    if (node is String) return node;
    if (node is h.Element) return node.text.trim();
    return node.toString();
  }

  /// JSONPath 子集：`$.a.b[0].c`、`$..name`、`a.b`（相对）
  static List<dynamic> _jsonPath(dynamic root, String path) {
    path = path.trim();
    if (path.isEmpty) return root == null ? [] : [root];
    if (path.startsWith(r'$')) path = path.substring(1);
    final tokens = _tokenizeJsonPath(path);
    var current = <dynamic>[root];
    for (final t in tokens) {
      final next = <dynamic>[];
      for (final item in current) {
        if (t == '*') {
          if (item is List) {
            next.addAll(item);
          } else if (item is Map) {
            next.addAll(item.values);
          }
        } else if (t.startsWith('[') && t.endsWith(']')) {
          final inner = t.substring(1, t.length - 1);
          if (inner == '*') {
            // [*] 对数组取元素、对对象取值（current0 包一层会错过 Map 分支）
            if (item is List) {
              next.addAll(item);
            } else if (item is Map) {
              next.addAll(item.values);
            }
          } else if (inner.length >= 2 &&
              (inner[0] == "'" || inner[0] == '"') &&
              inner.endsWith(inner[0])) {
            final key = inner.substring(1, inner.length - 1);
            if (item is Map && item.containsKey(key)) next.add(item[key]);
          } else {
            final filtered = _applyIndex(current0(item), inner);
            next.addAll(filtered);
          }
        } else if (t.startsWith('..')) {
          _descend(item, t.substring(2), next);
        } else {
          if (item is Map && item.containsKey(t)) {
            next.add(item[t]);
          } else if (item is List) {
            final n = int.tryParse(t);
            if (n != null && n >= 0 && n < item.length) next.add(item[n]);
          }
        }
      }
      current = next;
      if (current.isEmpty) break;
    }
    // 终点若命中 JSON 数组（如 bookList: `$.data`），展平为逐元素节点列表
    final flat = <dynamic>[];
    for (final e in current) {
      if (e is List) {
        flat.addAll(e);
      } else {
        flat.add(e);
      }
    }
    return flat;
  }

  static List<dynamic> current0(dynamic item) => item is List ? item : [item];

  static void _descend(dynamic node, String key, List<dynamic> out) {
    if (node is Map) {
      for (final entry in node.entries) {
        if (entry.key == key) {
          out.add(entry.value);
        } else {
          _descend(entry.value, key, out);
        }
      }
    } else if (node is List) {
      for (final e in node) {
        _descend(e, key, out);
      }
    }
  }

  static List<String> _tokenizeJsonPath(String path) {
    final tokens = <String>[];
    var buf = StringBuffer();
    var inBracket = 0;
    var descendNext = false; // 刚消费 `..`，下一个 token 为递归下降
    String? quote;
    void flush() {
      if (buf.isEmpty) return;
      final raw = buf.toString();
      var t = raw;
      if (descendNext) {
        if (!raw.startsWith('[')) {
          t = '..$raw';
        } else {
          // $..['key'] 括号式递归下降：归一为 ..key；$..[数字] 罕见，保留普通下标
          final inner = raw.substring(1, raw.length - 1).trim();
          if (inner.length >= 2 &&
              (inner[0] == "'" || inner[0] == '"') &&
              inner.endsWith(inner[0])) {
            t = '..${inner.substring(1, inner.length - 1)}';
          }
        }
      }
      tokens.add(t);
      buf = StringBuffer();
      descendNext = false;
    }

    for (var i = 0; i < path.length; i++) {
      final c = path[i];
      if (quote != null) {
        buf.write(c);
        if (c == quote) quote = null;
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        buf.write(c);
        continue;
      }
      if (c == '[') {
        flush();
        inBracket++;
        buf.write(c);
        continue;
      }
      if (c == ']') {
        inBracket--;
        buf.write(c);
        if (inBracket == 0) flush();
        continue;
      }
      if (c == '.' && inBracket == 0) {
        flush();
        if (i + 1 < path.length && path[i + 1] == '.') {
          descendNext = true;
          i++; // 消费第二个点
        }
        continue;
      }
      buf.write(c);
    }
    flush();
    return tokens.where((t) => t.isNotEmpty).toList();
  }
}

/// 解析 `id.content@textNodes` 里 JSON 内容等场景的入口辅助。
class ContentAnalyzer {
  /// 判断响应内容是否 JSON：仅看首字符会把 `[第一卷]` 开头的纯文本章节误判
  /// 成 JSON 导致正文为空，必须实际解码成功才算。
  static bool isJsonContent(String body) {
    final t = body.trimLeft();
    if (!t.startsWith('{') && !t.startsWith('[')) return false;
    try {
      jsonDecode(t);
      return true;
    } catch (_) {
      return false;
    }
  }
}

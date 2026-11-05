import 'dart:convert';

import 'package:html/dom.dart' as h;
import 'package:html/parser.dart' as html_parser;

import 'xpath.dart';

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
/// - 组合分隔符（按「字符串里最先出现」的那个拆，与 Legado 一致）：
///   `||` 回退（取第一个非空分支）、`&&` 拼接、`%%` 随机（固定取第一条）；
///   `;;` 回退是本实现的扩展写法
/// - CSS/JSoup 风格选择器：`class.x`、`id.x`、`tag.x`、`text.x`、`@css:...`，
///   `@` 与 `.` 都是步骤分隔符（`class.b0@dd.-1@a@text`）
/// - jsoup 专有筛选（package:html 不认，自己实现）：`:contains()`、`:containsOwn()`、
///   `:matches()`、`:matchesOwn()`、`[attr~=正则]`（jsoup 语义是正则 find，不是 CSS 词匹配）
/// - 属性读取：`@text`、`@textNodes`、`@ownText`、`@html`、`@innerHtml`、`@src`、`@href`、
///   `@id`、`@class`、`@tag` 或任意属性名
/// - 列表下标：`[0]`、`[1-3]`、`[last]`、`[last-2]`、`[-1]`（倒数）、`[-1:0]`（闭区间、可倒序），
///   `.`/`!` 分隔形式 `.0`、`.-1`、`.!-1`
/// - 模式标志与模板：行首 `@@`（按默认规则解析，剥掉即可）、`{{子规则}}` 字符串插值
/// - 正则处理：`##pattern##replacement`（无 replacement 时为匹配提取）、`###pattern`（过滤）
/// - JSON 模式 JSONPath 子集：`$.a.b[0]`、`$..key`、`[*]`、数组根 `$[*]`
/// - XPath 子集：`@xpath://div[@class='item']`、裸 `//meta[...]`（Legado 视同 `@xpath:`）、
///   `//li/a@href`、`//text()`、`[-1]`、`[last()]`、`[position()<5]`、`[text()='v']`、
///   `[contains(@id,'x')]`、`following-sibling::`、`not()`、`and`/`or`、`|`
///   （求值在 `core/xpath.dart`，超出子集一律当不支持）
/// - 不支持的规则（`<js>`、`@js:`、XPath 里超出子集的写法）返回空并记录警告
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
  /// [scalarsOnly]：模板插值用，JSON 里的 Map/List 结果留空（不能拼成 Dart 字面量）
  static List<dynamic> _analyze(String content, String rule,
      {bool nodes = false, bool isJson = false, bool scalarsOnly = false}) {
    rule = rule.trim();
    // Legado 的 `@@` 是「按默认规则解析」的模式标志（不是选择器的一部分）：
    // 真实书源用它来把 `@@//dt[-1]/…` 这种 XPath 从 JS 模式里择出来
    while (rule.startsWith('@@')) {
      rule = rule.substring(2).trimLeft();
    }
    if (rule.isEmpty) return [];
    if (content.isEmpty && isJson == false && rule != '@' && !rule.startsWith('@put')) return [];

    // 组合规则 ;; 回退
    final fallbackParts = _splitTopLevel(rule, ';;');
    if (fallbackParts.length > 1) {
      for (final p in fallbackParts) {
        final r = _analyze(content, p, nodes: nodes, isJson: isJson, scalarsOnly: scalarsOnly);
        if (r.isNotEmpty) return r;
      }
      return [];
    }

    // 组合分隔符：Legado 的 splitRule("&&","||","%%") 没有优先级，取「字符串里最先出现」的那个
    // 整条切开，每段再递归重切——所以 `a||b&&c` 先按 || 切，&& 只在后段内部生效。
    String? combinator;
    var combinatorAt = -1;
    for (final sep in const ['&&', '||', '%%']) {
      final pos = _topLevelPositions(rule, sep);
      if (pos.isEmpty) continue;
      if (combinatorAt < 0 || pos[0] < combinatorAt) {
        combinatorAt = pos[0];
        combinator = sep;
      }
    }
    if (combinator != null) {
      final parts = _splitTopLevel(rule, combinator);
      if (combinator == '||') {
        // 回退：第一条非空即停（真实写法：来看文学 `a.1@text||a.0@text`）
        for (final p in parts) {
          final r = _analyze(content, p, nodes: nodes, isJson: isJson, scalarsOnly: scalarsOnly);
          if (r.isNotEmpty) return r;
        }
        return [];
      }
      if (combinator == '%%') {
        // 随机取一条 —— 固定取第一条，结果可预期
        return _analyze(content, parts.first, nodes: nodes, isJson: isJson, scalarsOnly: scalarsOnly);
      }
      final out = <dynamic>[];
      for (final p in parts) {
        out.addAll(_analyze(content, p, nodes: nodes, isJson: isJson, scalarsOnly: scalarsOnly));
      }
      return out;
    }

    // 正则段：查找第一个 ##，剩余部分为替换。
    // `{{…##…}}` 模板内部的 ## 属于子规则，不能当外层切点（真实写法：
    // `{{@@class.ml@text##更新时间：}} • {{@@span:contains(类别：)@text##^类别：}}`）
    String core = rule;
    String? regexPattern;
    String? regexRepl;
    bool regexFilter = false;
    final idx = _firstOutsideTemplate(rule, '##');
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
    } else if (core.startsWith('@xpath:') || core.startsWith('//')) {
      // Legado 把 `//` 开头直接当 XPath（真实书源里 15 个源的 ruleBookInfo 全是 `//meta[...]`），
      // 与 `@xpath:` 前缀同义
      results = _xpathRule(content, core.startsWith('@xpath:') ? core.substring(7) : core);
    } else if (core.startsWith('@js:') || core.contains('<js>')) {
      _warn('暂不支持 JS 规则: ${core.length > 60 ? '${core.substring(0, 60)}…' : core}');
      return [];
    } else if (_hasTemplate(core)) {
      // Legado `{{子规则}}` 字符串模板：字面量原样保留，子规则对同一条内容求值，
      // 多条结果以换行连接（真实写法：来看文学 `{{@@dd.-1@a@text}} • {{@@class.ml@text##更新时间：}}`）
      if (core.contains('@js:')) {
        _warn('暂不支持 JS 规则: ${core.length > 60 ? '${core.substring(0, 60)}…' : core}');
        return [];
      }
      results = [_composeTemplate(content, core, isJson: isJson)];
    } else if (isJson) {
      results = _jsonPath(_asJsonValue(content), core);
    } else {
      results = _cssChain(_parseHtml(content), core);
    }

    // 兜底只对纯文本内容生效：选择器没命中就把带标签的原文当文本喂给正则，
    // 上层会拿到整段 `<tr>…</tr>` 当书名，搜索结果页满屏脏条目。
    if (results.isEmpty &&
        nodes == false &&
        regexPattern != null &&
        core.isNotEmpty &&
        !isJson &&
        !containsMarkup(content)) {
      // 元素未命中时，允许对全文执行正则兜底（部分书源写法）
      results = [content];
    }

    if (nodes) return results;

    var texts = results.map(_nodeToText).toList();
    if (scalarsOnly) {
      // 模板插值用：JSON 的 Map/List 会变成 Dart 字面量（`{a: 1}`）拼进 URL 就是坏链，一律留空
      for (var i = 0; i < results.length && i < texts.length; i++) {
        final r = results[i];
        if (r is Map || r is List) texts[i] = '';
      }
    }

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

  /// 规则里是否含成对的 `{{…}}`（模板标志）
  static bool _hasTemplate(String core) {
    final open = core.indexOf('{{');
    return open >= 0 && core.indexOf('}}', open + 2) >= 0;
  }

  /// 第一个不落在 `{{…}}` 内部的 sep 出现位置，没有则返回 -1。
  /// 只数成对的 `{{`/`}}`：正则量词的单花括号（`{2,}`）不该影响切点。
  static int _firstOutsideTemplate(String s, String sep) {
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      if (s.startsWith('{{', i)) {
        depth++;
        i++;
        continue;
      }
      if (depth > 0 && s.startsWith('}}', i)) {
        depth--;
        i++;
        continue;
      }
      if (depth == 0 && s.startsWith(sep, i)) return i;
    }
    return -1;
  }

  /// `{{子规则}}` 模板求值：字面量原样保留，子规则结果去空后以换行连接。
  static String _composeTemplate(String content, String core, {bool isJson = false}) {
    final sb = StringBuffer();
    var pos = 0;
    while (pos < core.length) {
      final open = core.indexOf('{{', pos);
      if (open < 0) break;
      final close = core.indexOf('}}', open + 2);
      if (close < 0) break;
      sb.write(core.substring(pos, open));
      final sub = core.substring(open + 2, close).trim();
      if (sub.isNotEmpty) {
        final vals = _analyze(content, sub, isJson: isJson, scalarsOnly: true)
            .map(_nodeToText)
            .where((s) => s.isNotEmpty)
            .toList();
        sb.write(vals.join('\n'));
      }
      pos = close + 2;
    }
    sb.write(core.substring(pos));
    return sb.toString();
  }

  static String _expand(Match m, String template) {
    // 单次从左到右替换 $N，用组内容直接产出，避免把已插入的组文本当作新的 $N 再次展开
    // （旧的下行循环会让捕获自页面、内含 "$0"/"$1" 字面量的组值被重复替换而注入/复制正文）
    return template.replaceAllMapped(RegExp(r'\$(\d+)'), (g) {
      final i = int.tryParse(g[1]!);
      if (i == null || i > m.groupCount) return g[0]!;
      return m.group(i) ?? '';
    });
  }

  static dynamic _asJsonValue(String content) {
    final v = _tryJson(content);
    return v;
  }

  /// 拆分顶层分隔符（跳过引号内的部分）。
  /// 引号不配对（奇数个）时视为规则里的普通字符，按纯深度拆分，避免状态机吞掉分隔符。
  static List<String> _splitTopLevel(String s, String sep) {
    final cuts = _topLevelPositions(s, sep);
    if (cuts.isEmpty) return [s.trim()];
    final out = <String>[];
    var start = 0;
    for (final c in cuts) {
      out.add(s.substring(start, c));
      start = c + sep.length;
    }
    out.add(s.substring(start));
    return out.map((e) => e.trim()).toList();
  }

  /// `sep` 出现在「顶层」（引号与配对括号之外）的位置列表，重叠匹配只取先出现的那个。
  static List<int> _topLevelPositions(String s, String sep) {
    var sq = 0, dq = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == "'") {
        sq++;
      } else if (s[i] == '"') {
        dq++;
      }
    }
    final honorQuotes = sq % 2 == 0 && dq % 2 == 0;

    final out = <int>[];
    var depth = 0;
    String? quote;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (honorQuotes && quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (honorQuotes && (c == '"' || c == "'")) {
        quote = c;
        continue;
      }
      if (c == '{' || c == '[' || c == '(') depth++;
      if (c == '}' || c == ']' || c == ')') depth--;
      if (depth == 0 && i + sep.length <= s.length && s.substring(i, i + sep.length) == sep) {
        out.add(i);
        i += sep.length - 1;
      }
    }
    return out;
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
      if (!maybeAttr.contains('@') &&
          !maybeAttr.contains('.') &&
          !maybeAttr.contains('!') &&
          !_looksLikeSelectorStep(maybeAttr)) {
        work = work.substring(0, atIdx).trimRight();
        attr = maybeAttr;
      }
    }
    // 末尾下标：[0] [1-3] [-1] [last] [*]（仅识别下标形态，避免误吞 [href^="..."] 属性选择器）
    String? indexExpr;
    final indexMatch = RegExp(r'\[(.+)\]$').firstMatch(work);
    if (indexMatch != null &&
        _looksLikeIndex(indexMatch.group(1)!) &&
        _lastUnbracketed(work, '[') == work.length - indexMatch.group(0)!.length) {
      indexExpr = indexMatch.group(1);
      work = work.substring(0, work.length - indexMatch.group(0)!.length);
    }
    // 剩余的 @ 是步骤分隔符（Legado: class.a@tag.b@text），. 只在步骤内分隔修饰
    final dotted = _replaceAtOutsideBrackets(work);
    final steps = _splitAtOutsideBrackets(work);

    List<dynamic> elements = [];
    // 伪类 / 属性选择器 / 子组合符：分步匹配无法处理，先转成原生 CSS 尝试
    if (dotted.contains(':') || dotted.contains('[') || dotted.contains('>')) {
      elements = _selectNative(doc, dotted);
    }
    if (elements.isEmpty) elements = _selectSteps(doc, steps);

    if (attr == 'textNodes') {
      final texts = elements.map((e) => _getAttr(e, 'textNodes')).where((s) => (s as String).isNotEmpty).toList();
      return indexExpr == null ? texts : _applyIndex(texts, indexExpr);
    }
    if (indexExpr != null) elements = _applyIndex(elements, indexExpr);
    if (attr != null) return elements.map((e) => _getAttr(e, attr!)).toList();
    return elements;
  }

  static bool _looksLikeIndex(String e) =>
      e == '*' ||
      e == 'last' ||
      RegExp(r'^-?\d+$').hasMatch(e) ||
      RegExp(r'^\d+(-\d+)?$').hasMatch(e) ||
      RegExp(r'^last-\d+$').hasMatch(e) ||
      RegExp(r'^-?\d+:-?\d+(:-?\d+)?$').hasMatch(e);

  /// 列表下标步骤：`0`、`-1`（倒数第一）、`!-1`（Legado 的 `!` 分隔写法）。
  /// 返回取整后的下标，不是下标写法返回 null。
  static int? _indexToken(String t) {
    if (t.isEmpty) return null;
    final body = t[0] == '!' ? t.substring(1) : t;
    return RegExp(r'^-?\d+$').hasMatch(body) ? int.tryParse(body) : null;
  }

  static bool _isIndexToken(String t) => _indexToken(t) != null;

  /// Legado `AnalyzeByJSoup.findIndexSet`：负数下标 = 倒数第 N，越界静默丢弃（出空，不钳边）。
  static int? _indexAt(int length, int n) {
    final i = n < 0 ? length + n : n;
    return (i >= 0 && i < length) ? i : null;
  }

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

  /// 按顶层 `@` 切步骤（跳过 `[]`/`()` 里的 @，属性值里常见 `a@b.com`）。
  static List<String> _splitAtOutsideBrackets(String s) {
    final out = <String>[];
    var buf = StringBuffer();
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '[' || c == '(') depth++;
      if (c == ']' || c == ')') depth--;
      if (c == '@' && depth == 0) {
        out.add(buf.toString());
        buf = StringBuffer();
        continue;
      }
      buf.write(c);
    }
    out.add(buf.toString());
    return out.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// Legado 步骤链 → 原生 CSS：class.x→.x、id.x→#x、tag.x→x，步骤间按后代组合。
  /// 含 text. 前缀或数字下标时无法直译，返回 null 交给分步匹配。
  static List<dynamic> _selectNative(h.Document doc, String work) {
    final css = _legadoToCss(work);
    if (css == null || css.isEmpty) return [];
    return _selectStepCss(doc, css);
  }

  /// 选择器求值：先摘掉 jsoup 专有筛选（`:contains()`/`[attr~=正则]` 这些 package:html 不认的），
  /// 剩下的部分仍交回 CSS；一条都没摘到时直接走老路。
  static List<dynamic> _selectStepCss(h.Document doc, String css) {
    final ext = _extractJsoupFilters(css);
    if (ext == null) return _selectNativeCss(doc, css);
    // 只剩筛选伪类时用 `*` 兜底（jsoup 允许写 `:contains(x)` 省略标签名）
    final base = ext.css.trim().isEmpty ? '*' : ext.css.trim();
    return _applyJsoupFilters(_selectNativeCss(doc, base), ext);
  }

  static List<dynamic> _selectNativeCss(h.Document doc, String css) {
    final nth = _takeNthChild(css);
    if (nth != null) return _applyNthChild(doc, nth);
    // 走到这里说明 nth 形态没被上面接管（多个 nth、或不在末尾复合段），
    // 只能交给 package:html：它按「全部子节点」0 起算，比 jsoup 的元素序差一格，需平移
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

  /// `:nth-child(...)` / `:nth-last-child(...)` 自己实现（jsoup/Legado 语义）。
  /// 只接管「整条选择器恰有一个 nth 伪类，且位于最后一个复合选择段」的形态——
  /// 这是书源里的写法（`class.booklist tag.li:nth-child(2)`），也唯一能保证
  /// nth 下标算在所报元素自身身上的情形；其余形态返回 null 让调用方兜底。
  static _NthChild? _takeNthChild(String css) {
    final found = <int>[];
    final nthEnds = <int>[];
    var depth = 0;
    var hasComma = false;
    String? quote;
    var lastCombinatorEnd = -1; // 最后一个组合符（含其后空白）结束的位置，即末段起点
    for (var i = 0; i < css.length; i++) {
      final c = css[i];
      if (quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        continue;
      }
      if (c == '[' || c == '(') {
        depth++;
        continue;
      }
      if (c == ']' || c == ')') {
        depth--;
        continue;
      }
      if (depth != 0) continue;
      if (c == ',') hasComma = true; // 逗号选择器组：nth 只作用于其中一组，摘出来会误伤其余组
      if (c == '>' || c == '+' || c == '~' || c == ' ' || c == '\t' || c == '\n') {
        var j = i;
        while (j < css.length &&
            (css[j] == '>' ||
                css[j] == '+' ||
                css[j] == '~' ||
                css[j] == ' ' ||
                css[j] == '\t' ||
                css[j] == '\n')) {
          j++;
        }
        lastCombinatorEnd = j - 1;
        i = j - 1;
        continue;
      }
      if (c == ':' &&
          (css.startsWith(':nth-child(', i) || css.startsWith(':nth-last-child(', i))) {
        final open = css.indexOf('(', i);
        var d = 0;
        var k = open;
        for (; k < css.length; k++) {
          if (css[k] == '(') {
            d++;
          } else if (css[k] == ')') {
            d--;
            if (d == 0) break;
          }
        }
        if (k >= css.length) return null; // 括号不配对，交给原生解析报错走老路
        found.add(i);
        nthEnds.add(k);
        i = k;
      }
    }
    if (found.length != 1 || hasComma) return null;
    final start = found[0];
    if (lastCombinatorEnd > start) return null; // nth 不在末段，下标会算到别的元素上
    final fromEnd = css.startsWith(':nth-last-child', start);
    final open = css.indexOf('(', start);
    final expr = css.substring(open + 1, nthEnds[0]).trim();
    final ab = _parseAnPlusB(expr);
    if (ab == null) return null;
    final cleaned = (css.substring(0, start) + css.substring(nthEnds[0] + 1)).trim();
    if (cleaned.isEmpty) return null;
    return _NthChild(cleaned, fromEnd, ab[0], ab[1]);
  }

  /// `odd`/`even`/`3`/`2n`/`2n+1`/`-n+3` → [A, B]；解析不了（含溢出）返回 null。
  static List<int>? _parseAnPlusB(String expr) {
    final s = expr.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (s == 'odd') return [2, 1];
    if (s == 'even') return [2, 0];
    if (RegExp(r'^[+-]?\d+$').hasMatch(s)) {
      final b = int.tryParse(s.replaceFirst('+', ''));
      return b == null ? null : [0, b];
    }
    final m = RegExp(r'^([+-]?\d*)n(?:([+-]\d+))?$').firstMatch(s);
    if (m == null) return null;
    final aText = m.group(1)!;
    final int? a;
    if (aText.isEmpty || aText == '+') {
      a = 1;
    } else if (aText == '-') {
      a = -1;
    } else {
      a = int.tryParse(aText);
    }
    if (a == null) return null;
    final bText = m.group(2);
    final b = bText == null ? 0 : int.tryParse(bText);
    if (b == null) return null;
    return [a, b];
  }

  static List<dynamic> _applyNthChild(h.Document doc, _NthChild nth) {
    List<dynamic> base;
    try {
      base = doc.querySelectorAll(nth.css).toList();
    } catch (_) {
      return [];
    }
    return base.where((e) => e is h.Element && nth.matches(e)).toList();
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
        while (i + 1 < tokens.length && !_isKeyword(tokens[i + 1]) && !_isIndexToken(tokens[i + 1])) {
          sel += '.${tokens[++i]}';
        }
        parts.add(sel);
      } else if (t == 'id') {
        if (i + 1 >= tokens.length) return null;
        parts.add('#${tokens[++i]}');
      } else if (t == 'tag') {
        if (i + 1 >= tokens.length) return null;
        parts.add(tokens[++i]);
      } else if (t == 'text' || t == 'matches' || t == 'match' || _indexToken(t) != null) {
        return null;
      } else {
        parts.add(t);
      }
    }
    return parts.join(' ');
  }

  /// 按 `.` 切分，但跳过 `[]`/`()` 内部的点（属性选择器值可能含点）。
  /// `!` 后紧跟数字时同样是下标分隔符（Legado: `tag.tr!0`、`class.a!-1`）。
  /// 开头的 `.`/`#` 是原生 CSS 简写（`.chapter-table a.0@text`），要跟着下一段留住。
  static List<String> _splitDotOutsideBrackets(String s) {
    final out = <String>[];
    var buf = StringBuffer();
    var depth = 0;
    bool indexSep(int i) =>
        s[i] == '!' && i + 1 < s.length && (s[i + 1] == '-' || RegExp(r'\d').hasMatch(s[i + 1]));
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '[' || c == '(') {
        depth++;
      } else if (c == ']' || c == ')') {
        depth--;
      } else if (depth == 0 && i > 0 && (c == '.' || indexSep(i))) {
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
    // Legado `[]` 区间：`start:end[:step]`，两端闭区间且都可为负——
    // `[-1:0]` 是「从末到下标 0 倒序」，真实书源用它整表反转目录
    final slice = RegExp(r'^(-?\d*):(-?\d*)(?::(-?\d+))?$').firstMatch(expr);
    if (slice != null && (slice.group(1)!.isNotEmpty || slice.group(2)!.isNotEmpty)) {
      if (list.isEmpty) return [];
      final len = list.length;
      final startN = slice.group(1)!.isEmpty ? 0 : int.tryParse(slice.group(1)!);
      final endN = slice.group(2)!.isEmpty ? len - 1 : int.tryParse(slice.group(2)!);
      if (startN == null || endN == null) return [];
      final step = int.tryParse(slice.group(3) ?? '') ?? 1;
      if (step <= 0) return [];
      final start = startN < 0 ? startN + len : startN;
      final end = endN < 0 ? endN + len : endN;
      if ((start < 0 && end < 0) || (start >= len && end >= len)) return [];
      final out = <dynamic>[];
      if (end >= start) {
        for (var i = start; i <= end && i < len; i += step) {
          out.add(list[i]);
        }
      } else {
        for (var i = start; i >= end && i >= 0; i -= step) {
          out.add(list[i]);
        }
      }
      return out;
    }
    final n = int.tryParse(expr);
    if (n != null) {
      final i = _indexAt(list.length, n);
      return i == null ? [] : [list[i]];
    }
    // 未识别的 [...]（过滤器/切片/函数等）不能整表放行，否则错源产出假书目
    return [];
  }

  /// 按顶层 `@` 拆出的步骤链逐级求值：`class.b0@dd.-1@a` 三步各自收窄当前层。
  /// （Legado 的 `@` 与 `.` 都是步骤分隔符，`@` 后紧跟属性名时才表示取值，见 [_cssChain]）
  static List<dynamic> _selectSteps(h.Document doc, List<String> steps) {
    var level = <dynamic>[doc.documentElement!]; // 虚拟根
    for (final step in steps) {
      level = _selectFrom(doc, level, _splitDotOutsideBrackets(step));
      if (level.isEmpty) return [];
    }
    return level;
  }

  /// 顺序步骤选择：class./id./tag./text. 与裸标签名、数字下标逐步收窄。
  /// `from` 是本步的起点层（虚拟根或上一步的命中集合）。
  static List<dynamic> _selectFrom(h.Document doc, List<dynamic> from, List<String> tokens) {
    if (tokens.isEmpty) return from;

    List<dynamic> level = from;

    bool matchClass(dynamic el, String c) => el is h.Element && _hasClass(el, c);
    bool matchTag(dynamic el, String t) => el is h.Element && el.localName == t;
    bool matchId(dynamic el, String id) => el is h.Element && el.attributes['id'] == id;
    bool matchText(dynamic el, String t) => el is h.Element && el.text.trim().contains(t);

    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      String? next() => i + 1 < tokens.length ? tokens[++i] : null;

      List<dynamic> narrowed;
      final idxStep = t.startsWith('[') ? null : t.replaceFirst('!', '');
      // 下标步骤先于 CSS 步骤判定：`!0:1` 里的冒号是区间分隔符，不是伪类
      if (_indexToken(t) != null) {
        // Legado/jsoup：数字步骤对“当前匹配列表”取下标，负数从末尾倒着数（`.-1`=最后一个）
        final i = _indexAt(level.length, _indexToken(t)!);
        narrowed = i == null ? [] : [level[i]];
      } else if (idxStep != null && _looksLikeIndex(idxStep)) {
        // 区间步骤：`.*`、`!0:1`、`.1:2`、`last` —— 对当前层按 `[]` 同一套下标语义取值
        narrowed = _applyIndex(level, idxStep);
      } else if (t.contains(':') || t.startsWith('[') || t.startsWith('#') || t.startsWith('.') || t.contains(' ')) {
        // 属性选择器 / 伪类 / 原生 #id 与 .class（可带后代组合符 `a b`）：本步交给 CSS 侧
        // （含 `:contains()`/`:matches()`），结果限制在当前层的后代里，保持「逐步收窄」的级联语义
        final css = t.startsWith(':') || t.startsWith('[') ? '*$t' : t;
        final keep = _descendants(level).whereType<h.Element>().toSet();
        narrowed = _selectStepCss(doc, css).where((e) => keep.contains(e)).toList();
      } else if (t == 'class') {
        final v = next();
        if (v == null) return [];
        // class.a.b —— 连续非前缀 token 视为多个 class
        narrowed = _descendants(level).where((e) => matchClass(e, v)).toList();
        while (i + 1 < tokens.length && !_isKeyword(tokens[i + 1]) && !_isIndexToken(tokens[i + 1])) {
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

  /// `@xpath:` 规则：末段的 `@attr`（Legado 习惯写 `//a@href`）与 XPath 自身的
  /// `//a/@href` 走同一条路；认不出的形态记警告后返回空，绝不猜。
  static List<dynamic> _xpathRule(String content, String rawExpr) {
    var expr = rawExpr.trim();
    String? attr;
    final atIdx = _lastUnbracketed(expr, '@');
    if (atIdx > 0) {
      final maybe = expr.substring(atIdx + 1).trim();
      if (RegExp(r'^[-\w]+$').hasMatch(maybe)) {
        attr = maybe;
        expr = expr.substring(0, atIdx);
      }
    }
    try {
      final nodes = evaluateXPath(_parseHtml(content), expr);
      if (attr == null) return nodes;
      return nodes
          .map((e) => _getAttr(e, attr!))
          .where((v) => v is! String || v.isNotEmpty)
          .toList();
    } on UnsupportedXPath {
      _warn('暂不支持 XPath 规则: ${rawExpr.length > 60 ? '${rawExpr.substring(0, 60)}…' : rawExpr}');
      return [];
    }
  }

  static List<dynamic> _cssSelectAll(h.Document doc, String css) {
    final ext = _extractJsoupFilters(css);
    if (ext == null) return _cssSelectAllRaw(doc, css);
    final base = ext.css.trim().isEmpty ? '*' : ext.css.trim();
    return _applyJsoupFilters(_cssSelectAllRaw(doc, base), ext);
  }

  static List<dynamic> _cssSelectAllRaw(h.Document doc, String css) {
    final nth = _takeNthChild(css);
    if (nth != null) return _applyNthChild(doc, nth);
    try {
      return doc.querySelectorAll(css).toList();
    } catch (_) {
      return [];
    }
  }

  /// jsoup 有而 package:html 没有的筛选：`:contains()` / `:containsOwn()` / `:matches()` /
  /// `:matchesOwn()` 伪类，以及 `[attr~=正则]`（jsoup 语义是正则 find，不是 CSS 的词匹配）。
  /// 摘出来自己过滤，剩下的部分仍交给 package:html；一条都没摘到返回 null 走老路。
  /// 真实书源实例：来看文学 `span:contains(类别：)@text`、艾途/来看 `[property~=category|status]@content`。
  static _JsoupFilters? _extractJsoupFilters(String css) {
    final cleaned = StringBuffer();
    final predicates = <bool Function(h.Element)>[];
    var i = 0;
    while (i < css.length) {
      final c = css[i];
      if (c == '"' || c == "'") {
        final close = css.indexOf(c, i + 1);
        if (close < 0) {
          cleaned.write(css.substring(i));
          break;
        }
        cleaned.write(css.substring(i, close + 1));
        i = close + 1;
        continue;
      }
      if (c == '[') {
        final end = _closingBracket(css, i);
        if (end < 0) {
          cleaned.write(css.substring(i));
          break;
        }
        final inner = css.substring(i + 1, end).trim();
        final m = RegExp(r'^([\w-]+)~=(.*)$').firstMatch(inner.replaceAll(RegExp(r'\s+'), ''));
        if (m != null) {
          final attr = m.group(1)!;
          final pattern = _unquote(m.group(2)!.trim());
          final re = _compileJsoupRegex(pattern);
          if (re == null) return null; // 正则不合法就别猜，整条交给老路（出空也比出错数据好）
          predicates.add((el) => re.hasMatch(el.attributes[attr] ?? ''));
        } else {
          cleaned.write(css.substring(i, end + 1));
        }
        i = end + 1;
        continue;
      }
      if (c == ':') {
        final hit = _jsoupPseudoAt(css, i);
        if (hit != null) {
          final re = hit.kind == 'contains' || hit.kind == 'containsOwn'
              ? null
              : _compileJsoupRegex(hit.arg);
          if (hit.kind != 'contains' && hit.kind != 'containsOwn' && re == null) return null;
          final arg = hit.arg.toLowerCase();
          // jsoup 的 :contains*/:matches* 一律小写比较（Evaluator.ContainsText 用 lowerCase），
          // 英文站写成 `:contains(Chapter)` 而正文是 `chapter` 时，区分大小写会整表落空。
          switch (hit.kind) {
            case 'contains':
              predicates.add((el) => el.text.toLowerCase().contains(arg));
            case 'containsOwn':
              predicates.add((el) => _ownText(el).toLowerCase().contains(arg));
            case 'matches':
              predicates.add((el) => re!.hasMatch(el.text));
            default:
              predicates.add((el) => re!.hasMatch(_ownText(el)));
          }
          i = hit.end;
          continue;
        }
      }
      cleaned.write(c);
      i++;
    }
    if (predicates.isEmpty) return null;
    return _JsoupFilters(cleaned.toString(), predicates);
  }

  /// 从 `[` 处找配对的 `]`（跳过引号内），找不到返回 -1。
  static int _closingBracket(String s, int from) {
    var depth = 0;
    String? quote;
    for (var i = from; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '[') {
        depth++;
      } else if (c == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static ({String kind, String arg, int end})? _jsoupPseudoAt(String css, int at) {
    for (final name in const ['containsOwn', 'contains', 'matchesOwn', 'matches']) {
      final head = ':$name(';
      if (!css.startsWith(head, at)) continue;
      var depth = 0;
      String? quote;
      for (var i = at + head.length - 1; i < css.length; i++) {
        final c = css[i];
        if (quote != null) {
          if (c == quote) quote = null;
          continue;
        }
        if (c == '"' || c == "'") {
          quote = c;
        } else if (c == '(') {
          depth++;
        } else if (c == ')') {
          depth--;
          if (depth == 0) {
            return (
              kind: name,
              arg: _unquote(css.substring(at + head.length, i).trim()),
              end: i + 1,
            );
          }
        }
      }
      return null; // 括号不配对：整条走老路
    }
    return null;
  }

  static RegExp? _compileJsoupRegex(String pattern) {
    if (pattern.isEmpty) return null;
    try {
      return RegExp(pattern);
    } catch (_) {
      return null;
    }
  }

  static String _unquote(String s) => s.length >= 2 &&
          ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))
      ? s.substring(1, s.length - 1)
      : s;

  /// jsoup `Element.ownText()`：只取直属文本子节点（不含后代元素里的文字），
  /// 每段把连续空白规整成一个空格，非空白段之间以单个空格连接。
  static String _ownText(h.Element el) => el.nodes
      .whereType<h.Text>()
      .map((t) => t.text.replaceAll(RegExp(r'\s+'), ' '))
      .where((s) => s.trim().isNotEmpty)
      .join(' ')
      .trim();

  static List<dynamic> _applyJsoupFilters(List<dynamic> els, _JsoupFilters ext) {
    var out = els;
    for (final p in ext.predicates) {
      out = out.where((e) => e is h.Element && p(e)).toList();
    }
    return out;
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
      case 'ownText':
        return _ownText(node);
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

  static final RegExp _tagRe = RegExp(r'<\s*/?\s*[a-zA-Z!][^<>]*>');

  /// 文本里是否还残留 HTML 标签（含 `<!DOCTYPE` / `<!--`）。
  /// 用于识别"选择器没命中、把整段 markup 当正文返回"的脏结果。
  static bool containsMarkup(String s) => _tagRe.hasMatch(s);

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

  static void _descend(dynamic node, String key, List<dynamic> out, [int depth = 0]) {
    // 防御恶意/畸形深度嵌套 JSON（如 2 万层 `[[[...]]]`，jsonDecode 能过但此处递归会 StackOverflow）
    if (depth > 128) return;
    if (node is Map) {
      for (final entry in node.entries) {
        if (entry.key == key) {
          out.add(entry.value);
        } else {
          _descend(entry.value, key, out, depth + 1);
        }
      }
    } else if (node is List) {
      for (final e in node) {
        _descend(e, key, out, depth + 1);
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
          // raw 可能只是畸形的单个 `[`（如规则尾断成 `$..[`），须先校验长度与右括号再 substring，否则 RangeError
          if (raw.length >= 2 && raw.endsWith(']')) {
            final inner = raw.substring(1, raw.length - 1).trim();
            if (inner.length >= 2 &&
                (inner[0] == "'" || inner[0] == '"') &&
                inner.endsWith(inner[0])) {
              t = '..${inner.substring(1, inner.length - 1)}';
            }
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

/// 摘掉 nth 伪类后的选择器 + 该伪类对应的元素序号判据（jsoup/Legado 语义：只数元素、1 起算）。
class _NthChild {
  final String css;
  final bool fromEnd;
  final int a;
  final int b;
  _NthChild(this.css, this.fromEnd, this.a, this.b);

  bool matches(h.Element el) {
    final parent = el.parent;
    if (parent == null) return false;
    var count = 0;
    var index = 0; // 1 起算的元素序号
    for (final child in parent.nodes) {
      if (child is! h.Element) continue;
      count++;
      if (identical(child, el)) index = count;
    }
    if (index == 0) return false;
    final k = fromEnd ? count - index + 1 : index;
    final d = k - b;
    if (a == 0) return d == 0;
    if (d % a.abs() != 0) return false;
    return a > 0 ? d >= 0 : d <= 0;
  }
}

/// 摘掉 jsoup 专有筛选后的选择器 + 逐条元素判据（package:html 不认这些写法）。
class _JsoupFilters {
  final String css;
  final List<bool Function(h.Element)> predicates;
  _JsoupFilters(this.css, this.predicates);
}

import 'package:html/dom.dart' as h;

/// 书源里遇到求值不了的 XPath 形态时抛这个：调用方记警告并返回空。
/// 猜出来的节点集会把不相干的标签当书目/章节吐出去，比一条都选不到更坏。
class UnsupportedXPath implements Exception {
  final String expression;
  const UnsupportedXPath(this.expression);
  @override
  String toString() => '不支持的 XPath: $expression';
}

/// XPath 子集求值：把 Legado 书源里最常见的那批 `@xpath:` 表达式落到
/// 已有的 package:html DOM 上。
///
/// 支持：
/// - 路径步：`/`（子代）、`//`（后代），绝对路径 `/html/body/…`
/// - 节点测试：`*`、标签名、`text()`、`node()`
/// - 属性步：`/@href`、`//a/@id`（末段）
/// - 谓词：`[3]`、`[last()]`、`[position()<5]`、`[@attr]`、`[@attr='v']`、
///   `[@attr!='v']`、`[text()='v']`、`[.='v']`、`[contains(@attr,'v')]`、
///   `[contains(.,'v')]`、`[starts-with(@attr,'v')]`、`not(...)`、`and`/`or`，可串联
/// - 顶层并集：`//h1 | //h2`
///
/// 其余（轴 `parent::`、`normalize-space()` 之类的函数、命名空间前缀、变量）
/// 一律 [UnsupportedXPath]。
List<dynamic> evaluateXPath(h.Document doc, String expr) {
  final s = expr.trim();
  if (s.isEmpty) throw UnsupportedXPath(expr);

  // 顶层 `|` 并集（方括号与引号内的不算）
  final unions = _splitTopLevel(s, '|');
  if (unions.length > 1) {
    final out = <dynamic>[];
    for (final u in unions) {
      for (final r in evaluateXPath(doc, u)) {
        if (!out.any((e) => identical(e, r))) out.add(r);
      }
    }
    return out;
  }

  final steps = _parseSteps(s);
  var ctx = <dynamic>[doc];
  for (var i = 0; i < steps.length; i++) {
    final st = steps[i];
    if (st.attr != null) {
      // 属性只能落在末段：`@href` 之后已经没有节点集可言
      if (i != steps.length - 1 || st.predicates.isNotEmpty) throw UnsupportedXPath(expr);
      final out = <String>[];
      for (final n in ctx) {
        final v = _attrValue(n, st.attr!);
        if (v != null) out.add(v);
      }
      return out;
    }
    ctx = _applyStep(ctx, st);
    if (ctx.isEmpty) return [];
  }
  return _finish(ctx);
}

class _Step {
  final bool descendant;
  final String test;
  final List<String> predicates;
  final String? attr;
  _Step({required this.descendant, required this.test, required this.predicates, this.attr});
}

List<_Step> _parseSteps(String path) {
  var p = path;
  var firstDescendant = false;
  if (p.startsWith('//')) {
    p = p.substring(2);
    firstDescendant = true;
  } else if (p.startsWith('/')) {
    p = p.substring(1);
  } else if (p.startsWith('./')) {
    p = p.substring(2);
  }
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  if (p.isEmpty) throw UnsupportedXPath(path);

  final raw = <(bool, String)>[];
  var depth = 0;
  String? quote;
  var buf = StringBuffer();
  var pending = firstDescendant;
  for (var i = 0; i < p.length; i++) {
    final c = p[i];
    if (quote != null) {
      buf.write(c);
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      buf.write(c);
      continue;
    }
    if (c == '[' || c == '(') depth++;
    if (c == ']' || c == ')') depth--;
    if (depth == 0 && c == '/') {
      raw.add((pending, buf.toString()));
      buf = StringBuffer();
      pending = i + 1 < p.length && p[i + 1] == '/';
      if (pending) i++;
      continue;
    }
    buf.write(c);
  }
  raw.add((pending, buf.toString()));
  if (quote != null) throw UnsupportedXPath(path);

  return [for (final (desc, text) in raw) _parseStep(desc, text, path)];
}

_Step _parseStep(bool descendant, String text, String path) {
  final t = text.trim();
  if (t.isEmpty) throw UnsupportedXPath(path);
  String test;
  final preds = <String>[];
  final b = t.indexOf('[');
  if (b < 0) {
    test = t;
  } else {
    test = t.substring(0, b).trim();
    var i = b;
    while (i < t.length) {
      if (t[i] != '[') throw UnsupportedXPath(path);
      var depth = 0;
      String? quote;
      var j = i;
      for (; j < t.length; j++) {
        final c = t[j];
        if (quote != null) {
          if (c == quote) quote = null;
          continue;
        }
        if (c == '"' || c == "'") {
          quote = c;
          continue;
        }
        if (c == '[') {
          depth++;
        } else if (c == ']') {
          depth--;
          if (depth == 0) break;
        }
      }
      if (j >= t.length) throw UnsupportedXPath(path);
      preds.add(t.substring(i + 1, j));
      i = j + 1;
    }
  }

  if (test.startsWith('@')) {
    final name = test.substring(1);
    if (!_nameRe.hasMatch(name)) throw UnsupportedXPath(path);
    return _Step(descendant: descendant, test: '', predicates: preds, attr: name);
  }
  if (test != '*' && test != 'text()' && test != 'node()' && !_nameRe.hasMatch(test)) {
    // 命名空间前缀（`ns:tag`）、轴（`parent::`）、函数节点都在这里被挡掉
    throw UnsupportedXPath(path);
  }
  return _Step(descendant: descendant, test: test, predicates: preds);
}

final RegExp _nameRe = RegExp(r'^[A-Za-z][-\w.]*$');

List<dynamic> _applyStep(List<dynamic> ctx, _Step st) {
  final out = <dynamic>[];
  for (final node in ctx) {
    var set = st.descendant ? _descendantsOf(node, st.test) : _childrenOf(node, st.test);
    set = set.where((n) => _testMatches(n, st.test)).toList();
    for (final pred in st.predicates) {
      final next = <dynamic>[];
      for (var i = 0; i < set.length; i++) {
        if (_evalPredicate(pred, set[i], i + 1, set.length)) next.add(set[i]);
      }
      set = next;
    }
    for (final n in set) {
      if (!out.any((e) => identical(e, n))) out.add(n);
    }
  }
  return out;
}

bool _want(String test) => test == 'text()' || test == 'node()';

List<dynamic> _childrenOf(dynamic node, String test) {
  final Iterable<h.Node> kids;
  if (node is h.Document) {
    kids = node.nodes;
  } else if (node is h.Element) {
    kids = node.nodes;
  } else {
    return const [];
  }
  if (test == 'text()') return kids.whereType<h.Text>().toList();
  if (_want(test)) return kids.where((n) => n is h.Element || n is h.Text).toList();
  return kids.whereType<h.Element>().toList();
}

List<dynamic> _descendantsOf(dynamic node, String test) {
  final out = <dynamic>[];
  void walk(h.Node parent) {
    for (final c in parent.nodes) {
      if (c is h.Element) {
        if (test != 'text()') out.add(c);
        walk(c);
      } else if (c is h.Text) {
        if (_want(test)) out.add(c);
      }
    }
  }

  if (node is h.Node) walk(node);
  return out;
}

bool _testMatches(dynamic n, String test) {
  if (test == 'text()') return n is h.Text;
  if (test == 'node()') return n is h.Element || n is h.Text;
  if (n is! h.Element) return false;
  if (test == '*') return true;
  return (n.localName ?? '').toLowerCase() == test.toLowerCase();
}

String? _attrValue(dynamic node, String name) {
  if (node is! h.Element) return null;
  final v = node.attributes[name];
  return v is String ? v : null;
}

/// 节点的字符串值：元素取全文本，文本节点取自身。
String _stringValue(dynamic node) {
  if (node is h.Element) return node.text;
  if (node is h.Text) return node.text;
  return '';
}

final RegExp _numberRe = RegExp(r'^\d+$');

bool _evalPredicate(String predicate, dynamic node, int pos, int size) {
  final p = predicate.trim();
  if (p.isEmpty) throw UnsupportedXPath(predicate);

  final orParts = _splitTopLevel(p, 'or');
  if (orParts.length > 1) return orParts.any((e) => _evalPredicate(e, node, pos, size));
  final andParts = _splitTopLevel(p, 'and');
  if (andParts.length > 1) return andParts.every((e) => _evalPredicate(e, node, pos, size));

  if (p.startsWith('not(') && _closesAtEnd(p)) {
    return !_evalPredicate(p.substring(4, p.length - 1), node, pos, size);
  }
  if (_numberRe.hasMatch(p)) {
    final n = int.tryParse(p);
    // 超出 int 的位置谓词不可能命中任何节点；int.parse 会抛，异常不属于 UnsupportedXPath，
    // 会让整条规则从"匹配为空"升级成"解析中断"
    if (n == null) return false;
    return pos == n;
  }
  if (p == 'last()') return pos == size;

  final rel = RegExp(r'^position\(\)\s*(<=|>=|<|>|=|!=)\s*(\d+)$').firstMatch(p);
  if (rel != null) {
    // 同样的天文数字：小于它/不等于它成立，大于它/等于它不成立
    final n = int.tryParse(rel.group(2)!);
    if (n == null) {
      switch (rel.group(1)!) {
        case '<':
        case '<=':
        case '!=':
          return true;
        default:
          return false;
      }
    }
    switch (rel.group(1)!) {
      case '<':
        return pos < n;
      case '<=':
        return pos <= n;
      case '>':
        return pos > n;
      case '>=':
        return pos >= n;
      case '!=':
        return pos != n;
      default:
        return pos == n;
    }
  }

  final cmp = _splitComparison(p);
  if (cmp != null) {
    final lhs = _resolve(cmp[0], node, predicate);
    final rhs = _literal(cmp[2], predicate);
    final eq = lhs == rhs;
    return cmp[1] == '!=' ? !eq : eq;
  }

  if (p.startsWith('@') && _nameRe.hasMatch(p.substring(1))) {
    return _attrValue(node, p.substring(1)) != null;
  }
  // 没有比较符的函数谓词：`contains(...)`/`starts-with(...)` 命中返回 '1'，
  // _resolve 认得的返回非空串，认不出的直接抛 UnsupportedXPath
  if (_isCall(p)) return _resolve(p, node, predicate).isNotEmpty;
  throw UnsupportedXPath(predicate);
}

bool _isCall(String p) => RegExp(r'^(contains|starts-with)\s*\(').hasMatch(p.trim());

/// 在引号与括号之外找 `!=` / `=`，切成 [左, 运算符, 右]；没有则 null。
List<String>? _splitComparison(String p) {
  var depth = 0;
  String? quote;
  for (var i = 0; i < p.length; i++) {
    final c = p[i];
    if (quote != null) {
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    } else if (depth == 0) {
      if (i + 1 < p.length && p.substring(i, i + 2) == '!=') {
        return [p.substring(0, i).trim(), '!=', p.substring(i + 2).trim()];
      }
      if (c == '=') {
        final prev = i > 0 ? p[i - 1] : '';
        if (prev == '<' || prev == '>' || prev == '!') return null;
        return [p.substring(0, i).trim(), '=', p.substring(i + 1).trim()];
      }
    }
  }
  return null;
}

/// `contains(a,b)` / `starts-with(a,b)` 由 [_resolve]/[_literal] 接管。
String _resolve(String arg, dynamic node, String predicate) {
  final a = arg.trim();
  if (a.startsWith('@')) {
    if (!_nameRe.hasMatch(a.substring(1))) throw UnsupportedXPath(predicate);
    return _attrValue(node, a.substring(1)) ?? '';
  }
  if (a == 'text()' || a == '.') return _stringValue(node);
  final fn = RegExp(r'^(contains|starts-with)\((.*)\)$').firstMatch(a);
  if (fn != null) {
    final args = _splitTopLevel(fn.group(2)!, ',');
    if (args.length != 2) throw UnsupportedXPath(predicate);
    final hay = _resolve(args[0], node, predicate);
    final needle = _literal(args[1], predicate);
    if (fn.group(1)! == 'contains') return hay.contains(needle) ? '1' : '';
    return hay.startsWith(needle) ? '1' : '';
  }
  throw UnsupportedXPath(predicate);
}

String _literal(String raw, String predicate) {
  final t = raw.trim();
  if (t.length >= 2 && (t.startsWith("'") || t.startsWith('"')) && t.endsWith(t[0])) {
    return t.substring(1, t.length - 1).replaceAll(r"\'", "'").replaceAll(r'\"', '"');
  }
  throw UnsupportedXPath(predicate);
}

/// 结果里的文本节点摊平成字符串：上层的 `_nodeToText`/`_itemToText` 认 String
/// 与 Element，但拿到 `h.Text` 只会 toString 出 `Text:...` 这种脏值。
dynamic _flatten(dynamic n) => n is h.Text ? n.text : n;

List<dynamic> _finish(List<dynamic> nodes) => nodes.map(_flatten).toList();

/// 谓词是否形如 `xxx(...)`：第一个左括号配到的右括号正好在片段末尾
bool _closesAtEnd(String p) {
  var depth = 0;
  for (var i = 0; i < p.length; i++) {
    final c = p[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i == p.length - 1;
    }
  }
  return false;
}

/// 顶层分隔符切分（跳过方括号、圆括号与引号内部）。
List<String> _splitTopLevel(String s, String sep) {
  final out = <String>[];
  var depth = 0;
  String? quote;
  var buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      buf.write(c);
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      buf.write(c);
      continue;
    }
    if (c == '[' || c == '(') depth++;
    if (c == ']' || c == ')') depth--;
    if (depth == 0 && i + sep.length <= s.length && s.substring(i, i + sep.length) == sep) {
      out.add(buf.toString());
      buf = StringBuffer();
      i += sep.length - 1;
      continue;
    }
    buf.write(c);
  }
  out.add(buf.toString());
  return out.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}

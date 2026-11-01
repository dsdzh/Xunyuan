import 'dart:convert';
import 'dart:io' show gzip;

/// 书源导入的格式适配层：把"不是标准 Legado 3.0 JSON"的内容尽力还原成
/// `BookSource.fromJson` 直接可用的 map。
///
/// 三层容错，按代价从低到高：
/// 1. 外层包装：URL 编码 / base64（可层层套）/ gzip / 双重编码的 JSON 字符串；
/// 2. 宽松 JSON：`//` 与 `/* */` 注释、单引号字符串、裸键、尾逗号；
/// 3. 结构与字段：不认死包装键名，深度找出所有"像书源"的 map，
///    并把 `url`/`name`/`searchRule` 这些别名对齐到 Legado 规范键。
class SourceParseReport {
  /// 已规范化的书源 map（仍可能有条目 URL 为空，由上层丢弃）
  final List<Map<String, dynamic>> candidates;

  /// 书籍分享码条数：`{bookName, author, origin, tocUrl}` 那种，不是书源
  final int bookShares;

  /// 触及深度/访问量上限，后面的内容没再看
  final bool truncated;

  const SourceParseReport({
    this.candidates = const [],
    this.bookShares = 0,
    this.truncated = false,
  });
}

/// 深度/访问量上限：畸形超大嵌套或几 MB 的订阅文件不该把导入线程吃掉
const int _maxDepth = 6;
const int _maxVisits = 20000;
const int _maxTextLength = 8 * 1024 * 1024;

/// 规则组的"主字段"：扁平写法建组的前提，缺了这组就不该存在。
const Map<String, String> _primaryField = {
  'ruleBookInfo': 'name',
  'ruleSearch': 'bookList',
  'ruleExplore': 'bookList',
  'ruleToc': 'chapterList',
  'ruleContent': 'content',
};

/// 规范键 → 常见别名。只用来填补缺失的规范键，绝不覆盖已有值。
const List<String> _urlKeys = [
  'bookSourceUrl', 'bookSourceURL', 'baseUrl', 'sourceUrl', 'src', 'url', 'host', 'domain',
];
const List<String> _nameKeys = [
  'bookSourceName', 'bookSourceTitle', 'sourceName', 'name', 'title', 'cn_name',
];
const List<String> _groupKeys = ['bookSourceGroup', 'sourceGroup', 'group', 'typeName'];
const List<String> _searchUrlKeys = ['searchUrl', 'searchURL'];
const List<String> _exploreUrlKeys = ['exploreUrl', 'exploreURL'];
const List<String> _typeKeys = ['bookSourceType', 'sourceType', 'bookType', 'type'];
const List<String> _enabledKeys = ['enabled', 'enable', 'isEnable', 'isEnabled'];

/// 规则子对象的别名
const Map<String, List<String>> _ruleKeys = {
  'ruleBookInfo': ['ruleBookInfo', 'bookInfoRule', 'bookInfo'],
  'ruleSearch': ['ruleSearch', 'searchRule'],
  'ruleExplore': ['ruleExplore', 'exploreRule'],
  'ruleToc': ['ruleToc', 'tocRule', 'chapterListRule', 'ruleChapter', 'rulecat'],
  'ruleContent': ['ruleContent', 'contentRule', 'contentParseRule'],
};

/// 规则内部字段别名：规范字段 → 别名。宁可少填（留空→该字段不生效）也别填错，
/// 错选择器会产出假书目，比空结果更坏。
const Map<String, List<String>> _fieldKeys = {
  'bookList': ['bookList', 'booklist', 'listRule', 'ruleList'],
  'name': ['name', 'bookName', 'title'],
  'author': ['author', 'bookAuthor', 'authorName', 'writer'],
  'kind': ['kind', 'tags'],
  'wordCount': ['wordCount', 'size'],
  'lastChapter': ['lastChapter', 'latestChapter', 'newestChapter'],
  'checkKeyWord': ['checkKeyWord', 'checkKeyword', 'keyword'],
  'coverUrl': ['coverUrl', 'cover', 'bookCover', 'img', 'image'],
  'intro': ['intro', 'desc', 'description', 'summary', 'bookIntro', 'synopsis'],
  'bookUrl': ['bookUrl', 'href'],
  'tocUrl': ['tocUrl', 'catalogUrl', 'catalogURL'],
  'chapterList': ['chapterList', 'chapterlist', 'listRule'],
  'chapterName': ['chapterName', 'title', 'name'],
  'chapterUrl': ['chapterUrl', 'url', 'href'],
  'nextTocUrl': ['nextTocUrl', 'nextUrl'],
  'content': ['content', 'body', 'text'],
  'title': ['title', 'chapterName'],
  'nextContentUrl': ['nextContentUrl', 'nextUrl'],
  'replaceRegex': ['replaceRegex', 'purifyRegex'],
};

/// 把导入文本尽力还原成 JSON 结构；完全解不出来返回 null。
Object? decodeSourceJson(String text) {
  var s = _stripBom(text).trim();
  if (s.isEmpty || s.length > _maxTextLength) return null;
  for (var round = 0; round < 4; round++) {
    final direct = _tryJsonDecode(s);
    if (direct != _noValue) return direct;
    final jsonl = _decodeJsonLines(s);
    if (jsonl != null) return jsonl;
    final unwrapped = _unwrapOnce(s);
    if (unwrapped == null || unwrapped.trim() == s) {
      final repaired = _tryJsonDecode(_repairLooseJson(s));
      return repaired == _noValue ? null : repaired;
    }
    s = unwrapped.trim();
  }
  return null;
}

/// 主入口：解出结构 → 深度找书源 → 规范化字段。
SourceParseReport extractSourceCandidates(String text) {
  final decoded = decodeSourceJson(text);
  if (decoded == null) return const SourceParseReport();
  final out = <Map<String, dynamic>>[];
  var shares = 0;
  var visits = 0;
  var overBudget = false;

  void collect(dynamic v, int depth, {String? nameFromKey}) {
    if (overBudget) return;
    if (v is String) {
      // 字符串值里可能塞着整份书源：双重编码的 JSON、base64 / gzip / URL 编码的包装。
      // 只解一层不算适配——分享站就爱把数组 base64 后放进 data 字段。
      if (depth >= _maxDepth) return;
      var t = v.trim();
      for (var round = 0; round < 3 && t.length > 1; round++) {
        if (t.startsWith('{') || t.startsWith('[')) {
          var inner = _tryJsonDecode(t);
          if (inner == _noValue) {
            final fixed = _repairLooseJson(t);
            if (fixed == t) return;
            inner = _tryJsonDecode(fixed);
          }
          if (inner != _noValue) {
            collect(inner, depth + 1, nameFromKey: nameFromKey);
            return;
          }
        }
        final next = _unwrapOnce(t);
        if (next == null) return;
        t = next.trim();
      }
      return;
    }
    if (v is List) {
      for (final e in v) {
        collect(e, depth);
      }
      return;
    }
    if (v is! Map) return;
    final m = v.cast<String, dynamic>();
    if (++visits > _maxVisits) {
      overBudget = true;
      return;
    }
    if (_looksLikeSource(m)) {
      out.add(normalizeSourceMap(m, nameFromKey: nameFromKey));
      return;
    }
    if (isBookShareCode(m)) {
      shares++;
      return;
    }
    if (depth >= _maxDepth) return;
    // 「书源名 → 书源对象」的 map 形态（部分 iOS 客户端与转换站导出）：
    // 键名往往就是书源名，值里缺名字时拿来兜底
    for (final e in m.entries) {
      final keyName = e.key.toString().trim();
      collect(e.value, depth + 1, nameFromKey: keyName.isEmpty ? null : keyName);
    }
  }

  collect(decoded, 0);
  return SourceParseReport(candidates: out, bookShares: shares, truncated: overBudget);
}

/// 书籍分享码（详情页"分享给书友"那种），不是书源：没有任何规则，只有一个 origin。
bool isBookShareCode(Map<String, dynamic> m) {
  if (_firstString(m, _urlKeys) != null) return false;
  final hasOrigin = m['origin'] != null || m['originName'] != null;
  final hasBook = m['bookName'] != null || m['name'] != null;
  final hasLocate = m['tocUrl'] != null || m['coverUrl'] != null || m['author'] != null;
  return hasOrigin && hasBook && hasLocate;
}

bool _looksLikeSource(Map<String, dynamic> m) {
  if (m.containsKey('bookSourceUrl') || m.containsKey('bookSourceName')) {
    return _firstString(m, _urlKeys) != null || _firstString(m, _nameKeys) != null;
  }
  // 只有通用别名时要求再多一点特征，免得把业务数据里的一条 `{"url":...}` 当书源
  if (_firstString(m, _urlKeys) == null) return false;
  return _firstString(m, _nameKeys) != null ||
      _firstString(m, _searchUrlKeys) != null ||
      _firstString(m, _exploreUrlKeys) != null ||
      _ruleKeys.values.any((aliases) => aliases.any((a) => m[a] is Map));
}

/// 把别名字段对齐成 Legado 规范键；已有规范值一律不覆盖。
/// `nameFromKey`：「书源名 → 书源对象」map 形态里的键名，值内缺名字时用它，
/// 域名只是最后一档（一排 `www.xxx.com` 认不出是谁家的）。
Map<String, dynamic> normalizeSourceMap(Map<String, dynamic> src, {String? nameFromKey}) {
  final j = Map<String, dynamic>.from(src);
  final url = _firstString(j, _urlKeys);
  if (url != null) j['bookSourceUrl'] = url;
  final name = _firstString(j, _nameKeys);
  if (name != null) j['bookSourceName'] = name;
  final group = _firstString(j, _groupKeys);
  if (group != null) j['bookSourceGroup'] = group;
  if ((j['bookSourceName'] ?? '').toString().isEmpty) {
    if (nameFromKey != null && nameFromKey.isNotEmpty) {
      j['bookSourceName'] = nameFromKey;
    } else if (url != null) {
      // 名字都没有就用域名顶上，列表里至少看得出是哪家，不会一排「未命名书源」
      j['bookSourceName'] = _hostOf(url);
    }
  }

  // bookSourceType 的数字/字符串两形态都常见；枚举序不动，只是别再 toString 失败
  final type = _firstString(j, _typeKeys);
  if (type != null && j['bookSourceType'] == null) j['bookSourceType'] = type;

  for (final k in _enabledKeys) {
    if (!j.containsKey(k)) continue;
    final v = _asBool(j[k]);
    if (v != null) {
      j['enabled'] = v;
      break;
    }
  }

  var search = _firstString(j, _searchUrlKeys);
  search ??= _nestedString(j['ruleSearch'], _searchUrlKeys);
  search ??= _fromUrlList(j['searchUrl']);
  if (search != null) j['searchUrl'] = search;
  var explore = _firstString(j, _exploreUrlKeys);
  explore ??= _nestedString(j['ruleExplore'], _exploreUrlKeys);
  explore ??= _fromExploreList(j['exploreUrl']);
  if (explore != null) j['exploreUrl'] = explore;

  // header 是对象/数组时必须存成合法 JSON 文本：toString() 会得到 Dart 的
  // `{a: b}` 形态，引擎再按 `key:value` 行切就产出 `{a` 这种坏键名
  final header = j['header'];
  if (header is Map || header is List) j['header'] = jsonEncode(header);

  for (final numKey in const ['customOrder', 'lastUpdateTime', 'weight']) {
    final n = _asInt(j[numKey]);
    if (n != null) j[numKey] = n;
  }

  final pattern = _firstString(j, ['bookUrlPattern', 'urlPattern']);
  if (pattern != null && j['bookUrlPattern'] == null) j['bookUrlPattern'] = pattern;
  final comment = _firstString(j, ['bookSourceComment', 'comment', 'note']);
  if (comment != null && j['bookSourceComment'] == null) j['bookSourceComment'] = comment;

  for (final entry in _ruleKeys.entries) {
    final canonical = entry.key;
    Map<String, dynamic>? ruleMap;
    for (final alias in entry.value) {
      if (j[alias] is Map) {
        ruleMap = (j[alias] as Map).cast<String, dynamic>();
        break;
      }
    }
    // 扁平写法：规则字段直接摊在顶层（部分转换站产出这种）
    final merged = {...?ruleMap};
    if (ruleMap == null) {
      for (final f in _fieldsFor(canonical)) {
        for (final alias in _fieldKeys[f] ?? <String>[f]) {
          final v = _asStringOrNull(j[alias]);
          if (v != null && v.trim().isNotEmpty) {
            merged[f] = v;
            break;
          }
        }
      }
      // 只有主字段真在顶层出现才建这一组：否则一个顶层 `name` 会同时被塞进
      // ruleBookInfo/ruleSearch/ruleToc，ruleToc 拿到名字却拿不到 chapterList，
      // 目录解析会退化成"整页每个节点都是一章"
      final primary = _primaryField[canonical];
      if (primary == null || merged[primary] == null) continue;
    }
    // 原有键一并保留：只留规范字段会让导出时丢掉 Legado 的其它规则字段
    final rules = <String, dynamic>{...merged};
    for (final f in _fieldsFor(canonical)) {
      final v = _resolveRuleField(merged, f);
      if (v != null) {
        rules[f] = v;
      } else if (rules[f] != null && rules[f] is! String) {
        // 非文本的规则字段下游一律 toString 成 Dart 字面量，留着比删掉更坏
        rules.remove(f);
      }
    }
    if (rules.isNotEmpty) j[canonical] = rules;
  }
  return j;
}

/// 规则字段的取值优先级：规范键 → 别名 → 名为 *rule* 的嵌套子对象里的同名字段。
String? _resolveRuleField(Map<String, dynamic> merged, String f) {
  final direct = _asStringOrNull(merged[f]);
  if (direct != null && direct.trim().isNotEmpty) return direct;
  for (final alias in _fieldKeys[f] ?? const <String>[]) {
    if (alias == f) continue;
    final v = _asStringOrNull(merged[alias]);
    if (v != null && v.trim().isNotEmpty) return v;
  }
  // 再退一层：`bookListRule: {bookName: ...}` 这类写法
  return _deepString(merged, f);
}

List<String> _fieldsFor(String canonical) => const {
      'ruleBookInfo': ['name', 'author', 'intro', 'coverUrl', 'kind', 'tocUrl', 'lastChapter'],
      'ruleSearch': [
        'bookList', 'name', 'author', 'kind', 'wordCount', 'lastChapter',
        'checkKeyWord', 'coverUrl', 'intro', 'bookUrl',
      ],
      'ruleExplore': [
        'title', 'note', 'bookList', 'name', 'author', 'kind', 'wordCount',
        'lastChapter', 'coverUrl', 'intro', 'bookUrl', 'urlPattern',
      ],
      'ruleToc': ['chapterList', 'chapterName', 'chapterUrl', 'nextTocUrl'],
      'ruleContent': ['content', 'title', 'nextContentUrl', 'replaceRegex'],
    }[canonical] ??
    const [];

String? _hostOf(String url) {
  final u = Uri.tryParse(url);
  if (u != null && u.host.isNotEmpty) return u.host;
  return url.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
}

String? _asStringOrNull(dynamic v) {
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

String? _firstString(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = _asStringOrNull(m[k]);
    if (v != null && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

String? _nestedString(dynamic holder, List<String> keys) {
  if (holder is! Map) return null;
  return _firstString(holder.cast<String, dynamic>(), keys);
}

/// `[{"name":"起点","url":"https://...{key}"}, ...]`：v1 只用第一条。
/// 多条拼一起会让模板解析器把整串当一条 URL，搜不出结果还更难查。
String? _fromUrlList(dynamic v) {
  if (v is! List) return null;
  for (final e in v) {
    final s = e is Map
        ? _firstString(e.cast<String, dynamic>(), ['url', 'searchUrl', 'value'])
        : _asStringOrNull(e);
    if (s != null && s.trim().isNotEmpty) return s.trim();
  }
  return null;
}

/// exploreUrl 的数组形态就是发现页分类，逐条拼回 `名称::url` 换行格式。
String? _fromExploreList(dynamic v) {
  if (v is! List) return null;
  final parts = <String>[];
  for (final e in v) {
    if (e is! Map) continue;
    final m = e.cast<String, dynamic>();
    final url = _firstString(m, ['url', 'exploreUrl', 'value']);
    if (url == null) continue;
    final title = _firstString(m, ['title', 'name', 'bookSourceGroup']);
    parts.add(title == null || title.isEmpty ? url : '$title::$url');
  }
  return parts.isEmpty ? null : parts.join('\n');
}

bool? _asBool(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == '1') return true;
    if (s == 'false' || s == '0') return false;
  }
  return null;
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// 只往 `*rule*` 命名的子对象里找，避免把无关嵌套的同名字段当规则捡走
String? _deepString(Map<String, dynamic> m, String field) {
  for (final entry in m.entries) {
    final v = entry.value;
    if (v is! Map) continue;
    if (!entry.key.toLowerCase().contains('rule')) continue;
    final hit = _asStringOrNull(v.cast<String, dynamic>()[field]);
    if (hit != null && hit.trim().isNotEmpty) return hit;
  }
  return null;
}

// ---------- 外层包装与宽松 JSON ----------

const _noValue = Object();

Object? _tryJsonDecode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return _noValue;
  }
}

/// JSONL：每行一个对象
List<dynamic>? _decodeJsonLines(String s) {
  final lines = s.split(RegExp(r'\r?\n'));
  if (lines.length < 2) return null;
  final out = <dynamic>[];
  for (final line in lines) {
    final l = _stripBom(line).trim();
    if (l.isEmpty) continue;
    if (!l.startsWith('{') && !l.startsWith('[')) return null;
    var v = _tryJsonDecode(l);
    if (v == _noValue) v = _tryJsonDecode(_repairLooseJson(l));
    if (v == _noValue) return null;
    out.add(v);
  }
  return out.isEmpty ? null : out;
}

/// 剥掉一层外层包装：URL 编码 / base64（含 gzip）。剥不动返回 null。
String? _unwrapOnce(String s) {
  if (_isPercentEncoded(s)) {
    try {
      final d = Uri.decodeFull(s);
      if (d.trim() != s.trim()) return d;
    } catch (_) {}
  }
  final compact = s.replaceAll(RegExp(r'\s'), '');
  if (compact.length >= 24 &&
      compact.length % 4 == 0 &&
      RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(compact)) {
    List<int> bytes;
    try {
      bytes = base64Decode(compact);
    } catch (_) {
      return null;
    }
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      try {
        bytes = gzip.decode(bytes);
      } catch (_) {
        return null;
      }
    }
    try {
      final t = utf8.decode(bytes);
      if (!t.contains('\u0000') && t.trim() != s.trim()) return t;
    } catch (_) {}
  }
  return null;
}

/// 整段看着像 URL 编码（不是 JSON 起手）才解，`{"u":"a%20b"}` 这种不能被误伤
bool _isPercentEncoded(String s) {
  final t = s.trimLeft();
  if (t.startsWith('{') || t.startsWith('[')) return false;
  return RegExp(r'%[0-9A-Fa-f]{2}').hasMatch(t);
}

/// 宽松 JSON → 标准 JSON。字符串内部一律不动（书源里满是 `https://` 和正则串）。
String _repairLooseJson(String s) {
  final sb = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '"' || c == "'") {
      i = _copyString(s, i, c, sb);
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      final end = s.indexOf('*/', i + 2);
      i = end < 0 ? s.length : end + 2;
      continue;
    }
    if (_isBareKeyStart(s, i)) {
      // 不写 `^`：matchAsPrefix 已经锚在 i，但 `^` 只认 0 号位，带上它除了文档第一个
      // 字符以外全都匹配不到
      final m = RegExp(r"[A-Za-z_$][\w$.\-]*(?=\s*:)").matchAsPrefix(s, i);
      if (m != null) {
        sb.write('"${m.group(0)}"');
        i = m.end;
        continue;
      }
    }
    if (c == ',') {
      // 尾逗号后面还夹着注释才算真尾逗号：`{..., /* 备注 */}` 手写 JSON 里很常见
      final j = _skipBlankAndComments(s, i + 1);
      if (j < s.length && (s[j] == '}' || s[j] == ']')) {
        i++;
        continue;
      }
    }
    sb.write(c);
    i++;
  }
  return sb.toString();
}

/// 从 [start] 起跳过空白与注释，返回下一个实质字符下标（越界返回 s.length）。
int _skipBlankAndComments(String s, int start) {
  var j = start;
  while (j < s.length) {
    final c = s[j];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      j++;
      continue;
    }
    if (c == '/' && j + 1 < s.length && s[j + 1] == '/') {
      while (j < s.length && s[j] != '\n') {
        j++;
      }
      continue;
    }
    if (c == '/' && j + 1 < s.length && s[j + 1] == '*') {
      final end = s.indexOf('*/', j + 2);
      j = end < 0 ? s.length : end + 2;
      continue;
    }
    break;
  }
  return j;
}

/// 原样搬运一段字符串；单引号串换成双引号（内部 `"` 转义、`\'` 还原）。返回新下标。
int _copyString(String s, int start, String quote, StringBuffer sb) {
  var i = start + 1;
  final single = quote == "'";
  sb.write('"');
  while (i < s.length) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final n = s[i + 1];
      if (single && n == "'") {
        sb.write("'");
      } else {
        sb.write(r'\');
        sb.write(n);
      }
      i += 2;
      continue;
    }
    if (c == quote) {
      sb.write('"');
      return i + 1;
    }
    if (single && c == '"') {
      sb.write(r'\"');
      i++;
      continue;
    }
    if (c == '\n') {
      // 未闭合的串：单引号里换行不合法，原样吐出交给上层解码失败
      sb.write(c);
      return i + 1;
    }
    sb.write(c);
    i++;
  }
  sb.write('"');
  return i;
}

/// 裸键只可能出现在 `{` 或 `,` 之后；其余位置的 `xxx:` 是值里的文本（时间、正则）
bool _isBareKeyStart(String s, int i) {
  var j = i - 1;
  while (j >= 0 && (s[j] == ' ' || s[j] == '\t' || s[j] == '\r' || s[j] == '\n')) {
    j--;
  }
  if (j < 0) return false;
  return s[j] == '{' || s[j] == ',';
}

String _stripBom(String s) => s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF ? s.substring(1) : s;

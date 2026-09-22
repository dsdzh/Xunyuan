import 'dart:convert';

import 'package:html/dom.dart' as h;

import '../models/book_source.dart';
import 'http_client.dart';
import 'rule_engine.dart';

class SearchBook {
  final String name;
  final String author;
  final String kind;
  final String lastChapter;
  final String wordCount;
  final String intro;
  final String coverUrl;
  final String bookUrl;
  final String sourceUrl;
  final String sourceName;

  SearchBook({
    required this.name,
    required this.author,
    this.kind = '',
    this.lastChapter = '',
    this.wordCount = '',
    this.intro = '',
    this.coverUrl = '',
    required this.bookUrl,
    required this.sourceUrl,
    required this.sourceName,
  });
}

class Chapter {
  String title;
  String url;
  int index;
  bool isVip;
  Chapter(this.title, this.url, this.index, {this.isVip = false});

  Map<String, dynamic> toJson() => {'title': title, 'url': url, 'index': index, 'isVip': isVip};
  factory Chapter.fromJson(Map m) =>
      Chapter((m['title'] ?? '').toString(), (m['url'] ?? '').toString(),
          (m['index'] as num?)?.toInt() ?? 0, isVip: m['isVip'] == true);
}

class BookDetail {
  String name = '';
  String author = '';
  String intro = '';
  String coverUrl = '';
  String kind = '';
  String lastChapter = '';
  String tocUrl = '';
  String bookUrl = '';
  String sourceUrl = '';
  String sourceName = '';
}

/// 书源抓取引擎：搜索 / 发现 / 详情 / 目录 / 正文。
class BookSourceEngine {
  final BookSource source;
  BookSourceEngine(this.source);

  Map<String, String> get _headers {
    if (source.header == null || source.header!.trim().isEmpty) return {};
    try {
      final j = jsonDecode(source.header!);
      if (j is Map) return j.map((k, v) => MapEntry(k.toString(), v.toString()));
      if (j is List) {
        // [{key:..,value:..}] 形式
        final out = <String, String>{};
        for (final e in j) {
          if (e is Map && e['key'] != null) out[e['key'].toString()] = (e['value'] ?? '').toString();
        }
        return out;
      }
    } catch (_) {}
    // 极常见的裸文本形态：`User-Agent: xxx\nReferer: yyy`
    final out = <String, String>{};
    for (final line in source.header!.split(RegExp(r'[\r\n]+'))) {
      final i = line.indexOf(':');
      if (i > 0) out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    return out;
  }

  static final RegExp _schemeRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');

  String _abs(String base, String url) {
    url = url.trim();
    if (url.isEmpty) return url;
    // 大小写混合的 HTTP:// 也算绝对地址
    if (_schemeRe.hasMatch(url)) return url;
    if (url.startsWith('data:') || url.startsWith('file://')) return url;
    final b = Uri.tryParse(base);
    if (b == null) return url;
    if (url.startsWith('//')) return '${b.scheme}:$url';
    // RFC3986 相对解析：自带 ./ ../ 与 ?query 保留（旧 pathSegments 重组会把 ? 转义成 %3F）
    return b.resolve(url).toString();
  }

  /// 解析 URL 模板：支持 `url{key}`、`url&&{opts}` 与真源最常见的 `url,{opts}` 单引号写法。
  /// opts 字段：body / method / charset / contentType / headers。
  /// 返回 (最终 url, 请求参数)。`@js:` 或整体被 `<js>` 包裹时返回空 url（v1 不执行 JS）。
  ({
    String url,
    String? body,
    String? method,
    String? contentType,
    String? charset,
    Map<String, String> headers,
  }) _buildRequest(String tplRaw, {String? key, int page = 1}) {
    const empty = (url: '', body: null, method: null, contentType: null, charset: null, headers: <String, String>{});
    var tpl = tplRaw.trim();
    if (tpl.isEmpty || tpl.startsWith('@js:')) return empty;
    tpl = tpl.replaceAll(RegExp(r'<js>[\s\S]*?</js>'), '').trim();
    if (tpl.isEmpty) return empty;

    String? optText;
    final opts = _findOptions(tpl);
    if (opts != null) {
      optText = tpl.substring(opts.braceStart);
      tpl = tpl.substring(0, opts.urlEnd).trim();
    }

    // GBK 源的 GET 关键词也要按 GBK 百分号编码，UTF-8 编码会搜不到
    final keyCharset = optText == null ? null : _parseLegadoOptions(optText).charset;
    final gbkKey = keyCharset != null && keyCharset.startsWith('gb');

    String substitute(String s) {
      if (key != null) {
        final encodedKey = gbkKey ? _gbkPercent(key) : Uri.encodeComponent(key);
        // 先替换 {{key}}，否则 {{key}} 会残留花括号
        s = s.replaceAll('{{key}}', encodedKey).replaceAll('{key}', encodedKey);
        s = s.replaceAll('{bookName}', encodedKey);
      }
      s = s.replaceAllMapped(RegExp(r'\{\{?page\}?\}(?:<(\d+)>)?'), (m) {
        final step = int.tryParse(m.group(1) ?? '') ?? 1;
        return (1 + (page - 1) * step).toString();
      });
      s = s.replaceAll(RegExp(r'<1>'), '');
      return s;
    }

    final url = _abs(source.bookSourceUrl, substitute(tpl));
    if (optText == null) return (url: url, body: null, method: null, contentType: null, charset: null, headers: const {});

    final opt = _parseLegadoOptions(substitute(optText));
    return (
      url: url,
      body: opt.body,
      method: opt.method,
      contentType: opt.contentType,
      charset: opt.charset,
      headers: opt.headers,
    );
  }

  /// 找到 `,{'k':` / `&&{'k':` 形态选项的起点（引号内、括号内不匹配）
  ({int urlEnd, int braceStart})? _findOptions(String s) {
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '{' || c == '[' || c == '(') {
        depth++;
        continue;
      }
      if (c == '}' || c == ']' || c == ')') {
        depth--;
        continue;
      }
      if (depth != 0) continue;
      final isAmp = c == '&' && i + 1 < s.length && s[i + 1] == '&';
      if (c != ',' && !isAmp) continue;
      var j = i + (isAmp ? 2 : 1);
      while (j < s.length && (s[j] == ' ' || s[j] == '\t')) {
        j++;
      }
      if (j + 1 < s.length && s[j] == '{' && (s[j + 1] == "'" || s[j + 1] == '"')) {
        return (urlEnd: i, braceStart: j);
      }
    }
    return null;
  }

  /// 宽松解析 Legado 选项对象 `{'k':'v','headers':{'H':'V'}}`（单/双引号均可）
  static ({String? body, String? method, String? charset, String? contentType, Map<String, String> headers})
      _parseLegadoOptions(String obj) {
    final stringPairPatterns = [
      RegExp(r"'([^']+)'\s*:\s*'((?:[^'\\]|\\.)*)'"),
      RegExp(r'"([^"]+)"\s*:\s*"((?:[^"\\]|\\.)*)"'),
    ];
    String? body, method, charset, contentType;
    final headers = <String, String>{};

    // headers 是嵌套对象，先单独取出（并从文本中剔除避免被字符串对正则误匹配）
    final hm = RegExp(r'''['"]?headers['"]?\s*:\s*(\{[^{}]*\})''').firstMatch(obj);
    if (hm != null) {
      obj = obj.replaceRange(hm.start, hm.end, '');
      final inner = hm.group(1)!;
      for (final re in [
        RegExp(r"'([^']+)'\s*:\s*'([^']*)'"),
        RegExp(r'"([^"]+)"\s*:\s*"([^"]*)"'),
      ]) {
        for (final m in re.allMatches(inner)) {
          headers[m.group(1)!] = m.group(2)!;
        }
      }
    }

    for (final re in stringPairPatterns) {
      for (final m in re.allMatches(obj)) {
        var v = m.group(2)!;
        v = v.replaceAll(r"\'", "'").replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
        switch (m.group(1)!.toLowerCase()) {
          case 'body':
            body = v;
          case 'method':
            method = v;
          case 'charset':
            charset = v.toLowerCase();
          case 'contenttype':
            contentType = v;
        }
      }
    }
    return (body: body, method: method, charset: charset, contentType: contentType, headers: headers);
  }

  /// GBK 百分号编码（GBK 源 GET 关键词须按 GBK 字节编码，UTF-8 会搜不到）
  static String _gbkPercent(String s) {
    final bytes = HttpClient.gbkEncode(s);
    final sb = StringBuffer();
    for (final b in bytes) {
      // RFC 3986 非保留字符可裸写，其余 %XX 大写
      if ((b >= 0x41 && b <= 0x5A) ||
          (b >= 0x61 && b <= 0x7A) ||
          (b >= 0x30 && b <= 0x39) ||
          b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E) {
        sb.writeCharCode(b);
      } else {
        sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return sb.toString();
  }

  /// 按构建结果发起请求（POST/GET、charset、自定义 headers）
  Future<PageResponse> _fetch(({
    String url,
    String? body,
    String? method,
    String? contentType,
    String? charset,
    Map<String, String> headers,
  }) built) {
    final hdrs = {..._headers, ...built.headers};
    final method = built.method?.toUpperCase() ?? (built.body != null ? 'POST' : 'GET');
    if (method == 'POST') {
      Object bodyData = built.body ?? '';
      final charset = built.charset ?? '';
      if (charset.startsWith('gb')) {
        bodyData = HttpClient.gbkEncode(bodyData as String);
      }
      return _check(HttpClient.instance.post(built.url,
          body: bodyData,
          headers: hdrs,
          contentType: built.contentType ?? 'application/x-www-form-urlencoded',
          charsetHint: built.charset));
    }
    return _check(HttpClient.instance.get(built.url, headers: hdrs, charsetHint: built.charset));
  }

  Future<List<SearchBook>> search(String key, {int page = 1}) async {
    final built = _buildRequest(source.searchUrl ?? '', key: key, page: page);
    if (built.url.isEmpty) return [];
    final resp = await _fetch(built);
    return _parseBookList(resp.body, resp.url,
        listRule: source.ruleSearch.bookList,
        r: source.ruleSearch as Object);
  }

  /// 发现页分类：exploreUrl 形如 `名称::url&&名称2::url2`（换行分隔）
  static List<({String title, String url})> exploreCategories(BookSource source) {
    final raw = source.exploreUrl ?? '';
    if (raw.trim().isEmpty) return [];
    final out = <({String title, String url})>[];
    for (var seg in raw.split(RegExp(r'[\n]'))) {
      seg = seg.trim();
      if (seg.isEmpty) continue;
      final idx = seg.indexOf('::');
      if (idx <= 0) continue;
      out.add((title: seg.substring(0, idx).trim(), url: seg.substring(idx + 2).trim()));
    }
    return out;
  }

  Future<List<SearchBook>> explore(String urlTemplate, {int page = 1}) async {
    final built = _buildRequest(urlTemplate, page: page);
    if (built.url.isEmpty) return [];
    final resp = await _fetch(built);
    final er = source.ruleExplore;
    return _parseBookList(
      resp.body,
      resp.url,
      listRule: er.bookList,
      r: er,
    );
  }

  List<SearchBook> _parseBookList(String body, String pageUrl, {required String listRule, required Object r}) {
    final isJson = ContentAnalyzer.isJsonContent(body);
    List<dynamic> items;
    if (listRule.trim().isEmpty) {
      dynamic whole = body;
      if (isJson) {
        // 防截断/JSONP 伪 JSON 页抛 FormatException
        try {
          whole = jsonDecode(body);
        } catch (_) {
          whole = body;
        }
      }
      items = [whole];
    } else {
      items = RuleEngine.getElements(body, listRule, isJson: isJson);
    }
    final out = <SearchBook>[];
    for (final item in items) {
      final itemText = _itemToText(item);
      final itemIsMap = item is Map || item is List;
      String pick(String rule) {
        if (rule.trim().isEmpty) return '';
        final list = RuleEngine.getStringList(itemText, rule, isJson: itemIsMap);
        if (list.isEmpty) {
          // JSON 源的 URL 字面模板（如 `/book/{{$.id}}`）：规则本身即结果
          final t = _renderTemplates(rule.trim(), item);
          return t.trim() == rule.trim() ? '' : t.trim();
        }
        return _renderTemplates(list.first.trim(), item);
      }

      String name, bookUrl;
      if (r is SearchRule) {
        name = pick(r.name);
        bookUrl = pick(r.bookUrl);
        out.add(SearchBook(
          name: name,
          author: pick(r.author),
          kind: pick(r.kind),
          lastChapter: pick(r.lastChapter),
          wordCount: pick(r.wordCount),
          intro: pick(r.intro),
          coverUrl: _abs(pageUrl, pick(r.coverUrl)),
          bookUrl: _abs(pageUrl, bookUrl),
          sourceUrl: source.bookSourceUrl,
          sourceName: source.bookSourceName,
        ));
      } else if (r is ExploreRule) {
        name = pick(r.name);
        bookUrl = pick(r.bookUrl);
        out.add(SearchBook(
          name: name,
          author: pick(r.author),
          kind: pick(r.kind),
          lastChapter: pick(r.lastChapter),
          wordCount: pick(r.wordCount),
          intro: pick(r.intro),
          coverUrl: _abs(pageUrl, pick(r.coverUrl)),
          bookUrl: _abs(pageUrl, bookUrl),
          sourceUrl: source.bookSourceUrl,
          sourceName: source.bookSourceName,
        ));
      }
    }
    return out.where((b) => b.name.isNotEmpty).toList();
  }

  String _itemToText(dynamic item) {
    if (item is String) return item;
    if (item is Map || item is List) return jsonEncode(item);
    if (item is h.Element) return item.outerHtml;
    // 恶意/畸形规则可让列表元素退化为数字等标量，不能假设是 Element
    return item?.toString() ?? '';
  }

  /// JSON 源的 URL/文本模板：`/book/{{$.book_id}}/chapters` 用当前对象字段填充
  static String _renderTemplates(String s, dynamic ctx) {
    if (!s.contains('{{') || ctx is! Map) return s;
    return s.replaceAllMapped(RegExp(r'\{\{\$?\.?(\w+)\}\}'), (m) {
      final v = ctx[m.group(1)];
      // Map/List 插值会变成 Dart 字面量（如 {a: 1}）拼出坏链，非标量一律留空
      if (v == null || v is Map || v is List) return '';
      return '$v';
    });
  }

  Future<BookDetail> bookInfo(String bookUrl, {String? name, String? author}) async {
    if (bookUrl.trim().isEmpty) {
      throw Exception('该书源未能解析出详情页链接（规则可能依赖 JS 或站方改版）');
    }
    final resp = await _check(HttpClient.instance.get(bookUrl, headers: _headers));
    var body = resp.body;
    final url = resp.url;
    var isJson = ContentAnalyzer.isJsonContent(body);
    final rb = source.ruleBookInfo;
    // ruleBookInfo.init（模型字段 bookInfoUrl）：把子对象（如 $.data）设为后续规则的求值范围
    Map<String, dynamic>? scope;
    if (isJson && rb.bookInfoUrl.trim().isNotEmpty) {
      final vals = RuleEngine.getElements(body, rb.bookInfoUrl, isJson: true);
      if (vals.length == 1 && vals.first is Map) {
        scope = (vals.first as Map).cast<String, dynamic>();
        body = jsonEncode(scope);
      }
    } else if (isJson) {
      try {
        final j = jsonDecode(body);
        if (j is Map) scope = j.cast<String, dynamic>();
      } catch (_) {}
    }
    String pick(String rule) {
      if (rule.trim().isEmpty) return '';
      final l = RuleEngine.getStringList(body, rule, isJson: isJson);
      if (l.isEmpty) {
        final t = _renderTemplates(rule.trim(), scope);
        return t.trim() == rule.trim() ? '' : t.trim();
      }
      return _renderTemplates(l.first.trim(), scope);
    }

    final pickedName = pick(rb.name);
    final pickedAuthor = pick(rb.author);
    final detail = BookDetail()
      ..bookUrl = url
      ..sourceUrl = source.bookSourceUrl
      ..sourceName = source.bookSourceName
      ..name = pickedName.isNotEmpty ? pickedName : (name ?? '')
      ..author = pickedAuthor.isNotEmpty ? pickedAuthor : (author ?? '')
      ..intro = pick(rb.intro)
      ..kind = pick(rb.kind)
      ..lastChapter = pick(rb.lastChapter)
      ..coverUrl = _abs(url, pick(rb.coverUrl))
      ..tocUrl = _abs(url, pick(rb.tocUrl));
    if (detail.tocUrl.isEmpty) detail.tocUrl = url;
    return detail;
  }

  Future<List<Chapter>> toc(String tocUrl) async {
    final resp = await _check(HttpClient.instance.get(tocUrl, headers: _headers));
    var body = resp.body;
    var pageUrl = resp.url;
    final rt = source.ruleToc;
    // seen 跨 nextTocUrl 分页共享：分页目录常出现重复章节
    final seen = <String>{};
    var chapters = _parseTocPage(body, pageUrl, ContentAnalyzer.isJsonContent(body), 0, seen);

    // nextTocUrl 追加后续页
    if (rt.nextTocUrl.trim().isNotEmpty) {
      var isJson = ContentAnalyzer.isJsonContent(body);
      var nextUrl = RuleEngine.getString(body, rt.nextTocUrl, isJson: isJson);
      var guard = 0;
      while (nextUrl.trim().isNotEmpty && guard++ < 20) {
        final abs = _abs(pageUrl, nextUrl);
        if (abs == pageUrl) break;
        final PageResponse resp2;
        try {
          resp2 = await _check(HttpClient.instance.get(abs, headers: _headers));
        } catch (_) {
          // 后续分页失败但已解析到章节：保留已有部分（与 content() 的降级一致），
          // 仅首页也没拿到时才抛出
          if (chapters.isNotEmpty) break;
          rethrow;
        }
        body = resp2.body;
        pageUrl = resp2.url;
        isJson = ContentAnalyzer.isJsonContent(body);
        chapters = [...chapters, ..._parseTocPage(body, pageUrl, isJson, chapters.length, seen)];
        nextUrl = RuleEngine.getString(body, rt.nextTocUrl, isJson: isJson);
      }
    }
    return chapters;
  }

  /// 解析一页目录：优先 chapterList 选节点后逐节点取字段（避免 name/url 平行列表错位），
  /// 无 chapterList 时回退为全文平行列表对齐。按绝对 url 去重（chapterList 的 && 组合常出现父子节点重复命中）。
  List<Chapter> _parseTocPage(String body, String pageUrl, bool isJson, int startIndex, Set<String> seen) {
    final rt = source.ruleToc;
    final out = <Chapter>[];
    Map<String, dynamic>? rootCtx;
    if (isJson) {
      try {
        final j = jsonDecode(body);
        if (j is Map) rootCtx = j.cast<String, dynamic>();
      } catch (_) {}
    }
    if (rt.chapterList.trim().isNotEmpty) {
      final items = RuleEngine.getElements(body, rt.chapterList, isJson: isJson);
      var idx = startIndex;
      for (final item in items) {
        final itemJson = item is Map || item is List;
        final text = _itemToText(item);
        String pick(String rule) {
          if (rule.trim().isEmpty) return '';
          final l = RuleEngine.getStringList(text, rule, isJson: itemJson);
          String finish(String raw) {
            var v = _renderTemplates(raw, item);
            // 章节对象缺字段时（如 book_id 只在响应根上），用根对象再渲染一次
            if (v.contains('{{') && rootCtx != null) v = _renderTemplates(v, rootCtx);
            return v;
          }
          if (l.isEmpty) {
            final t = finish(rule.trim());
            return t.trim() == rule.trim() ? '' : t.trim();
          }
          return finish(l.first.trim());
        }

        var title = rt.chapterName.trim().isEmpty
            ? _nodeToTextSafe(item)
            : _cleanText(pick(rt.chapterName));
        title = _cleanText(title);
        final url = pick(rt.chapterUrl);
        if (title.isEmpty || url.isEmpty) continue;
        final absUrl = _abs(pageUrl, url);
        if (!seen.add(absUrl)) continue;
        final vipRaw = rt.isVip.trim().isEmpty ? '' : pick(rt.isVip);
        final isVip = vipRaw.isNotEmpty && vipRaw != '0' && vipRaw.toLowerCase() != 'false';
        out.add(Chapter(title, absUrl, idx++, isVip: isVip));
      }
      if (out.isNotEmpty) return out;
    }
    // 回退：全文平行列表
    if (rt.chapterName.trim().isEmpty) return [];
    final names = RuleEngine.getStringList(body, rt.chapterName, isJson: isJson);
    final urls = rt.chapterUrl.trim().isEmpty
        ? List.generate(names.length, (_) => '')
        : RuleEngine.getStringList(body, rt.chapterUrl, isJson: isJson);
    final len = names.length < urls.length ? names.length : urls.length;
    for (var i = 0; i < len; i++) {
      final title = _cleanText(names[i]);
      if (title.isEmpty) continue;
      final absUrl = _abs(pageUrl, urls[i]);
      if (absUrl.isEmpty) continue; // 无链接章节无法打开，跳过（与 chapterList 分支一致，避免堆积重复空链）
      if (!seen.add(absUrl)) continue;
      out.add(Chapter(title, absUrl, startIndex + out.length));
    }
    return out;
  }

  static String _nodeToTextSafe(dynamic node) {
    if (node == null) return '';
    if (node is String) return node;
    try {
      return node.text.toString();
    } catch (_) {
      return node.toString();
    }
  }

  Future<PageResponse> _check(Future<PageResponse> f) async {
    final resp = await f;
    if (resp.statusCode >= 400) {
      throw Exception('HTTP ${resp.statusCode}：站点拒绝或页面不存在（${resp.url}）');
    }
    return resp;
  }

  static String _cleanText(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<String> content(String chapterUrl, {String? title}) async {
    final rc = source.ruleContent;
    var url = chapterUrl;
    final buffers = <String>[];
    final visited = <String>{url};
    var guard = 0;
    var totalLen = 0;
    const maxLen = 2000000;
    while (url.isNotEmpty && guard++ < 20) {
      PageResponse resp;
      try {
        resp = await _check(HttpClient.instance.get(url, headers: _headers));
      } catch (_) {
        // 已取到部分内容时后续分页失败：保留已抓取文本
        if (buffers.isNotEmpty) break;
        rethrow;
      }
      final body = resp.body;
      final pageUrl = resp.url;
      final isJson = ContentAnalyzer.isJsonContent(body);
      final parts = rc.content.trim().isEmpty
          ? [body]
          : RuleEngine.getStringList(body, rc.content, isJson: isJson);
      buffers.addAll(parts);
      for (final s in parts) {
        totalLen += s.length;
      }
      if (rc.nextContentUrl.trim().isEmpty) break;
      if (totalLen > maxLen) break; // 分页正文累计封顶
      var next = _cleanText(RuleEngine.getString(body, rc.nextContentUrl, isJson: isJson));
      if (next.isEmpty) break;
      final abs = _abs(pageUrl, next);
      if (abs == url || !visited.add(abs)) break; // 环检测：A→B→A 这类非相邻重复也拦下
      url = abs;
    }
    var text = buffers.join('\n');
    if (text.length > maxLen) text = text.substring(0, maxLen);
    if (rc.replaceRegex.trim().isNotEmpty) {
      text = _applyReplace(text, rc.replaceRegex);
    }
    return _normalizeContent(text);
  }

  /// replaceRegex: Legado 格式 `##正则##替换`，多条用 `&&` 分隔；也兼容 `正则##替换`
  String _applyReplace(String text, String rule) {
    for (final rawSeg in rule.split('&&')) {
      var seg = rawSeg.trim();
      if (seg.startsWith('##')) seg = seg.substring(2);
      final parts = seg.split('##');
      try {
        if (parts.length >= 2) {
          text = text.replaceAllMapped(RegExp(parts[0], dotAll: true), (m) => _expand(m, parts[1]));
        } else if (parts.length == 1 && parts.first.isNotEmpty) {
          text = text.replaceAll(RegExp(parts.first, dotAll: true), '');
        }
      } catch (_) {}
      // 病态正则+模板可把文本滚成天文数字，按章上限截断
      if (text.length > 2000000) text = text.substring(0, 2000000);
    }
    return text;
  }

  String _expand(Match m, String template) {
    var r = template;
    for (var i = m.groupCount; i >= 0; i--) {
      r = r.replaceAll('\$$i', m.group(i) ?? '');
    }
    return r;
  }

  static String _normalizeContent(String raw) {
    var t = raw
        // script/style 整块删除，否则残留的 JS/CSS 文本会混进正文
        .replaceAll(RegExp(r'<(script|style)\b[^>]*>[\s\S]*?</\1\s*>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\r\n?'), '\n');
    // 去掉残留尖括号标签
    t = t.replaceAll(RegExp(r'<[^>]{0,200}>'), '');
    final lines = t.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    return lines.join('\n\n');
  }
}

import 'dart:convert';

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
      Chapter((m['title'] ?? '').toString(), (m['url'] ?? '').toString(), (m['index'] is num) ? m['index'] as int : 0,
          isVip: m['isVip'] == true);
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
    return {};
  }

  String _abs(String base, String url) {
    url = url.trim();
    if (url.isEmpty) return url;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('data:') || url.startsWith('file://')) return url;
    final b = Uri.tryParse(base);
    if (b == null) return url;
    if (url.startsWith('//')) return '${b.scheme}:$url';
    if (url.startsWith('/')) return '${b.scheme}://${b.authority}$url';
    // 相对路径
    final pathSegs = b.pathSegments.toList();
    if (pathSegs.isNotEmpty) pathSegs.removeLast();
    for (final seg in url.split('/')) {
      if (seg == '.' || seg.isEmpty) continue;
      if (seg == '..') {
        if (pathSegs.isNotEmpty) pathSegs.removeLast();
      } else {
        pathSegs.add(seg);
      }
    }
    return b.replace(pathSegments: pathSegs).toString();
  }

  /// 解析搜索 URL 模板：`url{key}...`，或 `url&&{jsonbody}`。
  /// 返回 (最终 url, postBody?)
  ({String url, String? body, String? contentType}) _buildSearchUrl(String key, int page) {
    var tpl = source.searchUrl ?? '';
    if (tpl.isEmpty) return (url: '', body: null, contentType: null);

    // 拆分 `&&` 后的选项（POST body / headers）
    String? bodyTemplate;
    final amp = _findOptionsSplit(tpl);
    if (amp != null) {
      bodyTemplate = tpl.substring(amp + 2).trim();
      tpl = tpl.substring(0, amp).trim();
    }

    final encodedKey = Uri.encodeComponent(key);
    String substitute(String s) {
      s = s.replaceAll('{key}', encodedKey).replaceAll('{{key}}', encodedKey);
      s = s.replaceAll('{bookName}', Uri.encodeComponent(key));
      // 页码：{page} 或 {{page}}；`<n>` 紧跟表示步长
      s = s.replaceAllMapped(RegExp(r'\{\{?page\}?\}(?:<(\d+)>)?'), (m) {
        final step = int.tryParse(m.group(1) ?? '') ?? 1;
        return (1 + (page - 1) * step).toString();
      });
      s = s.replaceAll(RegExp(r'<1>'), '');
      return s;
    }

    final url = _abs(source.bookSourceUrl, substitute(tpl));
    if (bodyTemplate != null && bodyTemplate.startsWith('{')) {
      try {
        final opt = jsonDecode(substitute(bodyTemplate.replaceAll("'", '"'))) as Map<String, dynamic>;
        final body = opt['body'];
        final ct = opt['contentType'] as String?;
        if (body != null) {
          return (url: url, body: body is String ? body : jsonEncode(body), contentType: ct);
        }
      } catch (_) {}
    }
    return (url: url, body: null, contentType: null);
  }

  /// 找到 url 部分与其 `&&` 选项分隔点（选项以 { 开头才算）
  int? _findOptionsSplit(String tpl) {
    var idx = tpl.indexOf('&&');
    while (idx >= 0) {
      final rest = tpl.substring(idx + 2).trim();
      if (rest.startsWith('{')) return idx;
      idx = tpl.indexOf('&&', idx + 2);
    }
    return null;
  }

  Future<List<SearchBook>> search(String key, {int page = 1}) async {
    final built = _buildSearchUrl(key, page);
    if (built.url.isEmpty) return [];
    PageResponse resp;
    if (built.body != null) {
      resp = await HttpClient.instance.post(built.url,
          body: built.body, headers: _headers, contentType: built.contentType ?? 'application/json');
    } else {
      resp = await HttpClient.instance.get(built.url, headers: _headers);
    }
    return _parseBookList(resp.body, resp.url,
        listRule: source.ruleSearch.bookList.isEmpty
            ? 'class.searchbook'
            : source.ruleSearch.bookList,
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
    var tpl = urlTemplate;
    String? bodyTemplate;
    final amp = _findOptionsSplit(tpl);
    if (amp != null) {
      bodyTemplate = tpl.substring(amp + 2).trim();
      tpl = tpl.substring(0, amp).trim();
    }
    tpl = tpl.replaceAllMapped(RegExp(r'\{\{?page\}?\}(?:<(\d+)>)?'), (m) {
      final step = int.tryParse(m.group(1) ?? '') ?? 1;
      return (1 + (page - 1) * step).toString();
    });
    final url = _abs(source.bookSourceUrl, tpl);
    PageResponse resp;
    if (bodyTemplate != null && bodyTemplate.trim().startsWith('{')) {
      resp = await HttpClient.instance.post(url, body: bodyTemplate, headers: _headers);
    } else {
      resp = await HttpClient.instance.get(url, headers: _headers);
    }
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
      items = isJson ? [jsonDecode(body)] : [body];
    } else {
      items = RuleEngine.getElements(body, listRule, isJson: isJson);
    }
    final out = <SearchBook>[];
    for (final item in items) {
      final itemText = _itemToText(item);
      String pick(String rule) {
        if (rule.trim().isEmpty) return '';
        final list = RuleEngine.getStringList(itemText, rule, isJson: item is Map || item is List);
        return list.isEmpty ? '' : list.first.trim();
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
    // Element
    return item.outerHtml.toString();
  }

  Future<BookDetail> bookInfo(String bookUrl, {String? name, String? author}) async {
    final resp = await HttpClient.instance.get(bookUrl, headers: _headers);
    final body = resp.body;
    final url = resp.url;
    final isJson = ContentAnalyzer.isJsonContent(body);
    final rb = source.ruleBookInfo;
    String pick(String rule) {
      if (rule.trim().isEmpty) return '';
      final l = RuleEngine.getStringList(body, rule, isJson: isJson);
      return l.isEmpty ? '' : l.first.trim();
    }

    final detail = BookDetail()
      ..bookUrl = url
      ..sourceUrl = source.bookSourceUrl
      ..sourceName = source.bookSourceName
      ..name = pick(rb.name).isNotEmpty ? pick(rb.name) : (name ?? '')
      ..author = pick(rb.author).isNotEmpty ? pick(rb.author) : (author ?? '')
      ..intro = pick(rb.intro)
      ..kind = pick(rb.kind)
      ..lastChapter = pick(rb.lastChapter)
      ..coverUrl = _abs(url, pick(rb.coverUrl))
      ..tocUrl = _abs(url, pick(rb.tocUrl));
    if (detail.tocUrl.isEmpty) detail.tocUrl = url;
    return detail;
  }

  Future<List<Chapter>> toc(String tocUrl) async {
    final resp = await HttpClient.instance.get(tocUrl, headers: _headers);
    var body = resp.body;
    var pageUrl = resp.url;
    final isJson = ContentAnalyzer.isJsonContent(body);
    final rt = source.ruleToc;

    // 章节列表规则：chapterList 选出节点，再逐个取 name/url
    // Legado 中 ruleToc 无 chapterList 字段，通常用选择前缀；约定：
    // 若规则含 `@`，前半为列表选择，但简化处理：chapterName 直接在全文找。
    List<String> names;
    List<String> urls;
    if (rt.chapterName.trim().isEmpty) {
      return [];
    }
    names = RuleEngine.getStringList(body, rt.chapterName, isJson: isJson);
    urls = rt.chapterUrl.trim().isEmpty ? List.generate(names.length, (_) => '') : RuleEngine.getStringList(body, rt.chapterUrl, isJson: isJson);
    if (urls.length == 1 && names.length > 1) urls = List.generate(names.length, (_) => urls.first);
    if (names.length == 1 && urls.length > 1) names = List.generate(urls.length, (_) => names.first);
    final len = names.length < urls.length ? names.length : urls.length;
    final chapters = <Chapter>[];
    for (var i = 0; i < len; i++) {
      final title = _cleanText(names[i]);
      if (title.isEmpty) continue;
      chapters.add(Chapter(title, _abs(pageUrl, urls[i]), i));
    }

    // nextTocUrl 追加后续页
    if (rt.nextTocUrl.trim().isNotEmpty) {
      var nextUrl = RuleEngine.getString(body, rt.nextTocUrl, isJson: isJson);
      var guard = 0;
      while (nextUrl.trim().isNotEmpty && guard++ < 20) {
        final abs = _abs(pageUrl, nextUrl);
        if (abs == pageUrl) break;
        final resp2 = await HttpClient.instance.get(abs, headers: _headers);
        body = resp2.body;
        pageUrl = resp2.url;
        final isJson2 = ContentAnalyzer.isJsonContent(body);
        final n2 = RuleEngine.getStringList(body, rt.chapterName, isJson: isJson2);
        final u2 = rt.chapterUrl.trim().isEmpty
            ? List.generate(n2.length, (_) => '')
            : RuleEngine.getStringList(body, rt.chapterUrl, isJson: isJson2);
        final l2 = n2.length < u2.length ? n2.length : u2.length;
        for (var i = 0; i < l2; i++) {
          final title = _cleanText(n2[i]);
          if (title.isEmpty) continue;
          chapters.add(Chapter(title, _abs(pageUrl, u2[i]), chapters.length));
        }
        nextUrl = RuleEngine.getString(body, rt.nextTocUrl, isJson: isJson2);
      }
    }
    return chapters;
  }

  static String _cleanText(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<String> content(String chapterUrl, {String? title}) async {
    final rc = source.ruleContent;
    var url = chapterUrl;
    final buffers = <String>[];
    var guard = 0;
    while (url.isNotEmpty && guard++ < 20) {
      final resp = await HttpClient.instance.get(url, headers: _headers);
      final body = resp.body;
      final pageUrl = resp.url;
      final isJson = ContentAnalyzer.isJsonContent(body);
      final parts = rc.content.trim().isEmpty
          ? [body]
          : RuleEngine.getStringList(body, rc.content, isJson: isJson);
      buffers.addAll(parts);
      if (rc.nextContentUrl.trim().isEmpty) break;
      var next = _cleanText(RuleEngine.getString(body, rc.nextContentUrl, isJson: isJson));
      if (next.isEmpty) break;
      final abs = _abs(pageUrl, next);
      if (abs == url) break;
      url = abs;
    }
    var text = buffers.join('\n');
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
      if (parts.length >= 2) {
        try {
          text = text.replaceAllMapped(RegExp(parts[0], dotAll: true), (m) => _expand(m, parts[1]));
        } catch (_) {}
      } else if (parts.length == 1 && parts.first.isNotEmpty) {
        try {
          text = text.replaceAll(RegExp(parts.first, dotAll: true), '');
        } catch (_) {}
      }
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

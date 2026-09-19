import 'dart:convert';

/// Legado 风格书源数据模型。
/// 仅保留 v1 规则引擎实际使用的字段，其余字段原样保留以便导出兼容。
class BookSource {
  final String bookSourceUrl;
  final String bookSourceName;
  final String bookSourceGroup;
  final String? bookSourceType;
  final String? bookUrlPattern;
  final String? searchUrl;
  final bool enabled;
  final int customOrder;
  final String? header;
  final String? bookSourceComment;
  final int? lastUpdateTime;
  final String? weight;

  final BookInfoRule ruleBookInfo;
  final SearchRule ruleSearch;
  final ExploreRule ruleExplore;
  final TocRule ruleToc;
  final ContentRule ruleContent;

  final Map<String, dynamic> raw;

  BookSource({
    required this.bookSourceUrl,
    required this.bookSourceName,
    this.bookSourceGroup = '',
    this.bookSourceType,
    this.bookUrlPattern,
    this.searchUrl,
    this.exploreUrl,
    this.enabled = true,
    this.customOrder = 0,
    this.header,
    this.bookSourceComment,
    this.lastUpdateTime,
    this.weight,
    required this.ruleBookInfo,
    required this.ruleSearch,
    required this.ruleExplore,
    required this.ruleToc,
    required this.ruleContent,
    required this.raw,
  });

  final String? exploreUrl;

  factory BookSource.fromJson(Map<String, dynamic> j) {
    Map<String, dynamic> m(dynamic v) =>
        v is Map<String, dynamic> ? v : (v is Map ? v.cast<String, dynamic>() : <String, dynamic>{});
    return BookSource(
      bookSourceUrl: (j['bookSourceUrl'] ?? '').toString(),
      bookSourceName: (j['bookSourceName'] ?? j['bookSourceUrl'] ?? '未命名书源').toString(),
      bookSourceGroup: (j['bookSourceGroup'] ?? '').toString(),
      bookSourceType: j['bookSourceType']?.toString(),
      bookUrlPattern: j['bookUrlPattern']?.toString(),
      searchUrl: j['searchUrl']?.toString(),
      exploreUrl: j['exploreUrl']?.toString(),
      enabled: j['enabled'] != false,
      customOrder: (j['customOrder'] is num) ? (j['customOrder'] as num).toInt() : 0,
      header: j['header']?.toString(),
      bookSourceComment: j['bookSourceComment']?.toString(),
      lastUpdateTime: (j['lastUpdateTime'] is num) ? (j['lastUpdateTime'] as num).toInt() : null,
      weight: j['weight']?.toString(),
      ruleBookInfo: BookInfoRule.fromJson(m(j['ruleBookInfo'])),
      ruleSearch: SearchRule.fromJson(m(j['ruleSearch'])),
      ruleExplore: ExploreRule.fromJson(m(j['ruleExplore'])),
      ruleToc: TocRule.fromJson(m(j['ruleToc'])),
      ruleContent: ContentRule.fromJson(m(j['ruleContent'])),
      raw: j,
    );
  }

  Map<String, dynamic> toJson() => raw;

  /// 书源类型: 0 小说 1 漫画 2 音频 3 视频
  int get sourceType => int.tryParse(bookSourceType ?? '0') ?? 0;
  bool get isNovel => sourceType == 0;
}

class BookInfoRule {
  final String name;
  final String author;
  final String intro;
  final String coverUrl;
  final String kind;
  final String tocUrl;
  final String lastChapter;
  final String canReName;
  final String bookInfoUrl;

  BookInfoRule({
    this.name = '',
    this.author = '',
    this.intro = '',
    this.coverUrl = '',
    this.kind = '',
    this.tocUrl = '',
    this.lastChapter = '',
    this.canReName = '',
    this.bookInfoUrl = '',
  });

  factory BookInfoRule.fromJson(Map<String, dynamic> j) => BookInfoRule(
        name: (j['name'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        intro: (j['intro'] ?? '').toString(),
        coverUrl: (j['coverUrl'] ?? j['cover'] ?? '').toString(),
        kind: (j['kind'] ?? '').toString(),
        tocUrl: (j['tocUrl'] ?? '').toString(),
        lastChapter: (j['lastChapter'] ?? '').toString(),
        canReName: (j['canReName'] ?? '').toString(),
        bookInfoUrl: (j['init'] ?? '').toString(),
      );
}

class SearchRule {
  final String bookList;
  final String name;
  final String author;
  final String kind;
  final String wordCount;
  final String lastChapter;
  final String checkKeyWord;
  final String coverUrl;
  final String intro;
  final String bookUrl;

  SearchRule({
    this.bookList = '##class.*item.*',
    this.name = '',
    this.author = '',
    this.kind = '',
    this.wordCount = '',
    this.lastChapter = '',
    this.checkKeyWord = '',
    this.coverUrl = '',
    this.intro = '',
    this.bookUrl = '',
  });

  factory SearchRule.fromJson(Map<String, dynamic> j) => SearchRule(
        bookList: (j['bookList'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        kind: (j['kind'] ?? '').toString(),
        wordCount: (j['wordCount'] ?? '').toString(),
        lastChapter: (j['lastChapter'] ?? '').toString(),
        checkKeyWord: (j['checkKeyWord'] ?? '').toString(),
        coverUrl: (j['coverUrl'] ?? '').toString(),
        intro: (j['intro'] ?? '').toString(),
        bookUrl: (j['bookUrl'] ?? '').toString(),
      );
}

class ExploreRule {
  final String title;
  final String note;
  final String bookList;
  final String name;
  final String author;
  final String kind;
  final String wordCount;
  final String lastChapter;
  final String coverUrl;
  final String intro;
  final String bookUrl;
  final String urlPattern;

  ExploreRule({
    this.title = '',
    this.note = '',
    this.bookList = '',
    this.name = '',
    this.author = '',
    this.kind = '',
    this.wordCount = '',
    this.lastChapter = '',
    this.coverUrl = '',
    this.intro = '',
    this.bookUrl = '',
    this.urlPattern = '',
  });

  factory ExploreRule.fromJson(Map<String, dynamic> j) => ExploreRule(
        title: (j['title'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
        bookList: (j['bookList'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        kind: (j['kind'] ?? '').toString(),
        wordCount: (j['wordCount'] ?? '').toString(),
        lastChapter: (j['lastChapter'] ?? '').toString(),
        coverUrl: (j['coverUrl'] ?? '').toString(),
        intro: (j['intro'] ?? '').toString(),
        bookUrl: (j['bookUrl'] ?? '').toString(),
        urlPattern: (j['urlPattern'] ?? '').toString(),
      );
}

class TocRule {
  final String chapterList;
  final String chapterName;
  final String chapterUrl;
  final String formatJs;
  final String nextTocUrl;
  final String updateTime;
  final String isVip;

  TocRule({
    this.chapterList = '',
    this.chapterName = '',
    this.chapterUrl = '',
    this.formatJs = '',
    this.nextTocUrl = '',
    this.updateTime = '',
    this.isVip = '',
  });

  factory TocRule.fromJson(Map<String, dynamic> j) => TocRule(
        chapterList: (j['chapterList'] ?? '').toString(),
        chapterName: (j['chapterName'] ?? '').toString(),
        chapterUrl: (j['chapterUrl'] ?? '').toString(),
        formatJs: (j['formatJs'] ?? '').toString(),
        nextTocUrl: (j['nextTocUrl'] ?? '').toString(),
        updateTime: (j['updateTime'] ?? '').toString(),
        isVip: (j['isVip'] ?? '').toString(),
      );
}

class ContentRule {
  final String content;
  final String title;
  final String nextContentUrl;
  final String replaceRegex;
  final String imageDecode;
  final String webViewJs;

  ContentRule({
    this.content = '',
    this.title = '',
    this.nextContentUrl = '',
    this.replaceRegex = '',
    this.imageDecode = '',
    this.webViewJs = '',
  });

  factory ContentRule.fromJson(Map<String, dynamic> j) => ContentRule(
        content: (j['content'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        nextContentUrl: (j['nextContentUrl'] ?? '').toString(),
        replaceRegex: (j['replaceRegex'] ?? '').toString(),
        imageDecode: (j['imageDecode'] ?? '').toString(),
        webViewJs: (j['webViewJs'] ?? '').toString(),
      );
}

/// 解析书源导入文本：支持 JSON 数组、JSONL（每行一个对象）、以及嵌套在
/// `{"books":[...]}` / `{"data":[...]}` 中的数组。
List<BookSource> parseBookSources(String text) {
  final trimmed = text.trim();
  final list = <Map<String, dynamic>>[];
  dynamic decoded;
  try {
    decoded = _jsonDecodeLoose(trimmed);
  } catch (_) {
    decoded = null;
  }
  if (decoded is List) {
    for (final e in decoded) {
      if (e is Map) list.add(e.cast<String, dynamic>());
    }
  } else if (decoded is Map) {
    final arr = decoded['books'] ?? decoded['data'] ?? decoded['source'] ?? decoded['list'];
    if (arr is List) {
      for (final e in arr) {
        if (e is Map) list.add(e.cast<String, dynamic>());
      }
    } else if (decoded['bookSourceUrl'] != null) {
      list.add(decoded.cast<String, dynamic>());
    }
  } else {
    // JSONL：逐行解析
    for (final line in trimmed.split(RegExp(r'\r?\n'))) {
      final l = line.trim();
      if (l.isEmpty) continue;
      try {
        final m = _jsonDecodeLoose(l);
        if (m is Map && m['bookSourceUrl'] != null) list.add(m.cast<String, dynamic>());
      } catch (_) {}
    }
  }
  return list
      .where((e) => (e['bookSourceUrl'] ?? '').toString().isNotEmpty)
      .map(BookSource.fromJson)
      .toList();
}

dynamic _jsonDecodeLoose(String text) {
  return jsonDecode(text);
}

import '../core/source_format_adapter.dart';

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
      bookUrlPattern: _plainText(j['bookUrlPattern']),
      searchUrl: _plainText(j['searchUrl']),
      exploreUrl: _plainText(j['exploreUrl']),
      enabled: j['enabled'] != false,
      customOrder: (j['customOrder'] is num) ? (j['customOrder'] as num).toInt() : 0,
      header: _plainText(j['header']),
      bookSourceComment: _plainText(j['bookSourceComment']),
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

  /// 这些字段只该是文本。以前直接 `toString()`，遇到对象/数组形态的书源
  /// （header 是 `{"User-Agent":"x"}`、searchUrl 是 `[{url:..}]`）会存成 Dart 的
  /// `{User-Agent: x}` 字面量，下游再也解析不回来。非文本一律当没有。
  static String? _plainText(dynamic v) {
    if (v == null || v is Map || v is List) return null;
    return v.toString();
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

/// 书源导入文本的解析结果：可用源 + 需要如实告知用户的旁落内容。
class BookSourceParseResult {
  final List<BookSource> sources;

  /// 缺 URL / 结构损坏被丢弃的条数
  final int dropped;

  /// 书籍分享码条数（不是书源，导不进来）
  final int bookShares;

  /// 内容超出深度/条目上限，后面没再看
  final bool truncated;

  const BookSourceParseResult({
    this.sources = const [],
    this.dropped = 0,
    this.bookShares = 0,
    this.truncated = false,
  });
}

/// 解析书源导入文本：顶层 JSON 数组、JSONL（每行一个对象）、任意包装键
/// （`{"books":[...]}` / `{"code":0,"data":{"bookSourceList":[...]}}` 都能挖到）、
/// 「书源名 → 对象」的 map 形态，外加 base64 / URL 编码 / gzip 包装与带注释、
/// 单引号、尾逗号、裸键的宽松 JSON；字段别名统一对齐到 Legado 规范键。
/// 按 bookSourceUrl 去重（保留后出现的），单条损坏只丢那一条。
List<BookSource> parseBookSources(String text) => parseBookSourcesDetailed(text).sources;

BookSourceParseResult parseBookSourcesDetailed(String text) {
  final report = extractSourceCandidates(text);
  final byUrl = <String, BookSource>{};
  var dropped = 0;
  for (final e in report.candidates) {
    try {
      final s = BookSource.fromJson(e);
      if (s.bookSourceUrl.isEmpty) {
        dropped++;
        continue;
      }
      byUrl[s.bookSourceUrl] = s;
    } catch (_) {
      dropped++;
    }
  }
  return BookSourceParseResult(
    sources: byUrl.values.toList(),
    dropped: dropped,
    bookShares: report.bookShares,
    truncated: report.truncated,
  );
}

/// 书源导入结果统计，用于向用户如实反馈"新增 / 更新 / 跳过"。
class ImportResult {
  final int added; // 本地原本没有、本次新建的源
  final int updated; // URL 已存在、按新内容刷新的源
  final int skipped; // 缺 URL / 结构损坏 / 写盘失败 / 超上限被丢弃的条目
  final int bookShares; // 识别为书籍分享码、按书源导不进来的条数
  final bool truncated; // 内容超出解析上限，后面没再看
  const ImportResult(
      {this.added = 0,
      this.updated = 0,
      this.skipped = 0,
      this.bookShares = 0,
      this.truncated = false});
  int get changed => added + updated;
  bool get isEmpty => changed == 0;

  String get summary {
    if (isEmpty) {
      if (bookShares > 0) return '内容是书籍分享码（$bookShares 条），不是书源';
      if (skipped > 0) return '未导入有效书源（$skipped 条无法解析）';
      return '未导入有效书源（内容需包含书源定义）';
    }
    final parts = <String>[];
    if (added > 0) parts.add('新增 $added');
    if (updated > 0) parts.add('更新 $updated');
    if (skipped > 0) parts.add('跳过 $skipped');
    if (bookShares > 0) parts.add('另有 $bookShares 条书籍分享码不是书源');
    if (truncated) parts.add('内容过长，超出部分未解析');
    return parts.join('，');
  }
}

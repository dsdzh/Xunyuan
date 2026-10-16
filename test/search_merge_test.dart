import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/book_source_engine.dart';
import 'package:xunyuan/models/book_source.dart';
import 'package:xunyuan/pages/search_page.dart';

BookSource src(String url, String name) =>
    BookSource.fromJson({'bookSourceUrl': url, 'bookSourceName': name});

SearchBook book(String name, String author) => SearchBook(
      name: name,
      author: author,
      bookUrl: 'https://x/$name-$author',
      sourceUrl: 'https://x',
      sourceName: 's',
    );

SourceGroupResult grp(BookSource source, List<SearchBook> books) =>
    SourceGroupResult(source)..books = books;

void main() {
  group('mergeSearchResults', () {
    test('同一本书被多个源命中时只留一条，并累计 dupes', () {
      final a = src('https://a', 'A源');
      final b = src('https://b', 'B源');
      final c = src('https://c', 'C源');
      final hits = mergeSearchResults([
        grp(a, [book('星渊纪元', '甲')]),
        grp(b, [book('星渊纪元', '甲')]),
        grp(c, [book('星渊纪元', '甲')]),
      ]);
      expect(hits.length, 1);
      expect(hits.single.dupes, 2);
      // 保留首次命中的源，点它才能用对应该源的详情规则
      expect(hits.single.source.bookSourceName, 'A源');
    });

    test('书名或作者不同即视为不同的书，顺序按返回次序', () {
      final a = src('https://a', 'A源');
      final hits = mergeSearchResults([
        grp(a, [book('甲书', '作者1'), book('乙书', '作者2'), book('丙书', '作者3')]),
      ]);
      expect(hits.map((h) => h.book.name), ['甲书', '乙书', '丙书']);
      expect(hits.every((h) => h.dupes == 0), isTrue);
    });

    test('空分组与无结果不影响输出', () {
      final a = src('https://a', 'A源');
      final b = src('https://b', 'B源');
      expect(mergeSearchResults([]), isEmpty);
      expect(mergeSearchResults([grp(a, []), grp(b, [])]), isEmpty);
      final hits = mergeSearchResults([
        grp(a, []),
        grp(b, [book('唯一', '者')]),
      ]);
      expect(hits.single.book.name, '唯一');
      expect(hits.single.source.bookSourceName, 'B源');
    });

    test('同名不同作者不合并', () {
      final a = src('https://a', 'A源');
      final b = src('https://b', 'B源');
      final hits = mergeSearchResults([
        grp(a, [book('重名', '张三')]),
        grp(b, [book('重名', '李四')]),
      ]);
      expect(hits.length, 2);
    });
  });
}

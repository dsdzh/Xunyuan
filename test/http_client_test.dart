import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/http_client.dart';

void main() {
  test('decode：空 charsetHint 不得压过 Content-Type 的 GBK 声明', () {
    final bytes = HttpClient.gbkEncode('第一章 星渊纪元');
    final out = HttpClient.decode(bytes,
        contentType: 'text/html; charset=GBK', hint: '');
    expect(out, '第一章 星渊纪元');
  });

  test('decode：有效 hint 优先于 Content-Type', () {
    final bytes = utf8.encode('你好世界');
    final out = HttpClient.decode(bytes,
        contentType: 'text/html; charset=gbk', hint: 'utf-8');
    expect(out, '你好世界');
  });

  test('CookieJar：Max-Age=0 是删除指令，不得存成空值重放', () {
    final jar = CookieJar();
    jar.storeFrom('https://m.example.com/search', ['sid=abc123; Path=/']);
    expect(jar.headerFor('https://m.example.com/x'), contains('sid=abc123'));
    jar.storeFrom('https://m.example.com/logout', ['sid=; Max-Age=0; Path=/']);
    expect(jar.headerFor('https://m.example.com/x'), isNot(contains('sid')));
  });

  test('CookieJar：Expires=1970 同样按删除处理', () {
    final jar = CookieJar();
    jar.storeFrom('https://a.example.com/', ['tok=v1']);
    jar.storeFrom('https://a.example.com/',
        ['tok=v2; Expires=Thu, 01 Jan 1970 00:00:00 GMT']);
    expect(jar.headerFor('https://a.example.com/'), isEmpty);
  });
}

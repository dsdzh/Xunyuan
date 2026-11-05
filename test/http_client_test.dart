import 'dart:convert';

import 'package:dio/dio.dart';
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

  group('出站请求的出口闸门', () {
    test('sanitizeHeaders：非法名与带 CR/LF 的值一律丢，合法项原样保留', () {
      expect(
        HttpClient.sanitizeHeaders({
          'User-Agent': 'UA',
          'a b': 'x',
          '': 'y',
          'X-Bad': 'v\r\nX-Injected: 1',
          'X-Multi': 'a\nb',
          'X-Good': '1',
        }),
        {'User-Agent': 'UA', 'X-Good': '1'},
      );
    });

    test('非 http/https 直接拒：file:// 与 data: 都轮不到 dio', () async {
      await expectLater(
        HttpClient.instance.get('file:///data/data/ds.xunyuan.com/files/x.json'),
        throwsA(isA<UnsupportedUrlException>()),
      );
      await expectLater(
        HttpClient.instance.post('data:text/plain,hello'),
        throwsA(isA<UnsupportedUrlException>()),
      );
    });

    test('协议白名单不影响 http（错误来自连接层，不是闸门）', () async {
      // 端口 1 上必然连不上：拿到 DioException 就说明放行到了发送层
      await expectLater(
        HttpClient.instance.get('http://127.0.0.1:1/'),
        throwsA(isA<DioException>()),
      );
    });

    /// 缺 scheme 的书源写法（`www.a.com/book/{key}`）与相对地址不是"别的协议"，
    /// 闸门不能把它们报成协议问题
    test('缺 scheme 的地址不算协议违规', () async {
      await expectLater(
        HttpClient.instance.get('127.0.0.1:1/x'),
        throwsA(isNot(isA<UnsupportedUrlException>())),
      );
    });

    test('异常信息只报协议名，不整段回显地址', () {
      expect(UnsupportedUrlException('file:///secret/dir/private.json').toString(),
          contains('file://'));
    });
  });
}

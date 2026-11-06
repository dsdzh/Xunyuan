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

  /// 只看 1970 的话，`Expires=Wed, 09 Jun 2021 10:18:14 GMT` 这种早已过期的会话
  /// Cookie 会被当成永久凭据一直重放，服务端按过期票据处理反而认不出登录态
  test('CookieJar：任何早于当前时刻的 Expires 都是删除指令', () {
    final jar = CookieJar();
    jar.storeFrom('https://a.example.com/', ['tok=live']);
    jar.storeFrom('https://a.example.com/',
        ['tok=dead; Expires=Wed, 09 Jun 2021 10:18:14 GMT']);
    expect(jar.headerFor('https://a.example.com/'), isEmpty);
  });

  test('CookieJar：还没到期的 Expires 必须留着，日期格式看不懂也当未过期', () {
    final jar = CookieJar();
    jar.storeFrom('https://a.example.com/', ['sid=keep; Expires=Wed, 09 Jun 2038 10:18:14 GMT']);
    expect(jar.headerFor('https://a.example.com/'), contains('sid=keep'));
    jar.storeFrom('https://b.example.com/', ['sid=odd; Expires=某个奇怪的写法']);
    expect(jar.headerFor('https://b.example.com/'), contains('sid=odd'));
  });

  test('CookieJar：Secure cookie 不在明文 http 上重放', () {
    final jar = CookieJar();
    jar.storeFrom('https://a.example.com/', ['sid=v; Secure; Path=/']);
    expect(jar.headerFor('https://a.example.com/x'), contains('sid=v'));
    expect(jar.headerFor('http://a.example.com/x'), isEmpty);
    // 普通 cookie 两边都给，别把老站的登录态一起掐了
    jar.storeFrom('https://c.example.com/', ['sid=plain']);
    expect(jar.headerFor('http://c.example.com/x'), contains('sid=plain'));
  });

  test('CookieJar：主机数封顶，扫站的站不会把内存撑到无界', () {
    final jar = CookieJar();
    for (var i = 0; i < 600; i++) {
      jar.storeFrom('https://h$i.example.com/', ['sid=$i']);
    }
    expect(jar.headerFor('https://h599.example.com/'), contains('sid=599'));
    expect(jar.headerFor('https://h0.example.com/'), isEmpty);
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

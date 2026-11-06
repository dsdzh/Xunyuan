import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/book_source_engine.dart';
import 'package:xunyuan/core/http_client.dart';
import 'package:xunyuan/models/book_source.dart';

/// 假网络出口：记下每一发出站请求，按请求路径返回预设响应。
/// "第几跳带了哪些 header、中途的 Set-Cookie 记在哪个主机"这类行为只有真跑一遍链路才看得见，
/// 单测 `UrlPolicy` 的纯函数是钉不住接线是否正确的。
class _FakeResponse {
  final int status;
  final Map<String, String> headers;
  final String body;
  const _FakeResponse(this.status, {this.headers = const {}, this.body = '<html>ok</html>'});
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.byPath);

  /// key 用请求路径（`/search`），不写全 URL：`{{key}}` 会被编码，拿完整 URL 比太脆。
  final Map<String, _FakeResponse> byPath;
  final List<RequestOptions> sent = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    sent.add(options);
    final r = byPath[options.uri.path] ?? const _FakeResponse(200);
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(r.body))),
      r.status,
      headers: {for (final e in r.headers.entries) e.key.toLowerCase(): [e.value]},
    );
  }

  @override
  void close({bool force = false}) {}
}

String? _header(RequestOptions o, String name) {
  for (final e in o.headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return e.value?.toString();
  }
  return null;
}

const creds = {'X-Token': 'tok-secret', 'Authorization': 'Bearer abc', 'Cookie': 'sid=me'};

void main() {
  late _FakeAdapter adapter;

  setUp(() => HttpClient.instance.cookies.clear());
  tearDown(() => HttpClient.instance.useAdapterForTesting(null));

  group('重定向逐跳的凭证剥离', () {
    test('一跳 302 到别的注册域：令牌类 header 全部不得跟过去', () async {
      adapter = _FakeAdapter({
        '/search': const _FakeResponse(302, headers: {'location': 'https://attacker.com/collect'}),
        '/collect': const _FakeResponse(200),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      final resp = await HttpClient.instance
          .get('https://www.qidian.com/search', headers: {...creds, 'User-Agent': 'UA'});

      expect(resp.statusCode, 200);
      expect(adapter.sent.length, 2);
      expect(adapter.sent[1].uri.host, 'attacker.com');
      // dart:io 自己跟随时只剥 authorization/cookie/www-authenticate/cookie2，
      // X-Token 会原样漏过去——这条就是那个洞
      expect(_header(adapter.sent[1], 'X-Token'), isNull);
      expect(_header(adapter.sent[1], 'Authorization'), isNull);
      expect(_header(adapter.sent[1], 'Cookie'), isNull);
      // 非凭证头照旧带着，别把 UA 也一刀切了
      expect(_header(adapter.sent[1], 'User-Agent'), 'UA');
    });

    test('同注册域（www→m.）跳转：凭证头继续带，功能不能因此坏掉', () async {
      adapter = _FakeAdapter({
        '/search': const _FakeResponse(302, headers: {'location': 'https://m.qidian.com/list'}),
        '/list': const _FakeResponse(200),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      await HttpClient.instance.get('https://www.qidian.com/search', headers: creds);

      expect(adapter.sent[1].uri.host, 'm.qidian.com');
      expect(_header(adapter.sent[1], 'X-Token'), 'tok-secret');
      expect(_header(adapter.sent[1], 'Cookie'), 'sid=me');
    });

    test('二级公有后缀算不同站：a.com.cn → b.com.cn 要剥', () async {
      adapter = _FakeAdapter({
        '/search': const _FakeResponse(302, headers: {'location': 'https://b.com.cn/x'}),
        '/x': const _FakeResponse(200),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      await HttpClient.instance.get('https://a.com.cn/search', headers: creds);

      expect(_header(adapter.sent[1], 'X-Token'), isNull);
    });

    test('两跳之后回到起点站：凭证头恢复（防的是漏给第三方，不是一路剥到底）', () async {
      adapter = _FakeAdapter({
        '/a': const _FakeResponse(302, headers: {'location': 'https://evil.com/b'}),
        '/b': const _FakeResponse(302, headers: {'location': 'https://m.qidian.com/c'}),
        '/c': const _FakeResponse(200),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      await HttpClient.instance.get('https://www.qidian.com/a', headers: creds);

      expect(_header(adapter.sent[1], 'X-Token'), isNull);
      expect(_header(adapter.sent[2], 'X-Token'), 'tok-secret');
    });

    test('中途那跳的 Set-Cookie 记在它自己的主机上，不再挂到终点域名', () async {
      adapter = _FakeAdapter({
        '/start': const _FakeResponse(
            302, headers: {'location': 'https://other.com/end', 'set-cookie': 'mid=1; Path=/'}),
        '/end': const _FakeResponse(200),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      await HttpClient.instance.get('https://www.qidian.com/start');

      expect(HttpClient.instance.cookies.headerFor('https://www.qidian.com/any'), contains('mid=1'));
      expect(HttpClient.instance.cookies.headerFor('https://other.com/any'), isEmpty);
    });

    test('跳转目标的 Cookie 用目标主机自己那份，不带起点站的登录态', () async {
      HttpClient.instance.cookies
          .storeFrom('https://other.com/', ['that=their-value']);
      adapter = _FakeAdapter({
        '/search': const _FakeResponse(302, headers: {'location': 'https://other.com/x'}),
        '/x': const _FakeResponse(200),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      await HttpClient.instance.get('https://www.qidian.com/search', headers: creds);

      expect(_header(adapter.sent[1], 'Cookie'), 'that=their-value');
    });
  });

  group('重定向的方法与协议', () {
    test('302/303 把 POST 换成 GET 并丢掉请求体，307 原样重发', () async {
      adapter = _FakeAdapter({
        '/p': const _FakeResponse(302, headers: {'location': 'https://www.qidian.com/r302'}),
        '/r302': const _FakeResponse(303, headers: {'location': 'https://www.qidian.com/final'}),
        '/final': const _FakeResponse(200),
        '/q': const _FakeResponse(307, headers: {'location': 'https://www.qidian.com/keep'}),
        '/keep': const _FakeResponse(200),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      await HttpClient.instance.post('https://www.qidian.com/p', body: 'kw=x');
      expect(adapter.sent.map((o) => o.method).toList(), ['POST', 'GET', 'GET']);

      adapter = _FakeAdapter({
        '/q': const _FakeResponse(307, headers: {'location': 'https://www.qidian.com/keep'}),
        '/keep': const _FakeResponse(200),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      await HttpClient.instance.post('https://www.qidian.com/q', body: 'kw=x');
      expect(adapter.sent.map((o) => o.method).toList(), ['POST', 'POST']);
    });

    test('跳到 javascript:/file: 一样被协议闸门拦下，不能因为"是站点让我跳的"就放行', () async {
      adapter = _FakeAdapter({
        '/search': const _FakeResponse(302, headers: {'location': 'javascript:alert(1)'}),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      await expectLater(
        HttpClient.instance.get('https://www.qidian.com/search'),
        throwsA(isA<UnsupportedUrlException>()),
      );
      expect(adapter.sent.length, 1); // 第二发根本没发出去

      adapter = _FakeAdapter({
        '/x': const _FakeResponse(302, headers: {'location': 'file:///data/data/x'}),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      await expectLater(
        HttpClient.instance.get('https://www.qidian.com/x'),
        throwsA(isA<UnsupportedUrlException>()),
      );
    });

    test('互相跳的环：跳满上限就收手，不把请求发不完', () async {
      adapter = _FakeAdapter({
        '/a': const _FakeResponse(302, headers: {'location': '/b'}),
        '/b': const _FakeResponse(302, headers: {'location': '/a'}),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      final resp = await HttpClient.instance.get('https://www.qidian.com/a');

      expect(adapter.sent.length, HttpClient.maxRedirectHops + 1);
      expect(resp.statusCode, 302); // 不再跟随，把手上的响应原样交回
    });

    test('PageResponse.url 保留跳转后的完整地址（含 query），相对链接基准不能丢', () async {
      adapter = _FakeAdapter({
        '/search': const _FakeResponse(
            302, headers: {'location': 'https://m.qidian.com/list?page=2&sign=abc'}),
        '/list': const _FakeResponse(200),
      });
      HttpClient.instance.useAdapterForTesting(adapter);
      final resp = await HttpClient.instance.get('https://www.qidian.com/search');
      expect(resp.url, 'https://m.qidian.com/list?page=2&sign=abc');
    });
  });

  test('站点拒绝的错误信息只到 path：跳转目标上的 ?code=/?token= 不会被写进健康度落盘', () async {
    adapter = _FakeAdapter({
      '/search': const _FakeResponse(
          302,
          headers: {
            'location': 'https://passport.qidian.com/login?code=SECRET-CODE&token=SECRET-TOKEN'
          }),
      '/login': const _FakeResponse(404, body: 'gone'),
    });
    HttpClient.instance.useAdapterForTesting(adapter);
    final engine = BookSourceEngine(BookSource.fromJson({
      'bookSourceUrl': 'https://www.qidian.com',
      'bookSourceName': '起点中文',
      'searchUrl': '/search?kw={{key}}',
    }));
    Object? caught;
    try {
      await engine.search('abc');
    } catch (e) {
      caught = e;
    }
    expect(caught, isNotNull);
    expect('$caught', contains('HTTP 404'));
    expect('$caught', contains('https://passport.qidian.com/login'));
    expect('$caught', isNot(contains('SECRET-CODE')));
    expect('$caught', isNot(contains('token')));
  });

  group('UrlPolicy', () {
    test('displayUrl 去掉 query 与 fragment，path 原样留着', () {
      expect(UrlPolicy.displayUrl('https://a.com/p/x?k=1#frag'), 'https://a.com/p/x');
      expect(UrlPolicy.displayUrl('https://a.com/?a=1'), 'https://a.com/');
      expect(UrlPolicy.displayUrl('https://a.com:8443/p'), 'https://a.com:8443/p');
      // 缺 scheme 的书源写法不是 URL，原样给回去别乱改
      expect(UrlPolicy.displayUrl('www.a.com:8080/x?a=1').contains('?'), isTrue);
      expect(UrlPolicy.displayUrl(''), '');
    });

    test('stripCredentials 只认名字不认值，UA/Referer 这些留着', () {
      final out = UrlPolicy.stripCredentials({
        'X-Token': 'a',
        'sessionId': 'b',
        'auth': 'c',
        'api-key': 'd',
        'Cookie': 'e',
        'User-Agent': 'UA',
        'Referer': 'https://a.com',
      });
      expect(out.keys.toSet(), {'User-Agent', 'Referer'});
    });

    test('任一侧解析不出主机就不设限（宁松不误伤老书源）', () {
      expect(UrlPolicy.sameSite('', 'https://a.com/x'), isTrue);
      expect(UrlPolicy.sameSite('https://a.com', 'not a url'), isTrue);
      expect(UrlPolicy.sameSite('http://127.0.0.1:8931/a', 'http://127.0.0.1:8931/b'), isTrue);
      expect(UrlPolicy.sameSite('http://127.0.0.1:1/a', 'http://127.0.0.1:2/b'), isTrue);
      expect(UrlPolicy.sameSite('http://127.0.0.1/a', 'http://192.168.1.2/a'), isFalse);
    });
  });
}

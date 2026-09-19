import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';

/// 响应：已按正确字符集解码
class PageResponse {
  final String body;
  final int statusCode;
  final String url;
  PageResponse(this.body, this.statusCode, this.url);
}

/// 极简 Cookie 管理（按域名）
class CookieJar {
  final Map<String, Map<String, String>> _cookies = {};

  String headerFor(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    final c = _cookies[host];
    if (c == null || c.isEmpty) return '';
    return c.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void storeFrom(String url, List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    final host = Uri.tryParse(url)?.host ?? '';
    final m = _cookies.putIfAbsent(host, () => {});
    for (final sc in setCookies) {
      final pair = sc.split(';').first;
      final eq = pair.indexOf('=');
      if (eq > 0) m[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
    }
  }

  void clear() => _cookies.clear();
}

class HttpClient {
  static final HttpClient instance = HttpClient._();
  late final Dio _dio;
  final CookieJar cookies = CookieJar();

  static const defaultUA =
      'Mozilla/5.0 (Linux; Android 14; SM-S9210) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  HttpClient._() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.bytes,
      followRedirects: true,
      maxRedirects: 10,
      validateStatus: (s) => s != null && s < 500,
    ));
  }

  Future<PageResponse> get(String url, {Map<String, String>? headers, String? charsetHint}) async {
    final options = Options(headers: {
      'User-Agent': defaultUA,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Cookie': cookies.headerFor(url),
      ...?headers,
    }..removeWhere((k, v) => v.isEmpty));
    try {
      final resp = await _dio.get(url, options: options);
      cookies.storeFrom(url, resp.headers['set-cookie']);
      return PageResponse(
        decode(resp.data as List<int>, contentType: resp.headers.value(Headers.contentTypeHeader), hint: charsetHint),
        resp.statusCode ?? 0,
        resp.realUri.toString(),
      );
    } on DioException catch (e) {
      final r = e.response;
      if (r != null && r.data is List<int>) {
        return PageResponse(decode(r.data as List<int>, contentType: r.headers.value(Headers.contentTypeHeader), hint: charsetHint), r.statusCode ?? 0, url);
      }
      rethrow;
    }
  }

  Future<PageResponse> post(String url, {Object? body, Map<String, String>? headers, String? contentType}) async {
    final options = Options(headers: {
      'User-Agent': defaultUA,
      'Cookie': cookies.headerFor(url),
      if (contentType != null) 'Content-Type': contentType,
      ...?headers,
    }..removeWhere((k, v) => v.isEmpty));
    final resp = await _dio.post(url, data: body, options: options);
    cookies.storeFrom(resp.realUri.toString(), resp.headers['set-cookie']);
    final data = resp.data;
    return PageResponse(
      decode(data is List<int> ? data : utf8.encode(data?.toString() ?? ''),
          contentType: resp.headers.value(Headers.contentTypeHeader)),
      resp.statusCode ?? 0,
      resp.realUri.toString(),
    );
  }

  /// 字节 → 字符串：Content-Type / meta charset / BOM / UTF-8 失败回退 GBK
  static String decode(List<int> bytes, {String? contentType, String? hint}) {
    String? charset = hint?.toLowerCase();
    if (charset == null) {
      final ct = contentType?.toLowerCase() ?? '';
      final m = RegExp(r'charset\s*=\s*"?([\w-]+)"?').firstMatch(ct);
      charset = m?.group(1)?.toLowerCase();
    }
    if (charset == null) {
      // 嗅探前 2048 字节的 meta 标签
      final head = String.fromCharCodes(bytes.take(2048));
      final m = RegExp(r'''charset\s*=\s*["']?([\w-]+)''', caseSensitive: false).firstMatch(head);
      charset = m?.group(1)?.toLowerCase();
    }
    if (charset != null && (charset == 'gbk' || charset == 'gb2312' || charset == 'gb18030')) {
      return gbkDecodeSafe(bytes);
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return gbkDecodeSafe(bytes);
    }
  }

  static String gbkDecodeSafe(List<int> bytes) {
    try {
      return gbk.decode(Uint8List.fromList(bytes));
    } catch (_) {
      try {
        return latin1.decode(bytes, allowInvalid: true);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }
}

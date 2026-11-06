import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fast_gbk/fast_gbk.dart';

/// 响应：已按正确字符集解码
class PageResponse {
  final String body;
  final int statusCode;
  final String url;
  PageResponse(this.body, this.statusCode, this.url);
}

/// 非 http/https 的出站地址（书源规则或页面里的链接可能被写成 `file://`、`data:`）
class UnsupportedUrlException implements Exception {
  final String url;
  UnsupportedUrlException(this.url);

  @override
  String toString() {
    final scheme = Uri.tryParse(url.trim())?.scheme;
    return '只支持 http/https 协议，已拒绝：${(scheme == null || scheme.isEmpty) ? url : '$scheme://…'}';
  }
}

/// 出站地址与 header 的同一套判定口径。
/// 请求前（引擎的 headersFor）和重定向逐跳（HttpClient）都必须用它，
/// 否则"入口剥干净、一跳 302 又全带过去"——dart:io 自己只认
/// authorization/www-authenticate/cookie/cookie2 四个名字（http_impl.dart 的 nonRedirectHeaders），
/// 书源常用的 X-Token、sessionId、auth 这类令牌会原样跟着跳去第三方域名。
class UrlPolicy {
  /// 凭证类 header 的名字特征：Cookie/Authorization 之外，
  /// 一批 API 型书源把令牌写成 `X-Token`、`auth`、`sessionId` 之类，名字里都带这些词。
  static final RegExp credentialName =
      RegExp(r'cookie|authorization|token|session|auth|key|secret', caseSensitive: false);

  static bool isCredentialHeader(String name) => credentialName.hasMatch(name);

  static Map<String, String> stripCredentials(Map<String, String> src) {
    final out = Map<String, String>.from(src);
    out.removeWhere((k, _) => isCredentialHeader(k));
    return out;
  }

  /// 两个地址是否同属一个注册域（qidian.com 与 m.qidian.com 算同站，
  /// com.cn / co.jp 这类二级公有后缀多取一段）。任一侧解析不出主机时**不设限**，
  /// 免得把老书源整批判成跨站、连带把 UA/Referer 也丢了。
  static bool sameSite(String aUrl, String bUrl) {
    final a = siteOf(Uri.tryParse(aUrl)?.host ?? '');
    if (a.isEmpty) return true;
    final b = siteOf(Uri.tryParse(bUrl.trim())?.host ?? '');
    if (b.isEmpty) return true;
    return a == b;
  }

  static String siteOf(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty) return '';
    // IP（含 v6）没有注册域概念，整串比
    if (h.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h)) return h;
    final labels = h.split('.');
    if (labels.length <= 2) return h;
    final tail2 = labels.sublist(labels.length - 2).join('.');
    final take = _twoLevelSuffixes.contains(tail2) ? 3 : 2;
    if (labels.length < take) return h;
    return labels.sublist(labels.length - take).join('.');
  }

  /// 常见的二级公有后缀：这些后面那段才是"域名"，多取一级才不会把 a.co.uk 与 b.co.uk 当同站
  static const Set<String> _twoLevelSuffixes = {
    'com.cn', 'net.cn', 'org.cn', 'gov.cn', 'edu.cn', 'ac.cn',
    'com.hk', 'org.hk', 'idv.hk',
    'com.tw', 'org.tw', 'idv.tw',
    'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'go.jp',
    'co.uk', 'org.uk', 'ac.uk', 'me.uk', 'gov.uk',
    'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au',
    'co.nz', 'net.nz', 'org.nz',
    'co.in', 'net.in', 'org.in', 'gen.in',
    'co.kr', 'or.kr', 'ne.kr', 're.kr', 'pe.kr', 'go.kr',
    'com.br', 'net.br', 'org.br',
    'com.sg', 'net.sg', 'org.sg', 'edu.sg', 'gov.sg',
    'com.my', 'net.my', 'org.my', 'edu.my', 'gov.my',
    'co.za', 'org.za', 'net.za', 'web.za',
    'com.ru', 'net.ru', 'org.ru', 'pp.ru',
    'com.ua', 'in.ua', 'kiev.ua',
    'com.tr', 'org.tr', 'net.tr',
    'com.mx', 'org.mx', 'gob.mx',
    'com.ar', 'net.ar',
    'com.pl', 'net.pl', 'org.pl',
    'com.vn', 'net.vn', 'org.vn',
    'com.ph', 'net.ph', 'org.ph',
    'co.il', 'org.il', 'net.il',
    'com.pe', 'net.pe', 'gob.pe',
    'co.id', 'web.id', 'or.id',
  };

  /// 放进错误信息/健康度里给用户看的 URL：**丢掉 query 和 fragment**。
  /// 站点拒绝的往往是带 `?code=`/`?token=` 的跳转目标，这些串会被写进 hive 并显示在书源页。
  /// 相对链接解析用不着 query（RFC 3986 只用 scheme/host/port/path 当基准），
  /// 所以该掩码的地方尽管掩，不影响功能。
  static String displayUrl(String url) {
    final t = url.trim();
    if (t.isEmpty) return t;
    final u = Uri.tryParse(t);
    // `www.a.com:8080/x?k=1` 会被 Uri 当成 scheme=`www.a.com` 的地址（点是合法 scheme
    // 字符），host 为空。这类缺 scheme 的书源写法不是 URL，按 URL 拆会把它绞碎，
    // 而 query 也就无所谓"泄漏"了——它压根没经过网络层。
    if (u == null || !u.hasScheme || u.host.isEmpty) return t;
    final buf = StringBuffer('${u.scheme}://${u.authority}');
    if (u.path.isNotEmpty) buf.write(u.path);
    return buf.toString();
  }
}

class _Cookie {
  final String value;
  final bool secure;
  _Cookie(this.value, {this.secure = false});
}

/// 极简 Cookie 管理（按域名）
class CookieJar {
  final Map<String, Map<String, _Cookie>> _cookies = {};

  /// 主机数上限：一批源里每个站都会落一条，长时间不清理会一直涨。
  /// 与 TOFU 钉证同口径（内存态、进程重启即清），牺牲的是冷启动后的少量重登。
  static const _maxHosts = 500;

  String headerFor(String url) {
    final uri = Uri.tryParse(url);
    final c = _cookies[uri?.host ?? ''];
    if (c == null || c.isEmpty) return '';
    // `Secure` cookie 过明文 http 重放出去等于把令牌裸奔在链路上，服务端也可能因此认不出用户
    final overTls = (uri?.scheme ?? '').toLowerCase() == 'https';
    final parts = <String>[];
    c.forEach((k, v) {
      if (overTls || !v.secure) parts.add('$k=${v.value}');
    });
    return parts.join('; ');
  }

  void storeFrom(String url, List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    final host = Uri.tryParse(url)?.host ?? '';
    if (_cookies.length > _maxHosts && !_cookies.containsKey(host)) {
      _cookies.clear(); // 上限：宁可整体重来，别让内存无界
    }
    final m = _cookies.putIfAbsent(host, () => {});
    for (final sc in setCookies) {
      final parts = sc.split(';');
      final pair = parts.first;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      final attrs = parts.skip(1).join(';').toLowerCase();
      final secure = parts.skip(1).any((a) => a.trim().toLowerCase() == 'secure');
      // Max-Age<=0 / 已过期的 Expires 是"删除此 Cookie"指令，
      // 若当作空值存储会被永久重放
      final maxAge = int.tryParse(RegExp(r'max-age\s*=\s*(-?\d+)').firstMatch(attrs)?.group(1) ?? '');
      var expired = maxAge != null && maxAge <= 0;
      if (!expired) {
        final exp = RegExp(r'expires\s*=\s*([^;]+)').firstMatch(attrs)?.group(1);
        if (exp != null) {
          // 只认 1970 的话，`Expires=Wed, 09 Jun 2021 10:18:14 GMT` 这种早已过期的
          // 会话 Cookie 会被当成永久凭据一直重放
          try {
            expired = io.HttpDate.parse(exp.trim()).isBefore(DateTime.now());
          } catch (_) {
            expired = false; // 日期形态不认识就当作未过期，别把能用的登录态丢了
          }
        }
      }
      if (expired) {
        m.remove(name);
      } else {
        m[name] = _Cookie(value, secure: secure);
      }
    }
  }

  void clear() => _cookies.clear();
}

class HttpClient {
  static final HttpClient instance = HttpClient._();
  late final Dio _dio;
  late final Dio _lenientDio;
  final CookieJar cookies = CookieJar();

  static const defaultUA =
      'Mozilla/5.0 (Linux; Android 14; SM-S9210) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  HttpClient._() {
    final base = BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.bytes,
      // 重定向由我们自己逐跳跟（见 _followHops）。交给 dart:io 跟的话，
      // 它只对 authorization/www-authenticate/cookie/cookie2 四个名字做跨域剥离，
      // 书源常见的 X-Token、sessionId、auth 会跟着一发 302 原样漏给第三方域名。
      followRedirects: false,
      validateStatus: (s) => s != null && s < 500,
    );
    _dio = Dio(base);
    // 不少小说站只下发叶子证书，浏览器靠 AIA 补链而 BoringSSL 直接报
    // CERTIFICATE_VERIFY_FAILED，握手失败时走这条重试通道。
    // 通道内不做无条件放行：按主机 TOFU 钉证，防止中间人攻击。
    _lenientDio = Dio(base)..httpClientAdapter = _lenientAdapter();
    for (final d in [_dio, _lenientDio]) {
      d.transformer = _SizeLimitTransformer();
    }
  }

  HttpClientAdapter _lenientAdapter() => IOHttpClientAdapter(
        createHttpClient: () {
          final client = io.HttpClient(context: io.SecurityContext(withTrustedRoots: true));
          client.badCertificateCallback = _trustOnFirstFail;
          return client;
        },
      );

  /// 测试缝：把两条通道的网络出口换成假的，用来钉住"重定向逐跳带哪些 header、
  /// 每跳的 Cookie 记在哪个主机"这类只有真跑一遍链路才看得见的行为；
  /// 传 null 恢复真实网络。业务代码不要调用。
  void useAdapterForTesting(HttpClientAdapter? adapter) {
    _dio.httpClientAdapter = adapter ?? IOHttpClientAdapter();
    _lenientDio.httpClientAdapter = adapter ?? _lenientAdapter();
  }

  /// 正常页面/书源文件都在百 KB 级，超限只可能是恶意或异常大响应（内存 DoS）
  static const maxResponseBytes = 20 * 1024 * 1024;

  /// 只放行 http/https。书源规则与页面里的链接都是不可信输入，
  /// `file://` / `data:` / `javascript:` 交给 dio 会抛 UnsupportedError
  /// （不属于 DioException，绕过了所有 `on DioException` 分支），协议白名单必须在出口处挡死。
  static void _requireHttpUrl(String url) {
    final t = url.trim();
    final colon = t.indexOf(':');
    // 没有冒号、或冒号前带点/斜杠的（`www.a.com:8080/x` 这种缺 scheme 的写法）都不算协议，
    // 那是书源自己的常见形态，别报成"协议违规"
    if (colon <= 0) return;
    final scheme = t.substring(0, colon).toLowerCase();
    if (scheme.contains('.') || scheme.contains('/')) return;
    if (scheme == 'http' || scheme == 'https') return;
    throw UnsupportedUrlException(t);
  }

  /// header 名按 RFC 7230 的 token 字符集校验，值不许带 CR/LF。
  /// 这是所有出站请求的最后一道闸：名字不合法 dio 会抛（整个源被打死），
  /// 值里塞换行则是请求头注入（能伪造 Host/Connection 之外的任意头）。
  static final RegExp headerNameRe = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

  static Map<String, String> sanitizeHeaders(Map<String, String>? src) {
    if (src == null || src.isEmpty) return <String, String>{};
    final out = Map<String, String>.from(src);
    out.removeWhere((k, v) =>
        k.isEmpty || !headerNameRe.hasMatch(k) || v.contains('\n') || v.contains('\r'));
    return out;
  }

  /// host -> 该主机严格校验失败时见过的证书指纹。
  /// 首次失败无法区分"缺中间证书的破链"与"中间人"，信任并钉住；
  /// 之后同主机只接受已钉证书——攻击者没有服务器私钥，伪造不了同指纹证书。
  /// 钉证窗口内允许记录同一条链上的其余不可信证书，窗口外一律严格。
  /// 仅在内存中生效，进程重启后重新钉证。
  final Map<String, _TofuPins> _tofuPins = {};

  /// 钉证过期重钉窗口：CDN 站点可能在一日内多次轮换叶子证书，
  /// 永久拒新证会让书源直到进程重启前都不可用；
  /// 超过窗口允许一次基于失败握手的重钉（重新 TOFU）。
  static const _rePinAfter = Duration(hours: 8);

  bool _trustOnFirstFail(io.X509Certificate cert, String host, int port) {
    final fp = crypto.sha256.convert(cert.der).toString();
    final now = DateTime.now();
    final pins = _tofuPins[host];
    if (pins == null) {
      if (_tofuPins.length > 500) _tofuPins.clear();
      _tofuPins[host] = _TofuPins({fp}, now);
      return true;
    }
    if (pins.fingerprints.contains(fp)) return true;
    if (now.difference(pins.firstSeen) > _rePinAfter) {
      _tofuPins[host] = _TofuPins({fp}, now); // 过期重钉：整组指纹换新，重新开窗口
      return true;
    }
    if (now.difference(pins.firstSeen).inSeconds <= 10 && pins.fingerprints.length <= 8) {
      pins.fingerprints.add(fp);
      return true;
    }
    return false;
  }

  static bool _isCertFailure(DioException e) {
    if (e.error is io.HandshakeException) return true;
    final err = e.error?.toString() ?? '';
    return e.type == DioExceptionType.connectionError &&
        err.contains('CERTIFICATE_VERIFY_FAILED');
  }

  /// 证书破链主机（已有 TOFU 钉证记录）直接走宽松通道，
  /// 避免每个请求都先严格失败再重发（双重 TLS 握手、POST 重放）。
  /// 握手期失败意味着请求从未送达服务端，降级重放是安全的。
  Future<Response<List<int>>> _execute(
      String url, Future<Response<List<int>>> Function(Dio dio) send) async {
    final host = Uri.tryParse(url)?.host ?? '';
    final pinned = _tofuPins.containsKey(host);
    try {
      return await send(pinned ? _lenientDio : _dio);
    } on DioException catch (e) {
      if (_isCertFailure(e) && !pinned) return await send(_lenientDio);
      rethrow;
    }
  }

  /// 跟随重定向的跳数上限，与交给 dart:io 时的 maxRedirects 同量。
  static const maxRedirectHops = 10;

  /// 3xx 的下一跳。不是重定向状态码、没有 Location、或 Location 解析不出来时返回 null
  /// （把当前响应原样交回调用方，跟浏览器"当普通响应处理"一致）。
  /// 目标协议不是 http(s) 时抛 [UnsupportedUrlException]：协议白名单是出口闸，
  /// 不能因为"这跳是站点让我跳的"就绕过去。
  static String? redirectTarget(Response<List<int>> resp, String fromUrl) {
    final code = resp.statusCode ?? 0;
    if (code != 301 && code != 302 && code != 303 && code != 307 && code != 308) return null;
    final loc = resp.headers.value('location')?.trim();
    if (loc == null || loc.isEmpty) return null;
    final Uri target;
    try {
      target = Uri.parse(fromUrl).resolve(loc);
    } catch (_) {
      return null;
    }
    if (target.scheme != 'http' && target.scheme != 'https') {
      throw UnsupportedUrlException(target.toString());
    }
    return target.toString();
  }

  /// 第 `hopUrl` 这一跳实际能带的 header。
  /// 起点与它不同注册域时凭证类名字一律剥掉——入口 `headersFor` 做的那一刀必须对每一跳都成立；
  /// 再补上该主机自己在 jar 里的 Cookie（浏览器也是这么做的，dart:io 跟随时不会问我们的 jar）。
  Map<String, String> _headersForHop(String originUrl, String hopUrl, Map<String, String> base) {
    if (UrlPolicy.sameSite(originUrl, hopUrl)) return Map<String, String>.from(base);
    final out = UrlPolicy.stripCredentials(base);
    final jarCookie = cookies.headerFor(hopUrl);
    if (jarCookie.isNotEmpty) out['Cookie'] = jarCookie;
    return out;
  }

  Future<Response<List<int>>> _sendHop(
    String url,
    String method,
    Object? body,
    Map<String, String> headers,
  ) {
    final out = Map<String, String>.from(headers);
    // Content-Type 是发给上一跳的请求体说明，改成 GET 后留着只会让某些站按 POST 处理
    if (method != 'POST') out.remove('Content-Type');
    final options = Options(
        headers: sanitizeHeaders(out)..removeWhere((k, v) => v.isEmpty));
    return _execute(url, (d) => method == 'POST'
        ? d.post(url, data: body, options: options)
        : d.get(url, options: options));
  }

  /// 返回 [(最后一跳的响应, 该跳的 URL)]。每一跳的 Set-Cookie 各归各的主机，
  /// 不会像自动跟随那样把中途的 Cookie 记到终点域名头上。
  Future<(Response<List<int>>, String)> _followHops(
      String url, String method, Object? body, Map<String, String> base) async {
    var current = url;
    var verb = method;
    var payload = body;
    Response<List<int>> resp = await _sendHop(current, verb, payload, _headersForHop(url, current, base));
    for (var hop = 0;; hop++) {
      cookies.storeFrom(current, resp.headers['set-cookie']);
      final next = redirectTarget(resp, current);
      if (next == null || next == current || hop >= maxRedirectHops) break;
      current = next;
      final code = resp.statusCode ?? 0;
      // 301/302/303 换方法（与 dart:io、浏览器一致），307/308 原样重发
      if (verb == 'POST' && code != 307 && code != 308) {
        verb = 'GET';
        payload = null;
      }
      resp = await _sendHop(current, verb, payload, _headersForHop(url, current, base));
    }
    return (resp, current);
  }

  Future<PageResponse> _follow(String url, String method,
      {Map<String, String>? headers, Object? body, String? charsetHint}) async {
    _requireHttpUrl(url);
    // Cookie 位先给该主机 jar 里的值，书源 header 显式写了 cookie 时以它为准（沿用原优先级）
    final base = <String, String>{'Cookie': cookies.headerFor(url), ...?headers};
    try {
      final (resp, finalUrl) = await _followHops(url, method, body, base);
      return PageResponse(
        decode(resp.data ?? const <int>[],
            contentType: resp.headers.value(Headers.contentTypeHeader), hint: charsetHint),
        resp.statusCode ?? 0,
        finalUrl,
      );
    } on DioException catch (e) {
      final r = e.response;
      if (r != null && r.data is List<int>) {
        // 4xx/5xx 页面同样要按最终 URL 记 Cookie、解相对链接基准
        final u = r.requestOptions.uri.toString();
        cookies.storeFrom(u, r.headers['set-cookie']);
        return PageResponse(
            decode(r.data as List<int>,
                contentType: r.headers.value(Headers.contentTypeHeader), hint: charsetHint),
            r.statusCode ?? 0,
            u);
      }
      rethrow;
    }
  }

  Future<PageResponse> get(String url, {Map<String, String>? headers, String? charsetHint}) =>
      _follow(url, 'GET',
          charsetHint: charsetHint,
          headers: {
            'User-Agent': defaultUA,
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            ...?headers,
          });

  Future<PageResponse> post(String url,
          {Object? body,
          Map<String, String>? headers,
          String? contentType,
          String? charsetHint}) =>
      _follow(url, 'POST',
          charsetHint: charsetHint,
          body: body,
          headers: {
            'User-Agent': defaultUA,
            // 空串会在下面的 removeWhere 里丢掉，等于不发这个头，交给 dio 按数据类型推
            'Content-Type': contentType ?? '',
            ...?headers,
          });

  /// 字节 → 字符串：Content-Type / meta charset / BOM / UTF-8 失败回退 GBK
  static String decode(List<int> bytes, {String? contentType, String? hint}) {
    // 规则提取失败时常传入空串占位，此时必须回退 Content-Type/meta 嗅探
    String? charset = (hint == null || hint.trim().isEmpty) ? null : hint.trim().toLowerCase();
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

  /// 表单字符串按 GBK 编码为请求体字节
  static List<int> gbkEncode(String s) {
    try {
      return gbk.encode(s);
    } catch (_) {
      return utf8.encode(s);
    }
  }
}

class _TofuPins {
  final Set<String> fingerprints;
  final DateTime firstSeen;
  _TofuPins(this.fingerprints, this.firstSeen);
}

/// 流式限长下载：content-length 声明超限直接掐断；
/// 分块/谎报长度时在累计字节超限的瞬间抛错断流，所有响应类型（文本/JSON/字节）统一生效
class _SizeLimitTransformer extends BackgroundTransformer {
  @override
  Future transformResponse(RequestOptions options, ResponseBody responseBody) async {
    final cl = responseBody.headers[Headers.contentLengthHeader];
    final declared = (cl != null && cl.isNotEmpty) ? int.tryParse(cl.first) ?? 0 : 0;
    if (declared > HttpClient.maxResponseBytes) {
      await responseBody.stream.listen((_) {}).cancel(); // 取消订阅即断开连接
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
        error: Exception('响应体过大（${declared >> 20}MB），已中止下载'),
      );
    }
    var total = 0;
    responseBody.stream = responseBody.stream.map((chunk) {
      total += chunk.length;
      if (total > HttpClient.maxResponseBytes) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
          error: Exception('响应体超过 ${HttpClient.maxResponseBytes >> 20}MB 上限'),
        );
      }
      return chunk;
    });
    return super.transformResponse(options, responseBody);
  }
}

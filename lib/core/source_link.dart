/// 用户在「从 URL 导入」里粘的东西往往不是一条裸链接：微信/群公告带的分享文案、
/// 缺 scheme 的域名、Legado 的 `legado://import/bookSource?url=...` 深链，
/// 甚至直接粘了书源 JSON 正文。这里把它们还原成"该抓哪个链接"或"这就是正文"。
class PastedSource {
  /// 需要去抓取的 http/https 链接；没有则 null
  final String? url;

  /// 粘进来的其实就是书源正文
  final String? inlineBody;

  const PastedSource({this.url, this.inlineBody});

  bool get isEmpty => url == null && inlineBody == null;
}

/// URL 里不可能合法出现的分隔字符：空白、尖括号、引号、中文标点。
/// 分享文案的链接后面常紧跟着 `，快导入` 这样的尾巴，光靠结尾裁剪不够，
/// 匹配阶段就得停下来（`,` `;` `:` 是合法 URL 字符，不放在这里）。
/// 引号写成 `\x22`/`\x27`：raw 字符串里 `\'` 不转义，直接放引号会把字符串截断。
const String _urlStops = r'\s<>\x22\x27｜，。；：、！？）】》（【《“”‘’';

/// 一条 http(s) 链接
final RegExp _urlRe = RegExp('https?://[^$_urlStops]+', caseSensitive: false);

/// 结尾的英文标点挡不住：`.` `:` `?` `/` 本身是 URL 字符，
/// `https://a.com/x.json.` 只能匹配完再把多余的那一下裁掉。
const String _trailingJunk = '.,;:!?、。，；：！？)）]】》>"\'';

/// 深链里可能藏链接的参数名
final RegExp _linkParamKeyRe = RegExp(r'^(url|src|bookSourceUrl|importUrl)$', caseSensitive: false);

/// 形如 `pv510kv.cn/book.json` / `example.com:8080/a?x=1` 的缺 scheme 域名。
/// 前缀写成 `(?:^|[^A-Za-z0-9._%-])` 是为了既能整段就是域名，也能从
/// `书源：pv510kv.cn/x.json` 这种被中文标签粘住的文案里摘出域名——
/// 而 `v1.25beta` 这类片段因为前一个字符是字母/数字/点而不会被当域名。
final RegExp _bareHostRe = RegExp('(?:^|[^A-Za-z0-9._%-])'
    '([A-Za-z0-9][-A-Za-z0-9.]*\\.[A-Za-z]{2,12}(?::\\d{1,5})?(?:/[^$_urlStops]*)?)');

PastedSource parsePastedSource(String text) {
  final t = text.trim();
  if (t.isEmpty) return const PastedSource();

  // 直接粘了正文：`[` / `{` 起手不可能是链接，交给导入侧的宽容解码去判
  if (t.startsWith('[') || t.startsWith('{')) return PastedSource(inlineBody: t);

  final head = _firstToken(t);
  // Legado 等客户端的导入深链：真正的链接藏在 url= 参数里（多半还是编码过的）
  final scheme = Uri.tryParse(head)?.scheme ?? '';
  if (scheme.isNotEmpty && scheme != 'http' && scheme != 'https') {
    final inner = _urlParam(t);
    if (inner != null) return PastedSource(url: _trimTail(inner));
    // 参数里没翻到链接也继续往下找：文案里可能另写了一条 http 链接
  }

  final embedded = _urlRe.firstMatch(t)?.group(0);
  if (embedded != null) return PastedSource(url: _trimTail(embedded));

  final host = _bareHostRe.firstMatch(t)?.group(1);
  if (host != null) return PastedSource(url: _trimTail('https://$host'));
  return const PastedSource();
}

/// 第一个空白之前的片段。粘贴框里也可能塞了几 MB 文本，
/// 所以只截取需要的这一段，不用 split 把整份都切成列表。
String _firstToken(String t) {
  final ws = t.indexOf(RegExp(r'\s'));
  return ws < 0 ? t : t.substring(0, ws);
}

String? _urlParam(String text) {
  final q = text.indexOf('?');
  if (q < 0) return _urlRe.firstMatch(text)?.group(0);
  for (final part in text.substring(q + 1).split(RegExp(r'[&]'))) {
    final kv = part.split('=');
    if (kv.length < 2) continue;
    if (!_linkParamKeyRe.hasMatch(kv.first.trim())) continue;
    final raw = kv.sublist(1).join('=');
    final decoded = Uri.decodeComponent(raw.replaceAll('+', ' ')).trim();
    final hit = _urlRe.firstMatch(decoded)?.group(0) ?? (decoded.startsWith('http') ? decoded : null);
    if (hit != null) return _trimTail(hit);
  }
  return _urlRe.firstMatch(text)?.group(0);
}

String _trimTail(String url) {
  var end = url.length;
  while (end > 0 && _trailingJunk.contains(url[end - 1])) {
    end--;
  }
  // 括号成对时结尾的 `)` 属于文案：`(https://a/x.json)`
  if (end > 0 && url[end - 1] == '(') end--;
  return url.substring(0, end);
}

import 'package:flutter_test/flutter_test.dart';

import 'package:xunyuan/core/source_link.dart';

void main() {
  group('从 URL 导入识别粘贴内容', () {
    test('裸链接原样拿走，http 不会被升级成 https', () {
      expect(parsePastedSource('https://pv510kv.cn/bookSource.json').url,
          'https://pv510kv.cn/bookSource.json');
      expect(parsePastedSource('http://a.com/x.json').url, 'http://a.com/x.json');
      expect(parsePastedSource('  https://a.com/x.json  \n').url, 'https://a.com/x.json');
    });

    test('分享文案里的链接能摘出来', () {
      expect(
          parsePastedSource('【书源分享】酷我小说 https://pv510kv.cn/bookSource.json 复制到浏览器打开')
              .url,
          'https://pv510kv.cn/bookSource.json');
      // 链接被尖括号/引号包住时不能把符号算进去
      expect(parsePastedSource('链接 "<https://a.com/x.json>"').url, 'https://a.com/x.json');
      // 括号成对时结尾的 ) 属于文案
      expect(parsePastedSource('(https://a.com/x.json)').url, 'https://a.com/x.json');
    });

    test('结尾的中英文标点不是链接的一部分', () {
      expect(parsePastedSource('https://a.com/x.json。').url, 'https://a.com/x.json');
      expect(parsePastedSource('https://a.com/x.json，快导入').url, 'https://a.com/x.json');
      // 多点一下也不能把 .json 吃掉
      expect(parsePastedSource('https://a.com/x.json.').url, 'https://a.com/x.json');
      // 真正以斜杠结尾的路径要留着
      expect(parsePastedSource('https://a.com/source/').url, 'https://a.com/source/');
    });

    test('缺 scheme 的域名补 https，被中文标签粘住也能摘出来', () {
      expect(parsePastedSource('pv510kv.cn/bookSource.json').url,
          'https://pv510kv.cn/bookSource.json');
      expect(parsePastedSource('example.com:8080/a?x=1').url, 'https://example.com:8080/a?x=1');
      expect(parsePastedSource('书源：pv510kv.cn/x.json').url, 'https://pv510kv.cn/x.json');
      // 文案里先写别的话，后面才是域名
      expect(parsePastedSource('自用书源 pv510kv.cn/x.json 长期更新').url,
          'https://pv510kv.cn/x.json');
    });

    test('Legado 导入深链取 url= 参数，编码与未编码都要还原', () {
      expect(
          parsePastedSource('legado://import/bookSource?url=https://a.com/x.json').url,
          'https://a.com/x.json');
      expect(
          parsePastedSource('legado://import/bookSource?url=https%3A%2F%2Fa.com%2Fx.json')
              .url,
          'https://a.com/x.json');
      // 参数值本身带查询串，编码后仍是一条完整链接
      expect(
          parsePastedSource('legado://import?src=https%3A%2F%2Fa.com%2Fx.json%3Fu%3D1').url,
          'https://a.com/x.json?u=1');
      // 深链里没翻出 http 链接时，退回去看文案中另写的链接
      expect(
          parsePastedSource('legado://import 备用地址 https://a.com/x.json').url,
          'https://a.com/x.json');
    });

    test('直接粘书源正文：不当链接，交正文通道', () {
      final list = parsePastedSource('[{"bookSourceUrl":"https://a.com","bookSourceName":"a"}]');
      expect(list.url, isNull);
      expect(list.inlineBody, startsWith('[{'));
      final obj = parsePastedSource('{"bookSourceUrl":"https://a.com"}');
      expect(obj.url, isNull);
      expect(obj.inlineBody, '{"bookSourceUrl":"https://a.com"}');
    });

    test('认不出来就是认不出来，不硬编一条链接去请求', () {
      expect(parsePastedSource('').isEmpty, true);
      expect(parsePastedSource('   \n ').isEmpty, true);
      expect(parsePastedSource('随便写点什么').isEmpty, true);
      expect(parsePastedSource('bookSourceUrl').isEmpty, true);
      // 版本号不是域名
      expect(parsePastedSource('当前版本 v1.25beta').isEmpty, true);
    });
  });
}

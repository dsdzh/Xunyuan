import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/crypto/crc32.dart';

/// 按 [4B 小端帧长][键值体][4B CRC32] 走出帧边界
List<List<int>> frameSpans(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final out = <List<int>>[];
  var off = 0;
  while (off + 8 <= bytes.length) {
    final len = view.getUint32(off, Endian.little);
    if (len < 8 || off + len > bytes.length) break;
    out.add([off, len]);
    off += len;
  }
  return out;
}

/// 把某个字符串值的 typeId 改成未注册的值，并重算该帧 CRC ——
/// 得到一个"CRC 合法但解码必炸"的帧，即用户手机上 unknown typeId 的形态。
/// hive 写字符串值的布局是 [0x04][4B 小端字节数][utf8]
Uint8List forgeUnknownTypeId(Uint8List src, String value, {int fakeTypeId = 46}) {
  final bytes = Uint8List.fromList(src);
  final view = ByteData.sublistView(bytes);
  final content = utf8.encode(value);
  var hit = -1;
  for (var i = 0; i + 5 + content.length <= bytes.length; i++) {
    if (bytes[i] != 4 || view.getUint32(i + 1, Endian.little) != content.length) continue;
    if (_bytesEqual(bytes, i + 5, content)) {
      hit = i;
      break;
    }
  }
  expect(hit, greaterThanOrEqualTo(0), reason: '没找到该值的帧体位置');
  bytes[hit] = fakeTypeId;
  final span = frameSpans(bytes).firstWhere((s) => s[0] <= hit && hit < s[0] + s[1]);
  view.setUint32(
    span[0] + span[1] - 4,
    Crc32.compute(bytes, offset: span[0], length: span[1] - 4),
    Endian.little,
  );
  return bytes;
}

bool _bytesEqual(Uint8List a, int offset, List<int> b) {
  for (var i = 0; i < b.length; i++) {
    if (a[offset + i] != b[i]) return false;
  }
  return true;
}

/// 按 hive 写帧的原始布局手工拼一帧，保留它的键长截断行为：
/// `writeByte(utf8 键长)` 只占一个字节，超过 255 就 mod 256。
/// CRC 仍然合法 —— 这正是 release 构建下超长键把整盒写坏、
/// 下次启动报 unknown typeId 的过程（debug 下会被 Frame.assertKey 拦住）。
Uint8List forgeFrame(String key, String value, {int? fakeKeyLengthByte}) {
  final keyBytes = utf8.encode(key);
  final valueBytes = utf8.encode(value);
  final body = BytesBuilder();
  body.addByte(1); // FrameKeyType.utf8StringT
  body.addByte((fakeKeyLengthByte ?? keyBytes.length) & 0xff);
  body.add(keyBytes);
  body.addByte(4); // FrameValueType.stringT
  body.add((ByteData(4)..setUint32(0, valueBytes.length, Endian.little)).buffer.asUint8List());
  body.add(valueBytes);
  final frame = Uint8List(8 + body.length);
  final view = ByteData.sublistView(frame);
  view.setUint32(0, frame.length, Endian.little);
  frame.setRange(4, 4 + body.length, body.toBytes());
  view.setUint32(
    frame.length - 4,
    Crc32.compute(frame, offset: 0, length: frame.length - 4),
    Endian.little,
  );
  return frame;
}

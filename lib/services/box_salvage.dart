import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hive_ce_flutter/hive_flutter.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/crypto/crc32.dart';

/// 打开结果。[note] 为 null 表示文件完好、一次打开成功，什么都没动。
class BoxRestore<T> {
  BoxRestore(this.box, this.note);
  final Box<T> box;
  final String? note;
}

/// 打开盒文件。文件读不出来时不再让整 App 停在"启动失败"页：
/// 坏文件改名留档，建新盒并写回还能按帧读出的条目，返回给用户的一句话说明。
/// [salvage] 为 false 时不抢救内容（章节缓存这类可重新获取的盒）。
/// [keySanitizer] 用来把抢救出来的键压成安全形态（超长键写回去会再次写坏文件）。
Future<BoxRestore<T>> openBoxWithRecovery<T>(
  String name,
  String label, {
  required String path,
  bool salvage = true,
  String Function(String key)? keySanitizer,
}) async {
  try {
    return BoxRestore<T>(await Hive.openBox<T>(name, path: path), null);
  } catch (_) {
    final got = salvage ? await _salvage<T>(name, path) : null;
    // 只有自己的逐帧扫描也认定文件坏了才动它；扫描干净却打不开，说明是
    // 文件锁/权限这类外部原因，改名重建反而会把好数据搬走 —— 宁可抛出让用户重试。
    // repaired 也要算：能修好超长键说明文件内容确实坏过，只是坏得能被我们读回来
    if (got == null || got.dropped > 0 || got.repaired > 0) {
      final restored =
          _sanitizeKeys<T>(got?.entries ?? const <dynamic, dynamic>{}, keySanitizer);
      await _quarantine(name, path);
      final box = await Hive.openBox<T>(name, path: path);
      if (restored.isNotEmpty) await box.putAll(restored);
      return BoxRestore<T>(
        box,
        _note(label, salvage, restored.length, got?.dropped ?? 0, got?.unreadTail ?? 0),
      );
    }
    rethrow;
  }
}

Map<String, T> _sanitizeKeys<T>(Map<dynamic, dynamic> entries, String Function(String)? fn) {
  final out = <String, T>{};
  for (final e in entries.entries) {
    if (e.key is! String || e.value is! T) continue;
    out[fn == null ? e.key as String : fn(e.key as String)] = e.value as T;
  }
  return out;
}

String _note(String label, bool salvage, int restored, int dropped, int unreadTail) {
  final lost = <String>[
    if (dropped > 0) '丢弃 $dropped 条',
    if (unreadTail > 0) '尾部内容无法辨认',
  ];
  if (!salvage) return '$label已重建（内容可重新获取）';
  if (restored == 0) {
    return '本地$label数据文件损坏，未能恢复任何条目${lost.isEmpty ? '' : '（${lost.join('、')}）'}，'
        '原文件已留档在应用数据目录';
  }
  return '本地$label数据文件损坏，已恢复 $restored 条'
      '${lost.isEmpty ? '' : '，${lost.join('、')}'}，原文件已留档在应用数据目录';
}

Future<({Map<String, T> entries, int dropped, int repaired, int unreadTail})> _salvage<T>(
    String name, String path) async {
  try {
    final bytes = await File('$path/$name.hive').readAsBytes();
    final scan = salvageFrames(bytes);
    final out = <String, T>{};
    for (final e in scan.entries.entries) {
      if (e.key is String && e.value is T) out[e.key as String] = e.value as T;
    }
    return (
      entries: out,
      dropped: scan.dropped,
      repaired: scan.repaired,
      unreadTail: scan.unreadTail
    );
  } catch (_) {
    return (entries: <String, T>{}, dropped: 0, repaired: 0, unreadTail: 0);
  }
}

/// 坏文件改名留档而不是删除：万一以后要人工捞数据，它是唯一凭据
Future<void> _quarantine(String name, String path) async {
  try {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('$path/$name.hive');
    if (await file.exists()) await file.rename('$path/$name.hive.broken-$stamp');
    final lock = File('$path/$name.hive.lock');
    if (await lock.exists()) await lock.delete();
  } catch (_) {}
}

/// 坏盒文件的逐帧抢救结果。
class SalvageResult {
  SalvageResult(this.entries, this.dropped, this.unreadTail, {this.repaired = 0});

  /// 还能读出来的条目（同键后写覆盖先写，与 hive 语义一致）
  final Map<dynamic, dynamic> entries;

  /// 丢掉的坏帧 / 坏区段数
  final int dropped;

  /// 按"键长被截断"还原回来的条目数
  final int repaired;

  /// 因尾部不可信而放弃的字节数，0 表示整个文件走完了
  final int unreadTail;
}

/// hive 的 openBox 会把整盒帧一次性解码，任意一个坏帧就抛异常且拿不到盒对象，
/// 用户表现为"启动失败、只能清除全部数据"。这里绕过它自己走帧链表，只丢真正
/// 坏死的那几条。
///
/// 盒文件就是一串帧的追加写：`[4B 小端帧长][键值体][4B CRC32]`，帧长含自身与
/// CRC，CRC 覆盖"帧长 + 键值体"（即除最后 4 字节外的全部）。
/// 帧完整但值解码失败（未知 typeId 这类）只丢这一条；长度或 CRC 不可信时向后
/// 重找下一个可信帧头 —— JSON 文本里的随机 4 字节要同时满足"长度自洽 + CRC
/// 相符"的概率约 2^-32，重定位既便宜又可靠。
///
/// 依赖 hive_ce 内部实现（帧格式与 reader），升级 hive 版本时需复核本文件。
SalvageResult salvageFrames(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final entries = <dynamic, dynamic>{};
  var off = 0, dropped = 0, repaired = 0;

  while (off + 8 <= bytes.length) {
    final len = _trustedFrameLen(view, bytes, off);
    if (len == null) {
      // 当前帧不可信。往后找下一个可信帧头
      final next = _nextTrustedFrame(view, bytes, off + 1);
      dropped++;
      if (next < 0) break;
      off = next;
      continue;
    }
    final end = off + len;
    final body = bytes.sublist(off, end);
    try {
      // 每帧单独建 reader：解码中途抛异常时 reader 内部的可用区间已被破坏，
      // 复用它会连累后面本来完好的帧
      final frame = BinaryReaderImpl(body, Hive).readFrame();
      if (frame == null) {
        dropped++;
        break;
      }
      if (frame.deleted) {
        entries.remove(frame.key);
      } else {
        entries[frame.key] = frame.value;
      }
    } catch (_) {
      // 帧长与 CRC 都可信，只有解码抛异常 —— 先试已知成因（超长键长度被截断），
      // 修不回来才丢这一条并继续走后面的帧。键值体是去掉帧长与 CRC 的中间段
      final fixed = _repairKeyLength(body.sublist(4, body.length - 4));
      if (fixed == null) {
        dropped++;
      } else {
        repaired++;
        if (fixed.deleted) {
          entries.remove(fixed.key);
        } else {
          entries[fixed.key] = fixed.value;
        }
      }
    }
    off = end;
  }
  return SalvageResult(entries, dropped, bytes.length - off, repaired: repaired);
}

/// 修复出来的条目（不用 hive 的 Frame：它的构造断言拒收 >255 的字符串键，
/// 而这里要拿到的正是这种键）
class _Entry {
  _Entry(this.key, this.value, {this.deleted = false});
  final dynamic key;
  final dynamic value;
  final bool deleted;
}

/// CRC 完好但解码抛异常时，先按"字符串键长度被截断"这一已知成因还原：
/// hive 用一个字节写键的 utf8 长度，超过 255 就写成 mod 256，于是真实键长
/// ≡ 该字节 (mod 256)。按此枚举候选长度，只接受能把剩余字节整段解成一次
/// 取值的候选；有歧义（多个候选都成立）就放弃，宁缺毋滥。
_Entry? _repairKeyLength(Uint8List body) {
  if (body.length < 3 || body[0] != 1) return null;
  final lenByte = body[1];
  _Entry? found;
  var hits = 0;
  for (var real = lenByte + 256; real + 2 <= body.length; real += 256) {
    final e = _tryDecodeAt(body, real);
    if (e == null) continue;
    hits++;
    found = e;
    if (hits > 1) return null;
  }
  return found;
}

_Entry? _tryDecodeAt(Uint8List body, int keyByteLen) {
  try {
    final r = BinaryReaderImpl(body, Hive);
    r.readByte(); // 键类型
    r.readByte(); // 写坏的键长
    final key = utf8.decode(r.viewBytes(keyByteLen));
    if (keyByteLen + 2 == body.length) return _Entry(key, null, deleted: true);
    final value = r.read();
    if (r.availableBytes != 0) return null; // 值没吃掉全部剩余字节 → 猜错
    return _Entry(key, value);
  } catch (_) {
    return null;
  }
}

/// 可信帧头：长度自洽且 CRC 相符；否则返回 null
int? _trustedFrameLen(ByteData view, Uint8List bytes, int off) {
  if (off + 8 > bytes.length) return null;
  final len = view.getUint32(off, Endian.little);
  if (len < 8 || off + len > bytes.length) return null;
  final storedCrc = view.getUint32(off + len - 4, Endian.little);
  if (storedCrc != Crc32.compute(bytes, offset: off, length: len - 4)) return null;
  return len;
}

int _nextTrustedFrame(ByteData view, Uint8List bytes, int from) {
  for (var off = from; off + 8 <= bytes.length; off++) {
    if (_trustedFrameLen(view, bytes, off) != null) return off;
  }
  return -1;
}

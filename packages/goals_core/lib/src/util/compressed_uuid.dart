import 'dart:convert' show base64Url, base64UrlEncode;
import 'dart:math' show Random, pow;
import 'dart:typed_data' show Uint8List;

import 'package:uuid/uuid.dart';

final BigInt _UUID_MASK =
    BigInt.parse("000000000000F000C000000000000000", radix: 16);
final BigInt _UUID_V4_VALUE =
    BigInt.parse("00000000000040008000000000000000", radix: 16);
final BigInt _UUID_V5_VALUE =
    BigInt.parse("00000000000050008000000000000000", radix: 16);

enum EncodedCupidFormat {
  uuid,
  base64Url,
}

// stands for Compressed Universal Parseable IDentifier
class Cupid {
  static var defaultEncodingFormat = EncodedCupidFormat.base64Url;
  final BigInt value;

  static final _rnd = Random();

  Cupid(String uuid)
      : value = BigInt.parse(uuid.replaceAll('-', ''), radix: 16);

  Uint8List _toBytes() {
    final int bytesLength =
        value.bitLength ~/ 8 + (value.bitLength % 8 != 0 ? 1 : 0);
    final bytes = Uint8List(bytesLength);
    for (int i = 0; i < bytesLength; i++) {
      bytes[i] = (value >> (i * 8) & BigInt.from(0xFF)).toInt();
    }
    return bytes;
  }

  const Cupid.fromBigInt(this.value);

  static Cupid _fromBytes(Uint8List bytes) {
    var value = BigInt.from(0);
    for (int i = 0; i < bytes.length; i++) {
      value |= BigInt.from(bytes[i]) << (i * 8);
    }

    final maskedValue = value & _UUID_MASK;
    if (maskedValue != _UUID_V4_VALUE && maskedValue != _UUID_V5_VALUE) {
      print('Invalid UUID bytes: $bytes, maskedValue: $maskedValue');
      throw Exception('Invalid UUID bytes: $bytes, maskedValue: $maskedValue');
    }

    return Cupid.fromBigInt(value);
  }

  static String toNewId(String id) {
    // typical case, this is an old UUID
    if (Uuid.isValidUUID(fromString: id)) {
      return Cupid(id).encode();
    }

    // this should never happen, but if we see an id
    // that is already a valid compressed uuid, just return it
    try {
      Cupid.decode(id);
      return id;
    } catch (e) {
      // continue
    }

    // fallback case, this is some unknown format so we
    // just generate a new deterministic UUID based on the id
    return Cupid(Uuid().v5(Namespace.url.value, id)).encode();
  }

  static Cupid random() {
    final b = Uint8List(10);

    for (var i = 0; i < 10; i += 4) {
      var k = _rnd.nextInt(pow(2, 32).toInt());
      b[i] = k;
      b[i + 1] = k >> 8;
      if (i + 2 < 10) {
        b[i + 2] = k >> 16;
      }
      if (i + 3 < 10) {
        b[i + 3] = k >> 24;
      }
    }

    // set the version and variant bits for UUID v4
    b[9] = (b[9] & 0x0f) | 0x40;
    b[7] = (b[7] & 0x3f) | 0x80;

    return Cupid._fromBytes(b);
  }

  static Cupid decode(String compressedUuid) {
    if (Uuid.isValidUUID(fromString: compressedUuid)) {
      return Cupid(compressedUuid);
    }

    final paddedLength = (compressedUuid.length + 3) ~/ 4 * 4;

    compressedUuid = compressedUuid.padRight(paddedLength, '=');
    // Decode the compressed UUID
    final bytes = base64Url.decode(compressedUuid);
    return Cupid._fromBytes(bytes);
  }

  String encode({EncodedCupidFormat? format}) {
    format ??= defaultEncodingFormat;

    if (format == EncodedCupidFormat.uuid) {
      return toUuid();
    }
    return base64UrlEncode(_toBytes()).replaceAll('=', '');
  }

  String toUuid() {
    String hex = value.toRadixString(16).padLeft(32, '0');
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

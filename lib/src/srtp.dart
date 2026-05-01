import 'dart:typed_data';
// import 'dart:math';
import 'package:pointycastle/export.dart';
import 'package:crypto/crypto.dart';

import 'rtp.dart';

const int AUTH_TAG_LEN = 10;
const int SESSION_KEY_LEN = 16;
const int SESSION_SALT_LEN = 14;
const int AUTH_KEY_LEN = 20;

Uint8List aesCtrEncrypt(Uint8List key, Uint8List iv, Uint8List data) {
  final cipher = StreamCipher('AES/CTR')
    ..init(true, ParametersWithIV(KeyParameter(key), iv));

  final out = Uint8List(data.length);
  cipher.processBytes(data, 0, data.length, out, 0);

  return out;
}

bool constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;

  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }

  return diff == 0;
}

int rtpHeaderLength(Buffer buf) {
  final cc = buf[0] & 0x0F;
  final hasExt = (buf[0] & 0x10) != 0;

  int len = 12 + cc * 4;

  if (hasExt && len + 4 <= buf.length) {
    final extLen = buf.readUInt16BE(len + 2);
    len += 4 + extLen * 4;
  }

  return len;
}

class SrtpSession {
  late Uint8List _rtpKey;
  late Uint8List _rtpSalt;
  late Uint8List _rtpAuth;

  final Map<int, _RocState> _rocMap = {};

  SrtpSession({required Uint8List masterKey, required Uint8List masterSalt}) {
    _rtpKey = _deriveKey(masterKey, masterSalt, 0, 16);
    _rtpSalt = _deriveKey(masterKey, masterSalt, 2, 14);
    _rtpAuth = _deriveKey(masterKey, masterSalt, 1, 20);
  }

  Buffer? encryptRtp(Buffer pkt) {
    if (pkt.length < 12) return null;

    final seq = pkt.readUInt16BE(2);
    final ssrc = pkt.readUInt32BE(8);

    final state = _rocMap.putIfAbsent(
      ssrc,
      () => _RocState(roc: 0, lastSeq: seq),
    );

    if (seq < 0x8000 && state.lastSeq > 0xC000) {
      state.roc++;
    }

    state.lastSeq = seq;

    final index = (state.roc << 16) | seq;

    final headerLen = rtpHeaderLength(pkt);
    final payload = pkt.subarray(headerLen);

    final iv = _buildIv(ssrc, index);

    final encPayload = aesCtrEncrypt(_rtpKey, iv, payload);

    final out = Buffer.allocUnsafe(pkt.length + AUTH_TAG_LEN);

    pkt.copy(out, 0, 0, headerLen);
    out.setRange(headerLen, headerLen + encPayload.length, encPayload);

    final authData = out.subarray(0, pkt.length);

    final mac = Hmac(
      sha1,
      _rtpAuth,
    ).convert(authData + _uint32ToBytes(state.roc));

    final tag = Uint8List.fromList(mac.bytes.sublist(0, AUTH_TAG_LEN));

    out.setRange(pkt.length, pkt.length + AUTH_TAG_LEN, tag);

    return out;
  }

  Buffer? decryptRtp(Buffer pkt) {
    if (pkt.length < 12 + AUTH_TAG_LEN) return null;

    final authStart = pkt.length - AUTH_TAG_LEN;

    final bodyU8 = pkt.subarray(0, authStart);
    final tagU8 = pkt.subarray(authStart);

    final body = Buffer.from(
      bodyU8.buffer,
      bodyU8.offsetInBytes,
      bodyU8.length,
    );

    final tag = Buffer.from(tagU8.buffer, tagU8.offsetInBytes, tagU8.length);

    final seq = body.readUInt16BE(2);
    final ssrc = body.readUInt32BE(8);

    final state = _rocMap.putIfAbsent(
      ssrc,
      () => _RocState(roc: 0, lastSeq: seq),
    );

    final index = (state.roc << 16) | seq;

    final macInput = _concatBytes(body.subarray(0), _uint32ToBytes(state.roc));

    final expectedMac = Hmac(sha1, _rtpAuth).convert(macInput);

    final expectedTag = Uint8List.fromList(
      expectedMac.bytes.sublist(0, AUTH_TAG_LEN),
    );

    if (!constantTimeEquals(tag.subarray(0), expectedTag)) {
      return null;
    }

    final headerLen = rtpHeaderLength(body);

    final iv = _buildIv(ssrc, index);

    final encPayload = body.subarray(headerLen);

    final decPayload = aesCtrEncrypt(_rtpKey, iv, encPayload);

    final out = Buffer.allocUnsafe(headerLen + decPayload.length);

    body.copy(out, 0, 0, headerLen);

    Buffer.from(
      decPayload.buffer,
      decPayload.offsetInBytes,
      decPayload.length,
    ).copy(out, headerLen);

    return out;
  }

  Uint8List _concatBytes(Uint8List a, Uint8List b) {
    final out = Uint8List(a.length + b.length);

    out.setRange(0, a.length, a);
    out.setRange(a.length, a.length + b.length, b);

    return out;
  }

  Uint8List _buildIv(int ssrc, int index) {
    final iv = Uint8List(16);

    // ✅ Step 1: copy salt (14 bytes)
    iv.setRange(0, 14, _rtpSalt);

    // last 2 bytes = 0
    iv[14] = 0;
    iv[15] = 0;

    // ✅ Step 2: XOR SSRC into bytes 4..7
    iv[4] ^= (ssrc >> 24) & 0xFF;
    iv[5] ^= (ssrc >> 16) & 0xFF;
    iv[6] ^= (ssrc >> 8) & 0xFF;
    iv[7] ^= ssrc & 0xFF;

    // ✅ Step 3: XOR packet index (48-bit) into 8..13
    final hi = (index >> 16) & 0xFFFFFFFF;
    final lo = index & 0xFFFF;

    iv[8] ^= (hi >> 8) & 0xFF;
    iv[9] ^= hi & 0xFF;

    // iv[10], iv[11] remain salt

    iv[12] ^= (lo >> 8) & 0xFF;
    iv[13] ^= lo & 0xFF;

    return iv;
  }

  Uint8List _deriveKey(
    Uint8List masterKey,
    Uint8List masterSalt,
    int label,
    int length,
  ) {
    final iv = Uint8List(16);
    iv.setAll(0, masterSalt);
    iv[7] ^= label;

    return aesCtrEncrypt(masterKey, iv, Uint8List(length));
  }

  Uint8List _uint32ToBytes(int v) {
    return Uint8List.fromList([
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ]);
  }
}

class _RocState {
  int roc;
  int lastSeq;

  _RocState({required this.roc, required this.lastSeq});
}

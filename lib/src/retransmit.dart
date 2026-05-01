import 'dart:math' as math;

import 'rtp.dart';

class SenderBuffer {
  final int size;
  final Map<int, List<_Slot?>> _rings = {};

  SenderBuffer({this.size = 512});

  void store(Buffer pkt) {
    if (pkt.length < 12) return;

    final ssrc = pkt.readUInt32BE(8);
    final seq = pkt.readUInt16BE(2);

    final ring = _rings.putIfAbsent(
      ssrc,
      () => List<_Slot?>.filled(size, null),
    );

    final u8 = pkt.subarray(0);

    ring[seq % size] = _Slot(
      seq: seq,
      packet: Buffer.from(u8.buffer, u8.offsetInBytes, u8.length),
    );
  }

  Buffer? get(int ssrc, int seq) {
    final ring = _rings[ssrc];
    if (ring == null) return null;

    final slot = ring[seq % size];
    if (slot == null || slot.seq != seq) return null;

    return slot.packet;
  }

  void clear([int? ssrc]) {
    if (ssrc == null) {
      _rings.clear();
    } else {
      _rings.remove(ssrc);
    }
  }
}

class _Slot {
  final int seq;
  final Buffer packet;

  _Slot({required this.seq, required this.packet});
}

Buffer? buildRtxPacket(
  Buffer origPkt, {
  required int rtxSsrc,
  required int rtxPt,
  required int rtxSeq,
}) {
  if (origPkt.length < 12) return null;

  final cc = origPkt[0] & 0x0F;
  final hasExt = (origPkt[0] & 0x10) != 0;

  int headerLen = 12 + cc * 4;

  if (hasExt && origPkt.length >= headerLen + 4) {
    final extLen = origPkt.readUInt16BE(headerLen + 2);
    headerLen += 4 + extLen * 4;
  }

  if (origPkt.length < headerLen) return null;

  final origSeq = origPkt.readUInt16BE(2);
  final payloadLen = origPkt.length - headerLen;

  final out = Buffer.allocUnsafe(headerLen + 2 + payloadLen);

  origPkt.copy(out, 0, 0, headerLen);

  // PT (preserve marker)
  out[1] = (origPkt[1] & 0x80) | (rtxPt & 0x7F);

  out.writeUInt16BE(rtxSeq, 2);
  out.writeUInt32BE(rtxSsrc, 8);

  // OSN
  out.writeUInt16BE(origSeq, headerLen);

  origPkt.copy(out, headerLen + 2, headerLen);

  return out;
}

Buffer? parseRtxPacket(
  Buffer pkt, {
  required int primarySsrc,
  required int primaryPt,
}) {
  if (pkt.length < 12) return null;

  final cc = pkt[0] & 0x0F;
  final hasExt = (pkt[0] & 0x10) != 0;

  int headerLen = 12 + cc * 4;

  if (hasExt && pkt.length >= headerLen + 4) {
    final extLen = pkt.readUInt16BE(headerLen + 2);
    headerLen += 4 + extLen * 4;
  }

  if (pkt.length < headerLen + 2) return null;

  final osn = pkt.readUInt16BE(headerLen);
  final payloadLen = pkt.length - headerLen - 2;

  final out = Buffer.allocUnsafe(headerLen + payloadLen);

  pkt.copy(out, 0, 0, headerLen);

  out[1] = (pkt[1] & 0x80) | (primaryPt & 0x7F);
  out.writeUInt16BE(osn, 2);
  out.writeUInt32BE(primarySsrc, 8);

  pkt.copy(out, headerLen, headerLen + 2);

  return out;
}

class RtxStream {
  final int _ssrc;
  final int _pt;
  int _seq;

  RtxStream({required int rtxSsrc, required int rtxPt, int? initialSeq})
    : _ssrc = rtxSsrc,
      _pt = rtxPt & 0x7F,
      _seq = initialSeq ?? math.Random.secure().nextInt(0x10000);

  Buffer wrap(Buffer pkt) {
    _seq = (_seq + 1) & 0xFFFF;

    return buildRtxPacket(pkt, rtxSsrc: _ssrc, rtxPt: _pt, rtxSeq: _seq)!;
  }

  int get ssrc => _ssrc;
  int get pt => _pt;
  int get seq => _seq;
}

class NackThrottle {
  final int windowMs;
  final Map<String, int> _lastSent = {};

  NackThrottle({this.windowMs = 100});

  bool shouldSend(int ssrc, int seq) {
    final key = '$ssrc:$seq';
    final now = DateTime.now().millisecondsSinceEpoch;

    final last = _lastSent[key];

    if (last != null && (now - last) < windowMs) {
      return false;
    }

    _lastSent[key] = now;

    // occasional cleanup
    if (math.Random().nextDouble() < 0.01) {
      _evict(now);
    }

    return true;
  }

  void _evict(int now) {
    final cutoff = now - windowMs * 20;

    _lastSent.removeWhere((k, v) => v < cutoff);
  }

  void clear() {
    _lastSent.clear();
  }
}

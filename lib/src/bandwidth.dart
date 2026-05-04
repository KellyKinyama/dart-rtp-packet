import 'dart:math' as math;

import 'rtp.dart';
import 'rtcp.dart'; // for buildTransportCC

// ==============================
// ✅ parseTransportCC
// ==============================

Map<String, dynamic>? parseTransportCC(Buffer fci) {
  if (fci.length < 8) return null;

  final baseSeq = fci.readUInt16BE(0);
  final packetCount = fci.readUInt16BE(2);

  int refRaw = (fci[4] << 16) | (fci[5] << 8) | fci[6];
  if ((refRaw & 0x800000) != 0) refRaw |= 0xFF000000;

  final referenceTimeMs = refRaw * 64;
  final fbPktCount = fci[7];

  final symbols = <int>[];
  int off = 8;

  while (symbols.length < packetCount) {
    if (off + 2 > fci.length) return null;

    final chunk = fci.readUInt16BE(off);
    off += 2;

    if ((chunk & 0x8000) == 0) {
      final s = (chunk >> 13) & 0x3;
      final runLen = chunk & 0x1FFF;

      for (int i = 0; i < runLen && symbols.length < packetCount; i++) {
        symbols.add(s);
      }
    } else {
      final symbolSize = (chunk >> 14) & 1;

      if (symbolSize == 0) {
        for (int i = 13; i >= 0 && symbols.length < packetCount; i--) {
          symbols.add(((chunk >> i) & 1) == 1 ? 1 : 0);
        }
      } else {
        for (int i = 6; i >= 0 && symbols.length < packetCount; i--) {
          symbols.add((chunk >> (i * 2)) & 0x3);
        }
      }
    }
  }

  final packets = <Map<String, dynamic>>[];

  for (int i = 0; i < packetCount; i++) {
    final seq = (baseSeq + i) & 0xFFFF;
    final sym = symbols[i];

    if (sym == 0 || sym == 3) {
      packets.add({'seq': seq, 'received': sym != 0, 'deltaUs': null});
      continue;
    }

    if (sym == 1) {
      if (off + 1 > fci.length) return null;

      final d8 = fci[off++];
      packets.add({'seq': seq, 'received': true, 'deltaUs': d8 * 250});
    } else {
      if (off + 2 > fci.length) return null;

      final d16 = fci.readInt16BE(off);
      off += 2;

      packets.add({'seq': seq, 'received': true, 'deltaUs': d16 * 250});
    }
  }

  return {
    'baseSeq': baseSeq,
    'packetCount': packetCount,
    'referenceTimeMs': referenceTimeMs,
    'fbPktCount': fbPktCount,
    'packets': packets,
  };
}

// ==============================
// ✅ parseREMB
// ==============================

Map<String, dynamic>? parseREMB(Buffer fci) {
  if (fci.length < 8) return null;

  if (fci[0] != 0x52 || fci[1] != 0x45 || fci[2] != 0x4D || fci[3] != 0x42) {
    return null;
  }

  final numSsrc = fci[4];
  final exp = (fci[5] >> 2) & 0x3F;

  final mantissa = ((fci[5] & 0x03) << 16) | (fci[6] << 8) | fci[7];

  final bitrate = mantissa * math.pow(2, exp).toInt();

  final ssrcs = <int>[];

  for (int i = 0; i < numSsrc; i++) {
    final off = 8 + i * 4;
    if (off + 4 > fci.length) break;

    ssrcs.add(fci.readUInt32BE(off));
  }

  return {'bitrate': bitrate, 'ssrcs': ssrcs};
}

// ==============================
// ✅ BandwidthEstimator
// ==============================

class BandwidthEstimator {
  final int minBps;
  final int maxBps;
  final int startBps;

  int _estimate;
  int _remoteRembBps = 0;

  final Map<int, _SendInfo> _sendHistory = {};
  final List<int> _order = [];

  double _delayTrendMs = 0;

  BandwidthEstimator({
    this.minBps = 50000,
    this.maxBps = 100000000,
    this.startBps = 500000,
  }) : _estimate = startBps;

  void recordSend(int seq, int timeMs, int sizeBytes) {
    _sendHistory[seq] = _SendInfo(timeMs, sizeBytes);
    _order.add(seq);

    if (_order.length > 2048) {
      final evict = _order.removeAt(0);
      _sendHistory.remove(evict);
    }
  }

  void observeRemb(int bitrate) {
    if (bitrate < 10000) return;

    _remoteRembBps = bitrate;

    final target = bitrate.clamp(minBps, maxBps);
    _estimate = ((_estimate + target) ~/ 2);
  }

  void observeTransportCC(Map report) {
    final packets = report['packets'];
    if (packets == null || packets.length < 2) return;

    double totalGradient = 0;
    int count = 0;

    int? prevSeq;
    int prevSend = 0;

    for (final p in packets) {
      if (p['received'] != true) continue;

      final seq = p['seq'];
      final rec = _sendHistory[seq];
      if (rec == null) continue;

      if (prevSeq != null && _sendHistory.containsKey(prevSeq)) {
        final deltaUs = p['deltaUs'];
        final sendDelta = rec.timeMs - prevSend;

        final gradient = deltaUs - (sendDelta * 1000);

        totalGradient += gradient;
        count++;
      }

      prevSeq = seq;
      prevSend = rec.timeMs;
    }

    if (count == 0) return;

    final avg = totalGradient / count;

    const alpha = 0.4;
    _delayTrendMs = (1 - alpha) * _delayTrendMs + alpha * (avg / 1000);

    num next;

    if (_delayTrendMs > 5) {
      next = _estimate * 0.95;
    } else if (_delayTrendMs < -3) {
      next = _estimate * 1.02;
    } else {
      next = _estimate * 1.01;
    }

    if (_remoteRembBps > 0) {
      next = math.min(next, _remoteRembBps);
    }

    next = next.clamp(minBps, maxBps);

    _estimate = next.round();
  }

  int getEstimate() => _estimate;

  void reset() {
    _estimate = startBps;
    _remoteRembBps = 0;
    _delayTrendMs = 0;
    _sendHistory.clear();
    _order.clear();
  }
}

class _SendInfo {
  final int timeMs;
  final int sizeBytes;

  _SendInfo(this.timeMs, this.sizeBytes);
}

// ==============================
// ✅ TransportCCFeedbackGenerator
// ==============================

class TransportCCFeedbackGenerator {
  int senderSsrc;
  int mediaSsrc;
  int _fbCount = 0;

  final List<_Arrival> _arrivals = [];

  TransportCCFeedbackGenerator({this.senderSsrc = 1, this.mediaSsrc = 0});

  void recordArrival(int seq, int timeMs) {
    seq &= 0xFFFF;

    for (final a in _arrivals) {
      if (a.seq == seq) return;
    }

    _arrivals.add(_Arrival(seq, timeMs));
  }

  Buffer? buildFeedback() {
    if (_arrivals.isEmpty) return null;

    final arrs = List<_Arrival>.from(_arrivals)
      ..sort((a, b) => a.seq.compareTo(b.seq));

    final baseSeq = arrs.first.seq;
    final highest = arrs.last.seq;

    int packetCount = highest - baseSeq + 1;
    if (packetCount > 0xFFFF) {
      packetCount = 0xFFFF;
    }

    final refTime = (arrs.first.timeMs ~/ 64) * 64;

    final packets = <TwccPacket>[];

    int ai = 0;
    int prevArrivalMs = refTime;

    for (int i = 0; i < packetCount; i++) {
      final seqI = arrs[0].seq + i;

      if (ai < arrs.length && arrs[ai].seq == seqI) {
        final deltaUs = (arrs[ai].timeMs - prevArrivalMs) * 1000;

        packets.add(TwccPacket(received: true, deltaUs: deltaUs));

        prevArrivalMs = arrs[ai].timeMs;
        ai++;
      } else {
        packets.add(TwccPacket(received: false, deltaUs: 0));
      }
    }

    final pkt = buildTransportCC(
      senderSsrc: senderSsrc,
      mediaSsrc: mediaSsrc,
      baseSeq: baseSeq,
      packetCount: packetCount,
      referenceTimeMs: refTime,
      fbPktCount: _fbCount,
      packets: packets,
    );

    _fbCount = (_fbCount + 1) & 0xFF;
    _arrivals.clear();

    return pkt;
  }

  void reset() {
    _arrivals.clear();
    _fbCount = 0;
  }
}

class _Arrival {
  final int seq;
  final int timeMs;

  _Arrival(this.seq, this.timeMs);
}

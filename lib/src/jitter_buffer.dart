import 'dart:async';
import 'rtp.dart';

class JitterBuffer {
  final int maxSize;
  int latencyMs;
  final int clockRate;

  final void Function(RtpPacket)? output;
  final void Function(int)? onLoss;

  final Map<int, _JbEntry> _buffer = {};
  int _nextSeq = -1;

  int _rttMs = 0;
  int _rttSafetyMs;

  Timer? _timer;

  JitterBuffer({
    this.latencyMs = 50,
    this.maxSize = 256,
    this.clockRate = 90000,
    this.output,
    this.onLoss,
    int rttMs = 0,
    int rttSafetyMs = 50,
  }) : _rttMs = rttMs,
       _rttSafetyMs = rttSafetyMs {
    _timer = Timer.periodic(
      Duration(milliseconds: (latencyMs ~/ 2).clamp(5, 1000)),
      (_) => _flush(),
    );
  }

  // ✅ PUSH PACKET
  void push(RtpPacket pkt) {
    final seq = pkt.sequenceNumber;

    // init
    if (_nextSeq == -1) {
      _nextSeq = seq;
    }

    // drop old
    final behind = _seqDiff(_nextSeq, seq);
    if (behind > 128) return;

    _buffer[seq] = _JbEntry(pkt, DateTime.now().millisecondsSinceEpoch);

    // size limit
    if (_buffer.length > maxSize) {
      _flush();
    }
  }

  // ✅ FLUSH
  void _flush() {
    final now = DateTime.now().millisecondsSinceEpoch;

    int emitted = 0;
    const maxEmit = 30;

    while (emitted < maxEmit) {
      final seq = _nextSeq & 0xFFFF;
      final entry = _buffer[seq];

      if (entry != null) {
        _buffer.remove(seq);

        output?.call(entry.pkt);

        _nextSeq = (_nextSeq + 1) & 0xFFFF;
        emitted++;
      } else {
        final next = _findNextAvailable();
        if (next == null) break;

        final waited = now - next.insertTime;

        if (waited >= _effectiveLatency()) {
          final gapStart = _nextSeq;
          final gapEnd = next.seq;

          int s = gapStart;
          while (s != gapEnd) {
            final lost = s & 0xFFFF;
            onLoss?.call(lost);
            s = (s + 1) & 0xFFFF;
          }

          _nextSeq = gapEnd;
        } else {
          break;
        }
      }
    }
  }

  _JbNext? _findNextAvailable() {
    for (int i = 1; i < 64; i++) {
      final seq = (_nextSeq + i) & 0xFFFF;
      final e = _buffer[seq];
      if (e != null) {
        return _JbNext(seq, e.insertTime);
      }
    }
    return null;
  }

  int _effectiveLatency() {
    if (_rttMs > 0) {
      return [
        latencyMs,
        2 * _rttMs + _rttSafetyMs,
      ].reduce((a, b) => a > b ? a : b);
    }
    return latencyMs;
  }

  void setLatency(int ms) {
    latencyMs = ms;

    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: (ms ~/ 2).clamp(5, 1000)),
      (_) => _flush(),
    );
  }

  void setRtt(int rttMs) {
    _rttMs = rttMs;
  }

  void reset() {
    _buffer.clear();
    _nextSeq = -1;
  }

  void close() {
    _timer?.cancel();
    _buffer.clear();
  }
}

// ═══════════════════════════════════════════════════════════════════
// INTERNAL
// ═══════════════════════════════════════════════════════════════════

class _JbEntry {
  final RtpPacket pkt;
  final int insertTime;

  _JbEntry(this.pkt, this.insertTime);
}

class _JbNext {
  final int seq;
  final int insertTime;

  _JbNext(this.seq, this.insertTime);
}

int _seqDiff(int a, int b) {
  final d = ((a - b) + 0x10000) & 0xFFFF;
  return d > 0x8000 ? d - 0x10000 : d;
}

// void main(){
//   final jb = JitterBuffer(
//   latencyMs: 50,
//   output: (pkt) {
//     depacketizer.depacketize({
//       'payload': pkt.payload,
//       'timestamp': pkt.timestamp,
//       'marker': pkt.marker,
//     });
//   },
//   onLoss: (seq) {
//     print("Packet lost: $seq");
//   },
// );
// }

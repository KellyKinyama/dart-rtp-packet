import 'rtp.dart';

const int dtmfClockRate = 8000; // RFC 4733 §2.5

// RFC 4733 §3 Table 1: Named event codes
enum DtmfDigit {
  d0(0),
  d1(1),
  d2(2),
  d3(3),
  d4(4),
  d5(5),
  d6(6),
  d7(7),
  d8(8),
  d9(9),
  star(10),
  hash(11),
  a(12),
  b(13),
  c(14),
  d(15),
  flash(16);

  final int code;
  const DtmfDigit(this.code);

  static DtmfDigit? fromString(String s) {
    switch (s.toUpperCase()) {
      case '0':
        return d0;
      case '1':
        return d1;
      case '2':
        return d2;
      case '3':
        return d3;
      case '4':
        return d4;
      case '5':
        return d5;
      case '6':
        return d6;
      case '7':
        return d7;
      case '8':
        return d8;
      case '9':
        return d9;
      case '*':
        return star;
      case '#':
        return hash;
      case 'A':
        return a;
      case 'B':
        return b;
      case 'C':
        return c;
      case 'D':
        return d;
      default:
        return null;
    }
  }

  String get symbol {
    if (code >= 0 && code <= 9) return code.toString();
    if (code == 10) return '*';
    if (code == 11) return '#';
    if (code >= 12 && code <= 15) {
      return String.fromCharCode(65 + code - 12); // A-D
    }
    return '?';
  }
}

// Legacy map for backward compatibility (internal use only)
const Map<String, int> eventNames = {
  '0': 0,
  '1': 1,
  '2': 2,
  '3': 3,
  '4': 4,
  '5': 5,
  '6': 6,
  '7': 7,
  '8': 8,
  '9': 9,
  '*': 10,
  '#': 11,
  'A': 12,
  'B': 13,
  'C': 14,
  'D': 15,
};

// ═══════════════════════════════════════════════════════════════════
// Typed DTMF Event
// ═══════════════════════════════════════════════════════════════════

class DtmfEvent {
  final int event;
  final int volume;
  final int durationSamples;
  final bool end;
  final int timestampUs;

  const DtmfEvent({
    required this.event,
    required this.volume,
    required this.durationSamples,
    required this.end,
    required this.timestampUs,
  });

  String? get symbol {
    for (final entry in eventNames.entries) {
      if (entry.value == event) return entry.key;
    }
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════
// Typed Input for Packetizer
// ═══════════════════════════════════════════════════════════════════

class DtmfChunk {
  final int timestampUs;
  final int event;
  final int durationSamples;
  final int volume;
  final bool end;
  final bool marker; // RFC 4733 §2.3.1: true for first packet of event

  const DtmfChunk({
    required this.timestampUs,
    required this.event,
    required this.durationSamples,
    this.volume = 10,
    this.end = false,
    this.marker = false,
  });
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class DTMFPacketizer {
  final RtpState state;

  DTMFPacketizer(RtpPacketizerConfig config)
    : state = RtpState.fromConfig(config);

  /// RFC 4733 §2.5.1.4: End packets MUST be retransmitted 3 times with same timestamp
  /// RFC 4733 §2.3.1: Marker bit MUST be set on first packet of event
  List<Buffer> packetize(DtmfChunk chunk) {
    final rtpTs = usToRtp(chunk.timestampUs, dtmfClockRate);

    final volume = chunk.volume & 0x3F; // RFC 4733 §2.5: bits 6-7 reserved
    final endBit = chunk.end ? 0x80 : 0;

    final payload = Buffer.allocUnsafe(4);

    payload[0] = chunk.event & 0xFF;
    payload[1] = endBit | volume;

    final dur = chunk.durationSamples;
    payload[2] = (dur >> 8) & 0xFF;
    payload[3] = dur & 0xFF;

    // RFC 4733 §2.3.1: marker bit on first packet only
    final pkt = makeRtpPacket(state, payload, rtpTs, chunk.marker);

    // RFC 4733 §2.5.1.4: retransmit end packet 3 times
    if (chunk.end) {
      return [pkt, pkt, pkt];
    }

    return [pkt];
  }
}

// ═══════════════════════════════════════════════════════════════════
// Depacketizer
// ═══════════════════════════════════════════════════════════════════

class DTMFDepacketizer {
  final RtpDepacketizerCallbacks<DtmfEvent> _callbacks;

  DTMFDepacketizer(RtpDepacketizerCallbacks<DtmfEvent> callbacks)
    : _callbacks = callbacks;

  static bool peekKeyframe() => false;

  void depacketize(RtpPacket packet) {
    final payload = packet.payload;

    if (payload.length < 4) {
      _callbacks.onError?.call(Exception('DTMF payload too small'));
      return;
    }

    final event = payload[0];
    final b1 = payload[1];

    final end = (b1 & 0x80) != 0;
    final volume = b1 & 0x3F;

    final duration = (payload[2] << 8) | payload[3];

    try {
      _callbacks.onFrame?.call(
        DtmfEvent(
          event: event,
          volume: volume,
          durationSamples: duration,
          end: end,
          timestampUs: (packet.timestamp * 1000000) ~/ dtmfClockRate,
        ),
      );
    } catch (e, st) {
      _callbacks.onError?.call(e, st);
    }
  }
}

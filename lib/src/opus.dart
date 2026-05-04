import 'dart:typed_data';
import 'rtp.dart';

const int opusClockRate = 48000;
const int silenceGapRtp = 24000; // 500 ms at 48 kHz

// ═══════════════════════════════════════════════════════════════════
// Typed Output Frame
// ═══════════════════════════════════════════════════════════════════

class OpusFrame {
  final Uint8List data;
  final int timestampUs;

  const OpusFrame({required this.data, required this.timestampUs});
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class OpusPacketizer {
  final RtpState state;

  bool _sentFirst = false;
  int _lastRtpTs = 0;

  OpusPacketizer(RtpPacketizerConfig config)
    : state = RtpState.fromConfig(config);

  List<Buffer> packetize(MediaChunk chunk) {
    final data = Buffer.from(
      chunk.data.buffer,
      chunk.data.offsetInBytes,
      chunk.data.lengthInBytes,
    );
    final rtpTs = usToRtp(chunk.timestampUs, opusClockRate);

    // RFC 7587 §4: Opus packets MUST NOT be fragmented
    if (data.length > state.mtu) {
      throw ArgumentError(
        'Opus frame ${data.length} exceeds MTU ${state.mtu} (RFC 7587 §4 forbids fragmentation)',
      );
    }

    // RFC 7587 §4: marker bit set on first packet of talkspurt (after silence)
    bool marker;

    if (!_sentFirst) {
      marker = true;
      _sentFirst = true;
    } else {
      final diff = (rtpTs - _lastRtpTs) & 0xFFFFFFFF;
      marker = diff > silenceGapRtp;
    }

    _lastRtpTs = rtpTs;

    return [makeRtpPacket(state, data, rtpTs, marker)];
  }
}

// ═══════════════════════════════════════════════════════════════════
// Depacketizer
// ═══════════════════════════════════════════════════════════════════

class OpusDepacketizer {
  final RtpDepacketizerCallbacks<OpusFrame> _callbacks;

  OpusDepacketizer(RtpDepacketizerCallbacks<OpusFrame> callbacks)
    : _callbacks = callbacks;

  static bool peekKeyframe() => false;

  void depacketize(RtpPacket packet) {
    if (packet.payload.isEmpty) {
      _callbacks.onError?.call(Exception('Opus: empty payload'));
      return;
    }

    try {
      _callbacks.onFrame?.call(
        OpusFrame(
          data: packet.payload,
          timestampUs: (packet.timestamp * 1000000) ~/ opusClockRate,
        ),
      );
    } catch (e, st) {
      _callbacks.onError?.call(e, st);
    }
  }
}

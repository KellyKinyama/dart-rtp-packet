import 'dart:typed_data';
import 'rtp.dart';

// RFC 3551 §4.5.2: G.722 uses 8000 Hz RTP clock (NOT 16000 Hz audio sample rate)
const int g722ClockRate = 8000;

// ═══════════════════════════════════════════════════════════════════
// Typed Output Frame
// ═══════════════════════════════════════════════════════════════════

class G722Frame {
  final Uint8List data;
  final int timestampUs;

  const G722Frame({required this.data, required this.timestampUs});
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class G722Packetizer {
  final RtpState state;

  G722Packetizer(RtpPacketizerConfig config)
    : state = RtpState.fromConfig(config);

  List<Buffer> packetize(MediaChunk chunk, {bool marker = false}) {
    final data = Buffer.from(
      chunk.data.buffer,
      chunk.data.offsetInBytes,
      chunk.data.lengthInBytes,
    );
    // RFC 3551 §4.5.2: RTP timestamp clock is 8000 Hz, not 16000 Hz
    final rtpTs = usToRtp(chunk.timestampUs, g722ClockRate);

    if (data.length <= state.mtu) {
      return [makeRtpPacket(state, data, rtpTs, marker)];
    }

    // When fragmenting, all fragments share the same timestamp
    final List<Buffer> out = [];
    int offset = 0;

    while (offset < data.length) {
      final size = (data.length - offset > state.mtu)
          ? state.mtu
          : data.length - offset;

      final slice = data.subarray(offset, offset + size);
      final isFirst = (offset == 0);

      out.add(
        makeRtpPacket(
          state,
          Buffer.from(slice.buffer, slice.offsetInBytes, slice.length),
          rtpTs, // same timestamp for all fragments
          isFirst && marker,
        ),
      );

      offset += size;
    }

    return out;
  }
}

// ═══════════════════════════════════════════════════════════════════
// Depacketizer
// ═══════════════════════════════════════════════════════════════════

class G722Depacketizer {
  final RtpDepacketizerCallbacks<G722Frame> _callbacks;

  G722Depacketizer(RtpDepacketizerCallbacks<G722Frame> callbacks)
    : _callbacks = callbacks;

  static bool peekKeyframe() => false;

  void depacketize(RtpPacket packet) {
    if (packet.payload.isEmpty) {
      _callbacks.onError?.call(Exception('G.722: empty payload'));
      return;
    }

    try {
      _callbacks.onFrame?.call(
        G722Frame(
          data: packet.payload,
          // RFC 3551 §4.5.2: RTP clock 8000 Hz
          timestampUs: (packet.timestamp * 1000000) ~/ g722ClockRate,
        ),
      );
    } catch (e, st) {
      _callbacks.onError?.call(e, st);
    }
  }
}

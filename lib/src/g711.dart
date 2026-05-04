import 'dart:typed_data';
import 'rtp.dart';

const int g711ClockRate = 8000; // RFC 3551 §4.5

// RFC 3551 §4.5.14: Static payload types for G.711
enum G711Codec {
  pcmu(0),
  pcma(8);

  final int payloadType;
  const G711Codec(this.payloadType);
}

// ═══════════════════════════════════════════════════════════════════
// Typed Output Frame
// ═══════════════════════════════════════════════════════════════════

class G711Frame {
  final Uint8List data;
  final int timestampUs;

  const G711Frame({required this.data, required this.timestampUs});
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class G711Packetizer {
  final RtpState state;

  G711Packetizer(RtpPacketizerConfig config)
    : state = RtpState.fromConfig(config);

  List<Buffer> packetize(MediaChunk chunk, {bool marker = false}) {
    final data = Buffer.from(
      chunk.data.buffer,
      chunk.data.offsetInBytes,
      chunk.data.lengthInBytes,
    );
    // RFC 3551 §4.5.14: one sample per byte at 8000 Hz
    final rtpTs = usToRtp(chunk.timestampUs, g711ClockRate);

    if (data.length <= state.mtu) {
      return [makeRtpPacket(state, data, rtpTs, marker)];
    }

    // RFC 3551: when fragmenting, all fragments share the same timestamp
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

class G711Depacketizer {
  final RtpDepacketizerCallbacks<G711Frame> _callbacks;

  G711Depacketizer(RtpDepacketizerCallbacks<G711Frame> callbacks)
    : _callbacks = callbacks;

  static bool peekKeyframe() => false;

  void depacketize(RtpPacket packet) {
    if (packet.payload.isEmpty) {
      _callbacks.onError?.call(Exception('G.711: empty payload'));
      return;
    }

    try {
      _callbacks.onFrame?.call(
        G711Frame(
          data: packet.payload,
          timestampUs: (packet.timestamp * 1000000) ~/ g711ClockRate,
        ),
      );
    } catch (e, st) {
      _callbacks.onError?.call(e, st);
    }
  }
}

import 'dart:typed_data';
import 'rtp.dart';

const int vp9ClockRate = 90000;

// ═══════════════════════════════════════════════════════════════════
// Typed Output Frame
// ═══════════════════════════════════════════════════════════════════

class Vp9Frame {
  final Uint8List data;
  final int timestampUs;
  final bool keyFrame;

  const Vp9Frame({
    required this.data,
    required this.timestampUs,
    required this.keyFrame,
  });
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

bool _isVp9Keyframe(Uint8List data) {
  if (data.isEmpty) return false;
  // RFC: P=1 means inter-frame (non-key), P=0 means key frame.
  // VP9 bitstream: frame_type bit (0=key, 1=non-key) is at bit 5 of first byte.
  // Assume frame_marker=2, profile=0, show_existing_frame=0.
  return ((data[0] >> 5) & 1) == 0;
}

class VP9Packetizer {
  final RtpState state;

  VP9Packetizer(RtpPacketizerConfig config)
    : state = RtpState.fromConfig(config);

  List<Buffer> packetize(MediaChunk chunk) {
    final data = Buffer.from(
      chunk.data.buffer,
      chunk.data.offsetInBytes,
      chunk.data.lengthInBytes,
    );
    final rtpTs = usToRtp(chunk.timestampUs, vp9ClockRate);

    final maxPayload = state.mtu - 1;

    final isKey = _isVp9Keyframe(chunk.data);
    final P = isKey ? 0 : 0x40;

    if (data.length <= maxPayload) {
      return [
        makePacketWithPrefix(
          state,
          P | 0x08 | 0x04,
          0,
          0,
          0,
          1,
          data,
          0,
          data.length,
          rtpTs,
          true,
        ),
      ];
    }

    final List<Buffer> out = [];
    int offset = 0;
    int fragIndex = 0;

    while (offset < data.length) {
      final remaining = data.length - offset;
      final size = remaining > maxPayload ? maxPayload : remaining;

      final isFirst = fragIndex == 0;
      final isLast = (offset + size) >= data.length;

      int descriptor = P;
      if (isFirst) descriptor |= 0x08;
      if (isLast) descriptor |= 0x04;

      out.add(
        makePacketWithPrefix(
          state,
          descriptor,
          0,
          0,
          0,
          1,
          data,
          offset,
          size,
          rtpTs,
          isLast,
        ),
      );

      offset += size;
      fragIndex++;
    }

    return out;
  }
}

// ═══════════════════════════════════════════════════════════════════
// Depacketizer
// ═══════════════════════════════════════════════════════════════════

class VP9Depacketizer {
  final RtpDepacketizerCallbacks<Vp9Frame> _callbacks;

  List<Uint8List> _fragments = [];
  int _lastTimestamp = 0;

  VP9Depacketizer(RtpDepacketizerCallbacks<Vp9Frame> callbacks)
    : _callbacks = callbacks;

  void depacketize(RtpPacket packet) {
    final payload = packet.payload;

    if (payload.isEmpty) {
      _callbacks.onError?.call(Exception('VP9: empty payload'));
      return;
    }

    _lastTimestamp = packet.timestamp;

    final desc = payload[0];
    final B = (desc & 0x08) != 0;
    final E = (desc & 0x04) != 0;

    int hdrLen = 1;

    if (hdrLen >= payload.length) {
      _callbacks.onError?.call(Exception('VP9: invalid header'));
      return;
    }

    final data = payload.sublist(hdrLen);

    if (B) {
      _fragments = [data];
    } else {
      _fragments.add(data);
    }

    if (E || packet.marker) {
      if (_fragments.isEmpty) return;

      final frame = _concat(_fragments);
      _fragments = [];

      bool isKey = false;
      if (frame.isNotEmpty) {
        final fm = (frame[0] >> 6) & 3;
        if (fm == 2) {
          isKey = true;
        }
      }

      try {
        _callbacks.onFrame?.call(
          Vp9Frame(
            data: frame,
            timestampUs: (_lastTimestamp * 1000000) ~/ vp9ClockRate,
            keyFrame: isKey,
          ),
        );
      } catch (e, st) {
        _callbacks.onError?.call(e, st);
      }
    }
  }

  Uint8List _concat(List<Uint8List> parts) {
    int size = parts.fold(0, (s, p) => s + p.length);
    final out = Uint8List(size);

    int offset = 0;
    for (final p in parts) {
      out.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return out;
  }
}

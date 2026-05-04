import 'dart:typed_data';
import 'rtp.dart';

const int av1ClockRate = 90000;

// ═══════════════════════════════════════════════════════════════════
// Typed Output Frame
// ═══════════════════════════════════════════════════════════════════

class Av1Frame {
  final Uint8List data;
  final int timestampUs;
  final bool keyFrame;

  const Av1Frame({
    required this.data,
    required this.timestampUs,
    required this.keyFrame,
  });
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

bool _isAv1Keyframe(Uint8List data) {
  if (data.length < 2) return false;
  // AV1 RTP: N bit (0x08) in aggregation header indicates new coded video sequence (keyframe).
  // Simplistic heuristic: check first OBU for FRAME_HEADER or KEY_FRAME type.
  // For now, we assume the encoder signals keyframes via separate metadata or
  // we parse the OBU header. This is a placeholder.
  // A proper implementation would parse the OBU header to detect OBU_FRAME with KEY_FRAME type.
  // For simplicity, we return false and rely on the encoder to provide correct data.
  return false;
}

class AV1Packetizer {
  final RtpState state;

  AV1Packetizer(RtpPacketizerConfig config)
    : state = RtpState.fromConfig(config);

  List<Buffer> packetize(MediaChunk chunk) {
    final data = Buffer.from(
      chunk.data.buffer,
      chunk.data.offsetInBytes,
      chunk.data.lengthInBytes,
    );
    final rtpTs = usToRtp(chunk.timestampUs, av1ClockRate);

    final maxPayload = state.mtu - 1;

    final isKey = _isAv1Keyframe(chunk.data);

    if (data.length <= maxPayload) {
      return [
        makePacketWithPrefix(
          state,
          isKey ? 0x08 : 0x00,
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

    final out = <Buffer>[];
    int offset = 0;

    final fragCount = (data.length / maxPayload).ceil();

    for (int i = 0; i < fragCount; i++) {
      final isFirst = i == 0;
      final isLast = i == fragCount - 1;

      final size = (data.length - offset > maxPayload)
          ? maxPayload
          : data.length - offset;

      int header = 0;

      if (!isFirst) header |= 0x80;
      if (!isLast) header |= 0x40;
      if (isFirst && isKey) header |= 0x08;

      out.add(
        makePacketWithPrefix(
          state,
          header,
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
    }

    return out;
  }
}

// ═══════════════════════════════════════════════════════════════════
// Depacketizer
// ═══════════════════════════════════════════════════════════════════

class AV1Depacketizer {
  final RtpDepacketizerCallbacks<Av1Frame> _callbacks;

  List<Uint8List> _fragments = [];
  bool _isKey = false;
  int _lastTimestamp = 0;

  AV1Depacketizer(RtpDepacketizerCallbacks<Av1Frame> callbacks)
    : _callbacks = callbacks;

  static bool peekKeyframe(Uint8List payload) {
    if (payload.isEmpty) return false;

    final hdr = payload[0];

    final Z = (hdr & 0x80) != 0;
    final N = (hdr & 0x08) != 0;

    return !Z && N;
  }

  void depacketize(RtpPacket packet) {
    final payload = packet.payload;

    if (payload.isEmpty) {
      _callbacks.onError?.call(Exception('AV1: empty payload'));
      return;
    }

    _lastTimestamp = packet.timestamp;

    final hdr = payload[0];

    final Z = (hdr & 0x80) != 0;
    final Y = (hdr & 0x40) != 0;
    final N = (hdr & 0x08) != 0;

    final data = payload.sublist(1);

    if (!Z) {
      _fragments = [data];
      _isKey = N;
    } else {
      _fragments.add(data);
    }

    if (!Y || packet.marker) {
      if (_fragments.isEmpty) return;

      Uint8List frame;

      if (_fragments.length == 1) {
        frame = _fragments[0];
      } else {
        frame = _concat(_fragments);
      }

      try {
        _callbacks.onFrame?.call(
          Av1Frame(
            data: frame,
            timestampUs: (_lastTimestamp * 1000000) ~/ av1ClockRate,
            keyFrame: _isKey,
          ),
        );
      } catch (e, st) {
        _callbacks.onError?.call(e, st);
      }

      _fragments = [];
      _isKey = false;
    }
  }

  Uint8List _concat(List<Uint8List> parts) {
    int total = 0;
    for (final p in parts) {
      total += p.length;
    }

    final out = Uint8List(total);
    int offset = 0;

    for (final p in parts) {
      out.setRange(offset, offset + p.length, p);
      offset += p.length;
    }

    return out;
  }
}

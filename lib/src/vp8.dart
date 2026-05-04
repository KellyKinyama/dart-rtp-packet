import 'dart:typed_data';
import 'rtp.dart';

const int vp8ClockRate = 90000;

// ═══════════════════════════════════════════════════════════════════
// Typed Output Frame
// ═══════════════════════════════════════════════════════════════════

class Vp8Frame {
  final Uint8List data;
  final int timestampUs;
  final bool keyFrame;

  const Vp8Frame({
    required this.data,
    required this.timestampUs,
    required this.keyFrame,
  });
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class VP8Packetizer {
  final RtpState state;

  VP8Packetizer(RtpPacketizerConfig config)
    : state = RtpState.fromConfig(config);

  List<Buffer> packetize(MediaChunk chunk) {
    final data = Buffer.from(
      chunk.data.buffer,
      chunk.data.offsetInBytes,
      chunk.data.lengthInBytes,
    );
    final rtpTs = usToRtp(chunk.timestampUs, vp8ClockRate);

    final maxPayload = state.mtu - 1;

    if (data.length <= maxPayload) {
      return [
        makePacketWithPrefix(
          state,
          0x10,
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

      out.add(
        makePacketWithPrefix(
          state,
          isFirst ? 0x10 : 0x00,
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

class VP8Depacketizer {
  final RtpDepacketizerCallbacks<Vp8Frame> _callbacks;

  List<Uint8List> _fragments = [];
  int _lastTimestamp = 0;

  VP8Depacketizer(RtpDepacketizerCallbacks<Vp8Frame> callbacks)
    : _callbacks = callbacks;

  void depacketize(RtpPacket packet) {
    final payload = packet.payload;

    if (payload.isEmpty) {
      _callbacks.onError?.call(Exception('VP8: empty payload'));
      return;
    }

    _lastTimestamp = packet.timestamp;

    final S = (payload[0] & 0x10) != 0;
    final X = (payload[0] & 0x80) != 0;

    int hdrLen = 1;

    if (X && payload.length > 1) {
      final ext = payload[1];
      hdrLen = 2;

      if (ext & 0x80 != 0) hdrLen++;
      if (ext & 0x40 != 0) hdrLen++;
      if (ext & 0x30 != 0) hdrLen++;

      if ((ext & 0x80) != 0 && payload.length > 2 && (payload[2] & 0x80) != 0) {
        hdrLen++;
      }
    }

    if (hdrLen >= payload.length) {
      _callbacks.onError?.call(Exception('VP8: invalid header'));
      return;
    }

    final data = payload.sublist(hdrLen);

    if (S) {
      _fragments = [data];
    } else {
      _fragments.add(data);
    }

    if (packet.marker && _fragments.isNotEmpty) {
      final frame = _concat(_fragments);

      final isKey = (frame[0] & 0x01) == 0;

      try {
        _callbacks.onFrame?.call(
          Vp8Frame(
            data: frame,
            timestampUs: (_lastTimestamp * 1000000) ~/ vp8ClockRate,
            keyFrame: isKey,
          ),
        );
      } catch (e, st) {
        _callbacks.onError?.call(e, st);
      }

      _fragments = [];
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

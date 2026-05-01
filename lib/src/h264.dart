import 'dart:typed_data';
import 'rtp.dart';

const int H264_CLOCK_RATE = 90000;

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class H264Packetizer {
  final RtpState state;

  H264Packetizer(Map<String, dynamic> opts) : state = createRtpState(opts);

  List<Buffer> packetize(Map<String, dynamic> chunk) {
    final data = toBuffer(chunk['data'])!;
    final timestamp = usToRtp(chunk['timestamp'], H264_CLOCK_RATE);

    final nalus = _splitNALUs(data);
    if (nalus.isEmpty) return const [];

    final List<Buffer> out = [];

    for (int i = 0; i < nalus.length; i++) {
      final nalu = nalus[i];
      final isLast = i == nalus.length - 1;

      if (nalu.length <= state.mtu) {
        out.add(makePacket(state, nalu, timestamp, isLast, false) as Buffer);
      } else {
        _fragmentFUA(nalu, timestamp, isLast, out);
      }
    }

    return out;
  }

  // ✅ FIXED: use Buffer ONLY (no Uint8List here)
  void _fragmentFUA(Buffer nalu, int rtpTs, bool isLastNalu, List<Buffer> out) {
    final naluHeader = nalu[0];
    final nri = (naluHeader >> 5) & 0x03;
    final naluType = naluHeader & 0x1F;

    final fuIndicator = (nri << 5) | 28;

    final maxPayload = state.mtu - 2;
    int offset = 1;

    while (offset < nalu.length) {
      final remaining = nalu.length - offset;
      final size = remaining > maxPayload ? maxPayload : remaining;

      final start = offset == 1;
      final end = (offset + size) >= nalu.length;

      final fuHeader = (start ? 0x80 : 0) | (end ? 0x40 : 0) | naluType;

      final pkt = makePacketWithPrefix(
        state,
        fuIndicator,
        fuHeader,
        0,
        0,
        2,
        nalu,
        offset,
        size,
        rtpTs,
        end && isLastNalu,
      );

      out.add(pkt);

      offset += size;
    }
  }

  // ✅ FIXED: return Buffer, not Uint8List
  List<Buffer> _splitNALUs(Buffer buf) {
    final data = buf.subarray(0);

    final List<Buffer> nalus = [];
    int start = -1;

    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 0 &&
          data[i + 1] == 0 &&
          (data[i + 2] == 1 || (data[i + 2] == 0 && data[i + 3] == 1))) {
        if (start != -1 && i > start) {
          nalus.add(
            Buffer.from(data.buffer, data.offsetInBytes + start, i - start),
          );
        }

        start = (data[i + 2] == 1) ? i + 3 : i + 4;
      }
    }

    if (start != -1 && start < data.length) {
      nalus.add(
        Buffer.from(
          data.buffer,
          data.offsetInBytes + start,
          data.length - start,
        ),
      );
    }

    return nalus;
  }
}

// ═══════════════════════════════════════════════════════════════════
// Depacketizer
// ═══════════════════════════════════════════════════════════════════

class H264Depacketizer {
  void Function(Map<String, dynamic>)? _output;
  void Function(Object)? _error;

  final List<Uint8List> _nalus = [];
  List<Uint8List> _fuFragments = [];

  bool _sawIDR = false;

  H264Depacketizer(Map<String, dynamic> opts) {
    _output = opts['output'];
    _error = opts['error'];
  }

  void depacketize(Map<String, dynamic> packet) {
    final payload = packet['payload'] as Uint8List;
    final type = payload[0] & 0x1F;

    if (type >= 1 && type <= 23) {
      _nalus.add(payload);
      if (type == 5) _sawIDR = true;
    } else if (type == 28) {
      if (payload.length < 2) return;

      final fuHeader = payload[1];
      final start = (fuHeader & 0x80) != 0;
      final end = (fuHeader & 0x40) != 0;

      if (start) {
        _fuFragments = [];

        final reconstructed = Uint8List(1);
        reconstructed[0] = (payload[0] & 0x60) | (fuHeader & 0x1F);

        _fuFragments.add(reconstructed);
      }

      _fuFragments.add(payload.sublist(2));

      if (end) {
        final full = _concat(_fuFragments);
        _nalus.add(full);

        if ((full[0] & 0x1F) == 5) _sawIDR = true;

        _fuFragments = [];
      }
    }

    // ✅ Frame output triggered by marker bit
    if (packet['marker'] == true && _nalus.isNotEmpty) {
      final frame = _joinAnnexB(_nalus);

      _output?.call({
        'data': frame,
        'timestamp': packet['timestamp'],
        'type': _sawIDR ? 'key' : 'delta',
      });

      _nalus.clear();
      _sawIDR = false;
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

  Uint8List _joinAnnexB(List<Uint8List> nalus) {
    int size = nalus.fold(0, (s, n) => s + n.length + 4);

    final out = Uint8List(size);
    int offset = 0;

    for (final n in nalus) {
      out.setAll(offset, [0, 0, 0, 1]);
      offset += 4;

      out.setRange(offset, offset + n.length, n);
      offset += n.length;
    }

    return out;
  }
}

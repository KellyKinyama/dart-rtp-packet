import 'dart:typed_data';
import 'rtp.dart';

const int VP9_CLOCK_RATE = 90000;

class VP9Packetizer {
  final RtpState state;

  VP9Packetizer(Map<String, dynamic> opts) : state = createRtpState(opts);

  List<Buffer> packetize(Map<String, dynamic> chunk) {
    final data = toBuffer(chunk['data'])!;
    final rtpTs = usToRtp(chunk['timestamp'], VP9_CLOCK_RATE);

    final maxPayload = state.mtu - 1;

    // ✅ P bit (key vs delta)
    final P = (chunk['type'] == 'delta') ? 0x40 : 0;

    // ✅ SINGLE PACKET
    if (data.length <= maxPayload) {
      return [
        makePacketWithPrefix(
          state,
          P | 0x08 | 0x04, // P + B + E
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

    // ✅ FRAGMENTED
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

class VP9Depacketizer {
  void Function(Map<String, dynamic>)? _output;
  void Function(Object)? _error;

  List<Uint8List> _fragments = [];

  VP9Depacketizer(Map<String, dynamic> opts) {
    _output = opts['output'];
    _error = opts['error'];
  }

  void depacketize(Map<String, dynamic> packet) {
    final payload = packet['payload'] as Uint8List;

    if (payload.isEmpty) {
      _emitError(Exception("VP9Depacketizer: empty payload"));
      return;
    }

    final desc = payload[0];
    final B = (desc & 0x08) != 0;
    final E = (desc & 0x04) != 0;

    int hdrLen = 1;

    if (hdrLen >= payload.length) {
      _emitError(Exception("VP9Depacketizer: invalid header"));
      return;
    }

    final data = payload.sublist(hdrLen);

    if (B) {
      _fragments = [data];
    } else {
      _fragments.add(data);
    }

    if (E || packet['marker'] == true) {
      if (_fragments.isEmpty) return;

      final frame = _concat(_fragments);
      _fragments = [];

      // ✅ simple keyframe detection
      bool isKey = false;
      if (frame.isNotEmpty) {
        final fm = (frame[0] >> 6) & 3;
        if (fm == 2) {
          isKey = true;
        }
      }

      _output?.call({
        'data': frame,
        'timestamp': packet['timestamp'],
        'type': isKey ? 'key' : 'delta',
      });
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

  void _emitError(Object err) {
    _error?.call(err);
  }
}

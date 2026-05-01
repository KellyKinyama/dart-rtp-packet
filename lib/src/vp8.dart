import 'dart:typed_data';
import 'rtp.dart';

const int VP8_CLOCK_RATE = 90000;

class VP8Packetizer {
  final RtpState state;

  VP8Packetizer(Map<String, dynamic> opts) : state = createRtpState(opts);

  List<Buffer> packetize(Map<String, dynamic> chunk) {
    final data = toBuffer(chunk['data'])!;
    final rtpTs = usToRtp(chunk['timestamp'], VP8_CLOCK_RATE);

    final maxPayload = state.mtu - 1; // minus 1-byte VP8 header

    // ✅ SINGLE PACKET
    if (data.length <= maxPayload) {
      return [
        makePacketWithPrefix(
          state,
          0x10, // S bit = start of partition
          0,
          0,
          0,
          1,
          data,
          0,
          data.length,
          rtpTs,
          true, // marker → end of frame
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

class VP8Depacketizer {
  void Function(Map<String, dynamic>)? _output;
  void Function(Object)? _error;

  List<Uint8List> _fragments = [];

  VP8Depacketizer(Map<String, dynamic> opts) {
    _output = opts['output'];
    _error = opts['error'];
  }

  void depacketize(Map<String, dynamic> packet) {
    final payload = packet['payload'] as Uint8List;

    if (payload.isEmpty) {
      _emitError(Exception("VP8Depacketizer: empty payload"));
      return;
    }

    final S = (payload[0] & 0x10) != 0;
    final X = (payload[0] & 0x80) != 0;

    int hdrLen = 1;

    // ✅ handle extended header
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
      _emitError(Exception("VP8Depacketizer: invalid header"));
      return;
    }

    final data = payload.sublist(hdrLen);

    if (S) {
      _fragments = [data];
    } else {
      _fragments.add(data);
    }

    // ✅ FRAME COMPLETE
    if (packet['marker'] == true && _fragments.isNotEmpty) {
      final frame = _concat(_fragments);

      _fragments = [];

      final isKey = (frame[0] & 0x01) == 0;

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

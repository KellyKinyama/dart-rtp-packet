import 'dart:typed_data';

import 'rtp.dart';

const int CLOCK_RATE = 90000;

class AV1Packetizer {
  final RtpState state;
  final int mtu;

  AV1Packetizer(Map<String, dynamic> opts)
    : state = createRtpState(opts),
      mtu = opts['mtu'] ?? 1400;

  List<Buffer> packetize(Map<String, dynamic> chunk) {
    _validateChunk(chunk);
    return _packetize(chunk);
  }

  void close() {}

  void _validateChunk(Map chunk) {
    if (chunk['data'] == null || chunk['timestamp'] == null) {
      throw Exception("AV1: invalid chunk");
    }
  }

  List<Buffer> _packetize(Map<String, dynamic> chunk) {
    final data = _toBuffer(chunk['data']);
    final rtpTs = usToRtp(chunk['timestamp'], CLOCK_RATE);

    final isKey = chunk['type'] == 'key';

    final maxPayload = mtu - 1;

    // ✅ SINGLE PACKET
    if (data.length <= maxPayload) {
      return [
        makePacketWithPrefix(
          state,
          isKey ? 0x08 : 0x00, // N bit
          0,
          0,
          0,
          1, // prefix length
          data,
          0,
          data.length,
          rtpTs,
          true,
        ),
      ];
    }

    // ✅ FRAGMENTATION
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

      if (!isFirst) header |= 0x80; // Z
      if (!isLast) header |= 0x40; // Y
      if (isFirst && isKey) header |= 0x08; // N

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

class AV1Depacketizer {
  void Function(Map<String, dynamic>)? _output;
  void Function(Object)? _error;

  List<Uint8List> _fragments = [];
  bool _isKey = false;

  AV1Depacketizer(Map<String, dynamic> opts) {
    _output = opts['output'];
    _error = opts['error'];
  }

  static bool peekKeyframe(Uint8List payload) {
    if (payload.isEmpty) return false;

    final hdr = payload[0];

    final Z = (hdr & 0x80) != 0;
    final N = (hdr & 0x08) != 0;

    return !Z && N;
  }

  void depacketize(Map<String, dynamic> packet) {
    final payload = packet['payload'] as Uint8List;

    if (payload.isEmpty) {
      _emitError("AV1: empty payload");
      return;
    }

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

    if (!Y || packet['marker'] == true) {
      if (_fragments.isEmpty) return;

      Uint8List frame;

      if (_fragments.length == 1) {
        frame = _fragments[0];
      } else {
        frame = _concat(_fragments);
      }

      _output?.call({
        'data': frame,
        'timestamp': packet['timestamp'],
        'type': _isKey ? 'key' : 'delta',
      });

      _fragments = [];
      _isKey = false;
    }
  }
}

void _emitError(Object err) {
  /* optional */
}

Buffer _toBuffer(dynamic d) {
  if (d is Buffer) return d;

  if (d is Uint8List) {
    return Buffer.from(d.buffer, d.offsetInBytes, d.length);
  }

  throw Exception("Invalid AV1 buffer");
}

Uint8List _concat(List<Uint8List> parts) {
  int total = 0;
  for (final p in parts) total += p.length;

  final out = Uint8List(total);
  int offset = 0;

  for (final p in parts) {
    out.setRange(offset, offset + p.length, p);
    offset += p.length;
  }

  return out;
}

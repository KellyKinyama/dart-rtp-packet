import 'dart:typed_data';

import 'rtp.dart';

// =============================
// CONSTANTS
// =============================

const int AU_HEADER_BITS = 16;
const int AU_HEADER_BYTES = 2;
const int AU_HEADERS_LENGTH_PREFIX_BYTES = 2;

const int MAX_AU_SIZE = (1 << 13) - 1;

const int DEFAULT_CLOCK_RATE = 48000;

// =============================
// PACKETIZER
// =============================

class AacPacketizer {
  final RtpState state;
  final int mtu;
  final int clockRate;

  AacPacketizer(Map<String, dynamic> opts)
    : state = createRtpState(opts),
      mtu = opts['mtu'] ?? 1400,
      clockRate = opts['clockRate'] ?? DEFAULT_CLOCK_RATE;

  List<Buffer> packetize(Map<String, dynamic> chunk) {
    _validate(chunk);
    return _packetize(chunk);
  }

  void close() {}

  void _validate(Map chunk) {
    if (chunk['data'] == null || chunk['timestamp'] == null) {
      throw Exception("AAC: invalid chunk");
    }
  }

  List<Buffer> _packetize(Map<String, dynamic> chunk) {
    final data = _toBuffer(chunk['data']);

    if (data.length == 0) return [];

    final rtpTs = usToRtp(chunk['timestamp'], clockRate);

    final headerOverhead = AU_HEADERS_LENGTH_PREFIX_BYTES + AU_HEADER_BYTES;

    final maxFragSize = mtu - headerOverhead;

    // ✅ SINGLE PACKET
    if (data.length <= maxFragSize) {
      return [_buildSinglePacket(data, rtpTs, true)];
    }

    // ✅ FRAGMENTATION
    final out = <Buffer>[];

    int offset = 0;
    final total = data.length;

    while (offset < total) {
      final size = (total - offset > maxFragSize)
          ? maxFragSize
          : total - offset;

      final u8 = data.subarray(offset, offset + size);

      // ✅ FIX: convert slice → Buffer
      final frag = Buffer.from(u8.buffer, u8.offsetInBytes, u8.length);

      final isLast = (offset + size == total);

      out.add(_buildFragmentPacket(frag, total, rtpTs, isLast));

      offset += size;
    }

    return out;
  }

  Buffer _buildSinglePacket(Buffer auData, int rtpTs, bool marker) {
    final auSize = auData.length & MAX_AU_SIZE;

    final payload = Buffer.allocUnsafe(2 + 2 + auData.length);

    payload.writeUInt16BE(AU_HEADER_BITS, 0);
    payload.writeUInt16BE((auSize << 3) & 0xFFFF, 2);

    auData.copy(payload, 4);

    return makePacket(state, payload, rtpTs, marker, false);
  }

  Buffer _buildFragmentPacket(
    Buffer fragData,
    int totalAuSize,
    int rtpTs,
    bool isLast,
  ) {
    final auSize = totalAuSize & MAX_AU_SIZE;

    final payload = Buffer.allocUnsafe(2 + 2 + fragData.length);

    payload.writeUInt16BE(AU_HEADER_BITS, 0);
    payload.writeUInt16BE((auSize << 3) & 0xFFFF, 2);

    fragData.copy(payload, 4);

    // ✅ FIX: use isLast instead of marker
    return makePacket(state, payload, rtpTs, isLast, false);
  }
}

// =============================
// DEPACKETIZER
// =============================

class AacDepacketizer {
  void Function(Map<String, dynamic>)? _output;
  void Function(Object)? _error;

  int constantDuration;

  List<Uint8List>? _fragments;
  int _expectedSize = 0;
  int _fragmentTimestamp = 0;
  int _receivedSize = 0;

  AacDepacketizer(Map<String, dynamic> opts)
    : constantDuration = opts['constantDuration'] ?? 1024 {
    _output = opts['output'];
    _error = opts['error'];
  }

  static bool peekKeyframe() => false;

  void depacketize(Map<String, dynamic> packet) {
    final payload = packet['payload'] as Uint8List;

    if (payload.length < 2) {
      _emitError("AAC payload too small");
      return;
    }

    final buf = Buffer.from(
      payload.buffer,
      payload.offsetInBytes,
      payload.length,
    );

    final auHeadersBits = buf.readUInt16BE(0);
    final auHeadersBytes = (auHeadersBits + 7) >> 3;

    final auHeadersStart = 2;
    final auHeadersEnd = auHeadersStart + auHeadersBytes;

    if (auHeadersEnd > buf.length) {
      _emitError("AAC headers overflow");
      return;
    }

    if (auHeadersBits % AU_HEADER_BITS != 0) {
      _emitError("AAC not hbr mode");
      return;
    }

    final numAUs = auHeadersBits ~/ AU_HEADER_BITS;

    final auDataStart = auHeadersEnd;

    final headers = <Map<String, int>>[];

    for (int i = 0; i < numAUs; i++) {
      final word = buf.readUInt16BE(auHeadersStart + i * 2);

      headers.add({'size': (word >> 3) & MAX_AU_SIZE});
    }

    if (numAUs == 1) {
      final size = headers[0]['size']!;
      final available = buf.length - auDataStart;

      if (available < size) {
        _handleFragment(
          buf,
          auDataStart,
          available,
          size,
          packet['timestamp'],
          packet['marker'],
        );
        return;
      }

      _reset();

      _output?.call({
        'data': payload.sublist(auDataStart, auDataStart + size),
        'timestamp': packet['timestamp'],
        'type': 'key',
      });

      return;
    }

    // ✅ MULTI-AU
    _reset();

    int dataOffset = auDataStart;
    int ts = packet['timestamp'];

    for (final h in headers) {
      final size = h['size']!;

      if (dataOffset + size > buf.length) {
        _emitError("AAC overflow");
        return;
      }

      _output?.call({
        'data': payload.sublist(dataOffset, dataOffset + size),
        'timestamp': ts,
        'type': 'key',
      });

      dataOffset += size;
      ts += constantDuration;
    }
  }

  void _handleFragment(
    Buffer buf,
    int start,
    int fragSize,
    int totalSize,
    int ts,
    bool marker,
  ) {
    if (_fragments == null || _expectedSize != totalSize) {
      _fragments = [];
      _expectedSize = totalSize;
      _fragmentTimestamp = ts;
      _receivedSize = 0;
    }

    final frag = buf.subarray(start, start + fragSize);

    _fragments!.add(frag);
    _receivedSize += fragSize;

    if (marker) {
      if (_receivedSize != _expectedSize) {
        _emitError("AAC fragment mismatch");
        _reset();
        return;
      }

      final out = _concat(_fragments!);

      _output?.call({
        'data': out,
        'timestamp': _fragmentTimestamp,
        'type': 'key',
      });

      _reset();
    }
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

  void _reset() {
    _fragments = null;
    _expectedSize = 0;
    _receivedSize = 0;
    _fragmentTimestamp = 0;
  }

  void _emitError(Object err) {
    _error?.call(err);
  }

  void reset() => _reset();

  void close() {
    _reset();
    _output = null;
    _error = null;
  }
}

// =============================
// HELPERS
// =============================

Buffer _toBuffer(dynamic d) {
  if (d is Buffer) return d;

  if (d is Uint8List) {
    return Buffer.from(d.buffer, d.offsetInBytes, d.length);
  }

  throw Exception("Invalid AAC buffer");
}

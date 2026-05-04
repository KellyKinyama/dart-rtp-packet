import 'dart:typed_data';

const int RTP_VERSION = 2;
const int RTP_HEADER_SIZE = 12;
const int DEFAULT_MTU = 1400;
const int PROFILE_ONE_BYTE = 0xBEDE;

final Buffer EMPTY_BUF = Buffer.fromList(const []);

// ═══════════════════════════════════════════════════════════════════
// Buffer
// ═══════════════════════════════════════════════════════════════════

class Buffer {
  final Uint8List _bytes;

  Buffer._(this._bytes);

  int get length => _bytes.length;

  int operator [](int i) => _bytes[i];
  void operator []=(int i, int v) => _bytes[i] = v & 0xFF;

  Uint8List subarray(int start, [int? end]) {
    return Uint8List.sublistView(_bytes, start, end);
  }

  void copy(
    Buffer target,
    int targetStart, [
    int? sourceStart,
    int? sourceEnd,
  ]) {
    final sStart = sourceStart ?? 0;
    final sEnd = sourceEnd ?? length;

    target._bytes.setRange(
      targetStart,
      targetStart + (sEnd - sStart),
      _bytes,
      sStart,
    );
  }

  static Buffer allocUnsafe(int length) {
    return Buffer._(Uint8List(length));
  }

  static Buffer from(ByteBuffer buffer, int byteOffset, int byteLength) {
    return Buffer._(Uint8List.view(buffer, byteOffset, byteLength));
  }

  static Buffer fromList(List<int> bytes) {
    return Buffer._(Uint8List.fromList(bytes));
  }

  int readUInt16BE(int offset) {
    return (_bytes[offset] << 8) | _bytes[offset + 1];
  }

  int readUInt32BE(int offset) {
    return (_bytes[offset] << 24) |
        (_bytes[offset + 1] << 16) |
        (_bytes[offset + 2] << 8) |
        _bytes[offset + 3];
  }

  void writeUInt16BE(int value, int offset) {
    _bytes[offset] = (value >> 8) & 0xFF;
    _bytes[offset + 1] = value & 0xFF;
  }

  void writeUInt32BE(int value, int offset) {
    _bytes[offset] = (value >> 24) & 0xFF;
    _bytes[offset + 1] = (value >> 16) & 0xFF;
    _bytes[offset + 2] = (value >> 8) & 0xFF;
    _bytes[offset + 3] = value & 0xFF;
  }

  void writeInt16BE(int value, int offset) {
    // convert to signed 16-bit two’s complement
    int v = value & 0xFFFF;

    _bytes[offset] = (v >> 8) & 0xFF;
    _bytes[offset + 1] = v & 0xFF;
  }

  int readInt16BE(int offset) {
    int value = (_bytes[offset] << 8) | _bytes[offset + 1];

    // ✅ convert from signed 16-bit (two's complement)
    if ((value & 0x8000) != 0) {
      value = value - 0x10000;
    }

    return value;
  }

  void setRange(int start, int end, Uint8List data) {
    for (int i = 0; i < data.length; i++) {
      _bytes[start + i] = data[i];
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════

Buffer? toBuffer(Object? b) {
  if (b == null) return null;
  if (b is Buffer) return b;
  if (b is Uint8List) {
    return Buffer.from(b.buffer, b.offsetInBytes, b.lengthInBytes);
  }
  throw ArgumentError('Expected Buffer or Uint8List');
}

int usToRtp(int us, int clockRate) {
  return ((us * clockRate) ~/ 1000000) & 0xFFFFFFFF;
}

// ═══════════════════════════════════════════════════════════════════
// Typed Configuration
// ═══════════════════════════════════════════════════════════════════

/// RFC 3550 compliant RTP packetizer configuration.
class RtpPacketizerConfig {
  final int ssrc;
  final int payloadType;
  final int mtu;
  final int? initialSequenceNumber;

  const RtpPacketizerConfig({
    required this.ssrc,
    required this.payloadType,
    this.mtu = DEFAULT_MTU,
    this.initialSequenceNumber,
  });

  /// Validate and return sanitized config.
  RtpPacketizerConfig validate() {
    if (payloadType < 0 || payloadType > 127) {
      throw ArgumentError('payloadType must be 0–127 (RFC 3551)');
    }
    if (mtu < 100 || mtu > 65535) {
      throw ArgumentError('mtu must be 100–65535');
    }
    return RtpPacketizerConfig(
      ssrc: ssrc & 0xFFFFFFFF,
      payloadType: payloadType & 0x7F,
      mtu: mtu,
      initialSequenceNumber: initialSequenceNumber,
    );
  }
}

/// Typed media chunk for all packetizers (replaces map-based chunk).
class MediaChunk {
  final Uint8List data;
  final int timestampUs;

  const MediaChunk({required this.data, required this.timestampUs});
}

/// Generic depacketizer callbacks (codecs parameterize T with their frame type).
class RtpDepacketizerCallbacks<T> {
  final void Function(T frame)? onFrame;
  final void Function(Object error, [StackTrace? st])? onError;

  const RtpDepacketizerCallbacks({this.onFrame, this.onError});
}

// ═══════════════════════════════════════════════════════════════════
// RTP STATE
// ═══════════════════════════════════════════════════════════════════

class RtpState {
  int ssrc;
  int payloadType;
  int mtu;
  int seq;

  RtpState._({
    required this.ssrc,
    required this.payloadType,
    required this.mtu,
    required this.seq,
  });

  /// Factory from typed config (RFC 3550 §5.1 initial sequence).
  factory RtpState.fromConfig(RtpPacketizerConfig config) {
    final validated = config.validate();
    final initialSeq =
        validated.initialSequenceNumber ??
        (DateTime.now().millisecondsSinceEpoch & 0xFFFF);
    return RtpState._(
      ssrc: validated.ssrc,
      payloadType: validated.payloadType,
      mtu: validated.mtu,
      seq: initialSeq & 0xFFFF,
    );
  }

  /// Legacy map-based constructor (deprecated, use fromConfig).
  @Deprecated('Use RtpState.fromConfig(RtpPacketizerConfig) instead')
  factory RtpState.fromMap(Map<String, dynamic> opts) {
    return RtpState.fromConfig(
      RtpPacketizerConfig(
        ssrc: opts['ssrc'] ?? (throw ArgumentError('ssrc required')),
        payloadType:
            opts['payloadType'] ??
            (throw ArgumentError('payloadType required')),
        mtu: opts['mtu'] ?? DEFAULT_MTU,
        initialSequenceNumber: opts['initialSequenceNumber'],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Packet + Meta
// ═══════════════════════════════════════════════════════════════════

class BufferMeta {
  final Buffer buffer;
  final int sequenceNumber;
  final int timestamp;
  final bool marker;

  BufferMeta({
    required this.buffer,
    required this.sequenceNumber,
    required this.timestamp,
    required this.marker,
  });
}

/// Build RTP packet (RFC 3550 §5.1). Returns buffer only.
Buffer makeRtpPacket(
  RtpState state,
  Buffer? payload,
  int rtpTimestamp,
  bool marker,
) {
  final seq = state.seq;
  final payloadLen = payload?.length ?? 0;

  final buf = Buffer.allocUnsafe(RTP_HEADER_SIZE + payloadLen);

  buf[0] = (RTP_VERSION << 6);
  buf[1] = (marker ? 0x80 : 0) | (state.payloadType & 0x7F);

  buf[2] = (seq >> 8) & 0xFF;
  buf[3] = seq & 0xFF;

  buf[4] = (rtpTimestamp >> 24) & 0xFF;
  buf[5] = (rtpTimestamp >> 16) & 0xFF;
  buf[6] = (rtpTimestamp >> 8) & 0xFF;
  buf[7] = rtpTimestamp & 0xFF;

  buf[8] = (state.ssrc >> 24) & 0xFF;
  buf[9] = (state.ssrc >> 16) & 0xFF;
  buf[10] = (state.ssrc >> 8) & 0xFF;
  buf[11] = state.ssrc & 0xFF;

  if (payloadLen > 0) {
    payload!.copy(buf, RTP_HEADER_SIZE);
  }

  state.seq = (state.seq + 1) & 0xFFFF;

  return buf;
}

/// Build RTP packet with metadata. Returns BufferMeta.
BufferMeta makeRtpPacketWithMeta(
  RtpState state,
  Buffer? payload,
  int rtpTimestamp,
  bool marker,
) {
  final seq = state.seq;
  final buf = makeRtpPacket(state, payload, rtpTimestamp, marker);

  return BufferMeta(
    buffer: buf,
    sequenceNumber: seq,
    timestamp: rtpTimestamp,
    marker: marker,
  );
}

/// Legacy dual-mode function (deprecated, use makeRtpPacket or makeRtpPacketWithMeta).
@Deprecated('Use makeRtpPacket or makeRtpPacketWithMeta')
dynamic makePacket(
  RtpState state,
  Buffer? payload,
  int rtpTimestamp,
  bool marker,
  bool withMeta,
) {
  if (withMeta) {
    // Re-capture seq before increment
    final seq = state.seq;
    final buf = makeRtpPacket(state, payload, rtpTimestamp, marker);
    return BufferMeta(
      buffer: buf,
      sequenceNumber: seq,
      timestamp: rtpTimestamp,
      marker: marker,
    );
  }
  return makeRtpPacket(state, payload, rtpTimestamp, marker);
}

class RtpPacket {
  final int payloadType;
  final int sequenceNumber;
  final int timestamp;
  final int ssrc;
  final Uint8List payload;
  final bool marker;

  RtpPacket({
    required this.payloadType,
    required this.sequenceNumber,
    required this.timestamp,
    required this.ssrc,
    required this.payload,
    required this.marker,
  });
}

RtpPacket? parseRtp(Buffer buf) {
  if (buf.length < RTP_HEADER_SIZE) return null;

  final b0 = buf[0];
  final b1 = buf[1];

  if (((b0 >> 6) & 0x03) != RTP_VERSION) return null;

  final marker = ((b1 >> 7) & 1) == 1;
  final payloadType = b1 & 0x7F;

  final sequenceNumber = buf.readUInt16BE(2);
  final timestamp = buf.readUInt32BE(4);
  final ssrc = buf.readUInt32BE(8);

  final payload = buf.subarray(RTP_HEADER_SIZE);

  return RtpPacket(
    payloadType: payloadType,
    sequenceNumber: sequenceNumber,
    timestamp: timestamp,
    ssrc: ssrc,
    payload: payload,
    marker: marker,
  );
}

Buffer makePacketWithPrefix(
  RtpState state,
  int p0,
  int p1,
  int p2,
  int p3,
  int prefixLen,
  Buffer data,
  int dataStart,
  int dataLen,
  int rtpTimestamp,
  bool marker,
) {
  final seq = state.seq;

  final totalLen = RTP_HEADER_SIZE + prefixLen + dataLen;
  final buf = Buffer.allocUnsafe(totalLen);

  // RTP header
  buf[0] = (RTP_VERSION << 6);
  buf[1] = (marker ? 0x80 : 0) | (state.payloadType & 0x7F);

  buf[2] = (seq >> 8) & 0xFF;
  buf[3] = seq & 0xFF;

  buf[4] = (rtpTimestamp >> 24) & 0xFF;
  buf[5] = (rtpTimestamp >> 16) & 0xFF;
  buf[6] = (rtpTimestamp >> 8) & 0xFF;
  buf[7] = rtpTimestamp & 0xFF;

  buf[8] = (state.ssrc >> 24) & 0xFF;
  buf[9] = (state.ssrc >> 16) & 0xFF;
  buf[10] = (state.ssrc >> 8) & 0xFF;
  buf[11] = state.ssrc & 0xFF;

  // ✅ Prefix (FU-A header etc.)
  if (prefixLen > 0) {
    buf[12] = p0 & 0xFF;
    if (prefixLen > 1) {
      buf[13] = p1 & 0xFF;
      if (prefixLen > 2) {
        buf[14] = p2 & 0xFF;
        if (prefixLen > 3) {
          buf[15] = p3 & 0xFF;
        }
      }
    }
  }

  // ✅ Copy payload
  if (dataLen > 0) {
    data.copy(buf, RTP_HEADER_SIZE + prefixLen, dataStart, dataStart + dataLen);
  }

  // ✅ increment sequence
  state.seq = (state.seq + 1) & 0xFFFF;

  return buf;
}

Buffer setHeaderExtension(Buffer rtpPacket, int id, Buffer data) {
  if (rtpPacket.length < 12) return rtpPacket;

  final cc = rtpPacket[0] & 0x0F;
  final hasExt = (rtpPacket[0] & 0x10) != 0;

  final fixedEnd = RTP_HEADER_SIZE + cc * 4;

  final payload = Buffer.from(
    rtpPacket.subarray(fixedEnd).buffer,
    rtpPacket.subarray(fixedEnd).offsetInBytes,
    rtpPacket.subarray(fixedEnd).length,
  );

  final Map<int, Uint8List> existingExts = {};

  if (hasExt) {
    final profile = rtpPacket.readUInt16BE(fixedEnd);
    if (profile != PROFILE_ONE_BYTE) return rtpPacket;

    final words = rtpPacket.readUInt16BE(fixedEnd + 2);
    final extLen = 4 + words * 4;

    final extStart = fixedEnd + 4;
    final extEnd = fixedEnd + extLen;

    if (extEnd <= rtpPacket.length) {
      existingExts.addAll(
        parseExtensions(rtpPacket.subarray(extStart, extEnd)),
      );
    }
  }

  existingExts[id] = data.subarray(0);

  final newExt = writeExtensions(existingExts);

  final out = Buffer.allocUnsafe(fixedEnd + newExt.length + payload.length);

  rtpPacket.copy(out, 0, 0, fixedEnd);

  out[0] |= 0x10;

  newExt.copy(out, fixedEnd);
  payload.copy(out, fixedEnd + newExt.length);

  return out;
}

Buffer transportCC(int seq) {
  final b = Buffer.allocUnsafe(2);

  b[0] = (seq >> 8) & 0xFF;
  b[1] = seq & 0xFF;

  return b;
}

Buffer absSendTime() {
  final now = DateTime.now().millisecondsSinceEpoch;

  // convert ms → seconds
  final seconds = (now / 1000.0);

  // 6-bit seconds + 18-bit fraction (RFC format)
  final v = ((seconds * (1 << 18)) % (1 << 24)).toInt();

  final b = Buffer.allocUnsafe(3);

  b[0] = (v >> 16) & 0xFF;
  b[1] = (v >> 8) & 0xFF;
  b[2] = v & 0xFF;

  return b;
}

Map<int, Uint8List> parseExtensions(Uint8List extData) {
  final Map<int, Uint8List> out = {};
  int i = 0;

  while (i < extData.length) {
    final b = extData[i];

    if (b == 0) {
      i++;
      continue;
    }

    final id = (b >> 4) & 0x0F;
    final len = (b & 0x0F) + 1;

    if (i + 1 + len > extData.length) break;

    final value = extData.sublist(i + 1, i + 1 + len);

    out[id] = value;

    i += 1 + len;
  }

  return out;
}

Buffer writeExtensions(Map<int, Uint8List> exts) {
  final bytes = <int>[];

  exts.forEach((id, data) {
    if (id < 1 || id > 14) return; // RFC 5285 limits

    final len = data.length;
    if (len == 0 || len > 16) return;

    final header = ((id & 0x0F) << 4) | ((len - 1) & 0x0F);

    bytes.add(header);
    bytes.addAll(data);
  });

  // padding to 32-bit boundary
  while (bytes.length % 4 != 0) {
    bytes.add(0);
  }

  final buffer = Buffer.allocUnsafe(4 + bytes.length);

  // RFC 5285 profile
  buffer.writeUInt16BE(PROFILE_ONE_BYTE, 0);

  // length in 32-bit words
  buffer.writeUInt16BE(bytes.length ~/ 4, 2);

  for (int i = 0; i < bytes.length; i++) {
    buffer[4 + i] = bytes[i];
  }

  return buffer;
}

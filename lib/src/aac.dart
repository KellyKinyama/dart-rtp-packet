import 'dart:typed_data';
import 'rtp.dart';

const int aacClockRate = 48000;
const int auHeaderBits = 16;
const int auHeaderBytes = 2;
const int auHeadersLengthPrefixBytes = 2;
const int maxAuSize = (1 << 13) - 1;

// ═══════════════════════════════════════════════════════════════════
// Typed Output Frame
// ═══════════════════════════════════════════════════════════════════

class AacFrame {
  final Uint8List data;
  final int timestampUs;

  const AacFrame({required this.data, required this.timestampUs});
}

// ═══════════════════════════════════════════════════════════════════
// Typed Config
// ═══════════════════════════════════════════════════════════════════

class AacPacketizerConfig {
  final RtpPacketizerConfig rtpConfig;
  final int clockRate;

  const AacPacketizerConfig({
    required this.rtpConfig,
    this.clockRate = aacClockRate,
  });
}

class AacDepacketizerConfig {
  final RtpDepacketizerCallbacks<AacFrame> callbacks;
  final int constantDuration;

  const AacDepacketizerConfig({
    required this.callbacks,
    this.constantDuration = 1024,
  });
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class AacPacketizer {
  final RtpState state;
  final int clockRate;

  AacPacketizer(AacPacketizerConfig config)
    : state = RtpState.fromConfig(config.rtpConfig),
      clockRate = config.clockRate;

  List<Buffer> packetize(MediaChunk chunk) {
    final data = Buffer.from(
      chunk.data.buffer,
      chunk.data.offsetInBytes,
      chunk.data.lengthInBytes,
    );

    if (data.length == 0) return [];

    final rtpTs = usToRtp(chunk.timestampUs, clockRate);

    final headerOverhead = auHeadersLengthPrefixBytes + auHeaderBytes;

    final maxFragSize = state.mtu - headerOverhead;

    if (data.length <= maxFragSize) {
      return [_buildSinglePacket(data, rtpTs, true)];
    }

    final out = <Buffer>[];

    int offset = 0;
    final total = data.length;

    while (offset < total) {
      final size = (total - offset > maxFragSize)
          ? maxFragSize
          : total - offset;

      final u8 = data.subarray(offset, offset + size);

      final frag = Buffer.from(u8.buffer, u8.offsetInBytes, u8.length);

      final isLast = (offset + size == total);

      out.add(_buildFragmentPacket(frag, total, rtpTs, isLast));

      offset += size;
    }

    return out;
  }

  Buffer _buildSinglePacket(Buffer auData, int rtpTs, bool marker) {
    final auSize = auData.length & maxAuSize;

    final payload = Buffer.allocUnsafe(2 + 2 + auData.length);

    // RFC 3640 §3.2.1: AU-headers-length in bits
    payload.writeUInt16BE(auHeaderBits, 0);
    payload.writeUInt16BE((auSize << 3) & 0xFFFF, 2);

    auData.copy(payload, 4);

    return makeRtpPacket(state, payload, rtpTs, marker);
  }

  Buffer _buildFragmentPacket(
    Buffer fragData,
    int totalAuSize,
    int rtpTs,
    bool isLast,
  ) {
    final auSize = totalAuSize & maxAuSize;

    final payload = Buffer.allocUnsafe(2 + 2 + fragData.length);

    payload.writeUInt16BE(auHeaderBits, 0);
    payload.writeUInt16BE((auSize << 3) & 0xFFFF, 2);

    fragData.copy(payload, 4);

    return makeRtpPacket(state, payload, rtpTs, isLast);
  }
}

// ═══════════════════════════════════════════════════════════════════
// Depacketizer
// ═══════════════════════════════════════════════════════════════════

class AacDepacketizer {
  final RtpDepacketizerCallbacks<AacFrame> _callbacks;
  final int constantDuration;

  List<Uint8List>? _fragments;
  int _expectedSize = 0;
  int _fragmentTimestamp = 0;
  int _receivedSize = 0;

  AacDepacketizer(AacDepacketizerConfig config)
    : _callbacks = config.callbacks,
      constantDuration = config.constantDuration;

  static bool peekKeyframe() => false;

  void depacketize(RtpPacket packet) {
    final payload = packet.payload;

    if (payload.length < 2) {
      _callbacks.onError?.call(Exception('AAC payload too small'));
      return;
    }

    final buf = Buffer.from(
      payload.buffer,
      payload.offsetInBytes,
      payload.length,
    );

    // RFC 3640 §3.2.1: AU-headers-length is in bits
    final auHeadersBits = buf.readUInt16BE(0);
    final auHeadersBytes = (auHeadersBits + 7) >> 3;

    final auHeadersStart = 2;
    final auHeadersEnd = auHeadersStart + auHeadersBytes;

    if (auHeadersEnd > buf.length) {
      _callbacks.onError?.call(Exception('AAC headers overflow'));
      return;
    }

    if (auHeadersBits % auHeaderBits != 0) {
      _callbacks.onError?.call(Exception('AAC not hbr mode'));
      return;
    }

    final numAUs = auHeadersBits ~/ auHeaderBits;

    final auDataStart = auHeadersEnd;

    final headers = <Map<String, int>>[];

    for (int i = 0; i < numAUs; i++) {
      final word = buf.readUInt16BE(auHeadersStart + i * 2);

      headers.add({'size': (word >> 3) & maxAuSize});
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
          packet.timestamp,
          packet.marker,
        );
        return;
      }

      _reset();

      try {
        _callbacks.onFrame?.call(
          AacFrame(
            data: payload.sublist(auDataStart, auDataStart + size),
            timestampUs: (packet.timestamp * 1000000) ~/ aacClockRate,
          ),
        );
      } catch (e, st) {
        _callbacks.onError?.call(e, st);
      }

      return;
    }

    _reset();

    int dataOffset = auDataStart;
    int ts = packet.timestamp;

    for (final h in headers) {
      final size = h['size']!;

      if (dataOffset + size > buf.length) {
        _callbacks.onError?.call(Exception('AAC overflow'));
        return;
      }

      try {
        _callbacks.onFrame?.call(
          AacFrame(
            data: payload.sublist(dataOffset, dataOffset + size),
            timestampUs: (ts * 1000000) ~/ aacClockRate,
          ),
        );
      } catch (e, st) {
        _callbacks.onError?.call(e, st);
      }

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
        _callbacks.onError?.call(Exception('AAC fragment mismatch'));
        _reset();
        return;
      }

      final out = _concat(_fragments!);

      try {
        _callbacks.onFrame?.call(
          AacFrame(
            data: out,
            timestampUs: (_fragmentTimestamp * 1000000) ~/ aacClockRate,
          ),
        );
      } catch (e, st) {
        _callbacks.onError?.call(e, st);
      }

      _reset();
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

  void _reset() {
    _fragments = null;
    _expectedSize = 0;
    _receivedSize = 0;
    _fragmentTimestamp = 0;
  }
}

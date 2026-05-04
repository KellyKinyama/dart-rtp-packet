import 'dart:typed_data';
import 'rtp.dart';

const int h264ClockRate = 90000;

// ═══════════════════════════════════════════════════════════════════
// H.264 NAL Unit Types (RFC 6184 §5.2 Table 1)
// ═══════════════════════════════════════════════════════════════════

enum H264NaluType {
  unspecified(0),
  nonIdrSlice(1),
  partitionA(2),
  partitionB(3),
  partitionC(4),
  idrSlice(5),
  sei(6),
  sps(7),
  pps(8),
  accessUnitDelimiter(9),
  endOfSequence(10),
  endOfStream(11),
  fillerData(12),
  spsExtension(13),
  prefix(14),
  subsetSps(15),
  auxiliarySlice(19),
  sliceExtension(20),
  sliceExtensionDepth(21),
  stapA(24),
  stapB(25),
  mtap16(26),
  mtap24(27),
  fuA(28),
  fuB(29);

  final int value;
  const H264NaluType(this.value);

  static H264NaluType fromByte(int b) {
    final type = b & 0x1F;
    return H264NaluType.values.firstWhere(
      (e) => e.value == type,
      orElse: () => H264NaluType.unspecified,
    );
  }

  bool get isKeyframe => this == H264NaluType.idrSlice;
}

// ═══════════════════════════════════════════════════════════════════
// Typed Output Frame
// ═══════════════════════════════════════════════════════════════════

class H264Frame {
  final Uint8List annexB;
  final int timestampUs;
  final bool keyFrame;

  const H264Frame({
    required this.annexB,
    required this.timestampUs,
    required this.keyFrame,
  });
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class H264Packetizer {
  final RtpState state;

  H264Packetizer(RtpPacketizerConfig config)
    : state = RtpState.fromConfig(config);

  @Deprecated('Use H264Packetizer(RtpPacketizerConfig) instead')
  H264Packetizer.fromMap(Map<String, dynamic> opts)
    : state = RtpState.fromMap(opts);

  List<Buffer> packetize(MediaChunk chunk) {
    final data = Buffer.from(
      chunk.data.buffer,
      chunk.data.offsetInBytes,
      chunk.data.lengthInBytes,
    );
    final timestamp = usToRtp(chunk.timestampUs, h264ClockRate);

    final nalus = _splitNALUs(data);
    if (nalus.isEmpty) return const [];

    final List<Buffer> out = [];

    for (int i = 0; i < nalus.length; i++) {
      final nalu = nalus[i];
      final isLast = i == nalus.length - 1;

      if (nalu.length <= state.mtu) {
        out.add(makeRtpPacket(state, nalu, timestamp, isLast));
      } else {
        _fragmentFUA(nalu, timestamp, isLast, out);
      }
    }

    return out;
  }

  @Deprecated('Use packetize(MediaChunk) instead')
  List<Buffer> packetizeMap(Map<String, dynamic> chunk) {
    final data = chunk['data'];
    final Uint8List bytes;
    if (data is Buffer) {
      bytes = data.subarray(0);
    } else if (data is Uint8List) {
      bytes = data;
    } else {
      bytes = Uint8List(0);
    }
    return packetize(
      MediaChunk(data: bytes, timestampUs: chunk['timestamp'] as int? ?? 0),
    );
  }

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
  final RtpDepacketizerCallbacks<H264Frame> _callbacks;

  final List<Uint8List> _nalus = [];
  List<Uint8List> _fuFragments = [];

  bool _sawIDR = false;
  int _lastTimestamp = 0;

  H264Depacketizer(RtpDepacketizerCallbacks<H264Frame> callbacks)
    : _callbacks = callbacks;

  @Deprecated('Use H264Depacketizer(RtpDepacketizerCallbacks) instead')
  H264Depacketizer.fromMap(Map<String, dynamic> opts)
    : _callbacks = RtpDepacketizerCallbacks<H264Frame>(
        onFrame: opts['output'] != null
            ? (frame) => opts['output']!({
                'data': frame.annexB,
                'timestamp': frame.timestampUs,
                'type': frame.keyFrame ? 'key' : 'delta',
              })
            : null,
        onError: opts['error'],
      );

  void depacketize(RtpPacket packet) {
    final payload = packet.payload;
    if (payload.isEmpty) return;

    final type = H264NaluType.fromByte(payload[0]);

    _lastTimestamp = packet.timestamp;

    if (type.value >= 1 && type.value <= 23) {
      _nalus.add(payload);
      if (type.isKeyframe) _sawIDR = true;
    } else if (type == H264NaluType.fuA) {
      if (payload.length < 2) return;

      final fuHeader = payload[1];
      final start = (fuHeader & 0x80) != 0;
      final end = (fuHeader & 0x40) != 0;

      if (start) {
        _fuFragments = [];

        // RFC 6184 §5.8: reconstruct NAL header from FU indicator (F|NRI) and FU header (Type).
        final reconstructed = Uint8List(1);
        reconstructed[0] = (payload[0] & 0xE0) | (fuHeader & 0x1F);

        _fuFragments.add(reconstructed);
      }

      _fuFragments.add(payload.sublist(2));

      if (end) {
        final full = _concat(_fuFragments);
        _nalus.add(full);

        if (H264NaluType.fromByte(full[0]).isKeyframe) _sawIDR = true;

        _fuFragments = [];
      }
    }

    if (packet.marker && _nalus.isNotEmpty) {
      final frame = H264Frame(
        annexB: _joinAnnexB(_nalus),
        timestampUs: (_lastTimestamp * 1000000) ~/ h264ClockRate,
        keyFrame: _sawIDR,
      );

      try {
        _callbacks.onFrame?.call(frame);
      } catch (e, st) {
        _callbacks.onError?.call(e, st);
      }

      _nalus.clear();
      _sawIDR = false;
    }
  }

  @Deprecated('Use depacketize(RtpPacket) instead')
  void depacketizeMap(Map<String, dynamic> packet) {
    depacketize(
      RtpPacket(
        payloadType: packet['payloadType'] ?? 0,
        sequenceNumber: packet['sequenceNumber'] ?? 0,
        timestamp: packet['timestamp'] ?? 0,
        ssrc: packet['ssrc'] ?? 0,
        payload: packet['payload'] ?? Uint8List(0),
        marker: packet['marker'] ?? false,
      ),
    );
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

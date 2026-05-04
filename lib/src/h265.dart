import 'dart:typed_data';
import 'rtp.dart';

const int h265ClockRate = 90000;

// ═══════════════════════════════════════════════════════════════════
// H.265 NAL Unit Types (RFC 7798 §1.1.4 Table 1)
// ═══════════════════════════════════════════════════════════════════

enum H265NaluType {
  trailN(0),
  trailR(1),
  tsaN(2),
  tsaR(3),
  stsaN(4),
  stsaR(5),
  radlN(6),
  radlR(7),
  raslN(8),
  raslR(9),
  blaN(16),
  blaR(17),
  blaWRadl(18),
  idrWRadl(19),
  idrNLp(20),
  craNut(21),
  vpsNut(32),
  spsNut(33),
  ppsNut(34),
  accessUnitDelimiter(35),
  eosNut(36),
  eobNut(37),
  fillerData(38),
  suffixSei(39),
  prefixSei(40),
  aggregationPacket(48),
  fragmentationUnit(49),
  paciPacket(50);

  final int value;
  const H265NaluType(this.value);

  static H265NaluType fromByte(int b) {
    final type = (b >> 1) & 0x3F;
    return H265NaluType.values.firstWhere(
      (e) => e.value == type,
      orElse: () => H265NaluType.trailN,
    );
  }

  bool get isKeyframe =>
      this == H265NaluType.idrWRadl || this == H265NaluType.idrNLp;
}

// ═══════════════════════════════════════════════════════════════════
// Typed Output Frame
// ═══════════════════════════════════════════════════════════════════

class H265Frame {
  final Uint8List annexB;
  final int timestampUs;
  final bool keyFrame;

  const H265Frame({
    required this.annexB,
    required this.timestampUs,
    required this.keyFrame,
  });
}

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class H265Packetizer {
  final RtpState state;

  H265Packetizer(RtpPacketizerConfig config)
    : state = RtpState.fromConfig(config);

  List<Buffer> packetize(MediaChunk chunk) {
    final data = Buffer.from(
      chunk.data.buffer,
      chunk.data.offsetInBytes,
      chunk.data.lengthInBytes,
    );
    final rtpTs = usToRtp(chunk.timestampUs, h265ClockRate);

    final nalus = _splitNALUs(data);
    if (nalus.isEmpty) return const [];

    final List<Buffer> out = [];

    for (int i = 0; i < nalus.length; i++) {
      final nalu = nalus[i];
      final isLast = i == nalus.length - 1;

      if (nalu.length <= state.mtu) {
        out.add(makeRtpPacket(state, nalu, rtpTs, isLast));
      } else {
        _fragmentFU(nalu, rtpTs, isLast, out);
      }
    }

    return out;
  }

  void _fragmentFU(Buffer nalu, int rtpTs, bool isLast, List<Buffer> out) {
    if (nalu.length < 2) return;

    final origHi = nalu[0];
    final origLo = nalu[1];
    final origType = (origHi >> 1) & 0x3F;

    // RFC 7798 §4.4.3: FU payload header (2 bytes) with type = 49
    final fuHdrHi = (origHi & 0x81) | (49 << 1);
    final fuHdrLo = origLo;

    final maxPayload = state.mtu - 3;

    int offset = 2;

    while (offset < nalu.length) {
      final remaining = nalu.length - offset;
      final size = remaining > maxPayload ? maxPayload : remaining;

      final start = offset == 2;
      final end = (offset + size) >= nalu.length;

      final fuByte = (start ? 0x80 : 0) | (end ? 0x40 : 0) | origType;

      out.add(
        makePacketWithPrefix(
          state,
          fuHdrHi,
          fuHdrLo,
          fuByte,
          0,
          3,
          nalu,
          offset,
          size,
          rtpTs,
          end && isLast,
        ),
      );

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

class H265Depacketizer {
  final RtpDepacketizerCallbacks<H265Frame> _callbacks;

  List<Uint8List> _nalus = [];
  List<Uint8List> _fuFragments = [];

  bool _sawIDR = false;
  int _lastTimestamp = 0;

  H265Depacketizer(RtpDepacketizerCallbacks<H265Frame> callbacks)
    : _callbacks = callbacks;

  void depacketize(RtpPacket packet) {
    final payload = packet.payload;

    if (payload.length < 2) {
      _callbacks.onError?.call(Exception('H265: payload too small'));
      return;
    }

    _lastTimestamp = packet.timestamp;

    final naluType = H265NaluType.fromByte(payload[0]);

    if (naluType.value < 48) {
      _nalus.add(payload);

      if (naluType.isKeyframe) {
        _sawIDR = true;
      }
    } else if (naluType == H265NaluType.fragmentationUnit) {
      if (payload.length < 3) return;

      final fuByte = payload[2];
      final start = (fuByte & 0x80) != 0;
      final end = (fuByte & 0x40) != 0;
      final origType = fuByte & 0x3F;

      if (start) {
        // RFC 7798 §4.4.3: reconstruct 2-byte payload header
        final hdrHi = (payload[0] & 0x81) | (origType << 1);
        final hdrLo = payload[1];

        final header = Uint8List(2);
        header[0] = hdrHi;
        header[1] = hdrLo;

        _fuFragments = [header];
      }

      _fuFragments.add(payload.sublist(3));

      if (end) {
        final full = _concat(_fuFragments);
        _nalus.add(full);

        if (H265NaluType.fromByte(full[0]).isKeyframe) {
          _sawIDR = true;
        }

        _fuFragments = [];
      }
    }

    if (packet.marker && _nalus.isNotEmpty) {
      final frame = H265Frame(
        annexB: _joinAnnexB(_nalus),
        timestampUs: (_lastTimestamp * 1000000) ~/ h265ClockRate,
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

  Uint8List _concat(List<Uint8List> parts) {
    int size = parts.fold(0, (s, p) => s + p.length);
    final out = Uint8List(size);

    int off = 0;
    for (var p in parts) {
      out.setRange(off, off + p.length, p);
      off += p.length;
    }

    return out;
  }

  Uint8List _joinAnnexB(List<Uint8List> nalus) {
    int size = nalus.fold(0, (s, n) => s + n.length + 4);

    final out = Uint8List(size);
    int off = 0;

    for (var n in nalus) {
      out.setAll(off, [0, 0, 0, 1]);
      off += 4;
      out.setRange(off, off + n.length, n);
      off += n.length;
    }

    return out;
  }
}

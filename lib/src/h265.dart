import 'dart:typed_data';
import 'rtp.dart';

const int H265_CLOCK_RATE = 90000;

const int NAL_AP = 48;
const int NAL_FU = 49;

class H265Packetizer {
  final RtpState state;

  H265Packetizer(Map<String, dynamic> opts) : state = createRtpState(opts);

  List<Buffer> packetize(Map<String, dynamic> chunk) {
    final data = toBuffer(chunk['data'])!;
    final rtpTs = usToRtp(chunk['timestamp'], H265_CLOCK_RATE);

    final nalus = _splitNALUs(data);
    if (nalus.isEmpty) return const [];

    final List<Buffer> out = [];

    for (int i = 0; i < nalus.length; i++) {
      final nalu = nalus[i];
      final isLast = i == nalus.length - 1;

      if (nalu.length <= state.mtu) {
        out.add(makePacket(state, nalu, rtpTs, isLast, false) as Buffer);
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

    // FU payload header
    final fuHdrHi = (origHi & 0x81) | (NAL_FU << 1);
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

class H265Depacketizer {
  void Function(Map<String, dynamic>)? _output;
  void Function(Object)? _error;

  List<Uint8List> _nalus = [];
  List<Uint8List> _fuFragments = [];

  bool _sawIDR = false;

  H265Depacketizer(Map<String, dynamic> opts) {
    _output = opts['output'];
    _error = opts['error'];
  }

  void depacketize(Map<String, dynamic> packet) {
    final payload = packet['payload'] as Uint8List;

    if (payload.length < 2) {
      _emitError(Exception("H265: payload too small"));
      return;
    }

    final naluType = (payload[0] >> 1) & 0x3F;

    if (naluType < NAL_AP) {
      _nalus.add(payload);

      if (naluType == 19 || naluType == 20) {
        _sawIDR = true;
      }
    } else if (naluType == NAL_FU) {
      if (payload.length < 3) return;

      final fuByte = payload[2];
      final start = (fuByte & 0x80) != 0;
      final end = (fuByte & 0x40) != 0;
      final origType = fuByte & 0x3F;

      if (start) {
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

        if (((full[0] >> 1) & 0x3F) == 19 || ((full[0] >> 1) & 0x3F) == 20) {
          _sawIDR = true;
        }

        _fuFragments = [];
      }
    }

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

  void _emitError(Object e) {
    _error?.call(e);
  }
}

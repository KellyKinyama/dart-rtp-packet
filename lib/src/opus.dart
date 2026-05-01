import 'dart:typed_data';
import 'rtp.dart';

const int OPUS_CLOCK_RATE = 48000;
const int _SILENCE_GAP_RTP = 24000; // 500 ms

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class OpusPacketizer {
  final RtpState state;

  bool _sentFirst = false;
  int _lastRtpTs = 0;

  OpusPacketizer(Map<String, dynamic> opts) : state = createRtpState(opts);

  /// Standard packetize
  List<Buffer> packetize(Map<String, dynamic> chunk) {
    _validateChunk(chunk);
    return [_packetize(chunk, false) as Buffer];
  }

  /// Packetize with metadata
  List<dynamic> packetizeWithMeta(Map<String, dynamic> chunk) {
    _validateChunk(chunk);
    return [_packetize(chunk, true)];
  }

  void close() {}

  dynamic _packetize(Map<String, dynamic> chunk, bool withMeta) {
    final data = toBuffer(chunk['data'])!;
    final rtpTs = usToRtp(chunk['timestamp'], OPUS_CLOCK_RATE);

    // ⚠️ MTU warning (Opus should not fragment)
    if (data.length > state.mtu) {
      print(
        'OpusPacketizer warning: frame ${data.length} exceeds MTU ${state.mtu}',
      );
    }

    // ✅ Marker logic (RFC 7587)
    bool marker;

    if (!_sentFirst) {
      marker = true;
      _sentFirst = true;
    } else {
      final diff = (rtpTs - _lastRtpTs) & 0xFFFFFFFF;
      marker = diff > _SILENCE_GAP_RTP;
    }

    _lastRtpTs = rtpTs;

    return makePacket(state, data, rtpTs, marker, withMeta);
  }

  void _validateChunk(Map<String, dynamic> chunk) {
    if (chunk['timestamp'] == null) {
      throw ArgumentError('chunk.timestamp is required');
    }

    if (chunk['data'] == null) {
      throw ArgumentError('chunk.data is required');
    }

    final data = chunk['data'];
    if (data is! Buffer && data is! Uint8List) {
      throw ArgumentError('chunk.data must be Buffer or Uint8List');
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
// Depacketizer
// ═══════════════════════════════════════════════════════════════════

class OpusDepacketizer {
  void Function(Map<String, dynamic>)? _output;
  void Function(Object)? _error;

  OpusDepacketizer(Map<String, dynamic> opts) {
    if (opts['output'] == null || opts['output'] is! Function) {
      throw ArgumentError('OpusDepacketizer: output required');
    }

    _output = opts['output'];
    _error = (opts['error'] is Function) ? opts['error'] : null;
  }

  static bool peekKeyframe() => false;

  void depacketize(Map<String, dynamic>? packet) {
    if (packet == null ||
        packet['payload'] == null ||
        (packet['payload'] as Uint8List).isEmpty) {
      _emitError(Exception('OpusDepacketizer: empty or missing payload'));
      return;
    }

    _output?.call({
      'data': packet['payload'],
      'timestamp': packet['timestamp'],
      'type': 'key',
    });
  }

  void _emitError(Object err) {
    if (_error == null) return;

    try {
      _error!(err);
    } catch (e) {
      print('OpusDepacketizer error callback threw: $e');
    }
  }

  void reset() {}

  void close() {
    _output = null;
    _error = null;
  }
}

void main() {
  final pkt = OpusPacketizer({'ssrc': 9999, 'payloadType': 111});

  final packets = pkt.packetize({
    'data': Uint8List.fromList(List.filled(100, 0xAA)), // fake opus frame
    'timestamp': 1000000,
  });

  print("Packets: ${packets.length}");
}

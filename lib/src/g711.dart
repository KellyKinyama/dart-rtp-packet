import 'dart:typed_data';
import 'rtp.dart';

const int G711_CLOCK_RATE = 8000;

// ═══════════════════════════════════════════════════════════════════
// Packetizer
// ═══════════════════════════════════════════════════════════════════

class G711Packetizer {
  final RtpState state;

  G711Packetizer(Map<String, dynamic> opts) : state = createRtpState(opts);

  /// Standard packetize (returns Buffer[])
  List<Buffer> packetize(Map<String, dynamic> chunk) {
    _validateChunk(chunk);
    return _packetize(chunk, false).cast<Buffer>();
  }

  /// Packetize with metadata
  List<dynamic> packetizeWithMeta(Map<String, dynamic> chunk) {
    _validateChunk(chunk);
    return _packetize(chunk, true);
  }

  void close() {}

  List<dynamic> _packetize(Map<String, dynamic> chunk, bool withMeta) {
    final data = toBuffer(chunk['data'])!;
    final rtpTs = usToRtp(chunk['timestamp'], G711_CLOCK_RATE);
    final marker = chunk['marker'] == true;

    // ✅ Fast path (most common)
    if (data.length <= state.mtu) {
      return [makePacket(state, data, rtpTs, marker, withMeta)];
    }

    // ⚠️ Large block (rare)
    print(
      'G711Packetizer warning: block ${data.length} > MTU ${state.mtu}, splitting',
    );

    final List<dynamic> out = [];
    int offset = 0;
    int fragIndex = 0;

    while (offset < data.length) {
      final size = (data.length - offset > state.mtu)
          ? state.mtu
          : data.length - offset;

      final slice = data.subarray(offset, offset + size);

      final fragTs = (rtpTs + offset) & 0xFFFFFFFF;

      out.add(
        makePacket(
          state,
          Buffer.from(slice.buffer, slice.offsetInBytes, slice.length),
          fragTs,
          fragIndex == 0 && marker,
          withMeta,
        ),
      );

      offset += size;
      fragIndex++;
    }

    return out;
  }
}

void _validateChunk(Map<String, dynamic> chunk) {
  if (chunk['timestamp'] == null) {
    throw ArgumentError('chunk.timestamp required');
  }

  if (chunk['data'] == null && chunk['nalus'] == null) {
    throw ArgumentError('chunk.data required');
  }

  final data = chunk['data'];
  if (data != null && data is! Buffer && data is! Uint8List) {
    throw ArgumentError('chunk.data must be Buffer or Uint8List');
  }
}

// ═══════════════════════════════════════════════════════════════════
// Depacketizer
// ═══════════════════════════════════════════════════════════════════

class G711Depacketizer {
  void Function(Map<String, dynamic>)? _output;
  void Function(Object)? _error;

  G711Depacketizer(Map<String, dynamic> opts) {
    if (opts['output'] == null || opts['output'] is! Function) {
      throw ArgumentError('G711Depacketizer: output callback is required');
    }

    _output = opts['output'];
    _error = (opts['error'] is Function) ? opts['error'] : null;
  }

  static bool peekKeyframe() => false;

  void depacketize(Map<String, dynamic>? packet) {
    if (packet == null ||
        packet['payload'] == null ||
        (packet['payload'] as Uint8List).isEmpty) {
      _emitError(Exception('G711Depacketizer: empty or missing payload'));
      return;
    }

    _output?.call({
      'data': packet['payload'],
      'timestamp': packet['timestamp'],
      'type': 'key',
      'marker': packet['marker'] == true,
    });
  }

  void _emitError(Object err) {
    if (_error == null) return;

    try {
      _error!(err);
    } catch (e) {
      print('G711Depacketizer error callback threw: $e');
    }
  }

  void reset() {}

  void close() {
    _output = null;
    _error = null;
  }
}

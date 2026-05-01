import 'dart:typed_data';

import 'rtp.dart';

const int DEFAULT_CLOCK_RATE = 8000;

const Map<String, int> EVENT_NAMES = {
  '0': 0,
  '1': 1,
  '2': 2,
  '3': 3,
  '4': 4,
  '5': 5,
  '6': 6,
  '7': 7,
  '8': 8,
  '9': 9,
  '*': 10,
  '#': 11,
  'A': 12,
  'B': 13,
  'C': 14,
  'D': 15,
};

class DTMFPacketizer {
  final RtpState state;
  final int clockRate;

  DTMFPacketizer(Map<String, dynamic> opts)
    : state = createRtpState(opts),
      clockRate = opts['clockRate'] ?? DEFAULT_CLOCK_RATE;

  List<Buffer> packetize(Map<String, dynamic> chunk) {
    return [_packetize(chunk, false)];
  }

  List<Map<String, dynamic>> packetizeWithMeta(Map<String, dynamic> chunk) {
    final pkt = _packetize(chunk, true);

    return [
      {
        'buffer': pkt,
        'timestamp': chunk['timestamp'],
        'marker': chunk['marker'] == true,
        // you can extend later
      },
    ];
  }

  Buffer _packetize(Map<String, dynamic> chunk, bool withMeta) {
    if (chunk['timestamp'] == null) {
      throw Exception("DTMF: timestamp required");
    }

    if (chunk['durationSamples'] == null) {
      throw Exception("DTMF: durationSamples required");
    }

    int event = _resolveEvent(chunk['event']);

    final volume = (chunk['volume'] ?? 10) & 0x3F;
    final endBit = (chunk['end'] == true) ? 0x80 : 0;

    final payload = Buffer.allocUnsafe(4);

    payload[0] = event & 0xFF;
    payload[1] = endBit | (volume & 0x3F);

    final dur = chunk['durationSamples'];
    payload[2] = (dur >> 8) & 0xFF;
    payload[3] = dur & 0xFF;

    final rtpTs = usToRtp(chunk['timestamp'], clockRate);

    return makePacket(state, payload, rtpTs, chunk['marker'] == true, withMeta);
  }

  int _resolveEvent(dynamic e) {
    if (e is int) {
      if (e < 0 || e > 255) {
        throw Exception("DTMF: event out of range");
      }
      return e;
    }

    if (e is String) {
      final key = e.toUpperCase();
      final v = EVENT_NAMES[key];
      if (v == null) {
        throw Exception("DTMF: invalid symbol $e");
      }
      return v;
    }

    throw Exception("DTMF: invalid event type");
  }

  void close() {}
}

class DTMFDepacketizer {
  void Function(Map<String, dynamic>)? _output;
  void Function(Object)? _error;

  static final List<String?> _symbolReverse = () {
    final list = List<String?>.filled(16, null);

    EVENT_NAMES.forEach((k, v) {
      list[v] = k;
    });

    return list;
  }();

  DTMFDepacketizer(Map<String, dynamic> opts) {
    _output = opts['output'];
    _error = opts['error'];
  }

  void depacketize(Map<String, dynamic> packet) {
    final payload = packet['payload'] as Uint8List;

    if (payload.length < 4) {
      _emitError("DTMF payload too small");
      return;
    }

    final event = payload[0];
    final b1 = payload[1];

    final end = (b1 & 0x80) != 0;
    final volume = b1 & 0x3F;

    final duration = (payload[2] << 8) | payload[3];

    _output?.call({
      'event': event,
      'end': end,
      'volume': volume,
      'durationSamples': duration,
      'timestamp': packet['timestamp'],
      'marker': packet['marker'] == true,
      'symbol': (event < 16) ? _symbolReverse[event] : null,
    });
  }

  void _emitError(Object err) {
    _error?.call(err);
  }

  static bool peekKeyframe() {
    return false;
  }

  void reset() {}

  void close() {
    _output = null;
    _error = null;
  }
}

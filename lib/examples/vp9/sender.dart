import 'dart:typed_data';

import '../../src/vp9.dart';
import '../rtp_socket.dart';

class VoipSenderVP9 {
  final RtpSocket socket;
  final VP9Packetizer packetizer;

  final String ip;
  final int port;

  int timestamp = 0;

  VoipSenderVP9({required this.socket, required this.ip, required this.port})
    : packetizer = VP9Packetizer({'ssrc': 9999, 'payloadType': 98});

  Future<void> sendFrame(Uint8List frame, {String type = 'key'}) async {
    final packets = packetizer.packetize({
      'data': frame,
      'timestamp': timestamp,
      'type': type,
    });

    for (final p in packets) {
      socket.send(p.subarray(0), ip, port);

      // ✅ IMPORTANT: pacing
      await Future.delayed(const Duration(microseconds: 200));
    }

    timestamp += 3000; // 30fps @ 90kHz
  }
}

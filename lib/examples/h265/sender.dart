import 'dart:typed_data';

import '../../src/h265.dart';
import '../rtp_socket.dart';

class VoipSenderH265 {
  final RtpSocket socket;
  final H265Packetizer packetizer;

  final String ip;
  final int port;

  int timestamp = 0;

  VoipSenderH265({
    required this.socket,
    required this.ip,
    required this.port,
  }) : packetizer = H265Packetizer({
          'ssrc': 1111,
          'payloadType': 96,
        });

  Future<void> sendFrame(Uint8List frame) async {
    final packets = packetizer.packetize({
      'data': frame,
      'timestamp': timestamp,
    });

    for (final p in packets) {
      socket.send(p.subarray(0), ip, port);
      await Future.delayed(const Duration(microseconds: 200));
    }

    timestamp += 3000;
  }
}
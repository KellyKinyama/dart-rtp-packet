import 'dart:typed_data';

import '../../src/g722.dart';
import '../rtp_socket.dart';
// import 'rtp_socket.dart';

class VoipSenderG722 {
  final RtpSocket socket;
  final G722Packetizer packetizer;

  final String remoteIp;
  final int remotePort;

  VoipSenderG722({
    required this.socket,
    required this.remoteIp,
    required this.remotePort,
  }) : packetizer = G722Packetizer({
         'ssrc': 5678,
         'payloadType': 9, // G.722
       });

  int timestamp = 0;

  void sendFrame(Uint8List g722Data) {
    // ✅ Packetize
    final packets = packetizer.packetize({
      'data': g722Data,
      'timestamp': timestamp,
      'marker': false,
    });

    // ✅ Send packets
    for (final p in packets) {
      socket.send(p.subarray(0), remoteIp, remotePort);
    }

    // ✅ G.722 RTP rule:
    // 1 byte = 1 RTP tick at 8kHz clock
    timestamp += g722Data.length;
  }
}

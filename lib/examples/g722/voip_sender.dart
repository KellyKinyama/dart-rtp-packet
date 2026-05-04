import 'dart:typed_data';

import '../../src/g722.dart';
import '../../src/rtp.dart';
import '../rtp_socket.dart';

class VoipSenderG722 {
  final RtpSocket socket;
  final G722Packetizer packetizer;

  final String remoteIp;
  final int remotePort;

  VoipSenderG722({
    required this.socket,
    required this.remoteIp,
    required this.remotePort,
  }) : packetizer = G722Packetizer(
         RtpPacketizerConfig(ssrc: 5678, payloadType: 9),
       );

  int timestamp = 0;

  void sendFrame(Uint8List g722Data) {
    // ✅ Packetize
    final packets = packetizer.packetize(
      MediaChunk(data: g722Data, timestampUs: timestamp),
    );

    // ✅ Send packets
    for (final p in packets) {
      socket.send(p.subarray(0), remoteIp, remotePort);
    }

    // ✅ G.722 RTP rule:
    // 1 byte = 1 RTP tick at 8kHz clock
    timestamp += g722Data.length;
  }
}

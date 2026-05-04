import 'dart:typed_data';

import '../../src/h264.dart';
import '../../src/rtp.dart';
import 'rtp_socket.dart';

class VoipSenderH264 {
  final RtpSocket socket;
  final H264Packetizer packetizer;

  final String remoteIp;
  final int remotePort;

  VoipSenderH264({
    required this.socket,
    required this.remoteIp,
    required this.remotePort,
  }) : packetizer = H264Packetizer(
         RtpPacketizerConfig(ssrc: 7777, payloadType: 96),
       );

  int timestamp = 0;

  /// Send one full H264 frame (Annex‑B)
  void sendFrame(Uint8List annexBFrame) async {
    final packets = packetizer.packetize(
      MediaChunk(data: annexBFrame, timestampUs: timestamp),
    );

    for (final p in packets) {
      socket.send(p.subarray(0), remoteIp, remotePort);

      // ✅ IMPORTANT: spacing between RTP packets
      await Future.delayed(const Duration(microseconds: 300));
    }

    timestamp += 3000;
  }
}

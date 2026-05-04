import 'dart:typed_data';

import '../../src/vp8.dart';
import '../../src/rtp.dart';
import '../rtp_socket.dart';

class VoipSenderVP8 {
  final RtpSocket socket;
  final VP8Packetizer packetizer;

  final String ip;
  final int port;

  int timestamp = 0;

  VoipSenderVP8({required this.socket, required this.ip, required this.port})
    : packetizer = VP8Packetizer(
        RtpPacketizerConfig(ssrc: 8888, payloadType: 96),
      );

  Future<void> sendFrame(Uint8List frame) async {
    final packets = packetizer.packetize(
      MediaChunk(data: frame, timestampUs: timestamp),
    );

    for (final p in packets) {
      socket.send(p.subarray(0), ip, port);

      // ✅ pacing (IMPORTANT)
      await Future.delayed(const Duration(microseconds: 200));
    }

    // ✅ 30fps @ 90kHz
    timestamp += 3000;
  }
}

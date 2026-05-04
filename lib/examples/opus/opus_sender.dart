import 'dart:typed_data';

import '../../src/opus.dart';
import '../../src/rtp.dart';
import '../rtp_socket.dart';

class VoipSenderOpus {
  final RtpSocket socket;
  final OpusPacketizer packetizer;

  final String remoteIp;
  final int remotePort;

  VoipSenderOpus({
    required this.socket,
    required this.remoteIp,
    required this.remotePort,
  }) : packetizer = OpusPacketizer(
         RtpPacketizerConfig(ssrc: 9999, payloadType: 111),
       );

  int timestamp = 0;

  /// Send ONE Opus frame
  void sendFrame(Uint8List opusFrame) {
    // ✅ packetize (always 1 packet)
    final packets = packetizer.packetize(
      MediaChunk(data: opusFrame, timestampUs: timestamp),
    );

    // ✅ send
    for (final p in packets) {
      socket.send(p.subarray(0), remoteIp, remotePort);
    }

    // ✅ Opus timestamp rule (always 48kHz clock)
    // Most frames = 20ms → 960 samples
    timestamp += 960;
  }
}

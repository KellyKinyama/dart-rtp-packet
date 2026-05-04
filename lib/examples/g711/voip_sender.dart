import 'dart:typed_data';

import '../../src/g711.dart';
import '../../src/rtp.dart';
import 'g711.dart' as codec;
import '../rtp_socket.dart';

class VoipSender {
  final RtpSocket socket;
  final G711Packetizer packetizer;

  final String remoteIp;
  final int remotePort;

  VoipSender({
    required this.socket,
    required this.remoteIp,
    required this.remotePort,
  }) : packetizer = G711Packetizer(
         RtpPacketizerConfig(ssrc: 1234, payloadType: 0),
       );

  int timestamp = 0;

  void sendPcm(Uint8List pcmChunk) {
    // ✅ 1. Encode PCM → G.711
    final g711 = codec.G711Encoder.encodePCM16(pcmChunk);

    // ✅ 2. Packetize
    final packets = packetizer.packetize(
      MediaChunk(data: g711, timestampUs: timestamp),
    );

    // ✅ 3. Send RTP packets
    for (final p in packets) {
      // ✅ expose bytes safely via helper
      socket.send(_bufferToBytes(p), remoteIp, remotePort);
    }

    // ✅ 4. Advance RTP timestamp
    // G.711: 1 byte = 1 sample @ 8kHz
    timestamp += g711.length;
  }

  /// ✅ Safe extractor for Buffer → Uint8List
  Uint8List _bufferToBytes(Buffer b) {
    return b.subarray(0); // zero-copy view
  }
}

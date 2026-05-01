import '../../src/rtp.dart';
import '../../src/vp8.dart';
import '../rtp_socket.dart';

class VoipReceiverVP8 {
  final RtpSocket socket;
  final VP8Depacketizer depacketizer;

  VoipReceiverVP8(this.socket)
    : depacketizer = VP8Depacketizer({
        'output': (Map frame) {
          print("VP8 frame: ${frame['data'].length}");
        },
      });

  void start() {
    socket.listen((data) {
      final pkt = parseRtp(Buffer.from(data.buffer, 0, data.length));

      if (pkt != null) {
        depacketizer.depacketize({
          'payload': pkt.payload,
          'timestamp': pkt.timestamp,
          'marker': pkt.marker,
        });
      }
    });
  }
}

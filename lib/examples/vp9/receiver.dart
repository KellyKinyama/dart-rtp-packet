import '../../src/rtp.dart';
import '../../src/vp9.dart';
import '../rtp_socket.dart';

class VoipReceiverVP9 {
  final RtpSocket socket;
  final VP9Depacketizer depacketizer;

  VoipReceiverVP9(this.socket)
    : depacketizer = VP9Depacketizer({
        'output': (Map frame) {
          print("VP9 frame: ${frame['data'].length}");
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

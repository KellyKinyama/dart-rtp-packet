import '../../src/g722.dart';
import '../../src/rtp.dart';
import '../rtp_socket.dart';
// import 'rtp_socket.dart';

class VoipReceiverG722 {
  final RtpSocket socket;
  final G722Depacketizer depacketizer;

  VoipReceiverG722(this.socket)
    : depacketizer = G722Depacketizer({
        'output': (Map frame) {
          print("G722 audio frame: ${frame['data'].length}");
          // 🔊 send to decoder + speaker here
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

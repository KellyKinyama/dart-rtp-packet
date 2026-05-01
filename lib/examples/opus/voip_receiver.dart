import '../../src/opus.dart';
import '../../src/rtp.dart';
import '../rtp_socket.dart';
// import 'rtp_socket.dart';

class VoipReceiverOpus {
  final RtpSocket socket;
  final OpusDepacketizer depacketizer;

  VoipReceiverOpus(this.socket)
    : depacketizer = OpusDepacketizer({
        'output': (Map frame) {
          print("Opus frame: ${frame['data'].length}");
          // 🔊 send to decoder here (libopus / flutter plugin)
        },
      });

  void start() {
    socket.listen((data) {
      final pkt = parseRtp(Buffer.from(data.buffer, 0, data.length));

      if (pkt != null) {
        depacketizer.depacketize({
          'payload': pkt.payload,
          'timestamp': pkt.timestamp,
        });
      }
    });
  }
}

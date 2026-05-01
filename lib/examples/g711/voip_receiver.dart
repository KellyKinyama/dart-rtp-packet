import '../../src/g711.dart';
import '../../src/rtp.dart';
import '../rtp_socket.dart';

class VoipReceiver {
  final RtpSocket socket;
  final G711Depacketizer depacketizer;

  VoipReceiver(this.socket)
    : depacketizer = G711Depacketizer({
        'output': (Map frame) {
          print("Audio frame: ${frame['data'].length}");
          // 🔊 send to speaker here
        },
      });

  void start() {
    socket.listen((data) {
      final pkt = parseRtp(Buffer.from(data.buffer, 0, data.length));

      if (pkt != null) {
        // ✅ Convert typed packet → Map expected by depacketizer
        depacketizer.depacketize({
          'payload': pkt.payload,
          'timestamp': pkt.timestamp,
          'marker': pkt.marker,
        });
      }
    });
  }
}

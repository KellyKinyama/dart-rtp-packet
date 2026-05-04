import '../../src/rtp.dart';
import '../../src/vp8.dart';
import '../rtp_socket.dart';

class VoipReceiverVP8 {
  final RtpSocket socket;
  final VP8Depacketizer depacketizer;

  VoipReceiverVP8(this.socket)
    : depacketizer = VP8Depacketizer(
        RtpDepacketizerCallbacks<Vp8Frame>(
          onFrame: (frame) {
            print('VP8 frame: ${frame.data.length} bytes');
          },
        ),
      );

  void start() {
    socket.listen((data) {
      final pkt = parseRtp(Buffer.from(data.buffer, 0, data.length));

      if (pkt != null) {
        depacketizer.depacketize(pkt);
      }
    });
  }
}

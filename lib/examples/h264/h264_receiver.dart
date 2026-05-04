import '../../src/h264.dart';
import '../../src/rtp.dart';
import 'rtp_socket.dart';

class VoipReceiverH264 {
  final RtpSocket socket;
  final H264Depacketizer depacketizer;

  VoipReceiverH264(this.socket)
    : depacketizer = H264Depacketizer(
        RtpDepacketizerCallbacks<H264Frame>(
          onFrame: (frame) {
            print(
              'Video frame: ${frame.annexB.length} bytes, '
              'keyframe: ${frame.keyFrame}',
            );
            // 🎬 send to decoder (H264 decoder, player, etc.)
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

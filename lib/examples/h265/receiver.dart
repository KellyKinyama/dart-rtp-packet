import '../../src/h265.dart';
import '../../src/rtp.dart';
import '../rtp_socket.dart';

class VoipReceiverH265 {
  final RtpSocket socket;
  final H265Depacketizer depacketizer;

  VoipReceiverH265(this.socket)
    : depacketizer = H265Depacketizer(
        RtpDepacketizerCallbacks<H265Frame>(
          onFrame: (frame) {
            print('H265 frame: ${frame.annexB.length} bytes');
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

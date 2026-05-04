import '../../src/dtmf.dart';
import '../../src/rtp.dart';

void main() {
  final dep = DTMFDepacketizer(
    RtpDepacketizerCallbacks<DtmfEvent>(
      onFrame: (evt) {
        print("DTMF: ${evt.symbol}, end=${evt.end}");
      },
    ),
  );
}

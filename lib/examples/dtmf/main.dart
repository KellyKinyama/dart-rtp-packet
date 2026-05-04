import '../../src/dtmf.dart';
import '../../src/rtp.dart';
import '../rtp_socket.dart';
import 'sender.dart';

void main() async {
  final senderSocket = RtpSocket();
  await senderSocket.bind(5000);

  final receiverSocket = RtpSocket();
  await receiverSocket.bind(5002);

  final packetizer = DTMFPacketizer(
    RtpPacketizerConfig(ssrc: 5555, payloadType: 101),
  );

  final sender = DtmfSender(
    packetizer: packetizer,
    socket: senderSocket,
    ip: "127.0.0.1",
    port: 5002,
  );

  // final receiver = DTMFDepacketizer({
  //   'output': (chunk) {
  //     if (chunk['end'] == true) {
  //       print("✅ DIGIT COMPLETE: ${chunk['symbol']}");
  //     }
  //   },
  // });

  int? _lastEvent;
  bool _ended = false;

  final receiver = DTMFDepacketizer(
    RtpDepacketizerCallbacks<DtmfEvent>(
      onFrame: (evt) {
        // ✅ new digit detected → reset state
        if (_lastEvent != evt.event) {
          _ended = false;
        }

        // ✅ only fire ONCE
        if (evt.end && !_ended) {
          print('✅ DIGIT COMPLETE: ${evt.symbol}');
          _ended = true;
        }

        _lastEvent = evt.event;
      },
    ),
  );

  receiverSocket.listen((data) {
    final pkt = parseRtp(Buffer.from(data.buffer, 0, data.length));

    if (pkt != null) {
      receiver.depacketize(pkt);
    }
  });

  // ✅ Send digits like a real keypad
  await sender.sendDigit("1");
  await Future.delayed(Duration(milliseconds: 500));

  await sender.sendDigit("5");
  await Future.delayed(Duration(milliseconds: 500));

  await sender.sendDigit("#");
}

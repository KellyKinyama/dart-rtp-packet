import 'dart:typed_data';

import '../rtp_socket.dart';
import 'voip_receiver.dart';
import 'voip_sender.dart';

void main() async {
  final socket = RtpSocket();
  await socket.bind(5004);

  final sender = VoipSenderG722(
    socket: socket,
    remoteIp: "127.0.0.1",
    remotePort: 5004,
  );

  final receiver = VoipReceiverG722(socket);
  receiver.start();

  final frame = Uint8List.fromList(List.filled(160, 0x55));

  // ✅ simulate real-time audio (20ms)
  for (int i = 0; i < 5; i++) {
    sender.sendFrame(frame);

    await Future.delayed(const Duration(milliseconds: 20));
  }
}

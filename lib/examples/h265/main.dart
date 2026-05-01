import 'dart:typed_data';

import '../rtp_socket.dart';
import 'receiver.dart';
import 'sender.dart';

void main() async {
  final senderSocket = RtpSocket();
  await senderSocket.bind(8000);

  final receiverSocket = RtpSocket();
  await receiverSocket.bind(8002);

  final sender = VoipSenderH265(
    socket: senderSocket,
    ip: "127.0.0.1",
    port: 8002,
  );

  final receiver = VoipReceiverH265(receiverSocket);
  receiver.start();

  final frame = Uint8List.fromList([
    0, 0, 0, 1,
    0x26, 0x01, // fake H265 header
    ...List.filled(2000, 0x55),
  ]);

  for (int i = 0; i < 5; i++) {
    await sender.sendFrame(frame);
    await Future.delayed(const Duration(milliseconds: 33));
  }
}

import 'dart:typed_data';

import '../rtp_socket.dart';
import 'receiver.dart';
import 'sender.dart';

void main() async {
  final senderSocket = RtpSocket();
  await senderSocket.bind(6000);

  final receiverSocket = RtpSocket();
  await receiverSocket.bind(6002);

  final sender = VoipSenderVP8(
    socket: senderSocket,
    ip: "127.0.0.1",
    port: 6002,
  );

  final receiver = VoipReceiverVP8(receiverSocket);
  receiver.start();

  final fakeFrame = Uint8List.fromList(List.filled(2000, 0xAA));

  for (int i = 0; i < 5; i++) {
    await sender.sendFrame(fakeFrame);

    await Future.delayed(const Duration(milliseconds: 33));
  }
}

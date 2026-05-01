import 'dart:typed_data';

import '../rtp_socket.dart';
import 'receiver.dart';
import 'sender.dart';

void main() async {
  final senderSocket = RtpSocket();
  await senderSocket.bind(7000);

  final receiverSocket = RtpSocket();
  await receiverSocket.bind(7002);

  final sender = VoipSenderVP9(
    socket: senderSocket,
    ip: "127.0.0.1",
    port: 7002,
  );

  final receiver = VoipReceiverVP9(receiverSocket);
  receiver.start();

  final fakeFrame = Uint8List.fromList(List.filled(2000, 0xBB));

  for (int i = 0; i < 5; i++) {
    await sender.sendFrame(fakeFrame, type: 'key');

    await Future.delayed(const Duration(milliseconds: 33));
  }
}

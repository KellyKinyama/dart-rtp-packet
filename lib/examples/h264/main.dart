import 'dart:typed_data';

import 'rtp_socket.dart';
import 'h264_receiver.dart';
import 'h264_sender.dart';

void main() async {
  final senderSocket = RtpSocket();
  await senderSocket.bind(5004);

  final receiverSocket = RtpSocket();
  await receiverSocket.bind(5006); // ✅ different port

  final sender = VoipSenderH264(
    socket: senderSocket,
    remoteIp: "127.0.0.1",
    remotePort: 5006, // ✅ send to receiver
  );

  final receiver = VoipReceiverH264(receiverSocket);
  receiver.start();

  final frame = Uint8List.fromList([
    0,
    0,
    0,
    1,
    0x65,
    ...List.filled(2000, 0x88),
  ]);

  for (int i = 0; i < 5; i++) {
    sender.sendFrame(frame);

    await Future.delayed(const Duration(milliseconds: 33));
  }
}

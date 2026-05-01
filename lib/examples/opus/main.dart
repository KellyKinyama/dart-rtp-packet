import 'dart:typed_data';

// import 'rtp_socket.dart';
// import 'voip_sender.dart';
import '../rtp_socket.dart';
import 'opus_sender.dart';
import 'voip_receiver.dart';

/// Fake Opus frame generator (for testing only)
class FakeOpus {
  static Uint8List frame([int size = 40]) {
    return Uint8List.fromList(List.filled(size, 0xAA));
  }
}

void main() async {
  final socket = RtpSocket();
  await socket.bind(5004);

  final sender = VoipSenderOpus(
    socket: socket,
    remoteIp: "127.0.0.1",
    remotePort: 5004,
  );

  final receiver = VoipReceiverOpus(socket);
  receiver.start();

  // ✅ simulate real-time Opus packets (20 ms)
  for (int i = 0; i < 5; i++) {
    final frame = FakeOpus.frame(40);

    sender.sendFrame(frame);

    await Future.delayed(const Duration(milliseconds: 20));
  }
}

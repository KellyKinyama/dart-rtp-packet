import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';

import '../rtp_socket.dart';
import 'voip_receiver.dart';
import 'voip_sender.dart';

class MicCapture {
  final recorder = FlutterSoundRecorder();

  Future<void> start(void Function(Uint8List pcm) onChunk) async {
    await recorder.openRecorder();

    await recorder.startRecorder(
      toStream: (buffer) {
        onChunk(Uint8List.fromList(buffer));
      },
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: 8000,
    );
  }
}

void main() async {
  .bind(5004);

  final sender = VoipSender(
    socket: socket,
    remoteIp: "192.168.1.10",
    remotePort: 5004,
  );

  final receiver = VoipReceiver(socket);
  receiver.start();

  final mic = MicCapture();

  await mic.start((pcm) {
    sender.sendPcm(pcm);
  });
}

final socket = RtpSocket();

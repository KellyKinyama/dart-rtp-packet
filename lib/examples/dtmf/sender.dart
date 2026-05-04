import '../../src/dtmf.dart';
import '../../src/rtp.dart';
import '../rtp_socket.dart';

class DtmfSender {
  final DTMFPacketizer packetizer;
  final RtpSocket socket;
  final String ip;
  final int port;

  int _timestamp = 0;

  DtmfSender({
    required this.packetizer,
    required this.socket,
    required this.ip,
    required this.port,
  });

  Future<void> sendDigit(
    String digit, {
    int durationMs = 200,
    int packetIntervalMs = 20,
  }) async {
    final samplesPerPacket = dtmfClockRate * packetIntervalMs ~/ 1000;

    int durationSamples = 0;

    final totalPackets = durationMs ~/ packetIntervalMs;

    // ✅ SEND START + MID
    for (int i = 0; i < totalPackets; i++) {
      durationSamples += samplesPerPacket;

      final packets = packetizer.packetize(
        DtmfChunk(
          timestampUs: _timestamp,
          event: DtmfDigit.fromString(digit)?.code ?? 0,
          durationSamples: durationSamples,
          marker: i == 0, // RFC 4733: marker on first packet
          end: false,
        ),
      );

      for (final p in packets) {
        socket.send(p.subarray(0), ip, port);
      }

      await Future.delayed(Duration(milliseconds: packetIntervalMs));
    }

    // ✅ SEND END (3x REQUIRED)
    for (int i = 0; i < 3; i++) {
      final packets = packetizer.packetize(
        DtmfChunk(
          timestampUs: _timestamp,
          event: DtmfDigit.fromString(digit)?.code ?? 0,
          durationSamples: durationSamples,
          end: true,
        ),
      );

      for (final p in packets) {
        socket.send(p.subarray(0), ip, port);
      }

      await Future.delayed(Duration(milliseconds: packetIntervalMs));
    }

    // ✅ advance timestamp (important!)
    _timestamp += durationSamples;
  }
}

void main() async {
  // ✅ Sender socket
  final senderSocket = RtpSocket();
  await senderSocket.bind(5000);

  // ✅ Receiver socket
  final receiverSocket = RtpSocket();
  await receiverSocket.bind(5002);

  // ✅ Packetizer
  final dtmfSender = DTMFPacketizer(
    RtpPacketizerConfig(ssrc: 5555, payloadType: 101),
  );

  // ✅ Depacketizer
  final dtmfReceiver = DTMFDepacketizer(
    RtpDepacketizerCallbacks<DtmfEvent>(
      onFrame: (evt) {
        print(
          "DTMF RECEIVED → symbol=${evt.symbol} "
          "event=${evt.event} "
          "end=${evt.end} "
          "duration=${evt.durationSamples}",
        );
      },
    ),
  );

  // ✅ Receiver pipeline
  receiverSocket.listen((data) {
    final pkt = parseRtp(Buffer.from(data.buffer, 0, data.length));

    if (pkt != null) {
      dtmfReceiver.depacketize(pkt);
    }
  });

  // ✅ Simulate sending a DTMF "5"
  const ip = "127.0.0.1";
  const port = 5002;

  int timestamp = 0;
  int duration = 0;

  print("Sending DTMF: 5");

  // ✅ START + MID packets
  for (int i = 0; i < 4; i++) {
    duration += 160; // ~20ms at 8kHz

    final packets = dtmfSender.packetize(
      DtmfChunk(
        timestampUs: timestamp,
        event: DtmfDigit.fromString('5')?.code ?? 5,
        durationSamples: duration,
        marker: i == 0, // ONLY first packet
        end: false,
      ),
    );

    for (final p in packets) {
      senderSocket.send(p.subarray(0), ip, port);
    }

    await Future.delayed(Duration(milliseconds: 20));
  }

  // ✅ END packets (send 3 times)
  for (int i = 0; i < 3; i++) {
    final packets = dtmfSender.packetize(
      DtmfChunk(
        timestampUs: timestamp,
        event: DtmfDigit.fromString('5')?.code ?? 5,
        durationSamples: duration,
        end: true,
      ),
    );

    for (final p in packets) {
      senderSocket.send(p.subarray(0), ip, port);
    }

    await Future.delayed(Duration(milliseconds: 20));
  }
}

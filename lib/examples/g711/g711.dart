import 'dart:typed_data';

import '../../src/g711.dart';
import '../../src/rtp.dart';

class G711Encoder {
  // μ-law encode (simple lookup version)
  static int linearToUlaw(int sample) {
    const int BIAS = 0x84;
    const int CLIP = 32635;

    int sign = (sample < 0) ? 0x80 : 0;
    if (sample < 0) sample = -sample;
    if (sample > CLIP) sample = CLIP;

    sample += BIAS;

    int exponent = 7;
    for (
      int expMask = 0x4000;
      (sample & expMask) == 0 && exponent > 0;
      exponent--, expMask >>= 1
    ) {}

    int mantissa = (sample >> ((exponent == 0) ? 4 : (exponent + 3))) & 0x0F;

    int ulawByte = ~(sign | (exponent << 4) | mantissa);
    return ulawByte & 0xFF;
  }

  static Uint8List encodePCM16(Uint8List pcm) {
    final out = Uint8List(pcm.length ~/ 2);

    for (int i = 0, j = 0; i < pcm.length; i += 2, j++) {
      int sample = (pcm[i + 1] << 8) | pcm[i];
      if (sample > 32767) sample -= 65536;
      out[j] = linearToUlaw(sample);
    }

    return out;
  }
}

void main() {
  final pkt = G711Packetizer(RtpPacketizerConfig(ssrc: 1234, payloadType: 0));

  // ✅ fake PCM16 (320 bytes = 160 samples)
  final pcm = Uint8List.fromList(List.filled(320, 0x00));

  // ✅ encode → G.711
  final g711 = G711Encoder.encodePCM16(pcm);

  final packets = pkt.packetize(
    MediaChunk(data: g711, timestampUs: 1000000),
    marker: true,
  );

  print("G711 bytes: ${g711.length}");
  print("Generated packets: ${packets.length}");
}

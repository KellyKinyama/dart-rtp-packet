/**
 * rtcp — RTCP packet types (RFC 3550, RFC 4585).
 *
 * Implements:
 *   - SR  (Sender Report)     — type 200
 *   - RR  (Receiver Report)   — type 201
 *   - NACK (Generic NACK)     — type 205, fmt=1
 *   - PLI  (Picture Loss)     — type 206, fmt=1
 *   - FIR  (Full Intra Req)   — type 206, fmt=4
 */

import 'dart:convert';
import 'dart:typed_data';

import 'rtp.dart';

/**
 * Build Sender Report.
 * @param {object} opts
 * @param {number} opts.ssrc         — sender SSRC
 * @param {number} opts.ntpTimestamp — NTP timestamp (64-bit as [hi, lo])
 * @param {number} opts.rtpTimestamp — RTP timestamp
 * @param {number} opts.packetCount  — total RTP packets sent
 * @param {number} opts.octetCount   — total payload bytes sent
 * @returns {Buffer}
 */
Buffer buildSR({
  required int ssrc,
  List<int>? ntpTimestamp,
  required int rtpTimestamp,
  required int packetCount,
  required int octetCount,
}) {
  final buf = Buffer.allocUnsafe(28);

  buf[0] = 0x80;
  buf[1] = 200;
  buf.writeUInt16BE(6, 2);

  buf.writeUInt32BE(ssrc, 4);

  final ntp = ntpTimestamp ?? _getNtpTimestamp();

  buf.writeUInt32BE(ntp[0], 8);
  buf.writeUInt32BE(ntp[1], 12);

  buf.writeUInt32BE(rtpTimestamp, 16);
  buf.writeUInt32BE(packetCount, 20);
  buf.writeUInt32BE(octetCount, 24);

  return buf;
}

/**
 * Build PLI (Picture Loss Indication) — request keyframe.
 * @param {number} senderSsrc — our SSRC
 * @param {number} mediaSsrc  — SSRC of the media stream
 * @returns {Buffer}
 */
Buffer buildPLI(int senderSsrc, int mediaSsrc) {
  final buf = Buffer.allocUnsafe(12);

  buf[0] = 0x81;
  buf[1] = 206;
  buf.writeUInt16BE(2, 2);

  buf.writeUInt32BE(senderSsrc, 4);
  buf.writeUInt32BE(mediaSsrc, 8);

  return buf;
}

/**
 * Build NACK — request retransmission of specific packets.
 * @param {number} senderSsrc — our SSRC
 * @param {number} mediaSsrc  — SSRC of the media stream
 * @param {number[]} seqNums  — lost sequence numbers
 * @returns {Buffer}
 */
Buffer? buildNACK(int senderSsrc, int mediaSsrc, List<int> seqNums) {
  if (seqNums.isEmpty) return null;

  final entries = _buildNackEntries(seqNums);

  final buf = Buffer.allocUnsafe(12 + entries.length * 4);

  buf[0] = 0x81;
  buf[1] = 205;
  buf.writeUInt16BE(2 + entries.length, 2);

  buf.writeUInt32BE(senderSsrc, 4);
  buf.writeUInt32BE(mediaSsrc, 8);

  for (int i = 0; i < entries.length; i++) {
    buf.writeUInt16BE(entries[i].pid, 12 + i * 4);
    buf.writeUInt16BE(entries[i].blp, 14 + i * 4);
  }

  return buf;
}

/**
 * Build FIR (Full Intra Request).
 * @param {number} senderSsrc — our SSRC
 * @param {number} mediaSsrc  — SSRC of the media stream
 * @param {number} seqNr      — FIR sequence number (increment each time)
 * @returns {Buffer}
 */
Buffer buildFIR(int senderSsrc, int mediaSsrc, int seqNr) {
  final buf = Buffer.allocUnsafe(20);

  buf[0] = 0x84;
  buf[1] = 206;
  buf.writeUInt16BE(4, 2);

  buf.writeUInt32BE(senderSsrc, 4);
  buf.writeUInt32BE(0, 8);
  buf.writeUInt32BE(mediaSsrc, 12);

  buf[16] = seqNr & 0xFF;

  return buf;
}

/**
 * Build Receiver Report (RR).
 * @param {object} opts
 * @param {number} opts.ssrc           — our SSRC
 * @param {number} opts.mediaSsrc      — source SSRC
 * @param {number} opts.fractionLost   — 0-255
 * @param {number} opts.totalLost      — cumulative packets lost (24-bit)
 * @param {number} opts.highestSeq     — highest seq received (full 32-bit: cycles + seq)
 * @param {number} opts.jitter         — interarrival jitter (RTP timestamp units)
 * @param {number} opts.lastSR         — middle 32 bits of last SR NTP timestamp
 * @param {number} opts.delaySinceLastSR — delay since last SR in 1/65536 seconds
 * @returns {Buffer}
 */
Buffer buildRR({
  required int ssrc,
  required int mediaSsrc,
  required int fractionLost,
  required int totalLost,
  required int highestSeq,
  required int jitter,
  required int lastSR,
  required int delaySinceLastSR,
}) {
  final buf = Buffer.allocUnsafe(32);

  buf[0] = 0x81;
  buf[1] = 201;
  buf.writeUInt16BE(7, 2);

  buf.writeUInt32BE(ssrc, 4);
  buf.writeUInt32BE(mediaSsrc, 8);

  buf[12] = fractionLost & 0xFF;

  buf[13] = (totalLost >> 16) & 0xFF;
  buf[14] = (totalLost >> 8) & 0xFF;
  buf[15] = totalLost & 0xFF;

  buf.writeUInt32BE(highestSeq, 16);
  buf.writeUInt32BE(jitter, 20);
  buf.writeUInt32BE(lastSR, 24);
  buf.writeUInt32BE(delaySinceLastSR, 28);

  return buf;
}

/**
 * Build REMB (Receiver Estimated Maximum Bitrate).
 * @param {number} senderSsrc — our SSRC
 * @param {number[]} mediaSsrcs — SSRCs this applies to
 * @param {number} bitrate — estimated max bitrate in bps
 * @returns {Buffer}
 */
Buffer buildREMB(int senderSsrc, List<int> mediaSsrcs, int bitrate) {
  final num = mediaSsrcs.length;
  final buf = Buffer.allocUnsafe(20 + num * 4);

  buf[0] = 0x8F;
  buf[1] = 206;
  buf.writeUInt16BE(2 + 1 + num, 2);

  buf.writeUInt32BE(senderSsrc, 4);
  buf.writeUInt32BE(0, 8);

  // "REMB"
  buf[12] = 0x52;
  buf[13] = 0x45;
  buf[14] = 0x4D;
  buf[15] = 0x42;

  int exp = 0;
  int mant = bitrate;

  while (mant > 0x3FFFF) {
    mant >>= 1;
    exp++;
  }

  buf[16] = num & 0xFF;
  buf[17] = ((exp & 0x3F) << 2) | ((mant >> 16) & 0x03);
  buf[18] = (mant >> 8) & 0xFF;
  buf[19] = mant & 0xFF;

  for (int i = 0; i < num; i++) {
    buf.writeUInt32BE(mediaSsrcs[i], 20 + i * 4);
  }

  return buf;
}

Buffer buildCompound(List<Buffer> packets) {
  final totalLen = packets.fold<int>(0, (sum, p) => sum + p.length);
  final out = Buffer.allocUnsafe(totalLen);

  int offset = 0;
  for (final p in packets) {
    p.copy(out, offset);
    offset += p.length;
  }

  return out;
}

class _Delta {
  final int size;
  final int value;

  _Delta(this.size, this.value);
}

class TwccPacket {
  final bool received;
  final int deltaUs;

  TwccPacket({required this.received, required this.deltaUs});
}

/**
 * buildTransportCC — encode a transport-wide congestion control feedback
 * message (RTPFB PT=205 FMT=15, draft-holmer-rmcat-transport-wide-cc-extensions-01).
 *
 * This is the counterpart of parseTransportCC in bandwidth.js.  The two
 * together allow round-trip testing of the format without involving the
 * network.
 *
 * Inputs describe which packets were received (and when), for a contiguous
 * range of transport-wide sequence numbers [baseSeq, baseSeq + packetCount).
 *
 * @param {object} opts
 * @param {number} opts.senderSsrc       — our SSRC (included in the header)
 * @param {number} opts.mediaSsrc        — SSRC of the media stream being reported on
 * @param {number} opts.baseSeq          — first transport-wide seq covered (u16)
 * @param {number} opts.packetCount      — number of packet status entries (u16)
 * @param {number} opts.referenceTimeMs  — abs time for the first *received* packet's
 *                                         delta base; will be truncated to 64ms units
 *                                         (24-bit signed wraps every ~4.6 hours)
 * @param {number} opts.fbPktCount       — feedback packet counter, 0..255, wraps
 * @param {Array}  opts.packets          — packetCount entries, each:
 *                                             { received: bool, deltaUs: int|null }
 *                                         deltaUs is the offset from the previous
 *                                         received packet's arrival (or from refTime
 *                                         for the first received packet), in µs.
 * @returns {Buffer} complete RTCP packet ready to send.
 *
 * Layout (from draft §3.1):
 *
 *    +V-P-FMT+   PT=205   +----- length -----+
 *    +------+ sender SSRC +------+ media SSRC +
 *    | baseSeq (16)      | packetCount (16)   |
 *    | referenceTime (24)        | fbPktCnt(8)|
 *    | chunk 1 (16) | chunk 2 (16)            |
 *    | ...                                    |
 *    | recv delta 1 (8/16) | recv delta 2 ... |
 *    | ...                                    |
 *    | zero padding to 4-byte boundary        |
 */
Buffer buildTransportCC({
  required int senderSsrc,
  required int mediaSsrc,
  required int baseSeq,
  required int packetCount,
  required int fbPktCount,
  required int referenceTimeMs,
  required List<TwccPacket> packets,
}) {
  senderSsrc &= 0xFFFFFFFF;
  mediaSsrc &= 0xFFFFFFFF;
  baseSeq &= 0xFFFF;
  packetCount &= 0xFFFF;
  fbPktCount &= 0xFF;

  // ✅ reference time (24-bit, 64ms units)
  int refUnits = (referenceTimeMs ~/ 64);

  if (refUnits > 0x7FFFFF) refUnits = 0x7FFFFF;
  if (refUnits < -0x800000) refUnits = -0x800000;

  final refTime24 = refUnits & 0xFFFFFF;

  // ✅ PASS 1 — symbols + deltas
  final List<int> symbols = List.filled(packetCount, 0);
  final List<_Delta> deltas = [];

  for (int i = 0; i < packetCount; i++) {
    final p = (i < packets.length) ? packets[i] : null;

    if (p == null || !p.received) {
      symbols[i] = 0;
      continue;
    }

    final deltaUs = p.deltaUs;
    final deltaQ = (deltaUs / 250).round();

    if (deltaQ >= 0 && deltaQ <= 0xFF) {
      symbols[i] = 1;
      deltas.add(_Delta(1, deltaQ));
    } else if (deltaQ >= -0x8000 && deltaQ <= 0x7FFF) {
      symbols[i] = 2;
      deltas.add(_Delta(2, deltaQ));
    } else {
      symbols[i] = 0;
    }
  }

  // ✅ PASS 2 — chunk encoding
  final List<int> chunks = [];
  int i2 = 0;

  while (i2 < packetCount) {
    final s = symbols[i2];

    int runEnd = i2 + 1;
    while (runEnd < packetCount && symbols[runEnd] == s) {
      runEnd++;
    }

    int runLen = runEnd - i2;
    if (runLen > 8191) runLen = 8191;

    // ✅ run-length
    if (s <= 2 && runLen >= 14) {
      final chunk = ((s & 0x3) << 13) | (runLen & 0x1FFF);
      chunks.add(chunk);
      i2 += runLen;
      continue;
    }

    // ✅ 1-bit vector
    final look14 = (packetCount - i2 > 14) ? 14 : (packetCount - i2);

    bool fits1bit = true;
    for (int j = 0; j < look14; j++) {
      if (symbols[i2 + j] > 1) {
        fits1bit = false;
        break;
      }
    }

    if (fits1bit && look14 > 0) {
      int chunk = 0x8000;

      for (int j = 0; j < look14; j++) {
        if (symbols[i2 + j] == 1) {
          chunk |= (1 << (13 - j));
        }
      }

      chunks.add(chunk);
      i2 += look14;
      continue;
    }

    // ✅ 2-bit vector
    final look7 = (packetCount - i2 > 7) ? 7 : (packetCount - i2);

    int chunk = 0xC000;

    for (int j = 0; j < look7; j++) {
      chunk |= (symbols[i2 + j] & 0x3) << ((6 - j) * 2);
    }

    chunks.add(chunk);
    i2 += look7;
  }

  // ✅ size calculations
  final headerSize = 12;
  final fciHeader = 8;
  final chunksSize = chunks.length * 2;

  int deltasSize = 0;
  for (final d in deltas) {
    deltasSize += d.size;
  }

  final unpadded = headerSize + fciHeader + chunksSize + deltasSize;
  final padded = (unpadded + 3) & ~3;

  final buf = Buffer.allocUnsafe(padded);

  // ✅ header
  buf[0] = 0x8F;
  buf[1] = 205;
  buf.writeUInt16BE((padded ~/ 4) - 1, 2);

  buf.writeUInt32BE(senderSsrc, 4);
  buf.writeUInt32BE(mediaSsrc, 8);

  // ✅ FCI header
  buf.writeUInt16BE(baseSeq, 12);
  buf.writeUInt16BE(packetCount, 14);

  buf[16] = (refTime24 >> 16) & 0xFF;
  buf[17] = (refTime24 >> 8) & 0xFF;
  buf[18] = refTime24 & 0xFF;

  buf[19] = fbPktCount;

  // ✅ chunks
  int off = 20;

  for (final c in chunks) {
    buf.writeUInt16BE(c & 0xFFFF, off);
    off += 2;
  }

  // ✅ deltas
  for (final d in deltas) {
    if (d.size == 1) {
      buf[off] = d.value & 0xFF;
      off += 1;
    } else {
      // writeInt16BE(buf, d.value, off);
      buf.writeInt16BE(d.value, off);
      off += 2;
    }
  }

  return buf;
}

Map<String, dynamic>? parseRTCP(Buffer buf) {
  if (buf.length < 4) return null;

  final b0 = buf[0];
  final version = (b0 >> 6) & 3;
  if (version != 2) return null;

  final padding = ((b0 >> 5) & 1) == 1;
  final count = b0 & 0x1F;
  final type = buf[1];
  final length = buf.readUInt16BE(2);

  final result = <String, dynamic>{
    'version': version,
    'padding': padding,
    'type': type,
    'length': length,
  };

  // ✅ SR (Sender Report)
  if (type == 200 && buf.length >= 28) {
    result['name'] = 'SR';
    result['ssrc'] = buf.readUInt32BE(4);
    result['ntpTimestampMsw'] = buf.readUInt32BE(8);
    result['ntpTimestampLsw'] = buf.readUInt32BE(12);
    result['rtpTimestamp'] = buf.readUInt32BE(16);
    result['packetCount'] = buf.readUInt32BE(20);
    result['octetCount'] = buf.readUInt32BE(24);

    final reports = [];
    for (int i = 0; i < count && 28 + (i + 1) * 24 <= buf.length; i++) {
      final off = 28 + i * 24;

      reports.add({
        'mediaSsrc': buf.readUInt32BE(off),
        'fractionLost': buf[off + 4],
        'totalLost':
            ((buf[off + 5] << 16) | (buf[off + 6] << 8) | buf[off + 7]),
        'highestSeq': buf.readUInt32BE(off + 8),
        'jitter': buf.readUInt32BE(off + 12),
        'lastSR': buf.readUInt32BE(off + 16),
        'delaySinceLastSR': buf.readUInt32BE(off + 20),
      });
    }

    result['reports'] = reports;
  }
  // ✅ PLI
  else if (type == 206 && count == 1 && buf.length >= 12) {
    result['name'] = 'PLI';
    result['senderSsrc'] = buf.readUInt32BE(4);
    result['mediaSsrc'] = buf.readUInt32BE(8);
  }
  // ✅ NACK
  else if (type == 205 && count == 1 && buf.length >= 16) {
    result['name'] = 'NACK';
    result['senderSsrc'] = buf.readUInt32BE(4);
    result['mediaSsrc'] = buf.readUInt32BE(8);
    result['lostSequenceNumbers'] = parseNackEntries(buf, 12);
  }
  // ✅ Transport-CC
  else if (type == 205 && count == 15 && buf.length >= 16) {
    result['name'] = 'TransportCC';
    result['senderSsrc'] = buf.readUInt32BE(4);
    result['mediaSsrc'] = buf.readUInt32BE(8);
    result['fci'] = buf.subarray(12);
  }
  // ✅ REMB
  else if (type == 206 && count == 15 && buf.length >= 20) {
    if (buf[12] == 0x52 &&
        buf[13] == 0x45 &&
        buf[14] == 0x4D &&
        buf[15] == 0x42) {
      result['name'] = 'REMB';
      result['senderSsrc'] = buf.readUInt32BE(4);
      result['mediaSsrc'] = buf.readUInt32BE(8);
      result['fci'] = buf.subarray(12);
    }
  }
  // ✅ FIR
  else if (type == 206 && count == 4 && buf.length >= 20) {
    result['name'] = 'FIR';
    result['senderSsrc'] = buf.readUInt32BE(4);
    result['mediaSsrc'] = buf.readUInt32BE(12);
    result['seqNr'] = buf[16];
  }
  // ✅ SDES
  else if (type == 202 && buf.length >= 8) {
    result['name'] = 'SDES';
    result['ssrc'] = buf.readUInt32BE(4);

    final items = [];
    int off = 8;

    while (off + 2 <= buf.length && buf[off] != 0) {
      final itemType = buf[off];
      final itemLen = buf[off + 1];

      if (off + 2 + itemLen > buf.length) break;

      final valueBytes = buf.subarray(off + 2, off + 2 + itemLen);
      final value = String.fromCharCodes(valueBytes);

      items.add({'type': itemType, 'value': value});

      off += 2 + itemLen;
    }

    if (items.isNotEmpty && items[0]['type'] == 1) {
      result['cname'] = items[0]['value'];
    }

    result['items'] = items;
  }
  // ✅ BYE
  else if (type == 203) {
    result['name'] = 'BYE';

    final ssrcs = [];

    for (int i = 0; i < count && 4 + (i + 1) * 4 <= buf.length; i++) {
      ssrcs.add(buf.readUInt32BE(4 + i * 4));
    }

    result['ssrcs'] = ssrcs;

    final reasonOff = 4 + count * 4;

    if (reasonOff + 1 <= buf.length && buf[reasonOff] > 0) {
      final rLen = buf[reasonOff];

      if (reasonOff + 1 + rLen <= buf.length) {
        final reasonBytes = buf.subarray(reasonOff + 1, reasonOff + 1 + rLen);

        result['reason'] = String.fromCharCodes(reasonBytes);
      }
    }
  }
  // ✅ RR
  else if (type == 201 && buf.length >= 32) {
    result['name'] = 'RR';

    result['ssrc'] = buf.readUInt32BE(4);
    result['mediaSsrc'] = buf.readUInt32BE(8);
    result['fractionLost'] = buf[12];

    result['totalLost'] = (buf[13] << 16) | (buf[14] << 8) | buf[15];

    result['highestSeq'] = buf.readUInt32BE(16);
    result['jitter'] = buf.readUInt32BE(20);
    result['lastSR'] = buf.readUInt32BE(24);
    result['delaySinceLastSR'] = buf.readUInt32BE(28);

    final reports = [];

    for (int i = 0; i < count && 8 + (i + 1) * 24 <= buf.length; i++) {
      final off = 8 + i * 24;

      reports.add({
        'mediaSsrc': buf.readUInt32BE(off),
        'fractionLost': buf[off + 4],
        'totalLost': (buf[off + 5] << 16) | (buf[off + 6] << 8) | buf[off + 7],
        'highestSeq': buf.readUInt32BE(off + 8),
        'jitter': buf.readUInt32BE(off + 12),
        'lastSR': buf.readUInt32BE(off + 16),
        'delaySinceLastSR': buf.readUInt32BE(off + 20),
      });
    }

    result['reports'] = reports;
  }

  return result;
}

/**
 * Parse a compound RTCP packet into an array of sub-packets.
 *
 * RFC 3550 §6.1 — RTCP packets are typically sent as compound packets
 * (e.g. SR+SDES, or RR+SDES+BYE). The transport carries one datagram, but
 * inside there are multiple RTCP "packets" concatenated. Each sub-packet
 * has its own 4-byte header with a `length` field (in 32-bit words, minus 1).
 *
 * Returns an array of parsed packets — call parseRTCP on each slice and
 * advance by (length + 1) * 4 bytes.
 *
 * @param {Buffer} buf — full RTCP datagram (post-decryption)
 * @returns {Array<object>} parsed sub-packets; empty if buf malformed
 */
List<Map<String, dynamic>> parseRTCPCompound(Buffer buf) {
  if (buf.length < 4) return [];

  final List<Map<String, dynamic>> out = [];

  int offset = 0;

  while (offset + 4 <= buf.length) {
    // ✅ length is in 32-bit words minus 1
    final subLenWords = buf.readUInt16BE(offset + 2) + 1;

    final subLen = subLenWords * 4;

    // ✅ sanity checks
    if (subLen <= 0 || offset + subLen > buf.length) {
      break;
    }

    // ✅ slice sub-packet
    final sub = Buffer.from(
      buf.subarray(offset, offset + subLen).buffer,
      buf.subarray(offset, offset + subLen).offsetInBytes,
      subLen,
    );

    final parsed = parseRTCP(sub);

    if (parsed != null) {
      out.add(parsed);
    }

    offset += subLen;
  }

  return out;
}
// ── Helpers ──

List<_NackEntry> _buildNackEntries(List<int> seqNums) {
  seqNums.sort();

  final entries = <_NackEntry>[];
  int i = 0;

  while (i < seqNums.length) {
    final pid = seqNums[i];
    int blp = 0;
    i++;

    while (i < seqNums.length && seqNums[i] - pid <= 16) {
      blp |= (1 << (seqNums[i] - pid - 1));
      i++;
    }

    entries.add(_NackEntry(pid, blp));
  }

  return entries;
}

class _NackEntry {
  final int pid;
  final int blp;

  _NackEntry(this.pid, this.blp);
}

List<int> _getNtpTimestamp() {
  final now = DateTime.now().millisecondsSinceEpoch;

  final sec = (now ~/ 1000) + 2208988800;
  final frac = ((now % 1000) / 1000 * 0x100000000).toInt() & 0xFFFFFFFF;

  return [sec, frac];
}

List<int> parseNackEntries(Buffer buf, int offset) {
  final List<int> lost = [];

  while (offset + 4 <= buf.length) {
    final pid = buf.readUInt16BE(offset);
    final blp = buf.readUInt16BE(offset + 2);

    // ✅ base packet (PID)
    lost.add(pid);

    // ✅ bitmask expansion (BLP)
    for (int bit = 0; bit < 16; bit++) {
      if ((blp & (1 << bit)) != 0) {
        lost.add(pid + bit + 1);
      }
    }

    offset += 4;
  }

  return lost;
}

String _toBase64(dynamic data) {
  if (data == null) return '';

  if (data is Uint8List) {
    return base64Encode(data);
  }

  if (data is List<int>) {
    return base64Encode(Uint8List.fromList(data));
  }

  if (data is ByteBuffer) {
    return base64Encode(Uint8List.view(data));
  }

  if (data is ByteData) {
    return base64Encode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  throw ArgumentError(
    'Unsupported type for base64 encoding: ${data.runtimeType}',
  );
}

String generateSDP(Map<String, dynamic>? opts) {
  opts ??= {};

  final addr = opts['address'] ?? '127.0.0.1';
  final port = opts['port'] ?? 5004;
  final codec = (opts['codec'] ?? 'h264').toString().toLowerCase();
  final pt = opts['payloadType'] ?? 96;
  final name = opts['name'] ?? 'media-processing RTP stream';

  final List<String> lines = [
    'v=0',
    'o=- 0 0 IN IP4 $addr',
    's=$name',
    'c=IN IP4 $addr',
    't=0 0',
  ];

  // ✅ H264
  if (codec == 'h264') {
    final clockRate = opts['clockRate'] ?? 90000;

    lines.add('m=video $port RTP/AVP $pt');
    lines.add('a=rtpmap:$pt H264/$clockRate');

    String fmtp = 'a=fmtp:$pt packetization-mode=1';

    if (opts['sps'] != null && opts['pps'] != null) {
      final sps = _toBase64(opts['sps']);
      final pps = _toBase64(opts['pps']);

      fmtp += '; sprop-parameter-sets=$sps,$pps';
    }

    lines.add(fmtp);
  }
  // ✅ H265 / HEVC
  else if (codec == 'h265' || codec == 'hevc') {
    final rate = opts['clockRate'] ?? 90000;

    lines.add('m=video $port RTP/AVP $pt');
    lines.add('a=rtpmap:$pt H265/$rate');

    final parts = <String>[];

    if (opts['vps'] != null) {
      parts.add('sprop-vps=${_toBase64(opts['vps'])}');
    }
    if (opts['sps'] != null) {
      parts.add('sprop-sps=${_toBase64(opts['sps'])}');
    }
    if (opts['pps'] != null) {
      parts.add('sprop-pps=${_toBase64(opts['pps'])}');
    }

    if (parts.isNotEmpty) {
      lines.add('a=fmtp:$pt ${parts.join("; ")}');
    }
  }
  // ✅ VP8
  else if (codec == 'vp8') {
    lines.add('m=video $port RTP/AVP $pt');
    lines.add('a=rtpmap:$pt VP8/90000');
  }
  // ✅ VP9
  else if (codec == 'vp9') {
    lines.add('m=video $port RTP/AVP $pt');
    lines.add('a=rtpmap:$pt VP9/90000');
  }
  // ✅ AV1
  else if (codec == 'av1') {
    lines.add('m=video $port RTP/AVP $pt');
    lines.add('a=rtpmap:$pt AV1/90000');
  }
  // ✅ OPUS
  else if (codec == 'opus') {
    final rate = opts['clockRate'] ?? 48000;
    lines.add('m=audio $port RTP/AVP $pt');
    lines.add('a=rtpmap:$pt opus/$rate/2');
  }
  // ✅ PCMU
  else if (codec == 'pcmu') {
    final pcmuPt = opts.containsKey('payloadType') ? pt : 0;
    lines.add('m=audio $port RTP/AVP $pcmuPt');
    lines.add('a=rtpmap:$pcmuPt PCMU/8000');
  }
  // ✅ PCMA
  else if (codec == 'pcma') {
    final pcmaPt = opts.containsKey('payloadType') ? pt : 8;
    lines.add('m=audio $port RTP/AVP $pcmaPt');
    lines.add('a=rtpmap:$pcmaPt PCMA/8000');
  }
  // ✅ G722
  else if (codec == 'g722') {
    final g722Pt = opts.containsKey('payloadType') ? pt : 9;
    lines.add('m=audio $port RTP/AVP $g722Pt');
    lines.add('a=rtpmap:$g722Pt G722/8000');
  }
  // ✅ AAC
  else if (codec == 'aac' || codec == 'mpeg4-generic') {
    final rate = opts['clockRate'] ?? 48000;
    final channels = opts['channels'] ?? 2;

    lines.add('m=audio $port RTP/AVP $pt');
    lines.add('a=rtpmap:$pt mpeg4-generic/$rate/$channels');

    String fmtp =
        'a=fmtp:$pt streamtype=5; profile-level-id=${opts['profileLevelId'] ?? 1}; '
        'mode=AAC-hbr; sizeLength=13; indexLength=3; indexDeltaLength=3';

    if (opts['config'] != null) {
      fmtp += '; config=${opts['config']}';
    }

    if (opts['constantDuration'] != null) {
      fmtp += '; constantDuration=${opts['constantDuration']}';
    }

    lines.add(fmtp);
  }
  // ✅ TELEPHONE EVENT (DTMF)
  else if (codec == 'telephone-event' || codec == 'dtmf') {
    final rate = opts['clockRate'] ?? 8000;
    final events = opts['events'] ?? '0-15';

    lines.add('m=audio $port RTP/AVP $pt');
    lines.add('a=rtpmap:$pt telephone-event/$rate');
    lines.add('a=fmtp:$pt $events');
  }

  lines.add('');

  return lines.join('\r\n');
}

Buffer buildSDES(int ssrc, String cname) {
  final cnameBytes = cname.codeUnits;

  // item: type + length + value
  final itemLen = 2 + cnameBytes.length;

  // chunk = SSRC (4) + item + null terminator
  final chunkLen = 4 + itemLen + 1;

  // align to 4 bytes
  final paddedChunkLen = (chunkLen + 3) & ~3;

  final buf = Buffer.allocUnsafe(4 + paddedChunkLen);

  // RTCP header
  buf[0] = 0x81; // V=2, SC=1
  buf[1] = 202; // SDES
  buf.writeUInt16BE(paddedChunkLen >> 2, 2);

  buf.writeUInt32BE(ssrc & 0xFFFFFFFF, 4);

  // SDES item (CNAME)
  buf[8] = 1; // CNAME
  buf[9] = cnameBytes.length;

  for (int i = 0; i < cnameBytes.length; i++) {
    buf[10 + i] = cnameBytes[i];
  }

  // rest is already zero (terminator + padding)

  return buf;
}

Buffer buildBYE(List<int> ssrcs, {String? reason}) {
  final reasonBytes = reason != null ? reason.codeUnits : null;

  final reasonLen = reasonBytes != null ? 1 + reasonBytes.length : 0;
  final paddedReasonLen = reasonBytes != null ? ((reasonLen + 3) & ~3) : 0;

  final totalLen = 4 + ssrcs.length * 4 + paddedReasonLen;

  final buf = Buffer.allocUnsafe(totalLen);

  // header
  buf[0] = 0x80 | (ssrcs.length & 0x1F);
  buf[1] = 203; // BYE
  buf.writeUInt16BE((totalLen >> 2) - 1, 2);

  // SSRCs
  for (int i = 0; i < ssrcs.length; i++) {
    buf.writeUInt32BE(ssrcs[i] & 0xFFFFFFFF, 4 + i * 4);
  }

  // reason (optional)
  if (reasonBytes != null) {
    final off = 4 + ssrcs.length * 4;

    buf[off] = reasonBytes.length;

    for (int i = 0; i < reasonBytes.length; i++) {
      buf[off + 1 + i] = reasonBytes[i];
    }
  }

  return buf;
}
// Buffer buildCompound(List<Buffer> packets) {
//   int totalLen = 0;

//   for (final p in packets) {
//     totalLen += p.length;
//   }

//   final out = Buffer.allocUnsafe(totalLen);

//   int offset = 0;

//   for (final p in packets) {
//     p.copy(out, offset);
//     offset += p.length;
//   }

//   return out;
// }
// NOTE: RTX (RFC 4588) build/parse used to live here but was buggy —
// it ignored CSRC lists and header extensions, copying only the fixed
// 12-byte RTP header. WebRTC packets carry RFC 5285 extensions
// (transport-cc, abs-send-time, mid…) so that implementation produced
// corrupt RTX packets. The correct implementation, which preserves
// the full original header (CSRCs + extension block), lives in
// retransmit.js as buildRtxPacket / parseRtxPacket.

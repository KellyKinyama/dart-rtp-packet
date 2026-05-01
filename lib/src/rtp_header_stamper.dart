// import 'dart:typed_data';
import 'rtp.dart';

class RtpHeaderStamper {
  Map<String, int> _extMap;

  String? _mid;
  Buffer? _midPayload;

  int _twccSeq;

  final Map<int, String> _ridBySsrc = {};
  final Map<int, String> _repairedRidBySsrc = {};

  final Map<int, Buffer> _ridPayloadCache = {};
  final Map<int, Buffer> _repairedRidPayloadCache = {};

  RtpHeaderStamper({
    Map<String, int>? extMap,
    String? mid,
    int initialTransportCcSeq = 0,
  }) : _extMap = extMap ?? {},
       _mid = mid,
       _twccSeq = initialTransportCcSeq & 0xFFFF {
    if (_mid != null && _extMap['mid'] != null) {
      _midPayload = Buffer.fromList(_mid!.codeUnits);
    }
  }

  // ✅ MAIN: apply extensions
  Buffer stamp(Buffer rtpPacket) {
    var pkt = rtpPacket;

    // ✅ transport-cc
    final twccId = _extMap['transport-cc'];
    if (twccId != null) {
      _twccSeq = (_twccSeq + 1) & 0xFFFF;
      pkt = setHeaderExtension(pkt, twccId, transportCC(_twccSeq));
    }

    // ✅ abs-send-time
    final absId = _extMap['abs-send-time'];
    if (absId != null) {
      pkt = setHeaderExtension(pkt, absId, absSendTime());
    }

    // ✅ MID
    final midId = _extMap['mid'];
    if (midId != null && _midPayload != null) {
      pkt = setHeaderExtension(pkt, midId, _midPayload!);
    }

    // ✅ RID / repaired RID
    final ridId = _extMap['rtp-stream-id'];
    final rridId = _extMap['repaired-rtp-stream-id'];

    if (ridId != null || rridId != null) {
      final ssrc = _readSsrc(pkt);

      if (ridId != null) {
        final payload = _ridPayloadCache[ssrc];
        if (payload != null) {
          pkt = setHeaderExtension(pkt, ridId, payload);
        }
      }

      if (rridId != null) {
        final payload = _repairedRidPayloadCache[ssrc];
        if (payload != null) {
          pkt = setHeaderExtension(pkt, rridId, payload);
        }
      }
    }

    return pkt;
  }

  // ✅ read SSRC directly (fast path)
  int _readSsrc(Buffer pkt) {
    return ((pkt[8] << 24) | (pkt[9] << 16) | (pkt[10] << 8) | pkt[11]) &
        0xFFFFFFFF;
  }

  // ✅ expose TWCC seq
  int lastTransportCcSeq() => _twccSeq;

  // ✅ update mid
  void setMid(String? mid) {
    _mid = mid;
    _midPayload = (_mid != null && _extMap['mid'] != null)
        ? Buffer.fromList(_mid!.codeUnits)
        : null;
  }

  // ✅ RID mapping
  void setRidForSsrc(int ssrc, String? rid) {
    final key = ssrc & 0xFFFFFFFF;

    if (rid == null) {
      _ridBySsrc.remove(key);
      _ridPayloadCache.remove(key);
    } else {
      final r = rid;
      _ridBySsrc[key] = r;
      _ridPayloadCache[key] = Buffer.fromList(r.codeUnits);
    }
  }

  // ✅ clear state
  void clearSsrc(int ssrc) {
    final key = ssrc & 0xFFFFFFFF;

    _ridBySsrc.remove(key);
    _ridPayloadCache.remove(key);

    _repairedRidBySsrc.remove(key);
    _repairedRidPayloadCache.remove(key);
  }

  // ✅ RTX mapping
  void setRtxRids(int ssrc, String? rid, String? repairedRid) {
    final key = ssrc & 0xFFFFFFFF;

    if (rid != null) {
      _ridBySsrc[key] = rid;
      _ridPayloadCache[key] = Buffer.fromList(rid.codeUnits);
    }

    if (repairedRid != null) {
      _repairedRidBySsrc[key] = repairedRid;
      _repairedRidPayloadCache[key] = Buffer.fromList(repairedRid.codeUnits);
    }
  }

  // ✅ update ext map (SDP renegotiation)
  void setExtMap(Map<String, int> extMap) {
    _extMap = extMap;

    _midPayload = (_mid != null && _extMap['mid'] != null)
        ? Buffer.fromList(_mid!.codeUnits)
        : null;
  }
}

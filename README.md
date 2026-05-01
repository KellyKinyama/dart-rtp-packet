# 📦 dart_rtp_packet

A complete **RTP/RTCP media stack for Dart**.

Build, parse, packetize, depacketize, encrypt, retransmit, and adapt real‑time media streams across all major codecs — fully in pure Dart.

Works anywhere RTP is used:

👉 WebRTC  
👉 SIP / VoIP  
👉 RTSP cameras  
👉 WHIP/WHEP  
👉 Raw RTP over UDP  

---

# 🚀 Features

## 🎥 Video Codecs
- ✅ H.264  
- ✅ H.265 (HEVC)  
- ✅ VP8  
- ✅ VP9  
- ✅ AV1  

## 🎧 Audio Codecs
- ✅ Opus  
- ✅ G.711 (μ-law / A-law)  
- ✅ G.722  
- ✅ AAC (RFC 3640 AAC-hbr)

## ☎️ Telephony
- ✅ DTMF (RFC 4733)

## 🌐 RTP / RTCP
- RTP packet parsing + building  
- Full RTCP support:
  - ✅ SR / RR  
  - ✅ NACK / PLI / FIR  
  - ✅ REMB  
  - ✅ Transport-CC (TWCC)  
  - ✅ SDES / BYE  
  - ✅ Compound packets  

## 🔒 Security
- ✅ SRTP (AES-128-CTR + HMAC-SHA1)  
- ✅ RFC 3711 compliant IV + salt  

## 📡 Networking & Reliability
- ✅ Jitter buffer (reordering + loss detection)  
- ✅ NACK + RTX (RFC 4585 / 4588)  
- ✅ Retransmission buffering  
- ✅ Feedback throttling  

## 📊 Congestion Control
- ✅ Transport‑CC parser  
- ✅ REMB parser  
- ✅ Delay-based bandwidth estimator  
- ✅ Feedback generator  

## 🧩 Extras
- ✅ SDP generation  
- ✅ RTP header extensions (RFC 5285)  
- ✅ Header extension stamping  

---

# 📦 Install

```yaml
dependencies:
  dart_rtp_packet:
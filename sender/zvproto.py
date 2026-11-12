"""zv-Protokoll v1: ein H.264-Access-Unit (Annex-B) wird in Fragmente <= MAX_PAYLOAD zerlegt.

Jedes Fragment ist genau eine zenoh-Nachricht (session.put) und damit ein UDP-Datagramm.

Header (16 Byte, Big-Endian):
  0  u8   version (=1)
  1  u8   flags   bit0 KEY (IDR enthalten), bit1 CONFIG (SPS/PPS enthalten)
  2  u16  frag_idx
  4  u16  frag_cnt
  6  u8   codec   1=H.264, 2=HEVC
  7  u8   reserved
  8  u32  frame_seq   fortlaufend pro Sender
  12 u32  pts_ms      Aufnahmezeit, Unix-Zeit in ms mod 2^32
"""
import struct

VERSION = 1
HDR = struct.Struct("!BBHHBBII")
FLAG_KEY = 0x01
FLAG_CONFIG = 0x02
CODEC_H264 = 1
CODEC_HEVC = 2
MAX_PAYLOAD = 1200  # + 16 B Header + ~30 B zenoh + 28 B UDP/IP  ->  ~1275 B pro Datagramm


def nal_types(au: bytes):
    """NAL-Typen eines Annex-B-Access-Units (H.264)."""
    types = []
    i, n = 0, len(au)
    while True:
        j = au.find(b"\x00\x00\x01", i)
        if j < 0 or j + 3 >= n:
            return types
        types.append(au[j + 3] & 0x1F)
        i = j + 3


def flags_for(au: bytes) -> int:
    t = nal_types(au)
    f = 0
    if 5 in t:
        f |= FLAG_KEY
    if 7 in t or 8 in t:
        f |= FLAG_CONFIG
    return f


def fragment(au: bytes, frame_seq: int, pts_ms: int, flags: int, max_payload=MAX_PAYLOAD, codec=CODEC_H264):
    cnt = max(1, (len(au) + max_payload - 1) // max_payload)
    for idx in range(cnt):
        chunk = au[idx * max_payload:(idx + 1) * max_payload]
        yield HDR.pack(VERSION, flags, idx, cnt, codec, 0, frame_seq & 0xFFFFFFFF, pts_ms & 0xFFFFFFFF) + chunk


def parse(msg: bytes):
    ver, flags, idx, cnt, codec, _, seq, pts = HDR.unpack_from(msg)
    return ver, flags, idx, cnt, codec, seq, pts, msg[HDR.size:]

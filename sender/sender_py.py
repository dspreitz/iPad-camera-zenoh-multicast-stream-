#!/usr/bin/env python3
"""iPad-Sender-Simulator (Python + zenoh-python).

ffmpeg erzeugt ein Testbild (oder liest eine beliebige Quelle), kodiert H.264
(Constrained Baseline, ~220 kbit/s) und schreibt Annex-B mit AUD-Trennern auf stdout.
Dieses Skript zerlegt den Strom in Access Units, fragmentiert sie (zvproto) und
publiziert jedes Fragment per session.put() über den zenoh-Peer (UDP-Multicast).
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time

import zenoh

import zvproto

AUD4 = b"\x00\x00\x00\x01\x09"


def ffmpeg_cmd(a):
    font = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
    if a.input:
        inp = ["-re", "-stream_loop", "-1", "-i", a.input]
    else:
        inp = ["-re", "-f", "lavfi", "-i", f"testsrc2=size={a.width}x{a.height}:rate={a.fps}"]
    vf = [f"scale={a.width}:{a.height}", f"fps={a.fps}"]
    if a.noise:
        # Kamerarauschen simulieren -> realistischere Last für die Ratenregelung
        vf.append(f"noise=alls={a.noise}:allf=t")
    if os.path.exists(font):
        vf.append(
            f"drawtext=fontfile={font}:text='%{{localtime\\:%T}} #%{{n}}':"
            "x=10:y=10:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.6"
        )
    br = a.bitrate_k
    return [
        "ffmpeg", "-hide_banner", "-loglevel", "error", *inp,
        "-vf", ",".join(vf), "-an",
        "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
        "-profile:v", "baseline", "-pix_fmt", "yuv420p",
        "-g", str(a.gop), "-keyint_min", str(a.gop), "-sc_threshold", "0",
        "-b:v", f"{br}k", "-maxrate", f"{br}k", "-bufsize", f"{int(br * 0.6)}k",
        "-x264-params", "repeat-headers=1:aud=1",
        "-f", "h264", "-",
    ]


def access_units(stream):
    """Liefert Access Units (ohne AUD) aus einem Annex-B-Strom mit AUD-Trennern."""
    buf = b""
    while True:
        chunk = stream.read1(65536) if hasattr(stream, "read1") else stream.read(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            s = buf.find(AUD4)
            if s < 0:
                break
            e = buf.find(AUD4, s + 5)
            if e < 0:
                break
            yield buf[s + 6:e]  # AUD = 00 00 00 01 09 xx
            buf = buf[e:]
    s = buf.find(AUD4)
    if s >= 0 and len(buf) > s + 6:
        yield buf[s + 6:]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", default=os.environ.get("ZV_CONFIG", "/app/config/peer-multicast.json5"))
    p.add_argument("--locator", default=os.environ.get("ZV_LOCATOR", ""))
    p.add_argument("--connect", default=os.environ.get("ZV_CONNECT", ""),
                   help="Client-Modus: z.B. tcp/zenohd1:7447 (statt Peer/Multicast)")
    p.add_argument("--key", default=os.environ.get("ZV_KEY", "video/ipad/h264"))
    p.add_argument("--width", type=int, default=int(os.environ.get("WIDTH", 640)))
    p.add_argument("--height", type=int, default=int(os.environ.get("HEIGHT", 360)))
    p.add_argument("--fps", type=int, default=int(os.environ.get("FPS", 10)))
    p.add_argument("--gop", type=int, default=int(os.environ.get("GOP", 20)))
    p.add_argument("--bitrate-k", type=int, default=int(os.environ.get("BITRATE_K", 220)))
    p.add_argument("--noise", type=int, default=int(os.environ.get("NOISE", 0)))
    p.add_argument("--input", default=os.environ.get("INPUT", ""))
    p.add_argument("--max-payload", type=int, default=int(os.environ.get("MAX_PAYLOAD", zvproto.MAX_PAYLOAD)))
    p.add_argument("--stats", default=os.environ.get("STATS_FILE", ""))
    a = p.parse_args()

    if a.connect:
        conf = zenoh.Config()
        conf.insert_json5("mode", '"client"')
        conf.insert_json5("connect/endpoints", json.dumps([a.connect]))
        conf.insert_json5("scouting/multicast/enabled", "false")
    else:
        with open(a.config) as f:
            conf = zenoh.Config.from_json5(f.read())
        if a.locator:
            conf.insert_json5("listen/endpoints", json.dumps([a.locator]))
    zenoh.init_log_from_env_or("error")
    session = zenoh.open(conf)
    time.sleep(1.0)

    cmd = ffmpeg_cmd(a)
    print("ffmpeg:", " ".join(cmd), file=sys.stderr, flush=True)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    signal.signal(signal.SIGTERM, lambda *_: proc.terminate())

    st = {"frames": 0, "keyframes": 0, "fragments": 0, "payload_bytes": 0, "max_au": 0, "start": time.time()}
    last = time.time()
    seq = 0
    for au in access_units(proc.stdout):
        flags = zvproto.flags_for(au)
        pts = int(time.time() * 1000)
        for frag in zvproto.fragment(au, seq, pts, flags, a.max_payload):
            session.put(a.key, frag, congestion_control=zenoh.CongestionControl.DROP)
            st["fragments"] += 1
            st["payload_bytes"] += len(frag)
        seq += 1
        st["frames"] += 1
        st["keyframes"] += 1 if flags & zvproto.FLAG_KEY else 0
        st["max_au"] = max(st["max_au"], len(au))
        now = time.time()
        if now - last >= 5:
            el = now - st["start"]
            line = (f"[sender] {st['frames']} frames ({st['frames']/el:.1f} fps), {st['keyframes']} key, "
                    f"{st['fragments']} frags, zv-payload {st['payload_bytes']*8/el/1000:.0f} kbit/s, max AU {st['max_au']} B")
            print(line, file=sys.stderr, flush=True)
            if a.stats:
                with open(a.stats, "w") as f:
                    json.dump({**st, "elapsed": el}, f)
            last = now
    session.close()


if __name__ == "__main__":
    main()

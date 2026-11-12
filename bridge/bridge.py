#!/usr/bin/env python3
"""zenoh -> WebSocket-Bridge mit Web-Viewer (WebCodecs).

Zweite zenoh-Instanz: abonniert den Video-Key (Peer über UDP-Multicast, oder als
Client an einem lokalen zenohd), setzt die zv-Fragmente wieder zu Access Units
zusammen und verteilt sie per WebSocket an Browser. Der Browser dekodiert mit
WebCodecs (VideoDecoder, Annex-B) und zeichnet auf ein <canvas>.

Verlustbehandlung (Best-Effort-Multicast, keine Retransmission):
  - fehlt ein Fragment, ist der ganze Frame verloren;
  - nach einem verlorenen Frame wird bis zum nächsten Keyframe nichts weitergegeben
    (sonst Artefakte/Decoderfehler). Mit GOP=1 s friert das Bild höchstens ~1 s ein.
  - Neue Browser bekommen sofort die GOP seit dem letzten Keyframe (schneller Start).
"""
import argparse
import asyncio
import json
import os
import struct
import sys
import threading
import time
from collections import deque

import zenoh
from aiohttp import web, WSMsgType

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sender"))
sys.path.insert(0, "/app/sender")
import zvproto  # noqa: E402

WS_HDR = struct.Struct("!BBHII")  # flags, codec, reserved, frame_seq, pts_ms
WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")


def now_ms32():
    return int(time.time() * 1000) & 0xFFFFFFFF


class Reassembler:
    def __init__(self, on_frame, max_pending=8):
        self.lock = threading.Lock()
        self.on_frame = on_frame
        self.pending = {}  # seq -> dict
        self.max_pending = max_pending
        self.last_seq = None
        self.need_key = True
        self.gop = []  # Frames seit letztem Keyframe (für neue Clients)
        self.st = dict(fragments=0, bytes=0, frames=0, keyframes=0, lost_frames=0, skipped=0,
                       bad=0, late=0, restarts=0)
        self.win = deque()  # (t, bytes) für Bitrate
        self.lat = deque()  # (t, latency_ms) Sender->Bridge (gleiche Uhr nur im Docker-Test)
        self.fps_win = deque()

    def on_sample(self, sample):
        msg = sample.payload.to_bytes()
        t = time.time()
        with self.lock:
            self.st["fragments"] += 1
            self.st["bytes"] += len(msg)
            self.win.append((t, len(msg)))
            if len(msg) < zvproto.HDR.size:
                self.st["bad"] += 1
                return
            ver, flags, idx, cnt, codec, seq, pts, data = zvproto.parse(msg)
            if ver != zvproto.VERSION or cnt == 0 or idx >= cnt:
                self.st["bad"] += 1
                return
            # Sender-Neustart erkennen (Sequenz springt weit zurück)
            if self.last_seq is not None and seq < self.last_seq and self.last_seq - seq > 1000:
                self.st["restarts"] += 1
                self.last_seq = None
                self.pending.clear()
                self.need_key = True
            if self.last_seq is not None and seq <= self.last_seq:
                self.st["late"] += 1
                return
            fr = self.pending.get(seq)
            if fr is None:
                fr = self.pending[seq] = dict(cnt=cnt, parts={}, flags=flags, pts=pts, codec=codec)
            fr["parts"][idx] = data
            if len(fr["parts"]) == fr["cnt"]:
                del self.pending[seq]
                au = b"".join(fr["parts"][i] for i in range(fr["cnt"]))
                self._complete(seq, fr, au, t)
            elif len(self.pending) > self.max_pending:
                old = min(self.pending)
                del self.pending[old]

    def _complete(self, seq, fr, au, t):
        # Alles Ältere, das noch fehlt, ist verloren.
        for s in [s for s in self.pending if s < seq]:
            del self.pending[s]
        if self.last_seq is not None and seq != self.last_seq + 1:
            self.st["lost_frames"] += seq - self.last_seq - 1
            self.need_key = True
        self.last_seq = seq
        key = bool(fr["flags"] & zvproto.FLAG_KEY)
        lat = (now_ms32() - fr["pts"]) & 0xFFFFFFFF
        if lat < 60000:
            self.lat.append((t, lat))
        if self.need_key and not key:
            self.st["skipped"] += 1
            return
        self.need_key = False
        self.st["frames"] += 1
        self.fps_win.append(t)
        if key:
            self.st["keyframes"] += 1
            self.gop = []
        pkt = WS_HDR.pack(fr["flags"], fr["codec"], 0, seq, fr["pts"]) + au
        self.gop.append(pkt)
        self.on_frame(pkt, key)

    def snapshot(self):
        t = time.time()
        with self.lock:
            for dq in (self.win, self.lat):
                while dq and dq[0][0] < t - 5:
                    dq.popleft()
            while self.fps_win and self.fps_win[0] < t - 5:
                self.fps_win.popleft()
            lats = sorted(x[1] for x in self.lat)
            span = 5.0
            return dict(
                self.st,
                zv_kbit_s=round(sum(b for _, b in self.win) * 8 / span / 1000, 1),
                fps=round(len(self.fps_win) / span, 1),
                lat_ms_p50=lats[len(lats) // 2] if lats else None,
                lat_ms_p95=lats[int(len(lats) * 0.95)] if lats else None,
                waiting_for_keyframe=self.need_key,
            )


class Hub:
    def __init__(self):
        self.clients = set()
        self.loop = None
        self.reasm = None

    def broadcast(self, pkt, key):
        for q in list(self.clients):
            if q.full():
                # Langsamer Browser: Queue leeren und auf Keyframe warten
                while not q.empty():
                    q.get_nowait()
                q.need_key = True
            if getattr(q, "need_key", False):
                if not key:
                    continue
                q.need_key = False
            q.put_nowait(pkt)

    def from_thread(self, pkt, key):
        if self.loop is not None:
            self.loop.call_soon_threadsafe(self.broadcast, pkt, key)


async def ws_handler(request):
    hub = request.app["hub"]
    ws = web.WebSocketResponse(heartbeat=10, max_msg_size=0)
    await ws.prepare(request)
    q = asyncio.Queue(maxsize=90)
    with hub.reasm.lock:
        for pkt in hub.reasm.gop:
            q.put_nowait(pkt)
        q.need_key = not hub.reasm.gop
    hub.clients.add(q)
    print(f"[bridge] client connected {request.remote}, {len(hub.clients)} total", flush=True)

    async def reader():
        async for m in ws:
            if m.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                break

    rt = asyncio.create_task(reader())
    try:
        while not ws.closed:
            try:
                pkt = await asyncio.wait_for(q.get(), timeout=1.0)
            except asyncio.TimeoutError:
                if rt.done():
                    break
                continue
            await ws.send_bytes(pkt)
    except (ConnectionResetError, RuntimeError):
        pass
    finally:
        hub.clients.discard(q)
        rt.cancel()
        print(f"[bridge] client gone, {len(hub.clients)} total", flush=True)
    return ws


async def stats_handler(request):
    hub = request.app["hub"]
    return web.json_response(dict(hub.reasm.snapshot(), clients=len(hub.clients)))


async def index(request):
    return web.FileResponse(os.path.join(WEB_DIR, "index.html"))


async def stats_logger(app):
    hub = app["hub"]
    path = app["stats_file"]
    while True:
        await asyncio.sleep(5)
        s = dict(hub.reasm.snapshot(), clients=len(hub.clients))
        print("[bridge] " + json.dumps(s), flush=True)
        if path:
            with open(path, "w") as f:
                json.dump(s, f)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", default=os.environ.get("ZV_CONFIG", "/app/config/peer-multicast.json5"))
    p.add_argument("--locator", default=os.environ.get("ZV_LOCATOR", ""),
                   help="überschreibt listen/endpoints (Peer-Modus)")
    p.add_argument("--connect", default=os.environ.get("ZV_CONNECT", ""),
                   help="Client-Modus: z.B. tcp/127.0.0.1:7447 (lokaler zenohd)")
    p.add_argument("--key", default=os.environ.get("ZV_KEY", "video/ipad/h264"))
    p.add_argument("--port", type=int, default=int(os.environ.get("HTTP_PORT", 8080)))
    p.add_argument("--stats", default=os.environ.get("STATS_FILE", ""))
    p.add_argument("--tls-cert", default=os.environ.get("TLS_CERT", ""), help="PEM-Zertifikat -> HTTPS")
    p.add_argument("--tls-key", default=os.environ.get("TLS_KEY", ""))
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

    hub = Hub()
    hub.reasm = Reassembler(hub.from_thread)
    session = zenoh.open(conf)
    sub = session.declare_subscriber(a.key, hub.reasm.on_sample)  # noqa: F841
    print(f"[bridge] zenoh {'client->' + a.connect if a.connect else 'peer'} subscribed {a.key}; http :{a.port}",
          flush=True)

    app = web.Application()
    app["hub"] = hub
    app["stats_file"] = a.stats
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)
    app.router.add_get("/stats", stats_handler)
    app.router.add_static("/", WEB_DIR)

    async def on_startup(app):
        hub.loop = asyncio.get_running_loop()
        app["logger"] = asyncio.create_task(stats_logger(app))

    app.on_startup.append(on_startup)
    ssl_ctx = None
    if a.tls_cert:
        import ssl
        ssl_ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_ctx.load_cert_chain(a.tls_cert, a.tls_key or None)
    print(f"[bridge] viewer: {'https' if ssl_ctx else 'http'}://<host>:{a.port}/", flush=True)
    web.run_app(app, port=a.port, print=None, ssl_context=ssl_ctx)


if __name__ == "__main__":
    main()

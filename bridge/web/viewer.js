// Web-Viewer: WebSocket (Bridge) -> WebCodecs VideoDecoder (H.264 Annex-B) -> <canvas>.
// WebCodecs gibt es nur in "secure contexts": https:// oder http://localhost.
'use strict';
const canvas = document.getElementById('c');
const ctx = canvas.getContext('2d');
const stateEl = document.getElementById('state');
const statsEl = document.getElementById('stats');

const S = window.zvStats = {
  wsMessages: 0, bytes: 0, decoded: 0, keyframes: 0, decodeErrors: 0, dropped: 0,
  codec: null, width: 0, height: 0, latencyMs: null, fps: 0, reconnects: 0, webcodecs: 'VideoDecoder' in window,
};
const latDec = [], latRx = [];
function pct(a, q) { if (!a.length) return null; const b = [...a].sort((x, y) => x - y); return b[Math.min(b.length - 1, Math.floor(b.length * q))]; }
function age(pts) { return ((Date.now() % 4294967296) - pts + 4294967296) % 4294967296; }
function push(a, v) { a.push(v); if (a.length > 150) a.shift(); }
let decoder = null, needKey = true, lastSeq = null, fpsCount = 0, fpsT = performance.now();

function setState(text, cls) { stateEl.textContent = text; stateEl.className = cls; }

function codecFromSps(au) {
  // Annex-B nach SPS (NAL-Typ 7) durchsuchen: profile_idc, constraint_flags, level_idc
  for (let i = 0; i + 7 < au.length; i++) {
    if (au[i] === 0 && au[i + 1] === 0 && au[i + 2] === 1 && (au[i + 3] & 0x1f) === 7) {
      const h = (b) => b.toString(16).padStart(2, '0');
      return 'avc1.' + h(au[i + 4]) + h(au[i + 5]) + h(au[i + 6]);
    }
  }
  return null;
}

function newDecoder(codec) {
  if (decoder && decoder.state !== 'closed') decoder.close();
  decoder = new VideoDecoder({
    output: (frame) => {
      if (canvas.width !== frame.displayWidth) { canvas.width = frame.displayWidth; canvas.height = frame.displayHeight; }
      ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
      S.width = frame.displayWidth; S.height = frame.displayHeight;
      S.latencyMs = age(frame.timestamp / 1000);
      push(latDec, S.latencyMs);
      frame.close();
      S.decoded++; fpsCount++;
    },
    error: (e) => { S.decodeErrors++; console.warn('decoder error', e); needKey = true; decoder = null; },
  });
  decoder.configure({ codec, optimizeForLatency: true, hardwareAcceleration: 'no-preference' });
  S.codec = codec;
}

function onPacket(buf) {
  const dv = new DataView(buf);
  const flags = dv.getUint8(0), seq = dv.getUint32(4), pts = dv.getUint32(8);
  const au = new Uint8Array(buf, 12);
  const key = (flags & 1) !== 0;
  push(latRx, age(pts));
  if (lastSeq !== null && seq !== lastSeq + 1 && !key) needKey = true; // Lücke (Bridge filtert schon, doppelt hält besser)
  lastSeq = seq;
  if (key) {
    S.keyframes++;
    const codec = codecFromSps(au);
    if (codec && (!decoder || codec !== S.codec)) newDecoder(codec);
  }
  if (!decoder || (needKey && !key)) { S.dropped++; return; }
  needKey = false;
  // Zu viel Rückstau im Decoder -> Frame verwerfen, auf Keyframe warten (Latenz klein halten)
  if (decoder.decodeQueueSize > 30) { needKey = true; S.dropped++; return; }
  try {
    decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: pts * 1000, data: au }));
  } catch (e) { S.decodeErrors++; needKey = true; }
}

function connect() {
  if (!S.webcodecs) {
    setState('kein WebCodecs (https:// oder localhost nötig, aktueller Browser)', 'err');
    return;
  }
  const proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
  const ws = new WebSocket(proto + location.host + '/ws');
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => setState('verbunden, warte auf Keyframe', 'warn');
  ws.onmessage = (ev) => { S.wsMessages++; S.bytes += ev.data.byteLength; onPacket(ev.data); };
  ws.onclose = () => { setState('getrennt, neuer Versuch…', 'err'); S.reconnects++; needKey = true; setTimeout(connect, 1000); };
}

setInterval(() => {
  const now = performance.now();
  S.fps = Math.round(fpsCount * 10000 / (now - fpsT)) / 10; fpsCount = 0; fpsT = now;
  S.latRxP50 = pct(latRx, 0.5); S.latRxP95 = pct(latRx, 0.95);
  S.latDecP50 = pct(latDec, 0.5); S.latDecP95 = pct(latDec, 0.95);
  if (S.decoded > 0 && S.fps > 0) setState('live', 'ok');
  statsEl.textContent =
    `codec ${S.codec || '-'}  ${S.width}x${S.height}  ${S.fps} fps  Latenz Empfang p50 ${S.latRxP50 ?? '-'} ms, Anzeige p50 ${S.latDecP50 ?? '-'} / p95 ${S.latDecP95 ?? '-'} ms (nur bei synchroner Uhr)\n` +
    `frames ${S.decoded}  keyframes ${S.keyframes}  verworfen ${S.dropped}  Decoderfehler ${S.decodeErrors}  ` +
    `empfangen ${(S.bytes / 1e6).toFixed(2)} MB  reconnects ${S.reconnects}`;
}, 1000);

connect();

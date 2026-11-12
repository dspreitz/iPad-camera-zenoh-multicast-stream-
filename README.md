# iPad-Kamera über zenoh in den Browser

Stand: 2026-11-12. Dieses Dokument wird fortlaufend ergänzt (Verlauf am Ende).

Ziel: Eine App auf einem iPad mini streamt das Kamerabild mit ca. 500 kbit/s über zenoh. Das Video wird in einer Webseite angezeigt.

## Kurzfassung

- **Topologie (Vorgabe des Nutzers, 2. Nachricht):**
  `iPad → zenoh-Server 1 ⇒ Datenlink (UDP-Multicast) ⇒ zenoh-Server 2 → Anzeige-Container (Podman) → Browser`
- **Wichtigstes Risiko: Paketverlust auf dem Datenlink.** Bei 1 % Verlust sinkt die Anzeige auf 7–10 fps, bei 5 % ist sie unbrauchbar. Gegenmaßnahmen stehen unter [Offene Punkte](#offene-punkte--risiken).
- **Prototyp läuft in Docker**, und zwar Ende-zu-Ende über zwei unveränderte `zenohd 1.10.1` (offiziell und gepatcht): 15 fps, 640×360, H.264. Auf dem Datenlink fließen **~480 kbit/s bei ~52 Paketen/s**. Alle Datagramme sind ≤ 1242 B UDP-Nutzlast, es gibt **keine IP-Fragmente**. Der Browser dekodiert ohne Fehler, die Latenz Sender → Anzeige liegt bei **p50 ~7 ms** (lokal, ohne echten Funklink). Messwerte: [Messungen](#messungen).
- **Anzeige-Seite = ein Container** (`viewer/Containerfile`, Podman-kompatibel): zenoh-Client zu Server 2, Reassembly, WebSocket und Web-Viewer (WebCodecs).
- **iPad-App:** Swift (AVCaptureSession → VideoToolbox-H.264 → **zenoh-pico** als Client per TCP zu Server 1). Encoder, Annex-B-Umsetzung und zenoh-pico-Sender sind **auf dem Mac getestet**, und zwar mit demselben Swift- und C-Code über einen Test-Harness. Ungetestet sind Kamera, UI und der Build für das Gerät, denn es gibt kein Xcode und kein iPad. Siehe [iPad-App](#ipad-app).
- **Kein Multicast-Entitlement nötig:** Das iPad spricht nur Unicast-TCP mit Server 1. Multicast läuft ausschließlich zwischen den beiden Servern.

- **Voreinstellung seit 12.11.2026: 220 kbit/s, 640×360 @ 10 fps, Keyframe alle 1 s** (App, Testsender, `run.sh`), ausgelegt für schmalbandige Datenlinks. Test gegen einen auf 250 kbit/s begrenzten Link: 450 kbit/s → 7 fps und > 30 s Verzögerung (Stau); 220 kbit/s → 10 fps, 142 ms (p50). Die Bitrate muss unter der tatsächlichen Link-Kapazität liegen.

## Architektur

```
 iPad mini (App "ZenohCam")                       Rechner A                  Datenlink                  Rechner B
 ┌──────────────────────────────┐   WLAN/TCP   ┌────────────────┐   UDP-Multicast 224.0.0.225   ┌────────────────┐  TCP  ┌────────────────────────┐  HTTP(S)/WS  ┌──────────┐
 │ AVCaptureSession 1280x720@15 │ ───────────▶ │ zenohd 1.10.x  │ ════════════════════════════▶ │ zenohd 1.10.x  │ ────▶ │ ipadvid-viewer (Podman)│ ───────────▶ │ Browser  │
 │ VideoToolbox H.264 640x360   │  zenoh-pico  │ Server 1, Peer │   (bestehende Konfiguration)  │ Server 2, Peer │       │ zenoh-Client, Reassem- │  WebCodecs   │ <canvas> │
 │ zv-Fragmente ≤1200 B         │  Client      └────────────────┘                               └────────────────┘       │ bly, WebSocket, Viewer │              └──────────┘
 └──────────────────────────────┘                                                                                        └────────────────────────┘
```

### Entscheidungen

| Thema | Entscheidung | Begründung |
|---|---|---|
| zenoh auf iOS | **zenoh-pico 1.10.2** (C), direkt als statische Lib/XCFramework | Reines C, baut mit Xcode-Clang ohne Rust-Toolchain. Die BSD-Socket-Schicht (`ZENOH_MACOS`) passt für iOS. Wird schon so auf iOS genutzt (z. B. swift-ros2, Apache-2.0, XCFrameworks für iOS). Klein (~1 MB). Auto-Reconnect ist eingebaut (`Z_FEATURE_AUTO_RECONNECT=1`). Getestet: Linux-Docker **und** nativ macOS (gleiche Quellen und Flags wie für iOS). |
| Alternative zenoh-c | nicht gewählt | Rust für `aarch64-apple-ios` wäre machbar, es gibt aber kein offizielles iOS-Paket und keine Swift-Bindings. Nötig wären Rust-Toolchain, cbindgen, eine große statische Lib (~20–30 MB) und ein eigenes XCFramework-Skript. Vorteil wäre nur die volle Feature-Parität, die hier nicht gebraucht wird. |
| Rolle des iPad | **Client** per TCP zu Server 1 | Das ist die Topologie-Vorgabe. Kein Multicast auf dem iPad, also kein Entitlement. TCP sichert die WLAN-Strecke ab. |
| Lizenz | zenoh-pico/zenoh: EPL-2.0 OR Apache-2.0 | Für eine interne App unkritisch. Bei Weitergabe Lizenztext beilegen. |
| Video | H.264 Constrained Baseline, 640×360 @ 10 fps, Ziel 220 kbit/s, Obergrenze 250 kbit/s/s, Keyframe alle 1 s, kein B-Frame (bis 12.11.: 15 fps, 450/500 kbit/s, Keyframe 2 s) | Jeder Browser dekodiert das (WebCodecs `avc1.42c016`). Kleine Keyframes (5–12 KB). Nach einem Verlust steht das Bild höchstens 2 s. HEVC würde ~30 % sparen, die Browser-Unterstützung ist aber uneinheitlich (Firefox/Chrome unter Linux). |
| Paketierung | eigenes Mini-Protokoll „zv v1“: 16-B-Header + ≤ 1200 B Nutzlast pro zenoh-`put` | Jede zenoh-Nachricht bleibt < MTU, keine IP-Fragmentierung (siehe Multicast-Problematik im Hauptprojekt). Das gilt unabhängig von batch_size-Fehlern in zenoh. Der Empfänger setzt Frames wieder zusammen. Siehe [Protokoll](#protokoll-zv-v1). |
| Senden | `session.put()` / `z_put()` ohne `declare_publisher` | Workaround für zenoh #2820: Ein spät verbundener Client sieht die Multicast-Subscriber nicht. Ein deklarierter Publisher würde sich dann für abnehmerlos halten und nichts senden. |
| Verlust | Best Effort, `CongestionControl.DROP`, keine Retransmission | Fehlt ein Fragment, wird der ganze Frame verworfen. Danach wartet die Anzeige auf den nächsten Keyframe (≤ 1 s). Die Bridge sendet neuen Browsern sofort die GOP seit dem letzten Keyframe, das ergibt einen schnellen Start. |
| Browser-Weg | **eigene kleine Bridge** (Python, zenoh-Client + aiohttp-WebSocket) + **WebCodecs** | Wenig Code, niedrige Latenz (kein Puffer wie bei MSE/HLS), Reassembly und Keyframe-Logik serverseitig, GOP-Cache für schnellen Start. Vergleich: [Browser-Optionen](#browser-optionen). |
| Anzeige-Container | `viewer/Containerfile` (Podman, auch Docker), Non-root, Healthcheck, optional HTTPS mit selbstsigniertem Zertifikat | Nutzervorgabe. WebCodecs gibt es nur auf `https://` oder `localhost`, deshalb HTTPS für entfernte Browser. |

### Browser-Optionen

| Option | Latenz | Aufwand | Bewertung |
|---|---|---|---|
| **A: eigene Bridge zenoh → WebSocket, WebCodecs im Browser** (gewählt) | ~10–50 ms + Netz | gering (~300 Zeilen Python + ~100 Zeilen JS) | Volle Kontrolle über Reassembly, Verlust und Start. Braucht einen secure context (HTTPS/localhost). Chrome/Edge/Safari ≥ 16.4/Firefox ≥ 130. |
| B: zenoh `remote-api`-Plugin + zenoh-ts im Browser + WebCodecs | ähnlich A | mittel | Das Plugin muss **binär exakt zur zenohd-Version passen**, mit dem gepatchten zenohd ist das heikel. Es müsste in den bestehenden Server 2 geladen werden. Reassembly und Keyframe-Logik lägen dann im Browser. Kein Vorteil gegenüber A. |
| C: Bridge → fMP4 → MSE (`<video>`) | 0,5–2 s (Puffer) | mittel (Remuxing) | Läuft ohne secure context. Die Latenz ist aber höher, und das Verhalten bei Lücken ist schlechter. |
| D: WebRTC (z. B. mediamtx/GStreamer/aiortc) | ~100–300 ms | hoch | ICE/STUN, SDP, schwer für einen kleinen Container. Lohnt erst bei vielen Zuschauern oder über NAT. |

### Protokoll „zv v1“

Ein zenoh-`put` auf Key `video/ipad/h264` (konfigurierbar) = ein Fragment:

```
Byte 0      version = 1
Byte 1      flags   bit0 KEY (IDR), bit1 CONFIG (SPS/PPS enthalten)
Byte 2-3    frag_idx   (Big-Endian)
Byte 4-5    frag_cnt
Byte 6      codec   1 = H.264, 2 = HEVC (reserviert)
Byte 7      reserviert
Byte 8-11   frame_seq  (fortlaufend pro Sender)
Byte 12-15  pts_ms     (Wanduhr bei Aufnahme, ms mod 2^32 → Latenzmessung bei synchronen Uhren)
Byte 16..   Nutzlast: Ausschnitt aus dem Access Unit im Annex-B-Format (Startcodes; Keyframes beginnen mit SPS+PPS)
```

Größen: 1200 B Nutzlast + 16 B Header + ~26 B zenoh = **1242 B UDP-Nutzlast** (gemessen), 1270 B IP. Das passt auch in MTU 1280 (IPv6-Minimum, viele VPNs/Funklinks).
Implementierungen: `sender/zvproto.py` (Python), `sender/csrc/zv_sender.c` (C, iPad + Linux-Test), `bridge/bridge.py` (Empfänger).

## Verzeichnis

| Pfad | Inhalt |
|---|---|
| `viewer/Containerfile`, `viewer/entrypoint.sh` | **Anzeige-Container** (Podman/Docker): Bridge + Web-Viewer |
| `viewer/podman.sh`, `viewer/ipadvid-viewer.container` | Podman: Build/Run/Save bzw. Quadlet-Unit (systemd-Autostart) |
| `bridge/bridge.py`, `bridge/web/` | zenoh → WebSocket-Bridge, Web-Viewer (WebCodecs, `viewer.js`) |
| `sender/csrc/zv_sender.[ch]` | C-Kern: Fragmentierung + zenoh-pico-Publish (iPad-App **und** Linux-Testsender) |
| `sender/csrc/main_stdin.c`, `sender/run_pico.sh` | Linux-Testsender: ffmpeg → H.264 → zv_pico_sender |
| `sender/sender_py.py`, `sender/zvproto.py` | Alternativer Testsender mit zenoh-python |
| `config/zenohd-server.json5` | Konfiguration der beiden zenoh-Server im Test (= Hauptprojekt-Konfiguration + TCP-Listener für Clients) |
| `config/peer-multicast.json5` | Nur für Variante „Anzeige/Sender selbst als Multicast-Peer“ |
| `docker/Dockerfile.*` | Test-Images: `ipadvid-zenohd:{stock,patched}`, `ipadvid-sender`, `ipadvid-pico`, `ipadvid-browser` |
| `run.sh` | Ende-zu-Ende-Test mit Messung (Bandbreite pro Strecke, Fragmente, Frames, Screenshot) |
| `test/matrix.sh`, `test/headless.js`, `test/podman-in-docker.sh` | Testmatrix, Headless-Chromium-Test, Podman-Test |
| `ios/` | iPad-App: Swift-Quellen, XcodeGen-Projekt, zenoh-pico-Build, macOS-Test-Harness |
| `third_party/` | Ablage für den gepatchten zenohd (nicht im Repo, Bezug siehe `third_party/README.md`) |
| `ios/ThirdParty/zenoh-pico` | Git-Submodul: eclipse-zenoh/zenoh-pico 1.10.2 (`6a881c2`) |
| `results/` | Messergebnisse je Lauf (`summary.txt`, Logs, `viewer.png`) |

## Lokale Voraussetzungen (geprüft am 2026-11-12)

| Werkzeug | Stand | Bedeutung |
|---|---|---|
| Xcode / `xcodebuild` | **fehlt** (nur CommandLineTools, `xcode-select -p` = `/Library/Developer/CommandLineTools`) | iOS-App bauen/signieren/aufs Gerät bringen **nicht möglich**. Xcode 16+ aus dem App Store nötig. |
| iOS-SDK | **fehlt** (nur MacOSX-SDKs 15/26) | wie oben |
| `swiftc` | 6.3.3 (CLT) | macOS-Harness baut und läuft. App-Code (ohne UIKit-Teil) typgeprüft gegen das macOS-SDK. |
| `clang`, `cmake` | CLT / Homebrew | zenoh-pico nativ für macOS gebaut |
| Rust | cargo 1.98.1, Targets `aarch64-apple-darwin`, `thumbv7em-none-eabihf` | **kein** `aarch64-apple-ios`. Nur für die zenoh-c-Variante nötig, die nicht gewählt ist. |
| Python / Node | 3.14.7 / 26.8.1 | lokal nicht nötig, alles läuft in Containern |
| ffmpeg | **fehlt lokal** | in den Containern vorhanden |
| Docker | colima, Docker 29.5.2, 4 CPU / 8 GiB | alle Tests |
| Podman | **fehlt lokal** | Anzeige-Container per Podman-in-Docker geprüft (Podman 5.6.2, `test/podman-in-docker.sh`). Nicht installiert, weil außerhalb des Projektordners. |
| XcodeGen | **fehlt** | `brew install xcodegen` (erzeugt das Xcode-Projekt aus `ios/project.yml`) |

## Schnellstart (Docker-Test auf dem Mac)

```bash
git clone --recurse-submodules https://github.com/dspreitz/iPad-camera-zenoh-multicast-stream-.git zenoh-ipad-video
cd zenoh-ipad-video   # bei bestehendem Klon: git submodule update --init
# Für die Variante "patched": gepatchten zenohd nach third_party/ legen (siehe third_party/README.md)
# Images bauen (einmalig, ~5 min)
docker build -f docker/Dockerfile.zenohd -t ipadvid-zenohd:stock .
docker build -f docker/Dockerfile.zenohd --build-arg VARIANT=patched -t ipadvid-zenohd:patched .
docker build -f docker/Dockerfile.sender -t ipadvid-sender .
docker build -f docker/Dockerfile.pico -t ipadvid-pico .
docker build -f viewer/Containerfile -t ipadvid-viewer .
docker build -f docker/Dockerfile.browser -t ipadvid-browser .

# Ende-zu-Ende-Test (60 s), Ergebnisse in results/<lauf>/summary.txt + viewer.png
./run.sh
# Laufen lassen und selbst ansehen: http://localhost:8080/  (localhost = secure context, WebCodecs geht)
KEEP=1 HEADLESS=0 ./run.sh
# Varianten
SENDER=py ./run.sh                     # zenoh-python statt zenoh-pico
ZENOHD=patched ./run.sh                # gepatchter zenohd 1.10.1
NETEM="loss 2%" ./run.sh               # Verlust auf dem Datenlink
NETEM="rate 600kbit delay 50ms" ./run.sh
LINK_MTU=1280 ./run.sh
SENDER=mac ./run.sh                    # Swift-Code der App (VideoToolbox) nativ auf dem Mac, s. iPad-App
./test/matrix.sh                       # alle Varianten nacheinander
# Aufräumen
docker rm -f ipadvid-ipad ipadvid-viewer ipadvid-zenohd1 ipadvid-zenohd2; docker network rm ipadvid-link ipadvid-wlan ipadvid-lan
# Images entfernen (~3,9 GB): ipadvid-browser 1,5 GB, ipadvid-pico/-sender je ~0,8 GB, -viewer 0,3 GB, -zenohd 2×0,2 GB
docker rmi ipadvid-browser ipadvid-pico ipadvid-sender ipadvid-viewer ipadvid-zenohd:stock ipadvid-zenohd:patched
```
Hinweis: Durch die wiederholten Builds sind namenlose (dangling) Image-Schichten entstanden. Ich habe sie nicht gelöscht, weil `docker image prune` auch fremde Images treffen würde. Bei Platzmangel bitte selbst prüfen.

## Anzeige-Container (Podman)

Enthält: zenoh-Client (Python `eclipse-zenoh 1.10.2`), Reassembly der zv-Fragmente, WebSocket-Server, Web-Viewer. Läuft als Non-root (UID 10001) auf Port 8080.

```bash
# auf dem Rechner hinter zenoh-Server 2 (Linux mit Podman):
podman build --format docker -f viewer/Containerfile -t ipadvid-viewer .     # --format docker: wegen HEALTHCHECK
# a) zenohd 2 läuft auf demselben Rechner (lauscht wie im Hauptprojekt auf tcp/127.0.0.1:7447):
podman run -d --name ipadvid-viewer --network host -e ZV_CONNECT=tcp/127.0.0.1:7447 -e HTTPS=1 \
  -v ipadvid-viewer-data:/data ipadvid-viewer
# b) zenohd 2 auf einem anderen Rechner:
podman run -d --name ipadvid-viewer -p 8080:8080 -e ZV_CONNECT=tcp/<IP-Server-2>:7447 -e HTTPS=1 ipadvid-viewer
# Browser: https://<Rechner>:8080/  (selbstsigniertes Zertifikat einmal akzeptieren)
# Autostart per systemd: viewer/ipadvid-viewer.container (Quadlet), Anleitung im Kopf der Datei
# Offline-Transfer: ./viewer/podman.sh save  -> ipadvid-viewer.tar ; dort: podman load -i ipadvid-viewer.tar
```

| Variable | Standard | Bedeutung |
|---|---|---|
| `ZV_CONNECT` | `tcp/host.containers.internal:7447` | zenoh-Server 2 |
| `ZV_KEY` | `video/ipad/h264` | Key, muss zur App passen |
| `HTTP_PORT` | 8080 | Port für Viewer, WebSocket und `/stats` |
| `HTTPS` | 0 | 1 = selbstsigniertes Zertifikat in `/data` erzeugen und HTTPS sprechen. **Pflicht für Browser auf anderen Rechnern**, weil WebCodecs nur im secure context läuft. |
| `TLS_CERT`/`TLS_KEY` | – | eigenes Zertifikat statt selbstsigniert |
| `ZV_MODE=peer`, `ZV_IFACE`, `ZV_GROUP` | client | Variante: der Container ist selbst Multicast-Peer (braucht `--network host`) |

Endpunkte: `/` Viewer, `/ws` WebSocket (Binärframes: 12-B-Header + Access Unit), `/stats` JSON (Fragmente, Frames, verlorene Frames, kbit/s, fps, Latenz).

## iPad-App

Quellen in `ios/`. Der Status jedes Teils ist unten markiert.

| Datei | Inhalt | Status |
|---|---|---|
| `ZenohCam/H264Encoder.swift` | VTCompressionSession: Low-Latency-Ratenregelung, Constrained Baseline, 220/250 kbit/s, Keyframe ≤ 1 s, kein Reordering. AVCC → Annex-B, SPS/PPS vor jedem Keyframe. Skaliert 1280×720 → 640×360. | **getestet auf macOS** (Harness, Hardware-Encoder des M2) |
| `ZenohCam/ZenohPublisher.swift` | Swift-Hülle um `zv_sender.c`: eigene Queue, Verbindungsaufbau mit Retry, Rückstau-Schutz (> 15 Frames → verwerfen bis Keyframe, Keyframe anfordern) | **getestet auf macOS** |
| `../sender/csrc/zv_sender.c` | C-Kern: Fragmentierung, zenoh-pico-Client, `z_put` mit DROP | **getestet** (Linux-Docker + macOS) |
| `ZenohCam/CameraCapture.swift` | AVCaptureSession, Rückkamera 1280×720, feste Bildrate (Voreinstellung 10 fps; greift auf der Mac-Kamera nicht), Querformat, Stabilisierung aus | typgeprüft (macOS-SDK), **auf dem iPad ungetestet** |
| `ZenohCam/StreamController.swift`, `ContentView.swift`, `ZenohCamApp.swift` | SwiftUI: Vorschau, Server-Adresse, Bitrate, Start/Stopp, Statistik, Display bleibt an | StreamController typgeprüft. UI **ungetestet** (UIKit nicht im macOS-SDK). |
| `ZenohCam/Info.plist`, `ZenohCam.entitlements` | Kamera- und Local-Network-Texte (Pflicht), Landscape, nur iPad. Keine besonderen Entitlements. | ungetestet |
| `project.yml` | XcodeGen: App-Target, Bridging-Header, Header-Pfade, `ZENOH_MACOS`, XCFramework | ungetestet |
| `scripts/build-zenoh-pico.sh` | zenoh-pico → `ZenohPico.xcframework` (iphoneos + simulator); `macosx` = Testbuild | macOS-Variante **getestet**, iOS-Variante ungetestet (braucht Xcode) |
| `scripts/build-mac-harness.sh`, `mac-harness/main.swift` | macOS-CLI: Testbild 1280×720 (oder Mac-Kamera mit Argument `camera`) → H264Encoder → ZenohPublisher | **getestet** (Testbild). Kamera-Modus nicht ausgeführt, weil er einen Berechtigungsdialog auslöst. |

### Bauen und aufs iPad bringen

1. Xcode (16 oder neuer) installieren, einmal starten, iOS-Plattform laden. `brew install xcodegen`.
2. `cd ios && ./scripts/build-zenoh-pico.sh` → `ZenohPico.xcframework`.
3. In `project.yml` `bundleIdPrefix`/`PRODUCT_BUNDLE_IDENTIFIER` und `DEVELOPMENT_TEAM` anpassen, dann `xcodegen generate` und `open ZenohCam.xcodeproj`.
4. iPad per USB verbinden. Am iPad den **Entwicklermodus** aktivieren (Einstellungen → Datenschutz & Sicherheit → Entwicklermodus, ab iPadOS 16). In Xcode das Gerät wählen und Run drücken.
5. Beim ersten Start Kamera und **„Lokales Netzwerk“** erlauben. Ohne die zweite Freigabe scheitert die TCP-Verbindung zu Server 1 stumm.
6. In der App `tcp/<IP von Server 1 im WLAN>:7447` eintragen und Start tippen.

**Apple-Account:**
- Ein kostenloses „Personal Team“ (Apple-ID) reicht für dieses Design (TCP, kein Multicast). Einschränkungen: Das Profil läuft nach **7 Tagen** ab (neu installieren), es gibt höchstens 3 Apps pro Gerät, und TestFlight geht nicht.
- Bezahlter Account (99 €/Jahr): Profile gelten 1 Jahr, Ad-hoc/TestFlight sind möglich.
- **Nur wenn das iPad selbst Multicast-Peer sein müsste**, bräuchte die App `com.apple.developer.networking.multicast`. Dieses Entitlement vergibt Apple nur auf Antrag (Formular, Bearbeitung typisch Tage), nur an bezahlte Accounts und nicht an Personal Teams. Ohne es liefert iOS beim Senden an Multicast-Adressen einen Fehler.
- Der gewählte Aufbau umgeht das vollständig.

### Server 1: nötige Änderung

Die Hauptprojekt-Konfiguration (`~/Desktop/zenoh/zenohd.json5`) lauscht per TCP nur auf `127.0.0.1`. Damit das iPad Server 1 erreicht, braucht **nur Server 1** einen zusätzlichen Listener auf der WLAN-Adresse:

```json5
listen: { endpoints: [
  "udp/224.0.0.225:7447#iface=<Datenlink-Interface>",
  "tcp/127.0.0.1:7447",
  "tcp/<WLAN-IP-von-Server-1>:7447",   // NEU: für das iPad (nicht 0.0.0.0, damit die Server untereinander nur Multicast nutzen)
]},
```

Server 2 bleibt unverändert, wenn der Anzeige-Container auf demselben Rechner mit `--network host` läuft (`tcp/127.0.0.1:7447`).

## Messungen

Docker/colima auf einem M2, je 60 s, `test/matrix.sh`. Video: 640×360 @ 15 fps, Ziel 450 kbit/s, GOP 30 (2 s). zenohd 1.10.1 mit Konfiguration `config/zenohd-server.json5`. „Datenlink“ = Multicast-Strecke zenohd1 → zenohd2, gemessen über die Interface-Zähler. „Anzeige“ = Headless-Chromium mit WebCodecs, die Latenz gilt ab Aufnahme, gemessen über die gemeinsame Uhr.
Rohdaten: `results/m*/summary.txt`, Screenshots in `results/m*/viewer.png`.

| Lauf | Sender | zenohd | Bedingung | iPad→S1 | Datenlink | Pakete/s | max. UDP | IP-Frag. | Frames verloren | fps Anzeige | Latenz Anzeige p50/p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| m1 | pico | stock | – | 490 kbit/s | **479 kbit/s** | 52 | 1242 B | 0 | 0 | 15 | 7 / 36 ms |
| m2 | pico | patched | – | 491 | 480 | 53 | 1243 B | 0 | 0 | 15 | 7 / 12 ms |
| m3 | pico | stock | Anzeige startet **nach** dem Sender | 498 | 488 | 54 | 1242 B | 0 | 0 | 15 | 7 / 12 ms |
| m4 | python | stock | – | 499 | 490 | 54 | 1242 B | 0 | 0 | 15 | 10 / 15 ms |
| m5 | pico | stock | Bildrauschen (schwerer zu kodieren) | 491 | 479 | 53 | 1242 B | 0 | 0 | 15 | 6 / 10 ms |
| m9 | pico | stock | **Datenlink-MTU 1280** | 498 | 487 | 53 | 1242 B | 0 | 0 | 15 | 6 / 10 ms |
| m8 | pico | stock | Datenlink **600 kbit/s + 50 ms** | 498 | 488 | 54 | 1242 B | 0 | 0 | 15 | 113 / 200 ms |
| m6 | pico | stock | **1 % Paketverlust** | 498 | 483 | 53 | 1242 B | 0 | 29 von 1050 | **6,6–10** | 8 / 11 ms |
| m11 | pico | stock | 1 % Verlust + Rauschen | 497 | 481 | 53 | 1242 B | 0 | 38 | 8,6–9 | 8 / 10 ms |
| m7 | pico | stock | **5 % Paketverlust** | 498 | 460 | 51 | 1242 B | 0 | 193 | **2–3** (ruckelt stark) | 8 / 602 ms |
| m10 | **Swift-Harness** (VideoToolbox, macOS) | stock | Sender auf dem Mac, TCP über colima-Portweiterleitung | – | 479 | 53 | 1242 B | 0 | 0 | 15 | 103 / 107 ms¹ |

¹ Die ~95 ms kommen von der TCP-Portweiterleitung Mac → colima-VM, nicht von zenoh. In der Bridge ist die Latenz bei allen Docker-internen Läufen p50 1–2 ms.

Weitere Ergebnisse:
- **Overhead:** zv-Nutzlast ~458 kbit/s → ~480 kbit/s auf dem Datenlink. Das sind rund 5 % (zenoh-Header ~26 B, UDP/IP 28 B, Joins alle 2,5 s). Die Rückrichtung zenohd2 → zenohd1 trägt nur ~0,2 kbit/s (Joins/Deklarationen).
- **Keyframes:** libx264 5–12 KB, VideoToolbox (Harness) bis ~8 KB, also 5–10 Fragmente. Delta-Frames passen meist in 1–3 Fragmente.
- **Verlust ist der kritische Punkt:** Ein verlorenes Datagramm kostet den Frame und alle Folgeframes bis zum nächsten Keyframe. Bei 1 % Paketverlust sinkt die Anzeige auf ~7–10 fps (sie friert jeweils bis zum Keyframe ein). Bei 5 % ist sie praktisch unbrauchbar. Gegenmaßnahmen sind unten bei den offenen Punkten aufgeführt.
- **#2820 mit zenoh-pico bestätigt** (`ZV_DECLARE_PUBLISHER=1`, Läufe `results/p2820-*`): Mit einem **deklarierten Publisher** sendet das iPad (pico) bei offiziellem zenohd 1.10.1 **gar nichts** (iPad → S1: 0,4 kbit/s, die Anzeige bekommt 0 Frames). pico unterdrückt das Senden selbst, weil Server 1 ihm den Multicast-Subscriber nicht meldet. Mit dem **gepatchten** zenohd: 15 fps, 0 Verlust. Mit `z_put` (Standard der App) funktioniert es mit beiden Varianten.
- **Podman:** `viewer/Containerfile` mit echtem Podman 5.6.2 gebaut und gestartet (`test/podman-in-docker.sh`, Podman läuft in einem Docker-Container). Healthcheck ok, empfängt 15 fps von zenohd2. HTTPS-Modus (`HTTPS=1`, selbstsigniert) getestet.

## Befunde

1. **zenoh-pico ↔ zenoh (Rust) über Multicast: batch_size muss exakt gleich sein.**
   Rust verwirft Joins mit anderer batch_size kommentarlos (nur im Debug-Log: `multicast/rx.rs`, „Ignoring Join … Unsupported Batch Size: 1472. Expected: 8192“). Der Rust-Wert ist `min(transport/link/tx/batch_size, Link-MTU, 8192)`, also standardmäßig 8192. zenoh-pico nimmt standardmäßig 2048 (`BATCH_MULTICAST_SIZE`).
   **Folge: Die Standardwerte von zenoh-pico und zenoh sind über Multicast nicht kompatibel.**
   Lösung: beide Seiten gleich setzen. Getestet: pico mit 1472 und Rust (Python 1.10.2) mit `batch_size: 1472` funktioniert. Für diese Topologie ist das nicht relevant, weil das iPad per TCP spricht. Es wird wichtig, falls das iPad doch Multicast-Peer werden soll.
   Nebenbefund: In zenoh-python 1.10.2 wirkt `transport/link/tx/batch_size` also auf den Multicast-Join. Das sollte gegen Befund 2 im Hauptprojekt (1.10.1) abgeglichen werden.
2. **Docker vergibt eth0/eth1 nicht verlässlich in Verbindungsreihenfolge**, wenn ein Container vor dem Start an zwei Netze angeschlossen wird. In einem Lauf landete der Multicast-Listener von zenohd 2 auf dem falschen Netz, und es kam nichts an. Deshalb wählt `docker/zenohd-entrypoint.sh` das Interface jetzt über das IP-Präfix (`LINK_IP_PREFIX`). Im Echtbetrieb gilt: `#iface=` in der Server-Konfiguration prüfen.
3. **zenoh #2820 betrifft auch zenoh-pico-Clients mit deklariertem Publisher.** Messung siehe oben. Deshalb muss die App `z_put` verwenden, solange die Server nicht gepatcht sind.
4. **Verlustempfindlichkeit:** Schon 1 % Paketverlust auf dem Datenlink halbiert die angezeigte Bildrate (siehe Messungen).
5. Headless-Chromium (Debian-Paket) dekodiert H.264 per WebCodecs (`isConfigSupported` → true). Playwright-Chromium kann das nicht (keine proprietären Codecs).

## Offene Punkte / Risiken

- **WLAN zwischen iPad und Server 1:** TCP glättet Verluste, bei schlechtem Empfang steigt aber die Latenz. Die App verwirft ab ~1 s Rückstau Frames und fordert einen Keyframe an. Auf echter Hardware ungetestet.
- **Datenlink:** Typ, MTU, Bandbreite und Verlustrate sind unbekannt. Getestet sind MTU 1500 und 1280, Verlust (netem) und Ratenbegrenzung, siehe Messungen. Echte Funkstrecken verlieren oft in Bursts. Dann friert das Bild bis zum nächsten Keyframe ein (≤ 2 s). Optional sind kürzere GOPs oder Intra-Refresh möglich.
- **zenoh #2820**, gemessen: Ein deklarierter pico-Publisher sendet bei offiziellem 1.10.1 nichts. Die App nutzt deshalb `z_put`. Mit dem gepatchten zenohd geht beides.
- **Verlust auf dem Datenlink:** Ab ~1 % Paketverlust leidet die Bildrate deutlich. Optionen, nach Aufwand sortiert:
  1. kürzeres Keyframe-Intervall (z. B. 1 s; kostet ~10–15 % Bitrate),
  2. **Intra-Refresh / periodische Intra-Slices** statt ganzer Keyframes (VideoToolbox: begrenzt), oder
  3. **Recovery-Nachfrage:** Die Bridge fordert per zenoh-`put` auf einen Rückkanal-Key einen Keyframe an, und die App reagiert mit `requestKeyframe()`. `requestKeyframe()` gibt es in der App schon, der Rückkanal fehlt noch. Kostet ~0 Bandbreite.
  4. FEC (z. B. XOR-Parität je Frame, +10–20 %).

  Der Verlust auf dem echten Datenlink ist zu messen, bevor entschieden wird.
- **Declare-Sturm (#2819):** Er tritt nur auf, wenn ≥ 2 Peers Subscriber auf demselben Key haben. Bei mehreren Anzeige-Containern an **verschiedenen** Servern gilt deshalb: gepatchten zenohd nutzen oder nur eine Anzeige pro Key.
- Hintergrundbetrieb: iOS stoppt die Kamera, wenn die App in den Hintergrund geht. Die App muss im Vordergrund bleiben, das Display bleibt an.
- Kein Audio, keine Verschlüsselung auf zenoh-Ebene (zenoh-TLS wäre möglich, kostet aber Bytes).

## Verlusttest mit Mac-Kamera (2026-11-12)

Echte Mac-Kamera (`zv-mac-harness … camera`), ~450 kbit/s, netem-Verlust live auf dem Datenlink (`eth0` beider zenohd, beide Richtungen), je 20 s am Viewer gemessen:

| Verlust | angezeigt | verlorene Frames | übersprungene Frames |
|---|---|---|---|
| 0 % | 30 fps | 0 | 0 |
| 1 % | ~24,5 fps | 11 | 101 |
| 5 % | ~7 fps | 64 | 397 |

Befunde dabei:
- `SENDER=mac ./run.sh` sendet ein **Testbild**; die Kamera braucht das zusätzliche Harness-Argument `camera` (das `run.sh` bisher nicht übergibt).
- Die feste 15-fps-Einstellung in `CameraCapture.swift` greift auf der Mac-Kamera nicht (30 fps); auf dem iPad zu prüfen.
- Echte Kamerabilder erzeugen größere Keyframes (bis ~23 KB statt ~8 KB beim Testbild) → mehr Fragmente je Keyframe, verlustanfälliger.

## Mac-Kamera mit neuer Voreinstellung (2026-11-12)

`SENDER=mac MAC_CAMERA=1 ./run.sh` (Lauf `results/20261112-231207-mac-stock`), 220 kbit/s, Ziel 10 fps, Keyframe 1 s:

| Messwert | Wert |
|---|---|
| Encoder / zenoh | 221 / 227 kbit/s |
| Datenlink (Multicast) | 257 kbit/s tx, 249 kbit/s rx, 0 IP-Fragmente |
| Bildrate | **~30 fps** (Kamera ignoriert die 10-fps-Vorgabe) |
| Keyframes | 1/s, bis 26,5 KB |
| Anzeige | 0 verlorene Frames, Latenz p50 37 ms |

- **Bildrate muss in der App erzwungen werden:** Mit 30 statt 10 fps entstehen mehr Pakete und mehr Overhead (Link ≈ 250–257 statt ≈ 234 kbit/s beim 10-fps-Testbild). Auf einem 250-kbit/s-Link wäre das wieder an der Grenze. → überzählige Frames vor dem Encoder verwerfen.
- **Keyframes dominieren das Budget:** 26,5 KB je Sekunde ≈ 210 kbit/s → für P-Frames bleibt wenig, Bildqualität leidet. → Keyframe-Abstand eher 2 s, dafür Keyframe-Anforderung nach Verlust.

## Fragen an den Nutzer

1. **Datenlink:** Welche nutzbare Bandbreite, MTU und Verlustrate hat der Datenlink? Wird IP-Multicast unverändert weitergeleitet? *Annahme: MTU ≥ 1280.*
2. **Server-Versionen:** Laufen die bestehenden Server mit zenohd 1.10.1 offiziell oder gepatcht? *Annahme: 1.10.1. Beide Varianten getestet.*
3. **Netz iPad ↔ Server 1:** Ist das WLAN mit Server 1 direkt verbunden? Wie lautet dessen IP/Interface? Darf Server 1 einen TCP-Listener auf dieser Adresse bekommen? *Annahme: ja.*
4. **Anzeige-Rechner:** Läuft Podman auf demselben Rechner wie Server 2 (Linux)? Von wo wird die Webseite geöffnet? *Annahme: derselbe Rechner, `--network host`, Browser auch von anderen Rechnern → HTTPS=1.*
5. **Apple-Account:** Personal Team (kostenlos, 7-Tage-Profil) oder bezahlter Developer-Account? *Annahme: zunächst Personal Team.*
6. **Bildformat:** Reichen 640×360 @ 10 fps bei 220 kbit/s, oder sind mehr Schärfe bzw. weniger Bewegung gewünscht (z. B. 960×540 @ 10 fps)?
7. Sollen die Server auf den gepatchten zenohd umgestellt werden? Dann wären deklarierte Publisher und mehrere Anzeigen problemlos.
8. Darf ich Podman auf dem Mac installieren (`brew install podman`), um den Anzeige-Container auch nativ zu testen? Bisher ist er nur per Podman-in-Docker geprüft.

## Verlauf

| Datum | Eintrag |
|---|---|
| 2026-11-12 | Projekt angelegt. Recherche: zenoh 1.10.2 ist erschienen und enthält den Kompressions-Fix #2821. #2819/#2820 sind weiter offen. |
| 2026-11-12 | Prototyp v0 (iPad als Multicast-Peer, Bridge als Peer) läuft: Python-Sender → Bridge → Headless-Browser, 15 fps, 0 Fehler. |
| 2026-11-12 | Nutzerwunsch: Anzeige-Funktion als Podman-Container → `viewer/Containerfile`. |
| 2026-11-12 | Befund 1 (pico/Rust batch_size bei Multicast). |
| 2026-11-12 | Nutzervorgabe Topologie: iPad → Server 1 → Datenlink → Server 2 → Anzeige. Umbau: iPad und Anzeige sind Clients, Multicast nur zwischen zwei zenohd 1.10.1. Damit entfällt das iOS-Multicast-Entitlement. |
| 2026-11-12 | Testmatrix m1–m11 (siehe Messungen), #2820-Test mit pico, Podman-Test, HTTPS-Test. |
| 2026-11-12 | Swift-Encoder und Publisher über den macOS-Harness Ende-zu-Ende getestet (VideoToolbox → zenoh-pico → zenohd1 → Multicast → zenohd2 → Browser). |

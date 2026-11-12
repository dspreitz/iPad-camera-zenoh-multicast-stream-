#!/usr/bin/env bash
# End-to-end-Test in Docker (colima):
#
#   [ipadvid-ipad]  --TCP-->  [ipadvid-zenohd1] ==UDP-Multicast==> [ipadvid-zenohd2] <--TCP-- [ipadvid-viewer] <-- Browser
#    iPad-Simulator     Netz ipadvid-wlan     Netz ipadvid-link (Datenlink)     Netz ipadvid-lan      (headless Chromium)
#
# Parameter (Umgebungsvariablen):
#   SENDER=pico|py|mac  iPad-Simulator: zenoh-pico (C-Kern der App, Standard), zenoh-python, oder
#                       mac = nativer macOS-Harness mit dem Swift-Code der App (VideoToolbox), ios/build/harness/zv-mac-harness
#   ZENOHD=stock|patched  zenohd 1.10.1 offiziell oder mit Fix 1-3 (Hauptprojekt)
#   DURATION=60         Messdauer in s
#   ORDER=sender-last|sender-first   Startreihenfolge (sender-first: Anzeige verbindet sich zuletzt)
#   LINK_MTU=1500       MTU des Datenlinks
#   NETEM=""            z.B. "loss 2%" oder "rate 1mbit delay 50ms" auf dem Datenlink (beide Richtungen)
#   BITRATE_K=220 FPS=10 WIDTH=640 HEIGHT=360 GOP=10 NOISE=0   Video-Parameter (GOP in Frames, 10 = 1 s)
#   MAC_CAMERA=1        bei SENDER=mac die Mac-Kamera statt des Testbilds verwenden
#   HEADLESS=1          Browser-Test (Frames zählen + Screenshot)
#   KEEP=0              1 = Container nach dem Test laufen lassen (Viewer: http://localhost:8080/)
set -euo pipefail
cd "$(dirname "$0")"

SENDER=${SENDER:-pico}; ZENOHD=${ZENOHD:-stock}; DURATION=${DURATION:-60}; ORDER=${ORDER:-sender-last}
LINK_MTU=${LINK_MTU:-1500}; NETEM=${NETEM:-}; HEADLESS=${HEADLESS:-1}; KEEP=${KEEP:-0}
RUN=${RUN:-$(date +%Y%m%d-%H%M%S)-${SENDER}-${ZENOHD}}
OUT=results/$RUN; mkdir -p "$OUT"
VID_ENV=(-e BITRATE_K=${BITRATE_K:-220} -e FPS=${FPS:-10} -e WIDTH=${WIDTH:-640} -e HEIGHT=${HEIGHT:-360} -e GOP=${GOP:-10} -e NOISE=${NOISE:-0})

log() { echo "[run] $*" | tee -a "$OUT/summary.txt"; }
cleanup() {
  docker rm -f ipadvid-ipad ipadvid-viewer ipadvid-zenohd1 ipadvid-zenohd2 ipadvid-browser-run >/dev/null 2>&1 || true
}
cleanup
for n in wlan lan; do docker network inspect ipadvid-$n >/dev/null 2>&1 || docker network create ipadvid-$n >/dev/null; done
docker network rm ipadvid-link >/dev/null 2>&1 || true
docker network create --opt com.docker.network.driver.mtu=$LINK_MTU ipadvid-link >/dev/null

log "Lauf $RUN: SENDER=$SENDER ZENOHD=$ZENOHD DURATION=${DURATION}s ORDER=$ORDER LINK_MTU=$LINK_MTU NETEM='${NETEM}' ${VID_ENV[*]}"

LINK_PREFIX=$(docker network inspect ipadvid-link --format '{{(index .IPAM.Config 0).Subnet}}' | cut -d. -f1-2).
# Interfacename eines Containers im Netz mit IP-Präfix $2 (Docker vergibt eth0/eth1 nicht verlässlich)
ifname() { docker exec ipadvid-$1 ip -o -4 addr show | awk -v p="$2" 'index($4, p) == 1 {print $2; exit}'; }
start_server() { # name zweitnetz
  local pub=""; [ "$1" = zenohd1 ] && pub="-p 127.0.0.1:17447:7447"   # für SENDER=mac (Harness auf dem Mac)
  docker create --name ipadvid-$1 --hostname $1 --network ipadvid-link --cap-add NET_ADMIN $pub \
    -e LINK_IP_PREFIX=$LINK_PREFIX -e RUST_LOG=${RUST_LOG:-warn} ipadvid-zenohd:$ZENOHD >/dev/null
  docker network connect --alias $1 ipadvid-$2 ipadvid-$1
  docker start ipadvid-$1 >/dev/null
  sleep 0.5
  local L; L=$(ifname $1 $LINK_PREFIX)
  local O; O=$(docker exec ipadvid-$1 ip -o -4 addr show | awk -v l="$L" '$2 != "lo" && $2 != l {print $2; exit}')
  eval "LINK_IF_$1=$L; OTHER_IF_$1=$O"
  if [ -n "$NETEM" ]; then docker exec ipadvid-$1 tc qdisc add dev $L root netem $NETEM; fi
}
start_viewer() {
  docker run -d --name ipadvid-viewer --network ipadvid-lan -p 127.0.0.1:8080:8080 \
    -e ZV_CONNECT=tcp/zenohd2:7447 ipadvid-viewer >/dev/null
}
start_sender() {
  if [ "$SENDER" = "mac" ]; then
    ios/build/harness/zv-mac-harness tcp/127.0.0.1:17447 $((DURATION + 40)) ${BITRATE_K:-220} ${FPS:-10} $([ "${MAC_CAMERA:-0}" = 1 ] && echo camera) > "$OUT/ipad.log" 2>&1 &
    MAC_PID=$!
  elif [ "$SENDER" = "py" ]; then
    docker run -d --name ipadvid-ipad --network ipadvid-wlan "${VID_ENV[@]}" -e ZV_CONNECT=tcp/zenohd1:7447 \
      ipadvid-sender python3 /app/sender/sender_py.py >/dev/null
  else
    docker run -d --name ipadvid-ipad --network ipadvid-wlan "${VID_ENV[@]}" -e ZV_LOCATOR=tcp/zenohd1:7447 -e ZV_DECLARE_PUBLISHER=${ZV_DECLARE_PUBLISHER:-0} \
      ipadvid-pico >/dev/null
  fi
}

start_server zenohd1 wlan
start_server zenohd2 lan
sleep 3
if [ "$ORDER" = "sender-first" ]; then start_sender; sleep 8; start_viewer; else start_viewer; sleep 3; start_sender; fi
sleep 8  # Aufwärmen: Join, Deklarationen, erster Keyframe

ctr() { docker exec ipadvid-$1 cat /sys/class/net/$2/statistics/$3; }
L1=$LINK_IF_zenohd1; W1=$OTHER_IF_zenohd1; L2=$LINK_IF_zenohd2; W2=$OTHER_IF_zenohd2
log "Interfaces: zenohd1 Datenlink=$L1 WLAN=$W1 | zenohd2 Datenlink=$L2 LAN=$W2"
read_all() {
  echo "$(ctr zenohd1 $W1 rx_bytes) $(ctr zenohd1 $L1 tx_bytes) $(ctr zenohd1 $L1 tx_packets) $(ctr zenohd2 $L2 rx_bytes) $(ctr zenohd2 $L2 rx_packets) $(ctr zenohd2 $W2 tx_bytes) $(ctr zenohd2 $L2 tx_bytes)"
}
# tcpdump auf dem Datenlink (Empfangsseite): Paketgrößen und IP-Fragmente
docker exec -d ipadvid-zenohd2 sh -c "timeout $DURATION tcpdump -ni $L2 -w /tmp/link.pcap udp or 'ip[6:2] & 0x3fff != 0' 2>/dev/null"
B0=($(read_all)); T0=$(date +%s)
if [ "$HEADLESS" = "1" ]; then
  docker run --rm --name ipadvid-browser-run --network container:ipadvid-viewer -v "$PWD/$OUT":/out ipadvid-browser \
    http://localhost:8080/ "$DURATION" /out/viewer.png > "$OUT/browser.log" 2>&1 || true
else
  sleep "$DURATION"
fi
B1=($(read_all)); T1=$(date +%s); EL=$((T1 - T0))
kbit() { echo "scale=1; ($2 - $1) * 8 / $EL / 1000" | bc; }
sleep 1
docker exec ipadvid-zenohd2 sh -c "tcpdump -nr /tmp/link.pcap 2>/dev/null" > "$OUT/link-tcpdump.txt" || true
FRAGS=$(docker exec ipadvid-zenohd2 sh -c "tcpdump -nr /tmp/link.pcap 'ip[6:2] & 0x3fff != 0' 2>/dev/null | wc -l" || echo "?")
MAXLEN=$(awk '/UDP, length/ {l=$NF; if (l>m) m=l} END {print m+0}' "$OUT/link-tcpdump.txt")
PKTS=$(grep -c "UDP, length" "$OUT/link-tcpdump.txt" || true)
log "Messdauer ${EL}s"
log "iPad -> zenohd1 (WLAN-Seite, rx):           $(kbit ${B0[0]} ${B1[0]}) kbit/s"
log "zenohd1 -> Datenlink (tx):              $(kbit ${B0[1]} ${B1[1]}) kbit/s, $(( (B1[2]-B0[2]) / EL )) Pakete/s"
log "Datenlink -> zenohd2 (rx):              $(kbit ${B0[3]} ${B1[3]}) kbit/s, $(( (B1[4]-B0[4]) / EL )) Pakete/s"
log "zenohd2 -> Datenlink (Rückrichtung, tx): $(kbit ${B0[6]} ${B1[6]}) kbit/s"
log "zenohd2 -> Anzeige-Container (tx):      $(kbit ${B0[5]} ${B1[5]}) kbit/s"
log "Datenlink-tcpdump: $PKTS UDP-Pakete, max. UDP-Länge $MAXLEN B, IP-Fragmente: $FRAGS"
if [ "$SENDER" = "mac" ]; then
  log "Sender:  $(grep '^\[harness\] [0-9]' "$OUT/ipad.log" | tail -1)"; kill ${MAC_PID:-0} 2>/dev/null || true
else
  log "Sender:  $(docker logs ipadvid-ipad 2>&1 | grep -E '^\[(pico-)?sender\]' | tail -1)"
fi
curl -s localhost:8080/stats > "$OUT/bridge-stats.json" || true
log "Bridge:  $(cat "$OUT/bridge-stats.json")"
[ "$HEADLESS" = "1" ] && log "Browser: $(grep -E '^RESULT|^support' "$OUT/browser.log" | tr '\n' ' ')"
[ "$HEADLESS" = "1" ] && log "Browser letzte Stats: $(grep '^t=' "$OUT/browser.log" | tail -1)"
for c in viewer zenohd1 zenohd2 $([ "$SENDER" = mac ] || echo ipad); do docker logs ipadvid-$c > "$OUT/$c.log" 2>&1 || true; done
if [ "$KEEP" != "1" ]; then cleanup; docker network rm ipadvid-link >/dev/null 2>&1 || true; else log "Container laufen weiter: http://localhost:8080/  (Aufräumen: ./run.sh-cleanup oder docker rm -f ipadvid-...)"; fi
log "Ergebnisse: $OUT"

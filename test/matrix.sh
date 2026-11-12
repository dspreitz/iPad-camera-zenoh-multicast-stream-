#!/usr/bin/env bash
# Testmatrix: mehrere run.sh-Läufe hintereinander, Kurzfassung nach results/matrix-<datum>.txt
cd "$(dirname "$0")/.."
M=results/matrix-$(date +%Y%m%d-%H%M%S).txt
run() { echo "=== $*" | tee -a $M; env "$@" ./run.sh 2>&1 | grep -E "Datenlink|iPad ->|Anzeige|Bridge:|Browser|Sender:" | tee -a $M; }
D=${DURATION:-60}
run RUN=m1-pico-stock        SENDER=pico ZENOHD=stock   DURATION=$D
run RUN=m2-pico-patched      SENDER=pico ZENOHD=patched DURATION=$D
run RUN=m3-pico-senderfirst  SENDER=pico ZENOHD=stock   DURATION=$D ORDER=sender-first
run RUN=m4-py-stock          SENDER=py   ZENOHD=stock   DURATION=$D
run RUN=m5-pico-noise        SENDER=pico ZENOHD=stock   DURATION=$D NOISE=10
run RUN=m6-pico-loss1        SENDER=pico ZENOHD=stock   DURATION=$D NETEM="loss 1%"
run RUN=m7-pico-loss5        SENDER=pico ZENOHD=stock   DURATION=$D NETEM="loss 5%"
run RUN=m8-pico-rate600k     SENDER=pico ZENOHD=stock   DURATION=$D NETEM="rate 600kbit delay 50ms"
run RUN=m9-pico-mtu1280      SENDER=pico ZENOHD=stock   DURATION=$D LINK_MTU=1280
run RUN=m10-mac-harness      SENDER=mac  ZENOHD=stock   DURATION=$D
run RUN=m11-pico-noise-loss1 SENDER=pico ZENOHD=stock   DURATION=$D NOISE=10 NETEM="loss 1%"
echo "fertig: $M"

#!/usr/bin/env bash
# Prüft den Anzeige-Container mit ECHTEM Podman, ohne Podman auf dem Mac zu installieren:
# Podman läuft in einem (privilegierten) Docker-Container "ipadvid-podman" (Image quay.io/podman/stable),
# baut dort viewer/Containerfile mit "podman build" und startet ihn mit "podman run" gegen zenohd2 im Docker-Test.
# Voraussetzung: ./run.sh mit KEEP=1 läuft (zenohd1/zenohd2/iPad-Simulator aktiv).
set -euo pipefail
cd "$(dirname "$0")/.."
docker rm -f ipadvid-podman >/dev/null 2>&1 || true
docker run -d --name ipadvid-podman --privileged --network ipadvid-lan \
  -v "$PWD":/src:ro quay.io/podman/stable:v5.6.2 sleep infinity >/dev/null
docker exec ipadvid-podman podman --version
docker exec ipadvid-podman sh -c "cd /src && podman build --format docker -q -f viewer/Containerfile -t ipadvid-viewer . | tail -1"
docker exec ipadvid-podman podman run -d --name ipadvid-viewer --network host -e ZV_CONNECT=tcp/zenohd2:7447 ipadvid-viewer
sleep 15
docker exec ipadvid-podman podman ps --format '{{.Names}} {{.Status}}'
docker exec ipadvid-podman podman healthcheck run ipadvid-viewer && echo "healthcheck ok"
docker exec ipadvid-podman curl -s localhost:8080/stats; echo
docker exec ipadvid-podman podman logs ipadvid-viewer 2>&1 | head -4

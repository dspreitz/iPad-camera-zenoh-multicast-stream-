#!/usr/bin/env bash
# Anzeige-Container mit Podman bauen und starten.
#   ./viewer/podman.sh build
#   ./viewer/podman.sh run [tcp/<zenoh-Server-2>:7447]   (Standard: tcp/127.0.0.1:7447, Host-Netz)
#   ./viewer/podman.sh save                               -> ipadvid-viewer.tar (Offline-Transfer: podman load -i ...)
set -euo pipefail
cd "$(dirname "$0")/.."
ENGINE=${ENGINE:-podman}
case "${1:-}" in
  build) $ENGINE build --format docker -f viewer/Containerfile -t ipadvid-viewer . ;;
  run)
    $ENGINE rm -f ipadvid-viewer >/dev/null 2>&1 || true
    $ENGINE run -d --name ipadvid-viewer --network host --restart unless-stopped \
      -e ZV_CONNECT="${2:-tcp/127.0.0.1:7447}" -e HTTPS="${HTTPS:-1}" \
      -v ipadvid-viewer-data:/data ipadvid-viewer
    echo "Viewer: http$([ "${HTTPS:-1}" = 1 ] && echo s)://<dieser-Rechner>:8080/   Logs: $ENGINE logs -f ipadvid-viewer" ;;
  save) $ENGINE save -o ipadvid-viewer.tar ipadvid-viewer && ls -lh ipadvid-viewer.tar ;;
  *) echo "Aufruf: $0 build|run [connect]|save"; exit 1 ;;
esac

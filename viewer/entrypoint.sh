#!/bin/sh
# Startet die Bridge (zenoh -> WebSocket -> Web-Viewer).
#  ZV_MODE=client (Standard): verbindet sich per TCP mit dem zenoh-Server 2 (ZV_CONNECT).
#  ZV_MODE=peer:              eigener zenoh-Peer direkt auf UDP-Multicast (ZV_GROUP, ZV_IFACE).
set -e
if [ "$ZV_MODE" = "peer" ]; then
  IFACE="$ZV_IFACE"
  if [ -z "$IFACE" ] || [ "$IFACE" = "auto" ]; then
    IFACE=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$IFACE" ] || IFACE=eth0
  fi
  export ZV_LOCATOR="udp/${ZV_GROUP}#iface=${IFACE}"
  unset ZV_CONNECT
  echo "[viewer] zenoh peer on ${ZV_LOCATOR}, key ${ZV_KEY}"
else
  echo "[viewer] zenoh client -> ${ZV_CONNECT}, key ${ZV_KEY}"
fi

if [ "$HTTPS" = "1" ] && [ -z "$TLS_CERT" ]; then
  if [ ! -f /data/viewer.crt ]; then
    echo "[viewer] erzeuge selbstsigniertes Zertifikat /data/viewer.crt"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=ipadvid-viewer" \
      -keyout /data/viewer.key -out /data/viewer.crt 2>/dev/null
  fi
  export TLS_CERT=/data/viewer.crt TLS_KEY=/data/viewer.key
fi
exec python3 /app/bridge/bridge.py "$@"

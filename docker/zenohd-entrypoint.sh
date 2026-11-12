#!/bin/sh
# Wählt das Multicast-Interface des Datenlinks und startet zenohd.
#  LINK_IFACE=eth0         fester Interfacename, oder
#  LINK_IP_PREFIX=172.22.  Interface, dessen IPv4-Adresse so beginnt (Docker vergibt eth0/eth1 nicht verlässlich
#                          in Verbindungsreihenfolge, daher im Test per Subnetz)
set -e
IFACE=${LINK_IFACE:-}
if [ -z "$IFACE" ] && [ -n "$LINK_IP_PREFIX" ]; then
  IFACE=$(ip -o -4 addr show | awk -v p="$LINK_IP_PREFIX" 'index($4, p) == 1 {print $2; exit}')
fi
IFACE=${IFACE:-eth0}
sed "s/#iface=eth0/#iface=${IFACE}/" /etc/zenohd.json5 > /tmp/zenohd.json5
echo "[zenohd] $(cat /etc/zenohd-variant) - Datenlink-Interface ${IFACE}"
exec zenohd -c /tmp/zenohd.json5 "$@"

#!/bin/sh
# ffmpeg-Testbild -> H.264 (wie sender_py.py) -> zv_pico_sender (zenoh-pico)
# Standard wie die iPad-App: Client-Modus, TCP zum zenoh-Server 1. Alternativ ZV_MODE=peer + Multicast-Locator.
W=${WIDTH:-640}; H=${HEIGHT:-360}; FPS=${FPS:-10}; GOP=${GOP:-10}; BR=${BITRATE_K:-220}
MODE=${ZV_MODE:-client}; LOC=${ZV_LOCATOR:-tcp/zenohd1:7447}; KEY=${ZV_KEY:-video/ipad/h264}
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf
VF="fps=$FPS"; [ -n "$NOISE" ] && [ "$NOISE" != 0 ] && VF="$VF,noise=alls=$NOISE:allf=t"
VF="$VF,drawtext=fontfile=$FONT:text='pico %{localtime\:%T} #%{n}':x=10:y=10:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.6"
exec ffmpeg -hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=${W}x${H}:rate=$FPS" -vf "$VF" -an \
  -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -pix_fmt yuv420p \
  -g $GOP -keyint_min $GOP -sc_threshold 0 -b:v ${BR}k -maxrate ${BR}k -bufsize $((BR*6/10))k \
  -x264-params repeat-headers=1:aud=1 -f h264 - \
  | zv_pico_sender -m "$MODE" -l "$LOC" -k "$KEY" -p "${PACE_US:-0}"

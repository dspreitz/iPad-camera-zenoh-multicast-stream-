#!/usr/bin/env bash
# Baut den macOS-Test-Harness (gleicher Swift-Code wie die App: H264Encoder + ZenohPublisher + C-Kern).
# Braucht nur die CommandLineTools (swiftc, clang), kein Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f build/zenoh-pico/macosx-arm64/libzenohpico.a ] || ./scripts/build-zenoh-pico.sh macosx
mkdir -p build/harness
clang -c -O2 -mmacosx-version-min=13.0 -DZENOH_MACOS -IThirdParty/zenoh-pico-config -IThirdParty/zenoh-pico/include \
  ../sender/csrc/zv_sender.c -o build/harness/zv_sender.o
swiftc -O -target arm64-apple-macos13.0 \
  -import-objc-header ZenohCam/ZenohCam-Bridging-Header.h -I../sender/csrc \
  -Xcc -DZENOH_MACOS -Xcc -IThirdParty/zenoh-pico-config -Xcc -IThirdParty/zenoh-pico/include \
  ZenohCam/H264Encoder.swift ZenohCam/ZenohPublisher.swift ZenohCam/CameraCapture.swift mac-harness/main.swift \
  build/harness/zv_sender.o build/zenoh-pico/macosx-arm64/libzenohpico.a \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework AVFoundation \
  -o build/harness/zv-mac-harness
echo "fertig: ios/build/harness/zv-mac-harness"

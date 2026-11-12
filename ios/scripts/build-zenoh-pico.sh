#!/usr/bin/env bash
# Baut zenoh-pico (ThirdParty/zenoh-pico, Version 1.10.2) als statische Bibliothek bzw. XCFramework für iOS.
#   ./scripts/build-zenoh-pico.sh            -> ZenohPico.xcframework (iphoneos arm64 + iphonesimulator arm64), braucht Xcode
#   ./scripts/build-zenoh-pico.sh macosx     -> nur libzenohpico.a für macOS (Test ohne Xcode, mit CommandLineTools)
# Quellenliste und config.h stammen aus einem CMake-Lauf für Darwin (ZENOH_MACOS = BSD-Socket-Schicht, passt für iOS):
#   ThirdParty/zenoh-pico-sources.txt, ThirdParty/zenoh-pico-config/zenoh-pico/config.h
#   (BATCH_MULTICAST_SIZE=1472, sonst Defaults; Z_FEATURE_AUTO_RECONNECT=1)
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=ThirdParty/zenoh-pico
OUT=build/zenoh-pico
DEFS="-DZENOH_MACOS -DZENOH_COMPILER_OTHER -DZENOH_C_STANDARD=11 -DZ_BUILD_LOG=0 -DNDEBUG"
INC="-IThirdParty/zenoh-pico-config -I$SRC/include"

build() { # sdk arch minflag
  local sdk=$1 arch=$2 minflag=$3 dir=$OUT/$1-$2
  mkdir -p "$dir/obj"
  local cc; cc=$(xcrun -sdk "$sdk" -f clang); local sysroot; sysroot=$(xcrun -sdk "$sdk" --show-sdk-path)
  echo "== $sdk $arch ($sysroot)"
  local objs=()
  while read -r f; do
    [ -z "$f" ] && continue
    o="$dir/obj/$(echo "$f" | tr '/' '_').o"
    "$cc" -isysroot "$sysroot" -arch "$arch" $minflag -std=gnu11 -O2 -fPIC $DEFS $INC -c "$SRC/$f" -o "$o" &
    objs+=("$o")
    # max. 8 parallel
    while [ "$(jobs -r | wc -l)" -ge 8 ]; do sleep 0.05; done
  done < ThirdParty/zenoh-pico-sources.txt
  wait
  xcrun -sdk "$sdk" libtool -static -o "$dir/libzenohpico.a" "${objs[@]}"
  echo "   -> $dir/libzenohpico.a"
}

if [ "${1:-}" = "macosx" ]; then
  build macosx arm64 "-mmacosx-version-min=13.0"
  exit 0
fi
build iphoneos arm64 "-miphoneos-version-min=16.0"
build iphonesimulator arm64 "-mios-simulator-version-min=16.0"
mkdir -p $OUT/headers && cp -R $SRC/include/. $OUT/headers/ && cp -R ThirdParty/zenoh-pico-config/. $OUT/headers/
rm -rf ZenohPico.xcframework
xcodebuild -create-xcframework \
  -library $OUT/iphoneos-arm64/libzenohpico.a -headers $OUT/headers \
  -library $OUT/iphonesimulator-arm64/libzenohpico.a -headers $OUT/headers \
  -output ZenohPico.xcframework
echo "fertig: ios/ZenohPico.xcframework"

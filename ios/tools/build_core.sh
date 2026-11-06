#!/bin/sh
# Builds ios/build/OnAirCore.xcframework for the device and the simulator. Needs: Xcode, cmake, ninja, pkg-config, rustup with the
# aarch64-apple-ios and aarch64-apple-ios-sim targets, and the headers of `brew install hackrf libusb ffmpeg` (only the headers are used).
# Usage: build_core.sh [iphoneos] [iphonesimulator]   (default: both)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/ios/build"
SDKS=${*:-iphoneos iphonesimulator}
ARGS=""
for sdk in $SDKS; do
  B="$OUT/$sdk"
  cmake -S "$ROOT/ios/core" -B "$B" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_BUILD_TYPE=Release
  cmake --build "$B" --target onair_ios
  # one archive for Xcode: every static library of the build, Rust included
  mkdir -p "$B/merged"
  find "$B" -name '*.a' -not -path '*/merged/*' -not -path '*/deps/*' -not -path '*/build/*/deps/*' | sort > "$B/merged/libs.txt"
  xcrun libtool -static -no_warning_for_no_symbols -o "$B/merged/libOnAirCore.a" -filelist "$B/merged/libs.txt" 2>/dev/null
  ARGS="$ARGS -library $B/merged/libOnAirCore.a -headers $ROOT/ios/core/include"
done
rm -rf "$OUT/OnAirCore.xcframework"
xcodebuild -create-xcframework $ARGS -output "$OUT/OnAirCore.xcframework"

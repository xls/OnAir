#!/bin/sh
# Builds OnAir's voice codec plug-ins for iOS into ios/build/<sdk>/codecs, as tools/codec-builder/build-codecs.sh does for a desktop: mbelib-neo at the same pinned
# commit (GPL-2.0-or-later) and OnAir's wrapper. These codecs may be covered by patents: this is a personal build, and whoever builds it is responsible for
# that (docs/CODECS-BUILD-HELPER.md). The Xcode project signs the results into the app. Usage: build_codecs.sh iphoneos|iphonesimulator
set -eu
SDK=$1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/ios/build"
HELPER="$ROOT/tools/codec-builder/build-codecs.sh"
PIN=$(sed -n 's/^PIN_COMMIT="\(.*\)"$/\1/p' "$HELPER")
REPO=$(sed -n 's/^REPO_URL="\(.*\)"$/\1/p' "$HELPER")
SRC="$OUT/deps/mbelib-neo"
DEST="$OUT/$SDK/codecs"
B="$OUT/$SDK/mbelib"
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
if [ "$SDK" = iphoneos ]; then TARGET=arm64-apple-ios17.0; else TARGET=arm64-apple-ios17.0-simulator; fi
if [ ! -d "$SRC" ]; then
  git clone --quiet "$REPO" "$SRC"
  git -C "$SRC" checkout --quiet "$PIN"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$PIN" ] || { echo "mbelib-neo is not at the pinned commit"; exit 1; }
cmake -S "$SRC" -B "$B" -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
  -DMBELIB_BUILD_TESTS=OFF -DMBELIB_BUILD_EXAMPLES=OFF -DMBELIB_WARNINGS_AS_ERRORS=OFF > "$B.cmake.log" 2>&1 || { tail -20 "$B.cmake.log"; exit 1; }
cmake --build "$B" > "$B.build.log" 2>&1 || { tail -20 "$B.build.log"; exit 1; }
LIB=$(find "$B" -name 'libmbe*static*.a' | head -n 1)
[ -n "$LIB" ] || LIB=$(find "$B" -name 'libmbe*.a' | head -n 1)
VER=$(find "$B" -name version.h -path '*mbelib-neo*' | head -n 1)
GENINC=$(dirname "$(dirname "$VER")")
CC=$(xcrun --sdk "$SDK" -f clang)
mkdir -p "$DEST"
for id in tetra ambe2 ambe imbe ysf; do
  UPPER=$(echo "$id" | tr '[:lower:]' '[:upper:]')
  "$CC" -target "$TARGET" -isysroot "$SYSROOT" -dynamiclib -fPIC -O2 -DCODEC_"$UPPER" -I"$SRC/include" -I"$GENINC" "$ROOT/tools/codec-builder/onair_codec_wrapper.c" "$LIB" -lm \
    -install_name "@rpath/onair-codec-$id.dylib" -o "$DEST/onair-codec-$id.dylib"
done
echo "codec plug-ins for $SDK built"

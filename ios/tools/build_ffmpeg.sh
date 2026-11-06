#!/bin/sh
# Builds a small static FFmpeg for iOS into ios/build/<sdk>/ffmpeg: the version and the decoders of tools/package/build_ffmpeg_static.sh, cross-compiled,
# with Apple's VideoToolbox for hardware decoding. Usage: build_ffmpeg.sh iphoneos|iphonesimulator
set -eu
SDK=$1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/ios/build"
PREFIX="$OUT/$SDK/ffmpeg"
VER=8.0
[ -f "$PREFIX/lib/libavcodec.a" ] && { echo "FFmpeg for $SDK is built"; exit 0; }
mkdir -p "$OUT/deps"
TAR="$OUT/deps/ffmpeg-$VER.tar.xz"
[ -f "$TAR" ] || curl -fsSL -o "$TAR" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
[ -d "$OUT/deps/ffmpeg-$VER" ] || tar -xf "$TAR" -C "$OUT/deps"
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
CC=$(xcrun --sdk "$SDK" -f clang)
if [ "$SDK" = iphoneos ]; then TARGET=arm64-apple-ios17.0; else TARGET=arm64-apple-ios17.0-simulator; fi
W="$OUT/$SDK/ffmpeg-build"
rm -rf "$W"; mkdir -p "$W"; cd "$W"
"$OUT/deps/ffmpeg-$VER/configure" --prefix="$PREFIX" --enable-static --disable-shared --enable-pic \
  --enable-cross-compile --target-os=darwin --arch=arm64 --cc="$CC" --sysroot="$SYSROOT" \
  --extra-cflags="-target $TARGET" --extra-ldflags="-target $TARGET" \
  --disable-programs --disable-doc --disable-debug --disable-network --disable-autodetect \
  --disable-avdevice --disable-avfilter --disable-everything \
  --enable-protocol=file --enable-demuxer=mpegts,mov --enable-muxer=mpegts,hls,mp4 \
  --enable-parser=h264,hevc,mpegvideo,mpegaudio,aac,aac_latm,ac3,dvbsub,cavsvideo \
  --enable-decoder=h264,hevc,mpeg2video,mp2,mp2float,mp3,mp3float,ac3,eac3,aac,aac_latm,dvbsub,cavs \
  --enable-encoder=mpeg2video,mp2,aac \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata,null,setts,dts2pts \
  --enable-videotoolbox --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,mpeg2_videotoolbox > configure.log 2>&1 || { tail -25 configure.log; exit 1; }
make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -25 make.log; exit 1; }
make install > /dev/null
echo "FFmpeg $VER for $SDK installed"

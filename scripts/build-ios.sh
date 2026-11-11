#!/usr/bin/env bash
#
# Static libav for iOS (device + simulator, arm64). MSE links these; no ffmpeg CLI.
#
#   scripts/build-ios.sh iphoneos            # out/ios-arm64/{include,lib}
#   scripts/build-ios.sh iphonesimulator     # out/ios-simulator-arm64/{include,lib}
#
# Run on an Apple Silicon Mac (the mini). Intel cannot produce simulator-arm64 well.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/deps-video.sh"

SDK="${1:?usage: build-ios.sh iphoneos|iphonesimulator}"
case "$SDK" in
  iphoneos)
    SLUG=ios-arm64
    MIN="-miphoneos-version-min=13.0"
    ;;
  iphonesimulator)
    SLUG=ios-simulator-arm64
    MIN="-mios-simulator-version-min=13.0"
    ;;
  *) echo "unknown sdk: $SDK" >&2; exit 1 ;;
esac

SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
[ -d "$SYSROOT" ] || { echo "no SDK at $SYSROOT" >&2; exit 1; }
CC="$(xcrun --sdk "$SDK" -f clang)"
AR="$(xcrun --sdk "$SDK" -f ar)"
RANLIB="$(xcrun --sdk "$SDK" -f ranlib)"
NM="$(xcrun --sdk "$SDK" -f nm)"
ARCHFLAGS="-arch arm64 $MIN -isysroot $SYSROOT -fPIC"

DEPS="$ROOT/.deps-$SLUG"
DEPS_REL="../../.deps-$SLUG"
PREFIX="$ROOT/out/$SLUG"
PREFIX_REL="../../out/$SLUG"
DEP_CFLAGS="$DEP_STD $FF_OPTFLAGS $FF_SIZE_CFLAGS $ARCHFLAGS"

# iOS has no ymix helper process. MSE playback is VP9/Opus/WebM — skip lame/shine.
FF_OPTS="${FF_OPTS//--enable-protocol=file,pipe,ymix/--enable-protocol=file,pipe}"
FF_OPTS="${FF_OPTS//--enable-ffmpeg /}"
FF_OPTS="${FF_OPTS//--enable-libmp3lame/}"
FF_OPTS="${FF_OPTS//--enable-libshine/}"
FF_OPTS="${FF_OPTS//libmp3lame,/}"
FF_OPTS="${FF_OPTS//,libshine/}"
FF_OPTS="$FF_OPTS --disable-programs --disable-autodetect --enable-cross-compile --arch=aarch64 --cpu=generic --target-os=darwin --disable-runtime-cpudetect --disable-asm"
# VT is the iOS HW path. dav1d/libvpx are SW fallback (sim has no AV1/VP9 HW).
FF_OPTS="$FF_OPTS --enable-videotoolbox --enable-hwaccel=h264_videotoolbox,vp9_videotoolbox,av1_videotoolbox"
FF_OPTS="$FF_OPTS $(video_sw_ff_opts)"

apply_ymix_patch
apply_vt_allow_sw_patch

mkdir -p "$DEPS"
fetch_video_srcs
VIDEO_MESON_CROSS=1 VIDEO_MESON_SYSTEM=darwin VIDEO_MESON_CPU=aarch64 \
  build_dav1d "$DEPS" "$CC" "$DEP_CFLAGS" "$AR"
build_libvpx "$DEPS" "$CC" "$DEP_CFLAGS" "$AR"

rm -rf "$PREFIX"
mkdir -p "$PREFIX"

echo "[build] ffmpeg for $SLUG ($SDK)"
cd "$SRC/ffmpeg"
make distclean >/dev/null 2>&1 || true
# shellcheck disable=SC2086
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ./configure \
  --prefix="$PREFIX_REL" \
  --optflags="$FF_OPTFLAGS" \
  --cc="$CC" --ar="$AR" --ranlib="$RANLIB" --nm="$NM" \
  --sysroot="$SYSROOT" \
  --extra-cflags="-I$DEPS_REL/include $FF_SIZE_CFLAGS $ARCHFLAGS" \
  --extra-ldflags="-L$DEPS_REL/lib $ARCHFLAGS" \
  $FF_OPTS
make -j"$JOBS" libavcodec/libavcodec.a libavformat/libavformat.a libavutil/libavutil.a \
  libswscale/libswscale.a libswresample/libswresample.a
mkdir -p "$PREFIX/lib"
cp libavcodec/libavcodec.a libavformat/libavformat.a libavutil/libavutil.a \
  libswscale/libswscale.a libswresample/libswresample.a "$PREFIX/lib/"
cp -f "$DEPS/lib/libdav1d.a" "$DEPS/lib/libvpx.a" "$PREFIX/lib/"
make install-headers

rm -rf "$PREFIX/bin" "$PREFIX/share"
echo "[ok] $PREFIX/lib:"
ls "$PREFIX/lib"

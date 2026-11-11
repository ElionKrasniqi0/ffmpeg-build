#!/usr/bin/env bash
#
# Android, one ABI at a time.
#
#   scripts/build-android.sh <abi> [pack_output_dir]  abi: arm64-v8a | armeabi-v7a | x86 | x86_64
#
# Needs ANDROID_NDK_ROOT and patchelf (SONAME flatten: libavcodec.so.N → libavcodec.so;
# Android only extracts filenames that end in ".so"). Always installs shared libav + headers to
#   $ROOT/out/android-<abi>/{include,lib,bin,pack}
# pack/ is the relocatable flat set (libffmpeg.so + the same unversioned libav*.so MSE loads).
# The CLI is named libffmpeg.so on purpose: Android only extracts and grants exec permission to
# files under lib/<abi>/ that look like native libraries.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/deps-video.sh"

# Shared libav: the CLI and MSE both load these DSOs.
FF_OPTS="${FF_OPTS//$FF_LINK_STATIC/$FF_LINK_SHARED}"

command -v patchelf >/dev/null || {
  echo "FATAL: patchelf is required (Android SONAME flatten). brew install patchelf / apt install patchelf" >&2
  exit 1
}

ABI="${1:?usage: build-android.sh <abi> [out]}"
OUT="${2:-}"
# Resolved before anything cd's: the copy at the end runs from src/ffmpeg, so a relative path would
# deposit the binary inside the source tree instead of where the caller asked for it.
[ -n "$OUT" ] && { mkdir -p "$(dirname "$OUT")"; OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"; }
: "${ANDROID_NDK_ROOT:?set ANDROID_NDK_ROOT to an NDK r27+}"

# API 21 is the floor r27+ still ships, and covers the Android 7 target. armeabi-v7a is built WITH
# NEON — every v7a device since ~2012 has it, so the plain-ARM variant is wasted time.
API=21
# ffmpeg's --arch names are not the ABI names. 32-bit x86 additionally cannot use the hand-written
# assembly: it needs text relocations, which ld.lld rejects for a PIE, and Android requires PIE.
case "$ABI" in
  arm64-v8a)   TRIPLE=aarch64-linux-android;    ARCH=aarch64; CPU=armv8-a ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi; ARCH=armv7;   CPU=armv7-a
               EXTRA_CFLAGS="-mfpu=neon -mfloat-abi=softfp" ;;
  x86)         TRIPLE=i686-linux-android;       ARCH=i686;    CPU=i686
               ASM_OPT="--disable-asm" ;;
  x86_64)      TRIPLE=x86_64-linux-android;     ARCH=x86_64;  CPU=x86-64 ;;
  *) echo "unknown ABI: $ABI" >&2; exit 1 ;;
esac

# NDK prebuilt dirs are windows-x86_64 / linux-x86_64 / darwin-x86_64. MSYS2's
# `uname -s` is MSYS_NT-... / MINGW64_NT-..., which does not match those names.
case "$(uname -s)" in
  MINGW*|MSYS*|CLANG*|UCRT*|CYGWIN*|Windows*) NDK_HOST_TAG=windows-x86_64 ;;
  Darwin)  NDK_HOST_TAG=darwin-x86_64 ;;
  Linux)   NDK_HOST_TAG=linux-x86_64 ;;
  *)       NDK_HOST_TAG="$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64" ;;
esac
TC="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$NDK_HOST_TAG"
[ -d "$TC" ] || { echo "no NDK toolchain at $TC" >&2; exit 1; }
# Cross builds need a native C11 host compiler for configure host tools. On Windows that
# means mingw-w64 gcc (with its CRT headers). NDK clang is not usable as HOSTCC — it has
# no Windows ctype.h. Prefer an explicit HOSTCC; otherwise pick a mingw gcc on PATH or
# under the usual MSYS2 prefixes. Run this script from a MINGW64/UCRT64 shell so gcc works.
case "$(uname -s)" in
  MINGW*|MSYS*|CLANG*|UCRT*|CYGWIN*|Windows*)
    if [ -z "${HOSTCC:-}" ]; then
      if command -v gcc >/dev/null; then
        HOSTCC=$(command -v gcc)
      else
        for cand in /mingw64/bin/gcc /ucrt64/bin/gcc /clang64/bin/gcc; do
          if [ -x "$cand" ]; then HOSTCC=$cand; break; fi
        done
      fi
    fi
    if [ -z "${HOSTCC:-}" ]; then
      echo "FATAL: set HOSTCC to mingw-w64 gcc (run from a MINGW64 shell, or pacman -S mingw-w64-x86_64-gcc)" >&2
      exit 1
    fi
    # Keep mingw ahead of the NDK on PATH: if llvm-as/clang from the NDK shadow mingw's
    # assembler, HOSTCC cannot compile host programs (configure then reports "lacks C11").
    _mingw_bin=$(cd "$(dirname "$HOSTCC")" && pwd)
    export PATH="$_mingw_bin:$TC/bin:$PATH"
    _hostcc_probe=$(mktemp "${TMPDIR:-/tmp}/ff_hostcc.XXXXXX")
    printf 'int x;\n' > "${_hostcc_probe}.c"
    if ! "$HOSTCC" -std=c11 -c -o "${_hostcc_probe}.o" "${_hostcc_probe}.c" >/dev/null 2>&1; then
      rm -f "${_hostcc_probe}" "${_hostcc_probe}.c" "${_hostcc_probe}.o"
      echo "FATAL: HOSTCC=$HOSTCC cannot compile a C11 host program (use a MINGW64 shell)" >&2
      exit 1
    fi
    rm -f "${_hostcc_probe}" "${_hostcc_probe}.c" "${_hostcc_probe}.o"
    export HOSTCC
    echo "[toolchain] host-cc=$HOSTCC"
    ;;
  *)
    # The toolchain goes on PATH and the tools are named bare, because ffmpeg records --cc/--ar/... in
    # the configure line it compiles into the binary. Absolute paths there would publish the NDK
    # location, which on a developer machine is under $HOME.
    export PATH="$TC/bin:$PATH"
    ;;
esac
export CC="${TRIPLE}${API}-clang"
export AR=llvm-ar NM=llvm-nm RANLIB=llvm-ranlib STRIP=llvm-strip
command -v "$CC" >/dev/null || { echo "no $CC in $TC/bin" >&2; exit 1; }

DEPS="$ROOT/.deps-android-$ABI"
DEPS_REL="../../.deps-android-$ABI"
# 16 KB page alignment: required by Android 15+ devices that use 16 KB pages, and harmless on the
# 4 KB ones, so a single binary covers both.
LDFLAGS_ALIGN="-Wl,-z,max-page-size=16384"
# Single-quoted so ffmpeg's configure test does not expand $ORIGIN to empty (ld then
# drops `main`). pack_ffmpeg_shared also sets rpath via patchelf.
RPATH_LDFLAGS='-Wl,-rpath,\$ORIGIN'
# -fPIC is required: lame/shine/libvpx stay static inside libavcodec.so. ffmpeg itself is PIC
# via --enable-pic; lame/shine are autotools and need the flag on CFLAGS plus --with-pic.
DEP_CFLAGS="$DEP_STD $FF_OPTFLAGS $FF_SIZE_CFLAGS -fPIC ${EXTRA_CFLAGS:-}"

build_dep() {
  local src="$1" name="$2"; shift 2
  local bdir="$DEPS/.build/$name"
  [ -f "$src/configure" ] || { echo "no configure in $src — wrong path, or the tree needs bootstrapping" >&2; return 1; }
  # -L dereferences: shine carries symlinks under js/test, and MSYS2 cannot create symlinks
  # without developer mode. They are test fixtures, so copying their contents is equivalent.
  rm -rf "$bdir"; mkdir -p "$bdir"; cp -RL "$src/." "$bdir/"
  ( cd "$bdir"
    make distclean >/dev/null 2>&1 || true
    ./configure --host="$TRIPLE" --prefix="$DEPS" --disable-shared --enable-static --with-pic \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$DEP_CFLAGS" "$@" >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null )
}

apply_ymix_patch

[ -f "$DEPS/lib/libmp3lame.a" ] || { echo "[deps] lame";  build_dep "$SRC/lame/lame" lame --disable-frontend --disable-gtktest; }
[ -f "$DEPS/lib/libshine.a" ]   || { echo "[deps] shine"; bootstrap_shine; build_dep "$SRC/shine" shine; fix_shine_pc "$DEPS"; }

# MediaCodec is the Android video path. libvpx is SW fallback when MC will not take VP9.
fetch_video_srcs
build_libvpx "$DEPS" "$CC" "$DEP_CFLAGS" "$AR"
FF_OPTS="$FF_OPTS --disable-autodetect $(video_vpx_only_ff_opts)"

# Relative to src/ffmpeg so the recorded configure line has no /Users/... path.
PREFIX="$ROOT/out/android-$ABI"
PREFIX_REL="../../out/android-$ABI"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

echo "[build] ffmpeg for android/$ABI (API $API)"
cd "$SRC/ffmpeg"
make distclean >/dev/null 2>&1 || true
# shellcheck disable=SC2086
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$DEPS/lib64/pkgconfig" ./configure \
  --prefix="$PREFIX_REL" \
  --target-os=android --arch="$ARCH" --cpu="$CPU" --enable-cross-compile ${ASM_OPT:-} \
  --cc="$CC" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
  ${HOSTCC:+--host-cc="$HOSTCC"} \
  --enable-jni --enable-mediacodec \
  --enable-pic \
  --optflags="$FF_OPTFLAGS" \
  --extra-cflags="-I$DEPS_REL/include $FF_SIZE_CFLAGS ${EXTRA_CFLAGS:-}" \
  --extra-ldflags="-L$DEPS_REL/lib -Wl,--gc-sections $LDFLAGS_ALIGN $RPATH_LDFLAGS" \
  $FF_OPTS
make -j"$JOBS"
make install

# Case-insensitive; NDK + our unversioned libav/libsw. MediaCodec pulls libmediandk/libandroid.
ALLOWED_DEPS='^(libc|libm|libdl|liblog|libz|libandroid|libmediandk|libjnigraphics|libaaudio|libEGL|libOpenSLES|ld-android|libc\+\+|libstdc\+\+|libav|libsw)'

PACK="$PREFIX/pack"
pack_ffmpeg_shared "$PACK" "$PREFIX" "libffmpeg.so" "$ALLOWED_DEPS"
# MSE CMake links $PREFIX/lib. Replace versioned SONAMEs with the flattened copies the apk ships
# so DT_NEEDED is libavcodec.so, not libavcodec.so.61.
rm -f "$PREFIX/lib"/libav*.so.* "$PREFIX/lib"/libsw*.so.*
cp -a "$PACK"/libav*.so "$PACK"/libsw*.so "$PREFIX/lib/"

echo "[verify]"
file "$PACK/libffmpeg.so"
assert_anonymous "$PACK/libffmpeg.so"
"$TC/bin/llvm-readelf" -l "$PACK/libffmpeg.so" | grep -q "0x4000" && echo "  16 KB page aligned"
ls "$PACK"/libavcodec.so >/dev/null
echo "  installed $PREFIX (shared libav + headers); pack/ is the relocatable CLI+DSOs"

if [ -n "$OUT" ]; then
  mkdir -p "$OUT"
  cp -a "$PACK"/. "$OUT/"
  echo "[out] $OUT ($(du -sh "$OUT" | cut -f1))"
fi
echo "[android/$ABI] BUILD_OK"

#!/usr/bin/env bash
# dav1d + libvpx static PIC for MSE software fallback.
# Sourced from build-ios / build-android / build-desktop after common.sh.
#
#   fetch_video_srcs
#   build_dav1d  "$DEPS" "$CC" "$CFLAGS" "$AR"
#   build_libvpx "$DEPS" "$CC" "$CFLAGS" "$AR"
#
# Pinned tarballs (BSD). Not GPL. ffmpeg --enable-libdav1d / --enable-libvpx.
set -euo pipefail

DAV1D_VER="${DAV1D_VER:-1.5.1}"
LIBVPX_VER="${LIBVPX_VER:-1.15.2}"
DAV1D_URL="https://github.com/videolan/dav1d/archive/refs/tags/${DAV1D_VER}.tar.gz"
LIBVPX_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v${LIBVPX_VER}.tar.gz"
# Header-only (MIT): the drivers behind them are dlopen'd at runtime, so no link dependency.
NVCODEC_VER="${NVCODEC_VER:-n13.0.19.0}"
VKHEADERS_VER="${VKHEADERS_VER:-1.4.317}"
NVCODEC_URL="https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/${NVCODEC_VER}.tar.gz"
VKHEADERS_URL="https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v${VKHEADERS_VER}.tar.gz"

fetch_tarball() {
  local url="$1" dest="$2" stamp="$3"
  if [ -f "$dest/$stamp" ]; then
    return 0
  fi
  local tmp="$ROOT/.cache"
  mkdir -p "$tmp"
  local tgz="$tmp/$(basename "$url")"
  echo "[deps] fetch $url"
  curl -fsSL -o "$tgz" "$url"
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest" --strip-components=1
  touch "$dest/$stamp"
}

fetch_video_srcs() {
  mkdir -p "$SRC"
  fetch_tarball "$DAV1D_URL" "$SRC/dav1d" ".ver-$DAV1D_VER"
  fetch_tarball "$LIBVPX_URL" "$SRC/libvpx" ".ver-$LIBVPX_VER"
}

ensure_meson() {
  command -v meson >/dev/null && command -v ninja >/dev/null && return 0
  if command -v brew >/dev/null; then
    echo "[deps] brew install meson ninja"
    # brew can exit 1 on a post-install warning after a successful formula pour.
    HOMEBREW_NO_AUTO_UPDATE=1 brew install meson ninja || true
    command -v meson >/dev/null && command -v ninja >/dev/null && return 0
  fi
  echo "meson+ninja required to build dav1d" >&2
  return 1
}

# C-only dav1d (no asm): portable across iOS sim/device, Android, and desktop.
build_dav1d() {
  local prefix="$1" cc="$2" cflags="$3" ar="$4"
  [ -f "$prefix/lib/libdav1d.a" ] && return 0
  ensure_meson
  local bdir="$prefix/.build/dav1d"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  echo "[deps] dav1d $DAV1D_VER -> $prefix"
  if [ "${VIDEO_MESON_CROSS:-}" = 1 ]; then
    CC="$cc" AR="$ar" CFLAGS="$cflags" \
      MESON_SYS="${VIDEO_MESON_SYSTEM:-darwin}" MESON_CPU="${VIDEO_MESON_CPU:-aarch64}" \
      python3 - "$bdir/cross.ini" <<'PY'
import os, shlex, sys
args = ", ".join("'" + t.replace("'", "\\'") + "'" for t in shlex.split(os.environ["CFLAGS"]))
open(sys.argv[1], "w").write(f"""[binaries]
c = '{os.environ["CC"]}'
ar = '{os.environ["AR"]}'
[built-in options]
c_args = [{args}]
c_link_args = [{args}]
[host_machine]
system = '{os.environ["MESON_SYS"]}'
cpu_family = '{os.environ["MESON_CPU"]}'
cpu = '{os.environ["MESON_CPU"]}'
endian = 'little'
""")
PY
    meson setup "$bdir" "$SRC/dav1d" \
      --prefix="$prefix" --libdir=lib --buildtype=release --default-library=static \
      -Denable_tools=false -Denable_tests=false -Denable_examples=false \
      -Denable_asm=false \
      --cross-file "$bdir/cross.ini"
  else
    env CC="$cc" AR="$ar" meson setup "$bdir" "$SRC/dav1d" \
      --prefix="$prefix" --libdir=lib --buildtype=release --default-library=static \
      -Denable_tools=false -Denable_tests=false -Denable_examples=false \
      -Denable_asm=false \
      -Dc_args="$cflags"
  fi
  meson compile -C "$bdir" -j "$JOBS"
  meson install -C "$bdir"
}

# Cross (iOS/Android): generic-gnu, no asm. Desktop: LIBVPX_TARGET=x86_64-darwin20-gcc
# (etc.) so 4K VP9 hits AVX; generic-gnu is ~15 fps on Intel (log29 vs log30 Homebrew).
build_libvpx() {
  local prefix="$1" cc="$2" cflags="$3" ar="$4"
  local target="${LIBVPX_TARGET:-generic-gnu}"
  [ -f "$prefix/lib/libvpx.a" ] && return 0
  local bdir="$prefix/.build/libvpx"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  echo "[deps] libvpx $LIBVPX_VER target=$target -> $prefix"
  local cpu_detect="--disable-runtime-cpu-detect"
  if [ "$target" != "generic-gnu" ]; then
    cpu_detect=""
  fi
  (
    cd "$bdir"
    # LD is explicit: unset, libvpx probes -lpthread with the HOST's gcc before switching to $cc. On an
    # x86_64 Linux host that probe links an x86_64 Android object against glibc and "passes", and
    # the final link then hands -lpthread to ld.lld, which bionic does not have.
    # shellcheck disable=SC2086
    CC="$cc" CXX="$cc" LD="$cc" AR="$ar" RANLIB="${RANLIB:-ranlib}" \
      AS="${AS:-nasm}" CFLAGS="$cflags" CXXFLAGS="$cflags" LDFLAGS="$cflags" \
      "$SRC/libvpx/configure" \
        --prefix="$prefix" --libdir="$prefix/lib" \
        --target="$target" \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --enable-static --disable-shared --enable-pic \
        --enable-vp8 --enable-vp9 \
        --disable-vp8-encoder --disable-vp9-encoder \
        $cpu_detect \
        --extra-cflags="$cflags"
    make -j"$JOBS"
    make install
  )
}

# ffmpeg configure extras once dav1d+vpx are in $DEPS.
#
# --enable-decoder=NAME matches NAME_decoder against the component list, which
# uses underscores (libvpx_vp9_decoder). A hyphen (libvpx-vp9) matches nothing:
# libvpx is linked, native `vp9` still arrives via vp9_videotoolbox, and MSE
# then logs `no decoder id=166` because it will not open native `vp9`.
# ffnvcodec (NVDEC) + Vulkan headers into $prefix. Linux desktop hardware decode.
install_hw_headers() {
  local prefix="$1"
  fetch_tarball "$NVCODEC_URL" "$SRC/nv-codec-headers" ".ver-$NVCODEC_VER"
  fetch_tarball "$VKHEADERS_URL" "$SRC/vulkan-headers" ".ver-$VKHEADERS_VER"
  make -C "$SRC/nv-codec-headers" PREFIX="$prefix" install >/dev/null
  mkdir -p "$prefix/include"
  cp -R "$SRC/vulkan-headers/include/vulkan" "$SRC/vulkan-headers/include/vk_video" "$prefix/include/"
  echo "[deps] hw headers ffnvcodec $NVCODEC_VER, vulkan $VKHEADERS_VER -> $prefix"
}

# NVDEC loads libcuda/libnvcuvid and Vulkan loads libvulkan.so.1 on demand: a machine without the
# driver still loads libav and decodes in software. VAAPI is left out because it links libva.
video_hw_linux_ff_opts() {
  echo "--enable-ffnvcodec --enable-nvdec --enable-vulkan --enable-decoder=vp9" \
    "--enable-hwaccel=h264_nvdec,hevc_nvdec,vp9_nvdec,av1_nvdec,h264_vulkan,hevc_vulkan,vp9_vulkan,av1_vulkan"
}

video_sw_ff_opts() {
  echo "--enable-libdav1d --enable-libvpx --enable-decoder=libdav1d,libvpx_vp9,av1"
}

video_vpx_only_ff_opts() {
  echo "--enable-libvpx --enable-decoder=libvpx_vp9"
}

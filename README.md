# ffmpeg-build

The FFmpeg source and build scripts YMusic builds against: Android, macOS, Linux, Windows and iOS.
Source only — nothing is prebuilt or released here. YMusicV4 expects this repository checked out
as a sibling (`../ffmpeg-build`) and packs whatever `out/<slug>/pack` holds into the app.

## What gets built

A trimmed ffmpeg. Desktop and Android are **shared libav**: the `ffmpeg` CLI and YMusic's MSE
JNI both load the same packed `libav*` / `libsw*` DSOs. Rpath is baked (`@loader_path` /
`$ORIGIN`) so the CLI runs with an empty environment — do not paste `LD_LIBRARY_PATH`.
LAME, shine, dav1d and libvpx stay static *inside* libav. iOS stays static (no CLI, no dylibs).

Feature set lives in `scripts/common.sh`. Video software (dav1d, libvpx) and hardware plugins
(VideoToolbox, MediaCodec) are per-target in `build-*.sh` + `deps-video.sh`.

| target | how |
| --- | --- |
| `macos-x86_64`, `macos-arm64` | native, on a host of that architecture (no cross-compile) |
| `linux-x86_64`, `linux-arm64` | native |
| `windows-x86_64` | native, MSYS2 MINGW64 |
| `windows-arm64` | native, MSYS2 CLANGARM64 |
| `android-{arm64-v8a,armeabi-v7a,x86,x86_64}` | NDK r27+, API 21, 16 KB page aligned |
| `ios-arm64`, `ios-simulator-arm64` | Xcode clang, static libav for MSE (`scripts/build-ios.sh`) |

## Building locally

```bash
git clone --recursive --shallow-submodules <this repo> && cd ffmpeg-build
scripts/build-desktop.sh                         # out/<slug>/{include,lib,bin,pack}
scripts/build-android.sh arm64-v8a               # needs ANDROID_NDK_ROOT + patchelf
scripts/build-ios.sh                             # out/ios-*/{include,lib}, static
```

Build one Android ABI per invocation (`arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`); YMusicV4
needs `arm64-v8a`, `x86` and `x86_64`.

Each desktop/Android build writes:

| path | what |
| --- | --- |
| `out/<slug>/include`, `lib` | headers + shared libav (MSE `FFMPEG_ROOT`) |
| `out/<slug>/pack` | relocatable flat set: CLI + the same DSOs. This is what YMusicV4 packs. |

Android pack names the CLI `libffmpeg.so` and **unversions** SONAMEs (`libavcodec.so`, not
`libavcodec.so.61`) because the installer only extracts filenames that end in `.so`.

iOS (`scripts/build-ios.sh`) also builds dav1d + libvpx into `out/ios-*/lib` for MSE software
fallback; VideoToolbox is the hardware path. Static only.

`--shallow-submodules` fetches 21 MB instead of 654 MB. Each script applies
`patches/0001-ymix-protocol.patch` to the ffmpeg submodule first; re-running is safe.

## The `ymix` protocol

`ymix:<socket_path>` — reads and writes a file through a helper process over a Unix socket, for
Android's `content://` documents that FFmpeg cannot open directly.

Kept as a patch against the upstream commit in `patches/UPSTREAM_BASE`, so moving to a newer FFmpeg
is re-applying one file. Excluded from the Windows build: `ymix.c` needs `<sys/un.h>`.

## Licence

Output is **LGPL-2.1-or-later** (FFmpeg), with LGPL-2.0-or-later LAME and Shine statically linked
in. Components and sources: [NOTICE.md](NOTICE.md).

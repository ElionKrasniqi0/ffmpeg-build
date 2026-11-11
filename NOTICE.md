# Third-party components

| Component | Licence | Source |
| --- | --- | --- |
| FFmpeg | LGPL-2.1-or-later | https://github.com/FFmpeg/FFmpeg |
| LAME | LGPL-2.0-or-later | https://github.com/tanersener/lame (mirror of https://lame.sourceforge.io) |
| Shine | LGPL-2.0-or-later | https://github.com/toots/shine |
| dav1d | BSD-2-Clause | https://github.com/videolan/dav1d |
| libvpx | BSD-3-Clause | https://github.com/webmproject/libvpx |
| nv-codec-headers (Linux desktop) | MIT | https://github.com/FFmpeg/nv-codec-headers |
| Vulkan-Headers (Linux desktop) | Apache-2.0 | https://github.com/KhronosGroup/Vulkan-Headers |

Built without `--enable-gpl` and without `--enable-nonfree`. `ffmpeg -L` reports the licence of any
given binary.

LAME, Shine, dav1d and libvpx are statically linked; nv-codec-headers and Vulkan-Headers are
header-only (the NVIDIA and Vulkan drivers are loaded at runtime, never shipped). This
repository, with its pinned submodules, `scripts/deps-video.sh` tarballs, and `patches/`, is the
corresponding source.

Video: Android uses MediaCodec in MSE (ffmpeg libvpx is SW fallback). Apple uses VideoToolbox
hwaccels plus dav1d/libvpx when HW cannot decode (iOS Simulator AV1/VP9). Native ffmpeg
`av1`/`vp9` decoders are not used as the software path.

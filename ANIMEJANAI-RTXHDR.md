# AnimeJaNai native TensorRT + RTX HDR integration

This branch integrates dyphire's interface and tools with the native player
from AnimeJaNai 3.7.0. It requires a player built with the experimental
`cuda-d3d11` filter from
https://github.com/dahaox3/mpv-animejanai-rtxhdr/tree/gpu-resident-rtx-hdr .
The build workflow lives in
https://github.com/dahaox3/mpv-animejanai-rtxhdr-build .

The configuration directory is `portable_config/` beside `mpv.exe`. Keep
AnimeJaNai 3.7.0's `animejanai/`, inference dependencies, models and Manager
beside that directory. Inference ABI 8 is unchanged. This repository contains
configuration and source scripts, not the model/runtime binaries.

`scripts/hybrid.lua` owns AI selection, GPU API, hardware decoding, and the
managed video filters. Do not also load the unmodified upstream backend/slot
controllers: the versions in this branch delegate ownership to hybrid.lua.

- AI is off unless `[global] default_slot` in `animejanai/animejanai.conf`
  explicitly selects a nonzero slot through Manager.
- The configured inference backend is respected. Enabling HDR no longer
  silently changes TensorRT to DirectML.
- D3D11 presentation stays active for movies, TensorRT alone, and TensorRT
  with HDR. Enabling AI no longer destroys the D3D11 window to create Vulkan.
- TensorRT uses copy/software decode, CUDA upload, native inference and the
  CUDA-to-D3D11 RGB10 bridge. RTX HDR is appended only when manually enabled.
- DirectML's existing D3D11 path remains available when selected in Manager.
- RTX HDR is manually toggled with Ctrl+Alt+H or the HDR menu. The controller
  keeps it at the end of `vf`, including after filters added by other scripts.
  Native HDR sources are bypassed by the driver's SDR-to-HDR stage.

The ordering requirement is native upscaling before HDR. GLSL shaders still
run in the later VO stage. Software-only filters can require a host download
and upload; their placement before HDR does not make them GPU implementations.
The bridge removes the enlarged frame's CPU round trip. Initial copy decode
and CUDA upload are still present. No RGBA16 intermediate texture is required
by the current RGB10 bridge.

Local RTX 4070 Ti / driver 617.42 tests passed default selection, AI/HDR
toggles, seeking, resolution/codec changes, HDR10 bypass,
subtitles, menus, and WebUI. Sharp Balanced + HDR ran continuously for 60
seconds with zero frame drops. These checks do not certify every dyphire
plugin or every driver. The test build has different FFmpeg dependencies
from the release package, so it is distributed separately from the existing
player until that packaging difference is resolved.

The stable-window update was checked across ten AI/HDR mode combinations,
including changing Balanced/Performance and entering/leaving fullscreen. The
window handle stayed unchanged and no Win32 window teardown occurred during
the toggles. A brief decode/filter reset can still happen when models change;
this is distinct from replacing the presentation window.

For standard Balanced 1080p24 High10 to 4K, three same-runtime alternating
tests measured GPU bridge median 49.57 fps vs copy-back RGB10 median 48.26
fps (about 2.7%). This is a synthetic throughput comparison with an 800x450
preview, not a real-movie or fullscreen performance guarantee.

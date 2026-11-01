# Native parity verification — November 1, 2026

Release build passed on Apple Silicon, macOS 26.6.2, Swift 6.4, using the installed macOS 26.5 SDK. Motion recording/playback is excluded.

The final integration suite passed 63 checks, including nine window captures. See [test log](parity/selftest.log). Synthetic fixtures cover real playback/pause/loops, multi-selection and undo/redo, still-frame resume, locked/free-region grid placement, pinned shuffle/count changes, automatic shuffle, scenes, ratings, WMV conversion and cache reuse, actual 90-degree rotation, portable media with originals unavailable, recovery storage, five pixel-checked blend modes, MP4 video/mixed audio, recording during background preparation, and silence padding for short audio tracks. Both 440 Hz and 660 Hz source tones were detected in the recorded mix.

Native portable output opened and saved through the existing Electron storage module, then reopened natively. Browser version 1 and 4 fixtures also loaded. Media was deduplicated across scenes.

Manual native UI checks:

- Shift-click selected multiple videos; group dragging and opposite-corner resizing worked; undo restored geometry.
- Shift-1 captured a scene. Typing a name containing numbers and P did not trigger canvas shortcuts.
- P hid controls; Escape restored editing.
- Closing edited work showed Save/Discard/Cancel. Save wrote a valid portable project and closed the window.
- A separate restart restored an interrupted document. Discard on quit removed its recovery snapshot.

Visual review covers Video, Layers, Scenes and Setup in light/dark appearances and clean output. The capture harness targets the tested model's window explicitly; selecting the first visible window could capture an unrelated empty document.

`tools/grid-lint.sh`, `git diff --check`, and strict app signature verification passed. The tested release is installed at `~/Applications/Vollage Native.app`; its installed signature also passed. Final desktop launch verification was blocked because the Mac was locked. The release executable ran successfully throughout integration testing.

The build workaround copies matching PackageDescription interfaces/library to a temporary build directory and selects the existing SDK. No SDK copy or system-toolchain modification is required. SwiftPM emits a native-build-engine deprecation notice; app compilation succeeds without compiler warnings.

Limits: no prolonged high-count/4K stress test, Intel hardware test, external-display test, or comprehensive codec matrix. Real-time output can drop frames under load. Finder drop and external-player handoff are implemented but not covered by the automated assertions. Earlier prototype evidence is retained in INITIAL-RESULTS.md.

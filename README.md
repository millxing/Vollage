# Vollage Native

SwiftUI and AVFoundation Mac app, macOS 26+. This is the initial native port, not yet feature-equivalent to the Electron app.

## Build and run

```sh
./build.sh --open
```

Output: `build/Vollage Native.app`. Debug builds: `./build.sh --debug`.

The build uses the installed Command Line Tools, selects the macOS 26.5 SDK when available, and copies the matching public PackageDescription interface and library into `/tmp/vollage-native-build/toolchain`. This avoids stale Swift 5.10 private interfaces left in the system installation. No system developer files or global Xcode settings are modified. Set `VOLLAGE_BUILD_ROOT` or `VOLLAGE_SDK` to override the build directory or SDK.

## Current workflows

- Add MP4, MOV, and M4V videos; drop file URLs onto the canvas.
- Loop playback with AVFoundation; pause/resume all with Space.
- Select and drag videos; adjust size and playback speed in the inspector.
- Mute, mirror, lock placement, bring forward, and remove videos.
- Choose a folder recursively, set a count, and shuffle unlocked videos.
- Arrange a simple grid; locked videos preserve their position.
- Save/open `.vollage-native` projects, including playback settings and global pause.
- Command-N opens an independent canvas.

Projects reference original video paths; moving a source file breaks that reference. They do not embed media and are not compatible with browser/Electron `.vollage` files. Use the original app for portable projects, scenes, motion, blend modes, ratings, automatic shuffle, export/recording, undo, and codec conversion. Grid layout does not yet optimize aspect ratios or avoid locked rectangles.

## Verification

`tools/selftest.sh` generates two synthetic H.264 videos with FFmpeg and tests real AVFoundation decoding, advancing time, pause, looping, mute, save/open, invalid-project safety, locked placement, shuffle, and removal. It also captures the running window in light and dark appearances and performance mode. No personal media is used. `tools/grid-lint.sh` checks control spacing; canvas coordinates are deliberately freeform.

The verified app is also installed at `~/Applications/Vollage Native.app`, alongside the original Electron app. Build output does not automatically replace that installed copy. Verification evidence and reviewed screenshots are in `docs/verification/`.

The local toolchain workaround uses SwiftPM's native build engine, which currently emits a deprecation notice. A clean future Command Line Tools installation should allow returning to the default engine and removing this workaround.

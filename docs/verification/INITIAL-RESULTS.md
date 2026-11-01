# Verification — November 1, 2026

Release build: passed on Apple Silicon, macOS 26.6.2, Swift 6.4, macOS 26.5 SDK.
App bundle signature: `codesign --verify --strict` passed.

17 functional assertions and 3 window captures passed with synthetic H.264 landscape and portrait clips. See selftest.log. Covers actual playback time, pause, loop completion, mute, grid locks, save/load, invalid/missing-media rejection without losing the current composition, shuffle, speed, and removal.

Manual UI checks using the running native application:

- Native Open panel restored a saved project and its paused state.
- Selecting and dragging a video moved it with the pointer.
- Choose folder loaded both synthetic videos and enabled Shuffle.
- Command-S opened the Save panel and wrote valid project JSON to a temporary file.
- Command-N created a separate empty canvas.
- P hid controls. Escape initially failed with an unfocused canvas; after adding a window-scoped AppKit event handler, the same keyboard check restored both toolbar and inspector.
- Final empty-state window rendered its introduction and folder controls correctly.

Visual review:

- canvas-light.png: playing landscape and portrait media, readable inspector, no clipping of controls.
- canvas-dark.png: same state with readable dark controls and selected-video outline.
- performance.png: videos remain visible; inspector, toolbar actions, and selection outline are hidden.

`tools/grid-lint.sh`: passed. Video placement deliberately uses continuous canvas coordinates.

Toolchain workaround is local to the project build. The system CLT contains 2024 private PackageDescription interfaces alongside current public interfaces and dylib. `tools/swift.sh` copies only matching public interfaces and the current dylib and selects the macOS 26.5 SDK. The native SwiftPM build engine avoids CLT-only Swift Build framework search-path warnings. SwiftPM emits a deprecation notice for this engine; app compilation has no warnings or errors. No global developer settings were changed.

This verifies the initial native implementation, not feature parity. See README.md for missing features and format limitations. Untested: corrupt/unsupported media behavior, prolonged high-count playback, audio mixing quality, external displays, Intel Macs, and Finder drag/drop.

# Vollage Native

SwiftUI/AVFoundation macOS app. Read README.md for supported features and limitations.

- Build: `./build.sh --debug`, or `./build.sh --open` for a release build.
- Build wrapper: `tools/swift.sh` isolates stale system PackageDescription private interfaces without changing system files.
- Test actual app behavior: `tools/selftest.sh`. Uses synthetic media in /tmp; never personal media.
- Review `/tmp/vollage-native-shots` light/dark snapshots after UI changes.
- Spacing check: `tools/grid-lint.sh`.
- Keep player and canvas state on the main actor. Test AVFoundation time progression and looping, not just model values.
- Project loading must validate before replacing the current composition.
- New windows must own independent CanvasModel instances.
- Report feature gaps explicitly; do not claim compatibility with Electron .vollage projects.

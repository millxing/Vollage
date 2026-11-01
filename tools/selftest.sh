#!/bin/zsh
set -euo pipefail
here=${0:A:h:h}
fixtures=/tmp/vollage-native-fixtures
mkdir -p "$fixtures"
ffmpeg=${FFMPEG:-$(command -v ffmpeg)}
"$ffmpeg" -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30 -t 2 -c:v libx264 -pix_fmt yuv420p -y "$fixtures/landscape.mp4"
"$ffmpeg" -hide_banner -loglevel error -f lavfi -i testsrc2=size=360x640:rate=30 -t 2 -c:v libx264 -pix_fmt yuv420p -y "$fixtures/portrait.mp4"
VOLLAGE_TEST_MEDIA="$fixtures" VOLLAGE_SNAPSHOTS=/tmp/vollage-native-shots "$here/build/Vollage Native.app/Contents/MacOS/VollageNative" --selftest

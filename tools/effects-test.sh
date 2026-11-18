#!/bin/zsh
set -euo pipefail
here=${0:A:h:h}
fixtures=${VOLLAGE_EFFECT_FIXTURES:-/tmp/vollage-effects-fixtures}
mkdir -p "$fixtures/motion"
ffmpeg=${FFMPEG:-$(command -v ffmpeg)}
generate() {
  "$ffmpeg" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=960x540:rate=30:duration=4" \
    -vf "$2" -c:v libx264 -preset fast -pix_fmt yuv420p -y "$fixtures/motion/$1.mp4"
}
generate Displacement "null"
generate Slit-Scan "hflip,hue=h=45"
generate Feedback "vflip,hue=h=120"
generate Reference "hflip,vflip,hue=h=180"
generate Replacement "negate"
app=${VOLLAGE_TEST_APP:-"$here/build/Vollage Effects Test.app"}
export VOLLAGE_TEST_MEDIA="$fixtures"
export VOLLAGE_DATA_ROOT=/tmp/vollage-effects-test-data
export VOLLAGE_EFFECTS_CHECK=1
export VOLLAGE_SNAPSHOTS=${VOLLAGE_SNAPSHOTS:-/tmp/vollage-effects-shots}
"$app/Contents/MacOS/Vollage" --selftest

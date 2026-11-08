#!/bin/zsh
# Check native toolbar hover-help registration, including after state changes.
set -euo pipefail
here=${0:A:h:h}
export VOLLAGE_TOOLTIP_CHECK=1
export VOLLAGE_TEST_MEDIA=/tmp/vollage-tooltip-fixtures
export VOLLAGE_DATA_ROOT=/tmp/vollage-tooltip-data
mkdir -p "$VOLLAGE_TEST_MEDIA"
"$here/build/Vollage.app/Contents/MacOS/Vollage" --selftest

#!/bin/zsh
set -euo pipefail
here=${0:A:h}
cd "$here"
config=release
[[ " $* " == *" --debug "* ]] && config=debug
./tools/swift.sh build -c "$config"
cache=${VOLLAGE_BUILD_ROOT:-/tmp/vollage-native-build}
app="$here/build/Vollage Native.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$cache/package/$config/VollageNative" "$app/Contents/MacOS/VollageNative.new"
mv -f "$app/Contents/MacOS/VollageNative.new" "$app/Contents/MacOS/VollageNative"
sed "s/__BUILD__/$(date +%Y%m%d%H%M)/" Info.plist.in > "$app/Contents/Info.plist"
cp "$here/../../desktop/resources/Vollage.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "Built $app"
[[ " $* " != *" --open "* ]] || open "$app"

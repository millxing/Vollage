#!/bin/zsh
set -euo pipefail
here=${0:A:h}
cd "$here"
config=release
[[ " $* " == *" --debug "* ]] && config=debug
./tools/swift.sh build -c "$config"
cache=${VOLLAGE_BUILD_ROOT:-/tmp/vollage-native-build}
app="$here/build/Vollage.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$cache/package/$config/Vollage" "$app/Contents/MacOS/Vollage.new"
mv -f "$app/Contents/MacOS/Vollage.new" "$app/Contents/MacOS/Vollage"
sed "s/__BUILD__/$(date +%Y%m%d%H%M)/" Info.plist.in > "$app/Contents/Info.plist"
cp "$here/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
install_dir="/Applications"
mkdir -p "$install_dir"
/usr/bin/ditto "$app" "$install_dir/Vollage.app"
echo "Built $app"
echo "Installed $install_dir/Vollage.app"
[[ " $* " != *" --open "* ]] || open "$install_dir/Vollage.app"

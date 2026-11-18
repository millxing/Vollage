#!/bin/zsh
set -euo pipefail
here=${0:A:h}
cd "$here"
config=release
[[ " $* " == *" --debug "* ]] && config=debug
./tools/swift.sh build -c "$config"
cache=${VOLLAGE_BUILD_ROOT:-/tmp/vollage-native-build}
name="Vollage"
install_dir="/Applications"
if [[ " $* " == *" --effects-test "* ]]; then
  name="Vollage Effects Test"
  install_dir="$HOME/Applications"
fi
app="$here/build/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$cache/package/$config/Vollage" "$app/Contents/MacOS/Vollage.new"
mv -f "$app/Contents/MacOS/Vollage.new" "$app/Contents/MacOS/Vollage"
sed "s/__BUILD__/$(date +%Y%m%d%H%M)/" Info.plist.in > "$app/Contents/Info.plist"
if [[ "$name" != Vollage ]]; then
  plist="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.vollage.native.effects-test" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDocumentTypes:0:LSHandlerRank Alternate" "$plist"
fi
cp "$here/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
mkdir -p "$install_dir"
/usr/bin/ditto "$app" "$install_dir/$name.app"
echo "Built $app"
echo "Installed $install_dir/$name.app"
[[ " $* " != *" --open "* ]] || open "$install_dir/$name.app"

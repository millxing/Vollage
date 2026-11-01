#!/bin/zsh
# Isolate stale private PackageDescription interfaces shipped with this CLT installation.
# No system files are changed. Public interfaces and dylib come from the same toolchain.
set -euo pipefail
cache=${VOLLAGE_BUILD_ROOT:-/tmp/vollage-native-build}
mkdir -p "$cache/toolchain/ManifestAPI/PackageDescription.swiftmodule" "$cache/modules" "$cache/cache" "$cache/config" "$cache/security"
compiler=$(xcrun --find swift)
libs="${compiler:h:h}/lib/swift/pm/ManifestAPI"
cp "$libs/libPackageDescription.dylib" "$cache/toolchain/ManifestAPI/"
for interface in "$libs"/PackageDescription.swiftmodule/*.swiftinterface; do
  [[ "$interface" == *.private.swiftinterface ]] && continue
  cp "$interface" "$cache/toolchain/ManifestAPI/PackageDescription.swiftmodule/"
done
export SWIFTPM_CUSTOM_LIBS_DIR="$cache/toolchain"
export CLANG_MODULE_CACHE_PATH="$cache/modules"
sdk=${VOLLAGE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
[[ -d "$sdk" ]] || sdk=$(xcrun --show-sdk-path)
"$compiler" "$@" --build-system native --disable-sandbox --scratch-path "$cache/package" --cache-path "$cache/cache" --config-path "$cache/config" --security-path "$cache/security" --sdk "$sdk"

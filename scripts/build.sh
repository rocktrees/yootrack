#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox -c release
product=$(swift build --disable-sandbox -c release --show-bin-path)
destination="${YOOTRACK_BUILD_APP:-$PWD/build/YooTrack.app}"
# Sign outside the synced Desktop: Finder can reattach metadata between xattr
# removal and signing. Copy the already verified bundle without that metadata.
stage=$(mktemp -d "${TMPDIR:-/tmp}/power-watch-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
app="$stage/YooTrack.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/Helpers"
cp "$product/PowerWatch" "$app/Contents/MacOS/PowerWatch"
cp "$product/PowerWatchHelper" "$app/Contents/Library/Helpers/PowerWatchHelper"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/PowerWatch.icns "$app/Contents/Resources/"
cp Resources/YooTrackMark.png "$app/Contents/Resources/"
cp scripts/install-helper.sh scripts/uninstall-helper.sh "$app/Contents/Resources/"
xattr -cr "$app"
codesign --force --sign - --identifier ai.powerwatch.collector "$app/Contents/Library/Helpers/PowerWatchHelper"
codesign --force --sign - --identifier ai.powerwatch.app "$app"
codesign --verify --strict "$app"
mkdir -p "$(dirname "$destination")"
ditto --norsrc --noextattr "$app" "$destination"
printf 'Built %s\n' "$destination"

#!/bin/sh
# Build a versioned Apple silicon app ZIP and drag-to-Applications disk image.
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ]; then printf 'Usage: sh scripts/release.sh vMAJOR.MINOR.PATCH\n' >&2; exit 1; fi
tag=$1
case "$tag" in v*) version=${tag#v} ;; *) printf 'Release tag must start with v.\n' >&2; exit 1 ;; esac
if ! printf '%s\n' "$version" | /usr/bin/grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    printf 'Release version must be MAJOR.MINOR.PATCH.\n' >&2; exit 1
fi
plist=Resources/Info.plist
short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
if [ "$version" != "$short" ] || [ "$version" != "$build" ]; then
    printf 'Tag %s does not match both app versions (%s, %s).\n' "$tag" "$short" "$build" >&2; exit 1
fi
if [ "$(uname -m)" != arm64 ]; then printf 'Release builds require an Apple silicon Mac.\n' >&2; exit 1; fi
/bin/sh scripts/test.sh
/bin/sh scripts/build.sh
stage=$(mktemp -d "${TMPDIR:-/tmp}/yootrack-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/image"
ditto --norsrc --noextattr 'build/YooTrack.app' "$stage/image/YooTrack.app"
app="$stage/image/YooTrack.app"
for binary in "$app/Contents/MacOS/PowerWatch" "$app/Contents/Library/Helpers/PowerWatchHelper"; do
    if [ "$(/usr/bin/lipo -archs "$binary")" != arm64 ]; then printf 'Expected arm64 binary: %s\n' "$binary" >&2; exit 1; fi
done
codesign --verify --strict "$app"
output="$PWD/build/releases/$tag"
mkdir -p "$output"
ln -s /Applications "$stage/image/Applications"
zip="$output/YooTrack-$tag-macos-arm64.zip"
dmg="$output/YooTrack-$tag-macos-arm64.dmg"
rm -f "$zip" "$dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
hdiutil create -quiet -srcfolder "$stage/image" -volname "YooTrack $tag" -format UDZO "$dmg"
(cd "$output" && shasum -a 256 "$(basename "$zip")" "$(basename "$dmg")" > SHA256SUMS.txt)
printf 'Release artifacts: %s\n' "$output"

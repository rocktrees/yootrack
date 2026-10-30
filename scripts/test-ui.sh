#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
# Keep signed runner bundles outside the synced Desktop, where Finder metadata
# can invalidate ad-hoc signatures. Supply the same directory for comparisons.
pw_ui_derived="${POWER_WATCH_UI_DERIVED_DATA:-}"
if [ -z "$pw_ui_derived" ]; then pw_ui_derived=$(mktemp -d "${TMPDIR:-/tmp}/power-watch-ui.XXXXXX"); fi
printf '%s\n' "$pw_ui_derived" > build/ui-derived-path.txt
python3 scripts/generate-xcode-project.py
exec xcodebuild -project PowerWatch.xcodeproj -scheme PowerWatchUI -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$pw_ui_derived" "$@" test

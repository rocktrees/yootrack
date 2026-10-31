#!/bin/sh
# Build fresh into staging so an existing workspace build can remain running.
set -eu
cd "$(dirname "$0")/.."
stage=$(mktemp -d "${TMPDIR:-/tmp}/yootrack-local-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
export YOOTRACK_BUILD_APP="$stage/YooTrack.app"
/bin/sh scripts/build.sh
/bin/sh scripts/install-app.sh "$@"
# Keep both recognized installation locations in sync when both already exist.
if [ "$#" -eq 0 ] && [ -d /Applications/YooTrack.app ] && [ -d "$HOME/Applications/YooTrack.app" ]; then
    /bin/sh scripts/install-app.sh "$HOME/Applications/YooTrack.app"
fi

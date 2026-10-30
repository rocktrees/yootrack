#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
destination="${1:-$HOME/Applications/YooTrack.app}"
if [ ! -d 'build/YooTrack.app' ]; then /bin/sh scripts/build.sh; fi
# Adopt the earlier app bundle only when installing to the default location.
# Quit the old app before running this script.
legacy="$HOME/Applications/Power Watch.app"
if [ "$#" -eq 0 ] && [ ! -e "$destination" ] && [ -d "$legacy" ]; then
    identifier=$(codesign -dv "$legacy" 2>&1 | sed -n 's/^Identifier=//p')
    if [ "$identifier" != ai.powerwatch.app ]; then printf 'Refusing to move an unrelated app at %s\n' "$legacy" >&2; exit 1; fi
    mv "$legacy" "$destination"
fi
if [ -e "$destination" ]; then
    identifier=$(codesign -dv "$destination" 2>&1 | sed -n 's/^Identifier=//p')
    if [ "$identifier" != ai.powerwatch.app ]; then printf 'Refusing to replace an unrelated app at %s\n' "$destination" >&2; exit 1; fi
fi
mkdir -p "$(dirname "$destination")"
ditto --norsrc --noextattr 'build/YooTrack.app' "$destination"
codesign --verify --strict "$destination"
printf 'Installed %s\n' "$destination"

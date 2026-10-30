#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
destination="${1:-$HOME/Applications/Power Watch.app}"
if [ ! -d 'build/Power Watch.app' ]; then /bin/sh scripts/build.sh; fi
if [ -e "$destination" ]; then
    identifier=$(codesign -dv "$destination" 2>&1 | sed -n 's/^Identifier=//p')
    if [ "$identifier" != ai.powerwatch.app ]; then printf 'Refusing to replace an unrelated app at %s\n' "$destination" >&2; exit 1; fi
fi
mkdir -p "$(dirname "$destination")"
ditto --norsrc --noextattr 'build/Power Watch.app' "$destination"
codesign --verify --strict "$destination"
printf 'Installed %s\n' "$destination"

#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -gt 0 ]; then
    destination=$1
elif [ -e /Applications/YooTrack.app ]; then
    destination=/Applications/YooTrack.app
else
    destination="$HOME/Applications/YooTrack.app"
fi
source_app="${YOOTRACK_BUILD_APP:-$PWD/build/YooTrack.app}"
if [ ! -d "$source_app" ]; then /bin/sh scripts/build.sh; fi
# Adopt the earlier app bundle only when installing to the default location.
legacy="$HOME/Applications/Power Watch.app"
parent=$(dirname "$destination")
mkdir -p "$parent"
parent=$(cd "$parent" && pwd -P)
destination="$parent/$(basename "$destination")"
# Replacing a running bundle can invalidate its code signature or interrupt it.
if ! process_list=$(ps -axo command=); then
    printf 'Could not check running apps; refusing to replace the installed bundle.\n' >&2
    exit 1
fi
legacy_check=""
if [ "$#" -eq 0 ] && [ ! -e "$destination" ] && [ -d "$legacy" ]; then legacy_check="$legacy/Contents/MacOS/PowerWatch"; fi
if printf '%s\n' "$process_list" | awk -v path="$destination/Contents/MacOS/PowerWatch" -v legacy="$legacy_check" '
    function matches(path) { return index($0, path) == 1 && (length($0) == length(path) || substr($0, length(path) + 1, 1) == " ") }
    { sub(/^[[:space:]]+/, ""); if (matches(path) || (legacy != "" && matches(legacy))) found = 1 }
    END { exit !found }
'; then
    printf 'Quit the installed YooTrack or older Power Watch app before replacing it.\n' >&2
    exit 1
fi
if [ "$#" -eq 0 ] && [ ! -e "$destination" ] && [ -d "$legacy" ]; then
    identifier=$(codesign -dv "$legacy" 2>&1 | sed -n 's/^Identifier=//p')
    if [ "$identifier" != ai.powerwatch.app ]; then printf 'Refusing to move an unrelated app at %s\n' "$legacy" >&2; exit 1; fi
    mv "$legacy" "$destination"
fi
if [ -e "$destination" ]; then
    identifier=$(codesign -dv "$destination" 2>&1 | sed -n 's/^Identifier=//p')
    if [ "$identifier" != ai.powerwatch.app ]; then printf 'Refusing to replace an unrelated app at %s\n' "$destination" >&2; exit 1; fi
fi
stage=$(mktemp -d "$parent/.yootrack-install.XXXXXX")
restore=0
cleanup() {
    if [ "$restore" = 1 ] && [ -e "$stage/previous.app" ]; then
        if [ ! -e "$destination" ]; then
            if ! mv "$stage/previous.app" "$destination"; then
                printf 'Could not restore the previous app; it remains at %s\n' "$stage/previous.app" >&2
                return
            fi
        else
            printf 'The previous app remains at %s because the destination is occupied.\n' "$stage/previous.app" >&2
            return
        fi
    fi
    rm -rf "$stage"
}
trap cleanup EXIT HUP INT TERM
ditto --norsrc --noextattr "$source_app" "$stage/YooTrack.app"
codesign --verify --strict "$stage/YooTrack.app"
if [ -e "$destination" ]; then mv "$destination" "$stage/previous.app"; restore=1; fi
mv "$stage/YooTrack.app" "$destination"
if ! codesign --verify --strict "$destination"; then
    rm -rf "$destination"
    exit 1
fi
restore=0
printf 'Installed %s\n' "$destination"

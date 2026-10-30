#!/bin/sh
# Usage: sudo /bin/sh scripts/install-helper.sh '/absolute/YooTrack.app' USER_UID
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
validate_only=0
if [ "${1:-}" = --validate ]; then validate_only=1; shift; fi
if [ "$#" != 2 ]; then printf 'Usage: install-helper.sh APP_BUNDLE USER_UID\n' >&2; exit 1; fi
app=$(cd "$1" && pwd -P)
uid=$2
case "$uid" in ''|*[!0-9]*) printf 'Invalid user UID.\n' >&2; exit 1 ;; esac
if [ "$uid" -lt 500 ]; then printf 'Choose the logged-in user account, not root.\n' >&2; exit 1; fi
helper="$app/Contents/Library/Helpers/PowerWatchHelper"
# Finder can attach an empty FinderInfo attribute to generated bundles on a synced Desktop.
# This metadata is outside the signature and prevents strict verification on otherwise valid local builds.
xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true
codesign --verify --strict "$app"
codesign --verify --strict "$helper"
app_id=$(codesign -dv "$app" 2>&1 | sed -n 's/^Identifier=//p')
helper_id=$(codesign -dv "$helper" 2>&1 | sed -n 's/^Identifier=//p')
if [ "$app_id" != ai.powerwatch.app ] || [ "$helper_id" != ai.powerwatch.collector ]; then printf 'Unexpected app or helper identity.\n' >&2; exit 1; fi
hash=$(codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p')
case "$hash" in ''|*[!0-9a-fA-F]*) printf 'Missing or invalid app signature hash.\n' >&2; exit 1 ;; esac
if [ "${#hash}" != 40 ]; then printf 'Unexpected signature hash length.\n' >&2; exit 1; fi
codesign --verify --strict -R="identifier \"ai.powerwatch.app\" and cdhash H\"$hash\"" "$app"
if [ "$validate_only" = 1 ]; then printf 'App and helper signatures validated; no system changes made.\n'; exit 0; fi
if [ "$(id -u)" != 0 ]; then printf 'Run this installer with administrator authorization.\n' >&2; exit 1; fi
directory=/Library/PrivilegedHelperTools
daemon=/Library/LaunchDaemons/ai.powerwatch.collector.plist
mkdir -p "$directory"
if [ "$(stat -f %u "$directory")" != 0 ] || [ "$(stat -f %u /Library/LaunchDaemons)" != 0 ]; then printf 'Installation directories must be root-owned.\n' >&2; exit 1; fi
for installation_directory in "$directory" /Library/LaunchDaemons; do
    directory_mode=$(stat -f %Lp "$installation_directory")
    if [ -L "$installation_directory" ] || [ "$((0$directory_mode & 022))" != 0 ]; then printf 'Installation directories must not be symlinks or writable by other users.\n' >&2; exit 1; fi
done
stage=$(mktemp -d "$directory/.powerwatch-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
install -o root -g wheel -m 755 "$helper" "$stage/helper"
cat > "$stage/config" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>ClientUID</key><integer>$uid</integer><key>ClientRequirement</key><string>identifier &quot;ai.powerwatch.app&quot; and cdhash H&quot;$hash&quot;</string></dict></plist>
EOF
cat > "$stage/daemon" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>ai.powerwatch.collector</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/ai.powerwatch.collector</string></array>
<key>MachServices</key><dict><key>ai.powerwatch.collector</key><true/></dict>
<key>ProcessType</key><string>Background</string>
<key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
EOF
plutil -lint "$stage/config" "$stage/daemon"
chown root:wheel "$stage/config" "$stage/daemon"
chmod 644 "$stage/config" "$stage/daemon"
launchctl bootout system/ai.powerwatch.collector 2>/dev/null || true
mv -f "$stage/helper" "$directory/ai.powerwatch.collector"
mv -f "$stage/config" "$directory/ai.powerwatch.collector.plist"
mv -f "$stage/daemon" "$daemon"
launchctl bootstrap system "$daemon"
printf 'YooTrack collector installed for UID %s. Reopen the app or wait for its next sample.\n' "$uid"

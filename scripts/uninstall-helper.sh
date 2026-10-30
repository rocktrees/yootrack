#!/bin/sh
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
if [ "$(id -u)" != 0 ]; then printf 'Run this uninstaller with administrator authorization.\n' >&2; exit 1; fi
launchctl bootout system/ai.powerwatch.collector 2>/dev/null || true
rm -f /Library/LaunchDaemons/ai.powerwatch.collector.plist /Library/PrivilegedHelperTools/ai.powerwatch.collector /Library/PrivilegedHelperTools/ai.powerwatch.collector.plist
printf 'YooTrack collector removed. App and local history were retained.\n'

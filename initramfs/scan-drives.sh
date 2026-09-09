#!/bin/sh
# Scans for external drives and the backups on them.
#
#   scan-drives.sh <root-device> <root-mount> <targets-out> <backups-out>
#
# Called twice: once by init before the menu is drawn, and again by
# picker whenever the user taps Rescan.
#
# The rescan exists because the drive cannot be present at boot. With no
# keyboard attached there is no way to tell the firmware to skip a
# bootable USB stick, so plugging the Ventoy drive in before rebooting
# boots Ventoy instead of the picker. The drive therefore has to arrive
# AFTER the picker is running, and a scan done once at startup would
# never see it.
#
# Hotplug itself needs nothing special: /dev is devtmpfs, so the kernel
# creates the node when the drive enumerates. All that is missing is
# looking again.
#
# Writes both files atomically-ish via a temporary, so a rescan that
# fails part way cannot leave picker reading a half-written list.
set -eu

rootdev=${1:?usage: scan-drives.sh <root-device> <root-mount> <targets-out> <backups-out>}
rootmnt=${2:?usage: scan-drives.sh <root-device> <root-mount> <targets-out> <backups-out>}
targets=${3:?usage: scan-drives.sh <root-device> <root-mount> <targets-out> <backups-out>}
backups=${4:?usage: scan-drives.sh <root-device> <root-mount> <targets-out> <backups-out>}

here=$(dirname "$0")

: > "$targets.tmp"
: > "$backups.tmp"

"$here/discover-backup-targets.sh" "$rootdev" > "$targets.tmp" 2>/dev/null || : > "$targets.tmp"

while read -r dev _rest; do
    [ -n "$dev" ] || continue
    "$here/discover-backups.sh" "$rootmnt" "$dev" 2>/dev/null \
        | awk -v t="$dev" 'NF{print t "\t" $0}' >> "$backups.tmp" || :
done < "$targets.tmp"

cat "$targets.tmp" > "$targets"
cat "$backups.tmp" > "$backups"
rm -f "$targets.tmp" "$backups.tmp"

#!/bin/sh
# Scans for external drives, the backups on them, and which of them can
# be handed to firmware to boot directly.
#
#   scan-drives.sh <root-device> <root-mount> <targets-out> <backups-out> <bootable-out>
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
# Writes all three files atomically-ish via a temporary, so a rescan that
# fails part way cannot leave picker reading a half-written list.
set -eu

usage="usage: scan-drives.sh <root-device> <root-mount> <targets-out> <backups-out> <bootable-out>"
rootdev=${1:?$usage}
rootmnt=${2:?$usage}
targets=${3:?$usage}
backups=${4:?$usage}
bootable=${5:?$usage}

# Not dirname: it is not a busybox applet in the initramfs, so $(dirname)
# silently produced an empty path and every scan read nothing.
here=${0%/*}
[ "$here" != "$0" ] || here=.
# Same log as discover-backup-targets.sh: every scan's reasons, so a
# Rescan that finds nothing says why. The boot log prints this file.
scanlog=${NIGHTFALL_SCAN_LOG:-/run/nightfall/scan.log}
echo "scan-drives: start (root $rootdev, mount $rootmnt)" >> "$scanlog" 2>/dev/null || true

: > "$targets.tmp"
: > "$backups.tmp"
: > "$bootable.tmp"

"$here/discover-backup-targets.sh" "$rootdev" > "$targets.tmp" 2>>"$scanlog" || { echo "scan-drives: discover-backup-targets failed" >> "$scanlog"; : > "$targets.tmp"; }

while read -r dev _rest; do
    [ -n "$dev" ] || continue
    "$here/discover-backups.sh" "$rootmnt" "$dev" 2>>"$scanlog" \
        | awk -v t="$dev" 'NF{print t "\t" $0}' >> "$backups.tmp" || :
done < "$targets.tmp"

# A separate scan, not filtered from the targets list above: a drive can
# be a backup target without being bootable (an ordinary exFAT stick with
# no ESP on it) and bootable without being a useful backup target (a
# read-only Ventoy stick), so one list cannot stand in for the other.
"$here/discover-bootable-drives.sh" "$rootdev" > "$bootable.tmp" 2>>"$scanlog" || { echo "scan-drives: discover-bootable-drives failed" >> "$scanlog"; : > "$bootable.tmp"; }

cat "$targets.tmp" > "$targets"
cat "$backups.tmp" > "$backups"
cat "$bootable.tmp" > "$bootable"
rm -f "$targets.tmp" "$backups.tmp" "$bootable.tmp"

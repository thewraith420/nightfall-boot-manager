#!/bin/sh
# Renames one backup on an external drive, from the picker.
#
#   rename-backup.sh <root-mount> <target-partition> <old-name> <new-name>
#
# A backup gets its name when it is taken, and what you wish you had
# called it usually only becomes clear later - after the update you were
# hedging against either worked or did not.
#
# THE ORDERING IS THE WHOLE PROBLEM, and it is not the obvious one.
#
# A rename looks like two moves, the archive and its sidecar. But
# backup-system.sh now SWEEPS any .tar with no matching .info, because
# that is what a backup killed by power loss looks like and leaving it
# strands 86GB the tablet cannot see. So an interrupted two-move rename
# does not merely leave a mess - it sets up the next backup to DELETE
# the archive.
#
# Three steps instead, and at no point does a real archive exist without
# a sidecar:
#
#   1. write the NEW .info (from the old one, archive: line corrected)
#   2. mv the .tar  - the rename syscall, instant, no copying of 86GB
#   3. remove the OLD .info
#
# Interrupted after 1: old pair intact, plus a stray new .info.
# Interrupted after 2: new pair intact, plus a stray old .info.
# Either way what is left over is a 332-byte sidecar with no archive,
# which the sweep tidies away harmlessly, and a complete backup survives
# under one name or the other.
set -eu

root=${1:?usage: rename-backup.sh <root-mount> <target> <old-name> <new-name>}
target=${2:?usage: rename-backup.sh <root-mount> <target> <old-name> <new-name>}
old=${3:?usage: rename-backup.sh <root-mount> <target> <old-name> <new-name>}
new=${4:?usage: rename-backup.sh <root-mount> <target> <old-name> <new-name>}

say() { echo "rename-backup: $*" >&2; }
die() { echo "rename-backup: ERROR: $*" >&2; exit 1; }

BACKUP_DIR=nocturne-backups

[ -d "$root" ]     || die "root mount $root is not a directory"
[ -d "$root/mnt" ] || die "$root/mnt does not exist - cannot mount the backup drive"

# Both names are one path component. The new one is typed by a person on
# an on-screen keyboard; Nightfall sanitises it, but this must not depend
# on that having happened.
for n in "$old" "$new"; do
    case "$n" in
        */*|.|..|"") die "implausible backup name: '$n'" ;;
    esac
done

if [ "$old" = "$new" ]; then
    say "'$old' is already called that - nothing to do"
    exit 0
fi

mounted=0
cleanup() { [ "$mounted" = 1 ] && umount "$root/mnt" 2>/dev/null || true; }
trap cleanup EXIT

say "mounting $target"
mount "$target" "$root/mnt" || die "could not mount $target read-write - nothing was renamed"
mounted=1

dir=$root/mnt/$BACKUP_DIR
[ -d "$dir" ] || die "no $BACKUP_DIR directory on $target - nothing to rename"
[ -f "$dir/$old.tar" ] || die "no such backup: $BACKUP_DIR/$old.tar - nothing was renamed"
# A backup with no sidecar never finished. Renaming it would just move an
# archive that must not be restored from, and the sweep will clear it.
[ -f "$dir/$old.info" ] || \
    die "$BACKUP_DIR/$old.info is missing - that backup did not complete, refusing to rename it"

# Renaming onto an existing backup would destroy it silently, which is
# the worst thing this script could possibly do.
[ -e "$dir/$new.tar" ]  && die "a backup called '$new' already exists - refusing to overwrite it"
[ -e "$dir/$new.info" ] && die "a sidecar called '$new.info' already exists - refusing to overwrite it"

# Same read-only trap remove-backup.sh guards against: exFAT and NTFS
# fall back to ro on a dirty volume rather than refusing to mount, so a
# write can fail per-file under a run that reported success.
probe=$dir/.nightfall-write-probe
if ! (: > "$probe") 2>/dev/null; then
    rm -f "$probe" 2>/dev/null || true
    die "$target mounted read-only - it may be write-protected or need checking on a computer. Nothing was renamed."
fi
rm -f "$probe" 2>/dev/null || true

say "renaming $old -> $new"

# --- 1. the new sidecar, with its archive: line pointing at the new name
# awk rather than sed: sed is not one of the applets in this initramfs,
# and adding one for a single substitution is not worth the bytes.
awk -v new="$BACKUP_DIR/$new.tar" \
    '/^archive:/ { printf "archive:  %s\n", new; next } { print }' \
    "$dir/$old.info" > "$dir/$new.info" || die "could not write $new.info"

# --- 2. the archive itself. mv, so it is a rename within the filesystem
# rather than 86GB of copying.
if ! mv "$dir/$old.tar" "$dir/$new.tar"; then
    # Step 1 is undone here, so the old pair is left exactly as it was.
    rm -f "$dir/$new.info" 2>/dev/null || true
    die "could not rename the archive - nothing was changed"
fi

# --- 3. and only now the old sidecar
rm -f "$dir/$old.info" || \
    say "WARNING: renamed, but could not remove $old.info (harmless: with no archive it is ignored, and the next backup sweeps it)"
sync

say "renamed to $new"
exit 0

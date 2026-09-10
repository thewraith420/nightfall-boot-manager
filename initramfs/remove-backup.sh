#!/bin/sh
# Deletes one backup from an external drive, from the picker.
#
#   remove-backup.sh <root-mount> <target-partition> <backup-name>
#
# The counterpart to backup-system.sh. Two 86GB archives fill a 1TB
# stick faster than you would think, and with no keyboard there is no
# other way to clear one from the tablet.
#
# This only ever touches <target>/nocturne-backups/<name>.{tar,info}.
# It never mounts the real root read-write and never deletes anything on
# this machine - losing a backup is bad, losing the system that made it
# is worse, so the two jobs do not share a script.
#
# UNLIKE remove-kernel.sh, THIS DOES NOT REFUSE THE LAST ONE. Removing
# your last kernel leaves a machine that will not boot; removing your
# last backup leaves a machine that is completely fine. Freeing the
# space to take a fresh backup is a normal thing to want, and often the
# only way to do it. The confirm dialog says when it is the only one -
# warn, do not block.
set -eu

root=${1:?usage: remove-backup.sh <root-mount> <target-partition> <backup-name>}
target=${2:?usage: remove-backup.sh <root-mount> <target-partition> <backup-name>}
name=${3:?usage: remove-backup.sh <root-mount> <target-partition> <backup-name>}

say() { echo "remove-backup: $*" >&2; }
die() { echo "remove-backup: ERROR: $*" >&2; exit 1; }

BACKUP_DIR=nocturne-backups

[ -d "$root" ]     || die "root mount $root is not a directory"
[ -d "$root/mnt" ] || die "$root/mnt does not exist - cannot mount the backup drive"

# A name is one path component. Anything else is either a bug upstream
# or a way to make this delete a file outside the backup directory, and
# both should fail loudly rather than be cleaned up and obeyed.
case "$name" in
    */*|.|..|"") die "implausible backup name: '$name'" ;;
esac

mounted=0
cleanup() {
    [ "$mounted" = 1 ] && umount "$root/mnt" 2>/dev/null || true
}
trap cleanup EXIT

say "mounting $target"
mount "$target" "$root/mnt" || \
    die "could not mount $target read-write - nothing was deleted"
mounted=1

dir=$root/mnt/$BACKUP_DIR
archive=$dir/$name.tar
info=$dir/$name.info

[ -d "$dir" ]     || die "no $BACKUP_DIR directory on $target - nothing to delete"
[ -f "$archive" ] || die "no such backup: $BACKUP_DIR/$name.tar - nothing was deleted"

# ------------------------------------------------- prove writability first
# Same ordering rule the rest of this project learned the hard way: do
# the fallible setup and prove it works BEFORE the irreversible step.
#
# Here the specific trap is that a mount can succeed and still be
# read-only - exFAT and NTFS drivers fall back to ro on a dirty volume
# rather than refusing, and a stick with its write-protect switch on
# mounts perfectly happily. Without this probe the rm below would fail
# per-file while the script reported a clean run, which is exactly the
# kind of silent "success" this project keeps getting bitten by.
probe=$dir/.nightfall-write-probe
if ! (: > "$probe") 2>/dev/null; then
    rm -f "$probe" 2>/dev/null || true
    die "$target mounted read-only - it may be write-protected or need checking on a computer. Nothing was deleted."
fi
rm -f "$probe" 2>/dev/null || true

before_k=$(df -k "$root/mnt" 2>/dev/null | awk 'NR==2{print $4}')
size_k=$(ls -l "$archive" 2>/dev/null | awk '{print int($5/1024)}')
say "deleting $BACKUP_DIR/$name.tar (about $(( ${size_k:-0} / 1024 / 1024 ))G)"

# --------------------------------------------------------------- delete
# ORDER MATTERS, and it is the archive first.
#
# An interruption between the two leaves an orphan either way, but the
# two orphans are not equally bad:
#
#   .tar with no .info  - discover-backups.sh skips it (no sidecar means
#                         a run that never finished, which must never be
#                         offered as restorable). So it is invisible in
#                         the UI, and an invisible 86GB file cannot be
#                         deleted from the tablet at all.
#   .info with no .tar  - also skipped, and costs 332 bytes.
#
# So retire the expensive risk first. Either orphan is then swept by
# backup-system.sh before the next backup starts, so neither survives.
rm -f "$archive" || die "could not delete $BACKUP_DIR/$name.tar"
rm -f "$info" 2>/dev/null || \
    say "WARNING: deleted the archive but not $name.info (harmless: with no archive it is ignored, and the next backup sweeps it)"
sync

after_k=$(df -k "$root/mnt" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${before_k:-}" ] && [ -n "${after_k:-}" ]; then
    say "free on $target: $((before_k / 1024 / 1024))G -> $((after_k / 1024 / 1024))G"
fi

# Say what is left, so the screen answers "do I still have a backup?"
# without a trip back to the list.
left=0
for f in "$dir"/*.info; do
    [ -f "$f" ] || continue
    n=${f##*/}; n=${n%.info}
    [ -f "$dir/$n.tar" ] || continue
    left=$((left + 1))
done
say "$left completed backup(s) remain on this drive"

say "removed $name"
exit 0

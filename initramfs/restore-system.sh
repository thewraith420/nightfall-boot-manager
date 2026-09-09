#!/bin/sh
# Restores a backup made by backup-system.sh, from the picker.
#
#   restore-system.sh <root-mount> <target-partition> <backup-name>
#
# EXTRACTS OVER the existing system. It never wipes the partition, and
# that is a deliberate limit, not an omission:
#
#   - What people restore for is a broken config, a bad update, a
#     package operation gone wrong. Overwriting fixes all of those.
#   - Wiping first would give a true point-in-time restore, but a wipe
#     that fails part way through leaves no kernels, no grub.cfg and no
#     picker, on a tablet with no keyboard to drive GRUB's rescue
#     prompt. That is the one genuine brick in this project.
#   - TWRP can afford to wipe because it lives in its own recovery
#     partition. The picker lives on the partition it would be wiping.
#
# The consequence, stated plainly because it is the honest cost: files
# created since the backup are NOT removed. This puts the system back,
# it does not rewind it. For a true rewind, boot a live image from the
# same drive - the backup is an ordinary tar and any Linux can extract
# it.
#
# THE PICKER NEVER RESTORES OVER ITSELF. /boot/picker and the GRUB
# stanza in custom.cfg are excluded, so restoring a backup taken before
# the picker existed cannot remove the thing performing the restore.
set -eu

root=${1:?usage: restore-system.sh <root-mount> <target-partition> <backup-name>}
target=${2:?usage: restore-system.sh <root-mount> <target-partition> <backup-name>}
name=${3:?usage: restore-system.sh <root-mount> <target-partition> <backup-name>}

say() { echo "restore: $*" >&2; }
die() { echo "restore: ERROR: $*" >&2; exit 1; }

BACKUP_DIR=nocturne-backups

[ -d "$root" ]     || die "root mount $root is not a directory"
[ -d "$root/mnt" ] || die "$root/mnt does not exist - cannot mount the backup drive"

mounted=0
cleanup() {
    for d in dev/pts dev proc sys; do umount "$root/$d" 2>/dev/null || true; done
    [ "$mounted" = 1 ] && umount "$root/mnt" 2>/dev/null || true
    mount -o remount,ro "$root" 2>/dev/null || \
        say "WARNING: could not remount $root read-only again"
}
trap cleanup EXIT

say "mounting $target"
mount -o ro "$target" "$root/mnt" || die "could not mount $target"
mounted=1

archive=$root/mnt/$BACKUP_DIR/$name.tar
info=$root/mnt/$BACKUP_DIR/$name.info

[ -f "$archive" ] || die "no such backup: $BACKUP_DIR/$name.tar"

# backup-system.sh writes the sidecar only AFTER tar succeeds, so its
# absence means that backup never finished. Restoring a truncated
# archive would half-overwrite the system and stop, which is worse than
# any state it was in before.
[ -f "$info" ] || die "$BACKUP_DIR/$name.info is missing - that backup did not complete, refusing to restore it"

say "restoring $BACKUP_DIR/$name.tar"
cat "$info" >&2 2>/dev/null || true

# --------------------------------------------- prove the chroot first
# Same ordering lesson remove-kernel.sh learned the hard way: do the
# fallible setup and prove it works BEFORE the irreversible step. Here
# that means confirming update-grub will be able to run afterwards,
# while the system is still untouched.
say "preparing chroot"
mount -o remount,rw "$root" || die "could not remount $root read-write"
mount -t proc  none "$root/proc" 2>/dev/null || die "could not mount /proc in the chroot"
mount -t sysfs none "$root/sys"  2>/dev/null || die "could not mount /sys in the chroot"
mount -o bind /dev "$root/dev"   2>/dev/null || die "could not bind /dev into the chroot"
mount -o bind /dev/pts "$root/dev/pts" 2>/dev/null || true

chroot "$root" /usr/sbin/grub-probe --target=device / >/dev/null 2>&1 || \
    die "grub-probe cannot resolve the root device inside the chroot - refusing to restore anything"

# ---------------------------------------------------------- extract
# --exclude paths are relative to the archive root, which was made with
# "tar -cf ... /" so members look like /boot/picker/...
# Absolute path: a bare "tar" resolves to busybox's applet under
# Ubuntu's standalone busybox, not the chroot's GNU tar. Same note as
# backup-system.sh - it cost a real backup attempt there.
if   [ -x "$root/usr/bin/tar" ]; then TAR=/usr/bin/tar
elif [ -x "$root/bin/tar" ];     then TAR=/bin/tar
else die "no tar inside the target system - cannot restore with its own tools"
fi

say "extracting (this takes a while - do not power off)"
chroot "$root" "$TAR" \
    --checkpoint=50000 --checkpoint-action=echo \
    --totals \
    --exclude=/boot/picker --exclude=/boot/grub/custom.cfg \
    --exclude=/mnt --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
    -xpf "/mnt/$BACKUP_DIR/$name.tar" -C / \
    || die "extract failed - the system is now a mix of restored and original files; re-run the restore, or boot a live image from the same drive"

sync

# ------------------------------------------------- reconcile the menu
# The restored grub.cfg describes the kernels that existed when the
# backup was taken. Anything installed since is still on disk (nothing
# was deleted), so regenerate rather than leave the menu describing a
# system that no longer matches.
say "update-grub"
chroot "$root" /usr/sbin/update-grub || \
    say "WARNING: update-grub failed - the restored grub.cfg may not list every kernel now on disk"

sync
say "restore complete"
say "the picker and its menu entry were left untouched, as always"
exit 0

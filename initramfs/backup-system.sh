#!/bin/sh
# Backs the real system up to an external drive, from the picker.
#
#   backup-system.sh <root-mount> <target-partition> [name]
#
# The reason to do this from the picker rather than from the running
# system: THE SOURCE IS NOT IN USE. The root stays mounted read-only for
# the whole backup, so nothing is being written while it is read - no
# databases mid-transaction, no package manager half-way through, no
# files changing under tar. A running system cannot give you that about
# itself.
#
# Uses the real system's own tar via chroot, the same way
# install-kernel.sh uses its depmod and update-initramfs. GNU tar there
# handles sparse files, xattrs and hardlinks properly and can report
# progress; busybox tar here would be slower and quieter.
#
# The target is mounted at <root>/mnt, which already exists on the real
# system - mounting over a directory needs no write access to the
# filesystem underneath, so the root stays read-only. Inside the chroot
# that path is /mnt, which is excluded from the archive so the backup
# cannot swallow itself.
set -eu

root=${1:?usage: backup-system.sh <root-mount> <target-partition> [name]}
target=${2:?usage: backup-system.sh <root-mount> <target-partition> [name]}
name=${3:-}

say() { echo "backup: $*" >&2; }
die() { echo "backup: ERROR: $*" >&2; exit 1; }

[ -d "$root" ]    || die "root mount $root is not a directory"
[ -b "$target" ] || [ -e "$target" ] || die "target $target does not exist"
[ -d "$root/mnt" ] || die "$root/mnt does not exist - cannot mount the target inside the chroot"

BACKUP_DIR=nocturne-backups
[ -n "$name" ] || name=nightfall-backup-$(date +%Y%m%d-%H%M 2>/dev/null || echo manual)

mounted=0
cleanup() {
    [ "$mounted" = 1 ] && umount "$root/mnt" 2>/dev/null || true
    umount "$root/proc" 2>/dev/null || true
    umount "$root/sys" 2>/dev/null || true
}
trap cleanup EXIT

say "mounting $target"
mount "$target" "$root/mnt" || die "could not mount $target read-write - is it full, or a filesystem this kernel lacks?"
mounted=1

mkdir -p "$root/mnt/$BACKUP_DIR" || die "could not create $BACKUP_DIR on the target"

# ------------------------------------------------------------ space check
# Uncompressed tar, so the archive is about the size of what is in use.
# Checked BEFORE starting, because discovering it 70GB in wastes twenty
# minutes and leaves a truncated archive that looks like a real one.
used_k=$(df -k "$root"      2>/dev/null | awk 'NR==2{print $3}')
free_k=$(df -k "$root/mnt"  2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${used_k:-}" ] && [ -n "${free_k:-}" ]; then
    say "source in use: $((used_k / 1024 / 1024))G, free on target: $((free_k / 1024 / 1024))G"
    # 2% margin for tar's own padding and headers.
    need_k=$((used_k + used_k / 50))
    [ "$free_k" -gt "$need_k" ] || \
        die "not enough room: need about $((need_k / 1024 / 1024))G, target has $((free_k / 1024 / 1024))G"
else
    say "could not measure space - continuing, but the target may fill up"
fi

# ------------------------------------------------------- chroot for GNU tar
say "preparing chroot"
mount -t proc  none "$root/proc" 2>/dev/null || die "could not mount /proc in the chroot"
mount -t sysfs none "$root/sys"  2>/dev/null || true

# ABSOLUTE PATH, and it matters more than it looks. Ubuntu builds
# busybox with FEATURE_SH_STANDALONE, so a bare "tar" resolves from
# busybox's OWN applet table before the chroot's filesystem is ever
# consulted. That silently ran busybox tar inside the chroot, which has
# no --checkpoint or --totals, so it printed its usage and exited -
# costing a real backup attempt. Every other chroot call here already
# used an absolute path; these two were the exception.
if   [ -x "$root/usr/bin/tar" ]; then TAR=/usr/bin/tar
elif [ -x "$root/bin/tar" ];     then TAR=/bin/tar
else die "no tar inside the target system - cannot make a backup with its own tools"
fi
say "using $TAR from the target system"

archive=/mnt/$BACKUP_DIR/$name.tar

# Pseudo-filesystems and volatile state. /mnt is the target itself.
# Everything else is faithful, including /home and /var - a restore
# should put the machine back, not approximately back.
# Machine-readable, for picker's progress display. tar's own checkpoint
# lines count RECORDS, which is not a unit anyone thinks in - knowing the
# total lets the UI turn them into "50 GB of 86 GB" instead.
[ -n "${used_k:-}" ] && say "nightfall-total-kb: $used_k"

say "writing $archive (this takes a while - the source stays read-only)"
chroot "$root" "$TAR" \
    --checkpoint=50000 --checkpoint-action=echo \
    --totals \
    --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
    --exclude=/tmp --exclude=/mnt --exclude=/media --exclude=/lost+found \
    --exclude=/swapfile --exclude=/swap.img \
    -cf "$archive" / \
    || die "tar failed - the archive on the target is incomplete and should not be trusted"

# A backup you cannot identify later is barely a backup.
{
    echo "created:  $(date 2>/dev/null || echo unknown)"
    echo "source:   $target <- backup of the system on this machine"
    echo "kernel:   $(uname -r 2>/dev/null)"
    echo "archive:  $BACKUP_DIR/$name.tar"
    echo "size_kb:  ${used_k:-unknown}"
    echo "kernels:"
    ls "$root"/boot/vmlinuz-* 2>/dev/null | awk '{ n = $0; sub(/.*\/vmlinuz-/, "", n); print "  - " n }'
} > "$root/mnt/$BACKUP_DIR/$name.info" 2>/dev/null || \
    say "could not write the .info sidecar (the archive itself is fine)"

sync
say "backup complete: $BACKUP_DIR/$name.tar"
exit 0

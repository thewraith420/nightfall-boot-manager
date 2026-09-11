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

# The name is now typed by a person on an on-screen keyboard, so it is
# untrusted input rather than something this script generated. A name is
# one path component: anything else would write the archive outside
# $BACKUP_DIR, where discover-backups.sh will never find it and
# remove-backup.sh will refuse to delete it. Nightfall sanitises before
# it gets here; this is the guard that does not depend on it having.
case "$name" in
    */*|.|..) die "implausible backup name: '$name'" ;;
esac

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

# ------------------------------------------------------- sweep partials
# A backup that never finished leaves a .tar with no .info sidecar, and
# discover-backups.sh deliberately hides those - restoring a truncated
# archive would half-overwrite the system and stop. The consequence is
# that a failed run strands tens of gigabytes the tablet cannot see and
# therefore cannot delete.
#
# The failure paths this script can observe clean up after themselves
# (see the tar failure below). This sweep is for the one that cannot:
# power loss mid-backup, where by definition no cleanup code runs. So
# something later has to notice, and this is the right later - it is
# already mounted read-write, and freeing space is exactly what the
# caller wants right now.
#
# Placed BEFORE the space check on purpose: a stranded partial must not
# be the reason the next backup is refused for lack of room.
#
# Confined to $BACKUP_DIR, which this script creates and owns. Only one
# backup can run at a time from the picker, and this runs before our own
# archive is created, so it can never sweep a run in progress.
sweep_partials() {
    _d=$root/mnt/$BACKUP_DIR
    for _t in "$_d"/*.tar; do
        [ -f "$_t" ] || continue
        [ -f "${_t%.tar}.info" ] && continue
        _k=$(ls -l "$_t" 2>/dev/null | awk '{print int($5/1024)}')
        if rm -f "$_t" 2>/dev/null; then
            say "swept a partial backup that never finished: ${_t##*/} (${_k:-0}KB reclaimed)"
        else
            say "WARNING: could not remove the partial ${_t##*/}"
        fi
    done
    # The mirror image: a sidecar whose archive is gone. Harmless and
    # tiny, but it is equally invisible, so clear it while we are here.
    for _i in "$_d"/*.info; do
        [ -f "$_i" ] || continue
        [ -f "${_i%.info}.tar" ] && continue
        rm -f "$_i" 2>/dev/null && say "swept a stray sidecar with no archive: ${_i##*/}"
    done
}
sweep_partials

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
#
# /timeshift is the one judged exclusion, and it is a big one: on this
# machine it was 30.5GB of an 86GB archive, 414,270 members, larger than
# /home. It is Timeshift's own snapshot store, so including it means
# backing up a backup - and a useless one for the case this archive
# exists to cover, because those snapshots live on the same disk. In any
# situation where you need this tar, they are either fine (so you did
# not need it) or gone with the disk (so the copies inside are redundant
# with the restore you just did). Two independent backups at ~55GB are
# worth more than one 86GB snapshot-of-a-snapshot.
#
# Harmless if Timeshift is not installed: a pattern matching nothing is
# silently ignored.
#
# NOTE, and it is the real gap in this archive: /boot/efi is the ESP, a
# separate FAT partition that the picker does not mount, so it lands in
# the tar as an EMPTY DIRECTORY. Everything on it (shimx64.efi,
# grubx64.efi, the stub grub.cfg) is reproducible with grub-install from
# packages that ARE in here, but a restore alone will not put it back.
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
    --exclude=/timeshift \
    -cf "$archive" / \
    || tar_rc=$?
if [ "${tar_rc:-0}" != 0 ]; then
    # Delete the half-written archive rather than leaving it. It cannot
    # be restored from, and without a sidecar it is invisible to
    # discover-backups.sh - so leaving it behind strands its space with
    # no way to reclaim it from the tablet. The sweep above is the
    # backstop for power loss; this is the case we can actually see, so
    # handle it here and immediately.
    #
    # $archive is a path inside the chroot; from out here it needs the
    # $root prefix. Getting that wrong would silently delete nothing.
    partial=$root/mnt/$BACKUP_DIR/$name.tar
    if [ -f "$partial" ]; then
        pk=$(ls -l "$partial" 2>/dev/null | awk '{print int($5/1024)}')
        rm -f "$partial" 2>/dev/null \
            && say "removed the incomplete archive (${pk:-0}KB reclaimed)" \
            || say "WARNING: could not remove the incomplete archive $BACKUP_DIR/$name.tar"
    fi
    die "tar failed - the archive was incomplete, so it has been deleted rather than left looking real"
fi

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

#!/bin/sh
# Finds which real partition THIS EXACT Nightfall build actually lives on,
# instead of assuming it is always the Slate's internal eMMC.
#
#   find-real-root.sh <my-build-id>  ->  "/dev/<partition> <layout>" on stdout
#
# <layout> says WHERE on that partition the install's files live, which init
# needs because the two layouts put everything at different paths:
#   rootfs  the partition is the real root; the marker is boot/nightfall/build-id
#           and /boot/... is a directory on it (every machine so far)
#   bootfs  the partition IS /boot (a separate /boot partition); install
#           wrote <boot>/nightfall/build-id, so the marker is at the top level
#           and there is no boot/ directory (paths in grub.cfg are then
#           relative to it: /vmlinuz-..., not /boot/vmlinuz-...)
#
# WHY THIS EXISTS: the same initramfs image can now be booted from more
# than one disk on the same machine - Bob's portable recovery/toolkit USB
# stick carries its own Nightfall install, right alongside the Slate's
# internal one. By the time this script runs, GRUB has already handed off
# and the kernel has no memory of which physical partition it was loaded
# from, so this finds out the only way that's actually reliable without
# blkid or udev (neither is available in this initramfs): walk every
# candidate partition, mount it read-only, and look for the SAME build id
# this initramfs was stamped with at build time. build-initramfs.sh writes
# it to /etc/nightfall-build-id inside the image; install-nightfall.sh
# writes the matching value to <boot>/nightfall/build-id on whatever real
# root it installs onto. Whichever candidate's build-id file matches is
# unambiguously the one this exact boot came from - not merely "a"
# Nightfall install, but THIS one.
#
# This also naturally answers the question init actually needs answered
# ("which partition has /boot/grub/grub.cfg for the entry that booted
# this"), not the more general "which partition is really mounted at /":
# every machine this has ever run on keeps /boot merged with / (documented
# assumption already in init, true for the Slate and for Bob's stick), so
# the two questions currently have the same answer.
set -eu

my_id=${1:?usage: find-real-root.sh <my-build-id>}

# NIGHTFALL_ROOT_PROBE / NIGHTFALL_SYSBLOCK / NIGHTFALL_DEV are test seams
# and nothing else - the real things are always these fixed paths.
probe_dir=${NIGHTFALL_ROOT_PROBE:-/run/nightfall/probe-root}
mkdir -p "$probe_dir" 2>/dev/null || true

# Superblock magic -> filesystem name, empty if none of the four is recognised
# or the device cannot be read. od is in the image for this and for
# kexec-preflight.sh. Offsets: ext2/3/4 0x438 (53 ef), xfs 0 ("XFSB"), btrfs
# 0x10040 ("_BHRfS_M"), f2fs 0x400 (0xF2F52010, little-endian).
magic_at() {
    _b=$(od -An -tx1 -j "$2" -N "$3" "$1" 2>/dev/null) || _b=""
    set -- $_b
    echo "$*"
}
fs_type_of() {
    [ "$(magic_at "$1" 1080 2)" = "53 ef" ] && { echo ext4; return; }
    [ "$(magic_at "$1" 0 4)" = "58 46 53 42" ] && { echo xfs; return; }
    [ "$(magic_at "$1" 65600 8)" = "5f 42 48 52 66 53 5f 4d" ] && { echo btrfs; return; }
    [ "$(magic_at "$1" 1024 4)" = "10 20 f5 f2" ] && { echo f2fs; return; }
    # Something IS there but it is none of the four: say so, so the caller
    # can tell "unrecognised - skip" from "could not read - legacy fallback".
    _any=$(magic_at "$1" 0 16)
    [ -n "$_any" ] && echo other
    return 0
}

sysblock=${NIGHTFALL_SYSBLOCK:-/sys/block}
devdir=${NIGHTFALL_DEV:-/dev}
for disk in "$sysblock"/*; do
    d=${disk##*/}
    case "$d" in
        loop*|ram*|zram*|dm-*|md*|sr*) continue ;;
    esac

    for part in "$disk"/"$d"*; do
        [ -d "$part" ] || continue
        p=${part##*/}
        [ "$p" = "$d" ] && continue
        [ -e "$devdir/$p" ] || continue

        # WHAT is on the partition is read from its superblock magic, not
        # found out by trying mounts: a blind mount of an unknown filesystem
        # is exactly how a "read-only" probe ends up writing to something.
        # Each type then gets the option that stops its own journal/log replay
        # (a plain ro mount of a dirty ext4/xfs/btrfs/f2fs still writes):
        #   ext4 noload | xfs norecovery | btrfs rescue=nologreplay | f2fs norecovery
        # Unrecognised (vfat, swap, ntfs, anything else) is skipped WITHOUT
        # being mounted. Unreadable or unsniffable falls back to what this
        # script has always done - ext4 with noload - so an image whose od
        # misbehaves still finds the Slate. NEVER a plain, type-agnostic
        # mount, and never a retry without the protective option.
        # (btrfs: only the top-level subvolume is mounted, so a root inside a
        # subvolume such as @ is not found - documented limit.)
        fs=$(fs_type_of "$devdir/$p")
        case "$fs" in
            ext4)  mopts="ext4 ro,noload" ;;
            xfs)   mopts="xfs ro,norecovery" ;;
            btrfs) mopts="btrfs ro,rescue=nologreplay" ;;
            f2fs)  mopts="f2fs ro,norecovery" ;;
            "")    mopts="ext4 ro,noload" ;;
            *)     continue ;;
        esac
        set -- $mopts
        mount -t "$1" -o "$2" "$devdir/$p" "$probe_dir" 2>/dev/null || continue
        match=""
        layout=""
        if [ -f "$probe_dir/boot/nightfall/build-id" ]; then
            id=$(cat "$probe_dir/boot/nightfall/build-id" 2>/dev/null || echo "")
            [ -n "$id" ] && [ "$id" = "$my_id" ] && { match=1; layout=rootfs; }
        fi
        if [ -z "$match" ] && [ -f "$probe_dir/nightfall/build-id" ]; then
            id=$(cat "$probe_dir/nightfall/build-id" 2>/dev/null || echo "")
            [ -n "$id" ] && [ "$id" = "$my_id" ] && { match=1; layout=bootfs; }
        fi
        umount "$probe_dir" 2>/dev/null || true

        if [ -n "$match" ]; then
            printf '/dev/%s %s\n' "$p" "$layout"
            exit 0
        fi
    done
done
exit 1

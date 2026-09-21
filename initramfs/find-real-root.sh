#!/bin/sh
# Finds which real partition THIS EXACT Nightfall build actually lives on,
# instead of assuming it is always the Slate's internal eMMC.
#
#   find-real-root.sh <my-build-id>  ->  /dev/<partition> on stdout
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

        # No -t: whatever native filesystem this partition holds, the
        # kernel picks it - a partition this build's own root could
        # never actually be on (a vfat ESP, a swap partition) just fails
        # to mount and is skipped, the same as everywhere else here.
        mount -o ro "$devdir/$p" "$probe_dir" 2>/dev/null || continue
        match=""
        if [ -f "$probe_dir/boot/nightfall/build-id" ]; then
            id=$(cat "$probe_dir/boot/nightfall/build-id" 2>/dev/null || echo "")
            [ -n "$id" ] && [ "$id" = "$my_id" ] && match=1
        fi
        umount "$probe_dir" 2>/dev/null || true

        if [ -n "$match" ]; then
            printf '/dev/%s\n' "$p"
            exit 0
        fi
    done
done
exit 1

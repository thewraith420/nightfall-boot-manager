#!/bin/sh
# Finds external drives the picker could back up to.
#
#   discover-backup-targets.sh <root-device>  ->  dev\tfstype\tlabel\tsize\tfree
#
# <root-device> is the partition holding the real system, which is
# excluded along with the whole disk it lives on: backing a machine up
# onto itself is not a backup, and offering it would invite exactly that.
#
# Enumerated from /sys/block rather than lsblk(1), which is not a busybox
# applet. blkid supplies the filesystem type and label; a partition with
# no recognisable filesystem is skipped rather than guessed at.
#
# Free space is only known for something we can mount, so it is probed by
# mounting read-only and unmounting again. That is the cheapest honest
# answer - a partition size tells you nothing about what is already on it.
set -eu

rootdev=${1:?usage: discover-backup-targets.sh <root-device>}

# /dev/mmcblk0p2 -> mmcblk0 ; /dev/sda2 -> sda
rootpart=${rootdev##*/}
rootdisk=$rootpart
case "$rootdisk" in
    mmcblk*|nvme*) rootdisk=${rootdisk%p[0-9]*} ;;
    *)             while [ "${rootdisk%[0-9]}" != "$rootdisk" ]; do rootdisk=${rootdisk%[0-9]}; done ;;
esac

probe_dir=/run/picker/probe
mkdir -p "$probe_dir" 2>/dev/null || true

for disk in /sys/block/*; do
    d=${disk##*/}
    case "$d" in
        loop*|ram*|zram*|dm-*|md*|sr*) continue ;;
        "$rootdisk") continue ;;          # never the disk we boot from
    esac

    # Partitions appear as subdirectories named after themselves.
    for part in "$disk"/"$d"*; do
        [ -d "$part" ] || continue
        p=${part##*/}
        [ "$p" = "$d" ] && continue
        [ -e "/dev/$p" ] || continue

        line=$(blkid "/dev/$p" 2>/dev/null) || continue
        # awk, not sed: sed is not a busybox applet in this image, and a
        # script that works on the build host but not in the initramfs is
        # the exact failure this project keeps re-learning.
        fstype=$(printf '%s' "$line" | awk 'match($0, /TYPE="[^"]*"/) {
            t = substr($0, RSTART + 6, RLENGTH - 7); print t }')
        label=$(printf '%s' "$line" | awk 'match($0, /LABEL="[^"]*"/) {
            t = substr($0, RSTART + 7, RLENGTH - 8); print t }')
        [ -n "$fstype" ] || continue

        sectors=$(cat "$part/size" 2>/dev/null || echo 0)
        size=$(awk -v s="$sectors" 'BEGIN{
            b = s * 512
            if (b >= 1099511627776) printf "%.1fT", b/1099511627776
            else if (b >= 1073741824) printf "%.0fG", b/1073741824
            else printf "%.0fM", b/1048576
        }')

        # Free space, if it will mount at all. Read-only: this is a
        # survey, and a target that cannot even be mounted read-only is
        # not one to offer.
        free="?"
        if mount -o ro "/dev/$p" "$probe_dir" 2>/dev/null; then
            free=$(df -h "$probe_dir" 2>/dev/null | awk 'NR==2{print $4}')
            umount "$probe_dir" 2>/dev/null || true
        else
            continue
        fi

        printf '/dev/%s\t%s\t%s\t%s\t%s\n' "$p" "$fstype" "${label:-(no label)}" "$size" "${free:-?}"
    done
done

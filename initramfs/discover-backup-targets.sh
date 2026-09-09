#!/bin/sh
# Finds external drives the picker could back up to.
#
#   discover-backup-targets.sh <root-device>  ->  dev\tfstype\tlabel\tsize\tfree
#
# <root-device> is the partition holding the real system, which is
# excluded along with the whole disk it lives on: backing a machine up
# onto itself is not a backup, and offering it would invite exactly that.
#
# Enumerated from /sys/block: neither lsblk nor blkid is a busybox applet
# on the target. Each candidate is mounted read-only to learn both its
# filesystem type (from /proc/mounts, which reports what the kernel
# actually used) and its free space - a partition size tells you nothing
# about what is already on it. Anything that will not mount read-only is
# skipped; it is not a usable backup target whatever it is.
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

        sectors=$(cat "$part/size" 2>/dev/null || echo 0)
        [ "$sectors" -gt 0 ] 2>/dev/null || continue
        size=$(awk -v s="$sectors" 'BEGIN{
            b = s * 512
            if (b >= 1099511627776) printf "%.1fT", b/1099511627776
            else if (b >= 1073741824) printf "%.0fG", b/1073741824
            else printf "%.0fM", b/1048576
        }')

        # Mount it to find out what it is. blkid would be the obvious
        # tool and is NOT a busybox applet on the target (the Slate's
        # Ubuntu busybox lacks it, the dev machine's Debian one has it -
        # caught by build-initramfs.sh's applet preflight rather than at
        # boot). We already have to mount each candidate to measure free
        # space, and /proc/mounts then reports the type the kernel
        # actually used, which is a better answer than a probe anyway.
        #
        # A partition that will not mount read-only is skipped: it is not
        # a usable backup target, whatever it is.
        mount -o ro "/dev/$p" "$probe_dir" 2>/dev/null || continue
        fstype=$(awk -v d="/dev/$p" '$1 == d { print $3; exit }' /proc/mounts 2>/dev/null)
        free=$(df -h "$probe_dir" 2>/dev/null | awk 'NR==2{print $4}')
        umount "$probe_dir" 2>/dev/null || true
        [ -n "$fstype" ] || continue

        # Label is left empty: reading it needs blkid. picker falls back
        # to the device name, and device + type + free space is enough to
        # choose between drives.
        label=""

        # Emitted EMPTY, not "(no label)": picker falls back to the
        # device name when this is blank, and a literal placeholder
        # would defeat that and read worse.
        printf '/dev/%s\t%s\t%s\t%s\t%s\n' "$p" "$fstype" "$label" "$size" "${free:-?}"
    done
done

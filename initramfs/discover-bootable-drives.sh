#!/bin/sh
# Finds external drives that can be handed to FIRMWARE to boot directly -
# a Ventoy stick, a live USB written by Rufus/dd/the Startup Disk Creator,
# or a whole separate OS installed on an external disk.
#
#   discover-bootable-drives.sh <root-device>  ->  part-dev\tloader\tlabel\tsize
#
# <root-device> is excluded along with the whole disk it lives on, same
# reasoning as discover-backup-targets.sh: this machine is never its own
# "external drive to boot instead".
#
# A drive counts as bootable if ANY of its partitions is a FAT filesystem
# carrying the UEFI REMOVABLE MEDIA fallback loader - \EFI\BOOT\BOOTX64.EFI
# (or the 32-bit variant). This is deliberately NOT an attempt to find
# every OS-specific loader path (\EFI\ubuntu\shimx64.efi and so on): the
# fallback path is what Ventoy uses, what most live-USB creation tools
# write, and what boot-external-drive.sh's own fresh boot entry points
# at regardless of what is found here - so it is also the one path that
# actually has to exist for the boot attempt this discovery feeds to work
# at all. A "real" installed OS that also has its own named loader still
# gets found by this the same way, since removable installers commonly
# leave the fallback path in place too.
set -eu

rootdev=${1:?usage: discover-bootable-drives.sh <root-device>}

rootpart=${rootdev##*/}
rootdisk=$rootpart
case "$rootdisk" in
    mmcblk*|nvme*) rootdisk=${rootdisk%p[0-9]*} ;;
    *)             while [ "${rootdisk%[0-9]}" != "$rootdisk" ]; do rootdisk=${rootdisk%[0-9]}; done ;;
esac

# NIGHTFALL_ESP_PROBE is a test seam and nothing else.
probe_dir=${NIGHTFALL_ESP_PROBE:-/run/nightfall/probe-esp}
mkdir -p "$probe_dir" 2>/dev/null || true

# NIGHTFALL_SYSBLOCK / NIGHTFALL_DEV are test seams and nothing else -
# the real things are always /sys/block and /dev. discover-backup-targets.sh
# has this exact same /sys/block-and-/dev walk with no such override,
# which is why it has never had a test at all; not repeating that gap.
sysblock=${NIGHTFALL_SYSBLOCK:-/sys/block}
devdir=${NIGHTFALL_DEV:-/dev}
for disk in "$sysblock"/*; do
    d=${disk##*/}
    case "$d" in
        loop*|ram*|zram*|dm-*|md*|sr*) continue ;;
        "$rootdisk") continue ;;
    esac

    disksectors=$(cat "$disk/size" 2>/dev/null || echo 0)
    disksize=$(awk -v s="$disksectors" 'BEGIN{
        b = s * 512
        if (b >= 1099511627776) printf "%.1fT", b/1099511627776
        else if (b >= 1073741824) printf "%.0fG", b/1073741824
        else printf "%.0fM", b/1048576
    }')

    for part in "$disk"/"$d"*; do
        [ -d "$part" ] || continue
        p=${part##*/}
        [ "$p" = "$d" ] && continue
        [ -e "$devdir/$p" ] || continue

        # A partition that will not mount read-only is not a candidate,
        # whatever it is - same rule discover-backup-targets.sh uses.
        mount -o ro "$devdir/$p" "$probe_dir" 2>/dev/null || continue
        loader=""
        if   [ -f "$probe_dir/EFI/BOOT/BOOTX64.EFI" ]; then loader='\EFI\BOOT\BOOTX64.EFI'
        elif [ -f "$probe_dir/EFI/BOOT/BOOTX64.efi" ]; then loader='\EFI\BOOT\BOOTX64.efi'
        elif [ -f "$probe_dir/EFI/BOOT/BOOTIA32.EFI" ]; then loader='\EFI\BOOT\BOOTIA32.EFI'
        elif [ -f "$probe_dir/EFI/BOOT/BOOTIA32.efi" ]; then loader='\EFI\BOOT\BOOTIA32.efi'
        fi
        umount "$probe_dir" 2>/dev/null || true
        [ -n "$loader" ] || continue

        # Label empty, matching discover-backup-targets.sh exactly: no
        # blkid on the target, so picker falls back to the device name.
        printf '/dev/%s\t%s\t%s\t%s\n' "$p" "$loader" "" "$disksize"
        # One bootable entry per DISK is enough - a drive with two ESPs
        # is not a case worth the extra row.
        break
    done
done

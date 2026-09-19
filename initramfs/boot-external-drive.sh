#!/bin/sh
# Hands a whole external drive to FIRMWARE to boot next, instead of
# Nightfall trying to understand what is on it.
#
#   boot-external-drive.sh <partition-dev> <loader-path>
#
# <partition-dev> and <loader-path> are exactly what
# discover-bootable-drives.sh reported: the ESP partition it found (e.g.
# /dev/sda1) and the UEFI removable-media fallback loader path on it
# (e.g. '\EFI\BOOT\BOOTX64.EFI').
#
# WHY THIS EXISTS: boot-live-iso.sh only understands two specific live-USB
# layouts (casper, live-boot) reached by loop-mounting a .iso file - which
# is narrower than what was actually asked for: boot a Ventoy stick (which
# then shows VENTOY'S OWN menu), any other live-USB-creation-tool drive,
# or a whole separate OS installed on an external disk. None of those are
# things Nightfall should try to parse - an installed OS has no ISO to
# loop-mount at all. The generic answer is the same one pressing F12 gives
# with a keyboard: tell firmware which device to boot next, then get out
# of the way entirely and let ITS bootloader (Ventoy's grub, the live
# distro's own, the installed OS's own) take it from there.
#
# HOW: efibootmgr creates a fresh UEFI boot entry pointing at the loader
# already found on the drive, arms it with BootNext (one-shot - it does
# not touch BootOrder, so if the boot never happens for any reason, the
# NEXT reboot just falls through to the normal order). This script's job
# ends there - init still owns the actual reboot, the same way
# boot-live-iso.sh does the kexec but init decides when to call it.
#
# A fresh entry is created every time rather than reusing one already in
# NVRAM: matching an existing entry to a partition would need blkid or
# PARTUUID, neither of which is available in this initramfs (no udev).
# Any prior entry made by THIS script (same fixed label) is deleted first,
# so repeated use does not pile up NVRAM clutter across boots.
set -eu

part=${1:?usage: boot-external-drive.sh <partition-dev> <loader-path>}
loader=${2:?usage: boot-external-drive.sh <partition-dev> <loader-path>}

say() { echo "boot-external-drive: $*" >&2; }
die() { echo "boot-external-drive: ERROR: $*" >&2; exit 1; }

LABEL="Nightfall-boot-once"

# NIGHTFALL_EFIBOOTMGR is a test seam and nothing else - the real thing is
# always /sbin/efibootmgr. Same absolute-path-with-override convention
# fsck-root.sh uses for e2fsck (NIGHTFALL_FSCK), rather than relying on
# efibootmgr being on PATH.
EFIBOOTMGR=${NIGHTFALL_EFIBOOTMGR:-/sbin/efibootmgr}

# <partition-dev> -> disk + partition number, the two things efibootmgr
# wants separately. mmcblk/nvme use a 'p' separator precisely so their own
# trailing digits (mmcblk0, nvme0n1) are not mistaken for a partition
# number - same split discover-bootable-drives.sh does in the other
# direction (partition -> the disk it belongs to).
pdev=${part##*/}
case "$pdev" in
    mmcblk*|nvme*)
        disk=${pdev%p[0-9]*}
        partnum=${pdev#${disk}p}
        ;;
    *)
        disk=$pdev
        while [ "${disk%[0-9]}" != "$disk" ]; do disk=${disk%[0-9]}; done
        partnum=${pdev#$disk}
        ;;
esac
case "$partnum" in
    ''|*[!0-9]*) die "'$part' does not look like a partition (no trailing number)" ;;
esac

# Built next to $part rather than hardcoded to /dev/ - the only thing
# known here is the directory the caller actually gave for the partition,
# and assuming it is always literally /dev is exactly the kind of
# untestable hardcoding discover-backup-targets.sh already has and this
# project has been deliberately not repeating.
partdir=${part%/*}
diskdev="$partdir/$disk"
[ -e "$diskdev" ] || die "no such device: $diskdev"
[ -e "$part" ] || die "no such device: $part"

say "target: disk=$diskdev partition=$partnum loader=$loader"

# Cleanup first: any earlier boot-external-drive.sh entry left behind (an
# attempt that armed BootNext but, for whatever reason, never got to
# reboot) would otherwise accumulate forever - efibootmgr has no notion of
# "temporary". Matched on the fixed label alone: specific enough that no
# firmware or installer is expected to have produced it on its own.
old=$($EFIBOOTMGR 2>/dev/null | grep -F "$LABEL" | grep -oE '^Boot[0-9A-Fa-f]{4}' | sed 's/^Boot//') || old=""
for n in $old; do
    say "removing a stale entry from a previous attempt (Boot$n)"
    $EFIBOOTMGR -b "$n" -B >/dev/null 2>&1 || say "WARNING: could not remove Boot$n (continuing anyway)"
done

say "creating a new UEFI boot entry"
create_out=$($EFIBOOTMGR -c -d "$diskdev" -p "$partnum" -L "$LABEL" -l "$loader" 2>&1) || \
    die "efibootmgr could not create a boot entry - nothing was changed
$create_out"

bootnum=$(printf '%s\n' "$create_out" | grep -F "$LABEL" | grep -oE '^Boot[0-9A-Fa-f]{4}' | sed 's/^Boot//' | head -n1)
[ -n "$bootnum" ] || die "created an entry but could not find its Boot number in efibootmgr's output - refusing to guess
$create_out"

say "arming BootNext = Boot$bootnum"
if ! $EFIBOOTMGR -n "$bootnum" >/dev/null 2>&1; then
    $EFIBOOTMGR -b "$bootnum" -B >/dev/null 2>&1 || say "WARNING: could not remove Boot$bootnum after BootNext failed to set"
    die "could not set BootNext - the new entry was removed, nothing else was changed"
fi

# Read back rather than trust the exit status alone - BootNext is the one
# thing this whole script exists to set, so it gets its own confirmation
# instead of being inferred from efibootmgr not complaining.
confirmed=$($EFIBOOTMGR 2>/dev/null | grep -iE '^BootNext:' | grep -ioE '[0-9A-Fa-f]{4}$' || true)
if [ "$(printf '%s' "$confirmed" | tr a-f A-F)" != "$(printf '%s' "$bootnum" | tr a-f A-F)" ]; then
    $EFIBOOTMGR -b "$bootnum" -B >/dev/null 2>&1 || say "WARNING: could not remove Boot$bootnum after BootNext failed to confirm"
    die "BootNext did not take (read back '$confirmed', expected '$bootnum') - the new entry was removed, nothing else was changed"
fi

say "BootNext armed: this machine will boot from $part ($loader) on the next reboot"

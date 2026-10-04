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
# WHY THIS EXISTS: boot a Ventoy stick (which then shows VENTOY'S OWN
# menu), any other live-USB-creation-tool drive, or a whole separate OS
# installed on an external disk. None of those are things Nightfall should
# try to parse. It once tried, for single ISO files (boot-live-iso.sh,
# removed 2026-10-03): live systems cannot read the exFAT a Ventoy stick
# uses while they start, and a Ventoy-style workaround passed in QEMU but
# failed on real hardware - so Ventoy itself, reached through this, is
# the one way to boot an ISO. The generic answer is the same one pressing F12 gives
# with a keyboard: tell firmware which device to boot next, then get out
# of the way entirely and let ITS bootloader (Ventoy's grub, the live
# distro's own, the installed OS's own) take it from there.
#
# HOW: efibootmgr creates a fresh UEFI boot entry pointing at the loader
# already found on the drive, arms it with BootNext (one-shot), and this
# script's job ends there - init still owns the actual reboot.
#
# BootOrder is deliberately put back exactly as found. `efibootmgr -c`
# does NOT leave BootOrder alone - confirmed on real hardware, contrary
# to what an earlier version of this comment assumed - it prepends the
# entry it just created. Left alone, a boot that used BootNext once would
# permanently add a "boot this drive" entry to the front of someone's
# normal boot sequence, which is a far bigger footprint on THEIR firmware
# than the "temporary" this is supposed to be. BootNext does not need the
# entry to be IN BootOrder to work as a one-shot override, so the fix
# costs nothing: read BootOrder before creating anything, restore that
# exact value once BootNext is confirmed armed.
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

# Captured AFTER the stale entries are gone, so restoring it later puts
# BootOrder back to what it was minus our own leftovers - not "everything
# except our entry" computed some other way. Captured before, it put the
# deleted entries straight back into BootOrder on restore (the LOQ ended up
# with BootOrder starting 0007,0006 - two entries this script had made).
orig_order=$($EFIBOOTMGR 2>/dev/null | grep -oE '^BootOrder: .*' | cut -d' ' -f2) || orig_order=""

# Every failure after the new entry exists goes through here: remove the
# entry (if its number is known) and put BootOrder back, since
# efibootmgr -c has already moved the new entry to the front of it. A
# failed attempt has to leave NVRAM as it found it, or the next normal
# boot tries a one-shot entry that was never meant to stay.
undo_create() {
    if [ -n "${1:-}" ]; then
        $EFIBOOTMGR -b "$1" -B >/dev/null 2>&1 || say "WARNING: could not remove Boot$1"
    fi
    if [ -n "$orig_order" ]; then
        $EFIBOOTMGR -o "$orig_order" >/dev/null 2>&1 || say "WARNING: could not restore the original BootOrder"
    fi
}

say "creating a new UEFI boot entry"
create_out=$($EFIBOOTMGR -c -d "$diskdev" -p "$partnum" -L "$LABEL" -l "$loader" 2>&1) || \
    die "efibootmgr could not create a boot entry - nothing was changed
$create_out"

bootnum=$(printf '%s\n' "$create_out" | grep -F "$LABEL" | grep -oE '^Boot[0-9A-Fa-f]{4}' | sed 's/^Boot//' | head -n1)
# Some efibootmgr versions print less after -c. The stale entries are
# gone, so ours is the only one with this label: ask again rather than
# give up with a just-created entry left behind.
[ -n "$bootnum" ] || bootnum=$($EFIBOOTMGR 2>/dev/null | grep -F "$LABEL" | grep -oE '^Boot[0-9A-Fa-f]{4}' | sed 's/^Boot//' | head -n1)
if [ -z "$bootnum" ]; then
    undo_create ""
    die "created an entry but could not find its Boot number - BootOrder was put back; the entry may need removing by hand
$create_out"
fi

say "arming BootNext = Boot$bootnum"
if ! $EFIBOOTMGR -n "$bootnum" >/dev/null 2>&1; then
    undo_create "$bootnum"
    die "could not set BootNext - the new entry was removed and BootOrder put back"
fi

# Read back rather than trust the exit status alone - BootNext is the one
# thing this whole script exists to set, so it gets its own confirmation
# instead of being inferred from efibootmgr not complaining.
confirmed=$($EFIBOOTMGR 2>/dev/null | grep -iE '^BootNext:' | grep -ioE '[0-9A-Fa-f]{4}$' || true)
if [ "$(printf '%s' "$confirmed" | tr a-f A-F)" != "$(printf '%s' "$bootnum" | tr a-f A-F)" ]; then
    undo_create "$bootnum"
    die "BootNext did not take (read back '$confirmed', expected '$bootnum') - the new entry was removed and BootOrder put back"
fi


# Best-effort, and deliberately not a failure if it doesn't take: BootNext
# is already confirmed armed above, which is the part that actually has to
# work for this boot. Leaving BootOrder with our entry prepended would be
# a real, if lesser, problem the NEXT time firmware boots normally - but
# it is not a reason to unwind an already-successful BootNext.
if [ -n "$orig_order" ]; then
    $EFIBOOTMGR -o "$orig_order" >/dev/null 2>&1 || \
        say "WARNING: could not restore the original BootOrder (BootNext is still armed correctly)"
fi

say "BootNext armed: this machine will boot from $part ($loader) on the next reboot"

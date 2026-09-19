#!/bin/sh
# Boots a live ISO found on an external drive, from Nightfall.
#
#   boot-live-iso.sh <target-partition> <iso-path>
#
# <iso-path> is relative to the target partition's own root, exactly as
# discover-live-isos.sh reports it (e.g. "ubuntu-24.04-desktop-amd64.iso"
# or "isos/ubuntu-24.04-desktop-amd64.iso").
#
# WHY THIS EXISTS: scan-drives.sh's own header explains that the drive
# cannot be plugged in at boot, because with no keyboard there is no way
# to tell the firmware to skip a bootable USB stick - so a Ventoy drive
# has to arrive AFTER Nightfall is already running. Until now that only
# let you back up to it or restore from it. This is the keyboard-free
# path to the thing restore-system.sh's own header points at for the
# case nothing else can fix: booting a live image and going from there.
#
# HOW: Ventoy and similar tools store ISO files as plain files on an
# ordinary exFAT/NTFS partition - they never extract them - so this
# loop-mounts the .iso as iso9660 and looks inside for a live system it
# recognises, exactly the trick GRUB+Ventoy already do to boot one.
# Needs CONFIG_ISO9660_FS in the picker kernel; nothing here can work
# without it.
#
# TWO FAMILIES, checked in this order, because that covers what Bob
# actually has and keeps the detection surface small rather than
# guessing at every live-boot flavour in existence:
#   casper      Ubuntu and derivatives.    boot=casper iso-scan/filename=
#   live-boot   Debian Live.               boot=live findiso=
# Anything else is refused by name rather than guessed at - a wrong
# guess here means kexec into a kernel with no idea how to find its own
# root, which is a hang with no way back except the power button.
#
# Deliberately NOT quiet: this is a rescue boot. If the live system
# fails to find or mount the ISO after the handoff, that has to be
# visible, not hidden behind a splash - Nightfall's own boot screens
# stay off this one on purpose (see initramfs/init).
set -eu

target=${1:?usage: boot-live-iso.sh <target-partition> <iso-path>}
isopath=${2:?usage: boot-live-iso.sh <target-partition> <iso-path>}

say() { echo "boot-live-iso: $*" >&2; }
die() { echo "boot-live-iso: ERROR: $*" >&2; exit 1; }

# One path component at a time, like every other name this project
# accepts from the UI rather than typing: a "/.." component would escape
# the mounted drive, and this must not depend on the caller having been
# careful.
case "$isopath" in
    /*|*/../*|../*|*/..|"") die "implausible ISO path: '$isopath'" ;;
esac

# NIGHTFALL_LIVE_TARGET_MNT / NIGHTFALL_LIVE_ISO_MNT are test seams and
# nothing else - the real thing is always these two fixed /run/nightfall
# paths.
TARGET_MNT=${NIGHTFALL_LIVE_TARGET_MNT:-/run/nightfall/live-target}
ISO_MNT=${NIGHTFALL_LIVE_ISO_MNT:-/run/nightfall/live-iso}
mkdir -p "$TARGET_MNT" "$ISO_MNT" 2>/dev/null || true

# Torn down in the order it was built, and only what actually succeeded -
# a script that dies on its own first mkdir must not try to unmount a
# loop device that was never attached.
loopdev=""
iso_mounted=0
target_mounted=0
cleanup() {
    [ "$iso_mounted" = 1 ] && { umount "$ISO_MNT" 2>/dev/null || say "WARNING: could not unmount $ISO_MNT"; }
    [ -n "$loopdev" ] && { losetup -d "$loopdev" 2>/dev/null || say "WARNING: could not detach $loopdev"; }
    [ "$target_mounted" = 1 ] && { umount "$TARGET_MNT" 2>/dev/null || say "WARNING: could not unmount $TARGET_MNT"; }
}
trap cleanup EXIT

say "mounting $target read-only"
mount -o ro "$target" "$TARGET_MNT" || die "could not mount $target - nothing was booted"
target_mounted=1

iso="$TARGET_MNT/$isopath"
[ -f "$iso" ] || die "no such file: $isopath on $target - nothing was booted"

say "attaching $isopath as a loop device (read-only)"
loopdev=$(losetup -f 2>/dev/null) || die "no free loop device"
losetup -r "$loopdev" "$iso" || die "could not attach $loopdev to $isopath"

say "mounting $loopdev as iso9660"
mount -t iso9660 -o ro "$loopdev" "$ISO_MNT" || \
    die "could not mount $isopath as iso9660 - is it really an ISO image? Nothing was booted"
iso_mounted=1

# First match wins. Order is casper then live-boot, matching the header.
ktype="" kvmlinuz="" kinitrd=""
if [ -z "$ktype" ]; then
    for vmz in vmlinuz vmlinuz.efi; do
        [ -f "$ISO_MNT/casper/$vmz" ] || continue
        for ird in initrd initrd.gz initrd.lz initrd.img; do
            [ -f "$ISO_MNT/casper/$ird" ] || continue
            ktype=casper kvmlinuz=$ISO_MNT/casper/$vmz kinitrd=$ISO_MNT/casper/$ird
            break 2
        done
    done
fi
if [ -z "$ktype" ]; then
    for vmz in vmlinuz; do
        [ -f "$ISO_MNT/live/$vmz" ] || continue
        for ird in initrd.img initrd.gz initrd; do
            [ -f "$ISO_MNT/live/$ird" ] || continue
            ktype=live-boot kvmlinuz=$ISO_MNT/live/$vmz kinitrd=$ISO_MNT/live/$ird
            break 2
        done
    done
fi

[ -n "$ktype" ] || die "$isopath does not look like a supported live image
  (checked for casper's /casper/vmlinuz+initrd and Debian live-boot's
  /live/vmlinuz+initrd.img). Nothing was booted."

case "$ktype" in
    casper)    cmdline="boot=casper iso-scan/filename=/$isopath" ;;
    live-boot) cmdline="boot=live findiso=/$isopath" ;;
esac
say "found a $ktype live image: $kvmlinuz + $kinitrd"
say "cmdline: $cmdline"

# THE POINT OF NO RETURN. kexec -l reads and stages the kernel/initrd
# into memory now; the source files are irrelevant to it from here on,
# which is what makes it safe to tear the mounts down before -e - the
# new kernel enumerates devices fresh at boot and finds the ISO on its
# own via iso-scan/filename or findiso, exactly as GRUB+Ventoy do.
say "kexec -l"
kexec -l "$kvmlinuz" --initrd="$kinitrd" --command-line="$cmdline" || \
    die "kexec -l failed - nothing was booted, the machine is unchanged"

say "tearing down mounts before the handoff"
cleanup
trap - EXIT
iso_mounted=0; target_mounted=0; loopdev=""

say "kexec -e"
kexec -e

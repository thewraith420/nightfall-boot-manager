#!/bin/sh
# The repairs that run INSIDE the target system, from Nightfall.
#
#   repair-system.sh <root-mount> <dpkg|clean|grub>
#
# These are the three actions from Ubuntu's recovery menu that are worth
# having and need no network: repair half-configured packages, free disk
# space, and regenerate the boot menu. Ubuntu's versions are unreachable
# on this machine - recovery mode is an ncurses menu and the tablet has
# no keyboard - so they are reimplemented here as things you can tap.
#
# One script rather than three, because the chroot boilerplate is the
# bulk of each and having one copy of it means one place to get the bind
# mounts and the read-only remount right.
#
# Everything runs through the TARGET's own tools by absolute path. Both
# halves of that matter: its dpkg matches its package database, and a
# bare "dpkg" would resolve from busybox's applet table before the
# chroot's filesystem under Ubuntu's FEATURE_SH_STANDALONE build - the
# trap that has now cost this project a backup attempt and a test pass.
set -eu

root=${1:?usage: repair-system.sh <root-mount> <dpkg|clean|grub>}
action=${2:?usage: repair-system.sh <root-mount> <dpkg|clean|grub>}

say() { echo "repair: $*" >&2; }
die() { echo "repair: ERROR: $*" >&2; exit 1; }

case "$action" in
    dpkg|clean|grub) ;;
    *) die "unknown repair '$action'" ;;
esac

[ -d "$root" ] || die "root mount $root is not a directory"

cleanup() {
    for d in dev/pts dev proc sys; do umount "$root/$d" 2>/dev/null || true; done
    mount -o remount,ro "$root" 2>/dev/null || \
        say "WARNING: could not remount $root read-only again"
}
trap cleanup EXIT

say "remounting $root read-write"
mount -o remount,rw "$root" || die "could not remount $root read-write"

say "preparing chroot"
mount -t proc  none "$root/proc" 2>/dev/null || die "could not mount /proc in the chroot"
mount -t sysfs none "$root/sys"  2>/dev/null || true
mount -o bind /dev "$root/dev" 2>/dev/null || die "could not bind /dev into the chroot"
mount -o bind /dev/pts "$root/dev/pts" 2>/dev/null || true

used_before=$(df -k "$root" 2>/dev/null | awk 'NR==2{print $3}')

case "$action" in
  dpkg)
    # What a half-finished apt upgrade leaves behind. Needs no network:
    # everything it configures is already unpacked on disk.
    [ -x "$root/usr/bin/dpkg" ] || die "no dpkg inside the target system"
    say "configuring packages that were left half-installed"
    chroot "$root" /usr/bin/dpkg --configure -a || \
        die "dpkg could not finish - the output above says which package"
    if [ -x "$root/usr/bin/apt-get" ]; then
        # --no-download and --fix-broken together: fix what can be fixed
        # from what is already on disk, and do not sit waiting on a
        # network this initramfs does not have.
        say "fixing broken dependencies from packages already on disk"
        chroot "$root" /usr/bin/apt-get --no-download --fix-broken --yes install || \
            say "apt could not fix everything offline - some of it may need a network"
    fi
    say "package repair finished"
    ;;

  clean)
    # A full root filesystem is a classic "it will not boot" cause, and
    # the two biggest reclaimable things are the apt cache and the
    # journal. Deliberately NOT apt autoremove: it will happily remove
    # kernels, which is not a thing to do unattended from a repair menu.
    if [ -x "$root/usr/bin/apt-get" ]; then
        say "emptying the package cache"
        chroot "$root" /usr/bin/apt-get clean || say "apt-get clean failed - continuing"
    fi
    if [ -x "$root/usr/bin/journalctl" ]; then
        say "trimming the systemd journal to 50M"
        chroot "$root" /usr/bin/journalctl --vacuum-size=50M || \
            say "journal trim failed - continuing"
    fi
    say "space cleanup finished"
    ;;

  grub)
    # Cheap, and the fix when grub.cfg no longer matches what is on disk
    # - a half-finished kernel install, or a restore from a backup taken
    # when a different set of kernels existed.
    [ -x "$root/usr/sbin/grub-probe" ] || die "no grub-probe inside the target system"
    say "checking the chroot can resolve the disk"
    chroot "$root" /usr/sbin/grub-probe --target=device / >/dev/null 2>&1 || \
        die "grub-probe cannot resolve the root device - not regenerating the menu"
    say "update-grub"
    chroot "$root" /usr/sbin/update-grub || die "update-grub failed"
    say "boot menu regenerated"
    ;;
esac

sync

used_after=$(df -k "$root" 2>/dev/null | awk 'NR==2{print $3}')
if [ -n "${used_before:-}" ] && [ -n "${used_after:-}" ]; then
    freed=$((used_before - used_after))
    if [ "$freed" -gt 1024 ]; then
        say "freed $((freed / 1024))MB"
    elif [ "$freed" -lt -1024 ]; then
        say "used $(( -freed / 1024 ))MB more"
    fi
fi

exit 0

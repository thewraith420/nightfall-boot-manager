#!/bin/sh
# Assembles the picker initramfs into a cpio.gz the picker kernel can
# boot, then verifies the result can actually work before you trust it.
#
#   ./build-initramfs.sh [output.img]
#
# Run this ON THE TARGET (the Slate), or on a machine with a matching
# userland: the image bundles the local busybox, kexec, and the shared
# libraries ui/nightfall is linked against, so a mismatched libc here
# means a picker that won't start there.
#
# Everything it needs is checked up front and reported by name - a
# missing piece fails the build rather than producing an image that
# panics at boot with no console to say why.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
out=${1:-$here/nightfall-initramfs.img}
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

# Applets init/discover-kernels.sh/apply-default.sh/kexec-boot.sh use.
# The second group is used only by init's diagnostics (see the boot-log
# block in init): without them a failed boot leaves nothing behind, which
# is what made the first real attempt impossible to debug. They are
# applet symlinks into the one busybox binary, so they cost no space.
APPLETS="sh mount umount mkdir echo printf cut head awk cat ls
         sleep dmesg uname tail sync date wc grep
         tar chroot tee rm df mv
         reboot poweroff
         losetup
         od"

say() { echo "==> $*"; }
die() { echo "build-initramfs: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

missing=
need_cmd() { command -v "$1" >/dev/null 2>&1 || missing="$missing $1"; }
need_cmd busybox
need_cmd cpio
need_cmd gzip
need_cmd fakeroot
[ -n "$missing" ] && die "missing build tools:$missing
  Debian/Ubuntu: sudo apt install busybox-static cpio gzip fakeroot"

# e2fsck, so Repair can check the root filesystem with it UNMOUNTED -
# which is the one thing Ubuntu's own recovery mode cannot do here,
# because it runs with / still mounted. Built on the same machine it
# will check, so the version always matches the filesystem's features.
e2fsck_bin=$(command -v e2fsck || echo /sbin/e2fsck)
[ -x "$e2fsck_bin" ] || die "e2fsck not found - Repair cannot check the root filesystem.
  Debian/Ubuntu: sudo apt install e2fsprogs"

# efibootmgr, for boot-external-drive.sh: arms a one-shot UEFI BootNext
# entry so firmware boots a Ventoy stick/other live USB/external OS disk
# directly on the next restart, the same as picking it from a firmware
# boot menu. Small (~350KB with its two shared libraries) next to e2fsck.
efibootmgr_bin=$(command -v efibootmgr || echo /usr/sbin/efibootmgr)
[ -x "$efibootmgr_bin" ] || die "efibootmgr not found - cannot boot external drives.
  Debian/Ubuntu: sudo apt install efibootmgr"

kexec_bin=$(command -v kexec || true)
[ -n "$kexec_bin" ] || die "kexec not found - Nightfall's whole job is to kexec.
  Debian/Ubuntu: sudo apt install kexec-tools"

nightfall_bin=$repo/ui/nightfall
[ -x "$nightfall_bin" ] || die "$nightfall_bin not built.
  cd $repo/ui && ./fetch-lvgl.sh && make"

for f in "$here/init" "$here/discover-kernels.sh" "$here/apply-default.sh" \
         "$here/discover-tarballs.sh" "$here/install-kernel.sh" \
         "$here/remove-kernel.sh" "$here/apply-cmdline.sh" \
         "$here/discover-backup-targets.sh" "$here/backup-system.sh" \
         "$here/restore-system.sh" "$here/remove-backup.sh" \
         "$here/rename-backup.sh" "$here/fsck-root.sh" \
         "$here/repair-system.sh" "$here/clear-overrides.sh" \
         "$here/discover-backups.sh" "$here/scan-drives.sh" \
         "$here/discover-live-isos.sh" "$here/boot-live-iso.sh" \
         "$here/discover-bootable-drives.sh" "$here/boot-external-drive.sh" \
         "$here/find-real-root.sh" "$here/kexec-preflight.sh" \
         "$here/discover-bls.sh" \
         "$repo/boot-integration/kexec-boot.sh"; do
    [ -r "$f" ] || die "missing source file: $f"
done

for a in $APPLETS; do
    busybox --list | grep -qx "$a" || die "this busybox lacks the '$a' applet"
done

# --------------------------------------------------------------- staging root

say "staging root at $staging"
mkdir -p "$staging"/bin "$staging"/sbin "$staging"/proc "$staging"/sys \
         "$staging"/dev/pts "$staging"/run/nightfall "$staging"/mnt/root \
         "$staging"/lib "$staging"/lib64 "$staging"/etc

install -m 0755 "$(command -v busybox)" "$staging/bin/busybox"
for a in $APPLETS; do
    [ -e "$staging/bin/$a" ] || ln -s busybox "$staging/bin/$a"
done
# mdev lives in /sbin on most systems; init calls it bare so either works
ln -sf ../bin/busybox "$staging/sbin/mdev"

install -m 0755 "$kexec_bin" "$staging/sbin/kexec"
install -m 0755 "$e2fsck_bin" "$staging/sbin/e2fsck"
install -m 0755 "$efibootmgr_bin" "$staging/sbin/efibootmgr"
ln -sf ../sbin/kexec "$staging/bin/kexec"
install -m 0755 "$nightfall_bin" "$staging/bin/nightfall"

# init references these by absolute path - keep them in lockstep with
# initramfs/init, which is the source of truth for where they live.
install -m 0755 "$here/init"                        "$staging/init"
install -m 0755 "$here/discover-kernels.sh"         "$staging/bin/discover-kernels.sh"
install -m 0755 "$here/apply-default.sh"            "$staging/bin/apply-default.sh"
install -m 0755 "$here/discover-tarballs.sh"        "$staging/bin/discover-tarballs.sh"
install -m 0755 "$here/install-kernel.sh"           "$staging/bin/install-kernel.sh"
install -m 0755 "$here/remove-kernel.sh"            "$staging/bin/remove-kernel.sh"
install -m 0755 "$here/apply-cmdline.sh"            "$staging/bin/apply-cmdline.sh"
install -m 0755 "$here/discover-backup-targets.sh"  "$staging/bin/discover-backup-targets.sh"
install -m 0755 "$here/backup-system.sh"            "$staging/bin/backup-system.sh"
install -m 0755 "$here/restore-system.sh"           "$staging/bin/restore-system.sh"
install -m 0755 "$here/remove-backup.sh"            "$staging/bin/remove-backup.sh"
install -m 0755 "$here/rename-backup.sh"            "$staging/bin/rename-backup.sh"
install -m 0755 "$here/fsck-root.sh"               "$staging/bin/fsck-root.sh"
install -m 0755 "$here/repair-system.sh"           "$staging/bin/repair-system.sh"
install -m 0755 "$here/clear-overrides.sh"         "$staging/bin/clear-overrides.sh"
install -m 0755 "$here/discover-backups.sh"         "$staging/bin/discover-backups.sh"
install -m 0755 "$here/scan-drives.sh"              "$staging/bin/scan-drives.sh"
install -m 0755 "$here/discover-live-isos.sh"       "$staging/bin/discover-live-isos.sh"
install -m 0755 "$here/boot-live-iso.sh"            "$staging/bin/boot-live-iso.sh"
install -m 0755 "$here/discover-bootable-drives.sh" "$staging/bin/discover-bootable-drives.sh"
install -m 0755 "$here/boot-external-drive.sh"      "$staging/bin/boot-external-drive.sh"
install -m 0755 "$here/find-real-root.sh"           "$staging/bin/find-real-root.sh"
install -m 0755 "$here/kexec-preflight.sh"          "$staging/bin/kexec-preflight.sh"
install -m 0755 "$here/discover-bls.sh"             "$staging/bin/discover-bls.sh"
install -m 0755 "$repo/boot-integration/kexec-boot.sh" "$staging/sbin/kexec-boot.sh"

# ------------------------------------------------------------ shared libraries

# Copy every .so each binary actually needs, plus the dynamic loader.
# Missing one of these is the classic "init exists but the kernel says
# it can't run it" boot failure, so resolve them from ldd rather than
# guessing a list.
copy_libs_for() {
    bin=$1
    ldd "$bin" 2>/dev/null | while read -r line; do
        case $line in
            *"=>"*) lib=$(echo "$line" | awk '{print $3}') ;;
            /*)     lib=$(echo "$line" | awk '{print $1}') ;;
            *)      continue ;;
        esac
        [ -n "${lib:-}" ] && [ -e "$lib" ] || continue
        dest="$staging$lib"
        [ -e "$dest" ] && continue
        mkdir -p "$(dirname "$dest")"
        cp -L "$lib" "$dest"
        echo "    $lib"
    done
}

say "resolving shared libraries"
for b in "$staging/bin/busybox" "$staging/sbin/kexec" "$staging/bin/nightfall" \
         "$staging/sbin/e2fsck" "$staging/sbin/efibootmgr"; do
    echo "  $(basename "$b"):"
    copy_libs_for "$b"
done

# ------------------------------------------------------------------ build id

# Stamped into the image so find-real-root.sh can recognise, at boot time,
# which physical partition this exact build actually lives on - needed
# now that the same image can be installed on more than one disk on the
# same machine (Bob's portable recovery/toolkit USB stick, alongside the
# Slate's own internal install). install-nightfall.sh reads the sibling
# file this writes next to $out and copies it onto whatever real root it
# installs to; see find-real-root.sh's own header for the full mechanism.
#
# /proc/sys/kernel/random/uuid needs nothing this build machine wouldn't
# already have (a normal /proc, no extra package) - falls back to
# something merely "probably unique" only if that is somehow unreadable,
# since a build id that collided across two different builds would be a
# much worse failure (find-real-root.sh confidently returning the WRONG
# partition) than this script simply refusing to produce one.
build_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
if [ -z "$build_id" ]; then
    build_id="fallback-$(date +%s%N 2>/dev/null || echo 0)-$$-$(hostname 2>/dev/null || echo unknown)"
    echo "build-initramfs: WARNING: /proc/sys/kernel/random/uuid unavailable," >&2
    echo "  using a weaker fallback build id ($build_id)." >&2
fi
# WITH a trailing newline (%s\n, not %s): init reads this file with the
# shell's own `read`, and `read` on a file with no trailing newline
# returns 1 at EOF even though it assigns the value correctly - which,
# discovered on real hardware, silently turned every build's id back
# into "" the moment init's own `|| ...=""` treated that nonzero status
# as "nothing was there". install-nightfall.sh's copy of this file
# inherits whatever newline convention it's given, so getting it right
# starts here.
printf '%s\n' "$build_id" > "$staging/etc/nightfall-build-id"
printf '%s\n' "$build_id" > "$out.build-id"
say "build id: $build_id"

# ---------------------------------------------------------------------- pack

say "packing $out"
( cd "$staging" && find . -print0 |
    fakeroot sh -c '
        # /dev/console must exist before init runs: the kernel opens it
        # for init stdio, and without it any failure message from init
        # (including the rescue-shell path) goes nowhere.
        mknod -m 622 dev/console c 5 1
        mknod -m 666 dev/null    c 1 3
        mknod -m 666 dev/tty     c 5 0
        find . | cpio -o -H newc --quiet
    ' ) | gzip -9 > "$out"

say "built $out ($(du -h "$out" | cut -f1))"
say "verifying"
"$here/verify-initramfs.sh" "$out"

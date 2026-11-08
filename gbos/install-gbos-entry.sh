#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs (or removes) the GBOS boot entry: gbos-init in the GBOS directory,
# the /boot/gbos symlinks, /etc/gbos settings and /etc/grub.d/42_gbos, then
# update-grub. It touches nothing else: the images and /data are the GBOS
# image builder's, and are never written or removed here.
#
#   sudo ./install-gbos-entry.sh [--release <kernel-release>] [--dir /gbos]
#   sudo ./install-gbos-entry.sh --remove
#
# --release defaults to the running kernel. It must be a kernel with the GBOS
# options built in (CONFIG_GBOS_VEXEMU, EROFS, netfilter): BobZKernel
# pixel-slate-7.2 or later. Installing before the images exist is fine: the
# entry appears on the first update-grub after they do.
#
# Test seams: GBOS_BOOT_DIR, GBOS_CONF_DIR, GBOS_GRUBD_DIR, GBOS_ROOT_PREFIX,
# GBOS_UPDATE_GRUB.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
BOOT=${GBOS_BOOT_DIR:-/boot}
CONF=${GBOS_CONF_DIR:-/etc/gbos}
GRUBD=${GBOS_GRUBD_DIR:-/etc/grub.d}
ROOTPFX=${GBOS_ROOT_PREFIX:-}
UPDATE_GRUB=${GBOS_UPDATE_GRUB:-update-grub}

release=$(uname -r); dir=/gbos; remove=""
while [ $# -gt 0 ]; do
    case "$1" in
        --release) release=${2:?--release needs a value}; shift 2 ;;
        --dir)     dir=${2:?--dir needs a value}; shift 2 ;;
        --remove)  remove=1; shift ;;
        *) echo "usage: $0 [--release REL] [--dir /gbos] | --remove" >&2; exit 2 ;;
    esac
done
case "$dir" in /*) ;; *) echo "error: --dir must be an absolute path" >&2; exit 2 ;; esac
case "$release" in */*|""|.|..) echo "error: implausible release '$release'" >&2; exit 2 ;; esac
dir=${dir%/}
if [ -z "$ROOTPFX" ] && [ "$(id -u)" != 0 ]; then
    echo "error: run as root (sudo)" >&2; exit 1
fi

if [ -n "$remove" ]; then
    olddir=$(cat "$CONF/dir" 2>/dev/null || echo /gbos)
    rm -f "$GRUBD/42_gbos" "$BOOT/gbos/vmlinuz" "$BOOT/gbos/initrd.img"
    rmdir "$BOOT/gbos" 2>/dev/null || :
    rm -f "$ROOTPFX$olddir/gbos-init" "$CONF/kernel-release" "$CONF/dir"
    rmdir "$CONF" 2>/dev/null || :     # kept if a cmdline file is in it
    $UPDATE_GRUB
    echo "GBOS boot entry removed. $olddir (images and data) was left untouched."
    exit 0
fi

[ -f "$BOOT/vmlinuz-$release" ] || { echo "error: $BOOT/vmlinuz-$release does not exist" >&2; exit 1; }
[ -f "$BOOT/initrd.img-$release" ] || { echo "error: $BOOT/initrd.img-$release does not exist" >&2; exit 1; }
cfg="$BOOT/config-$release"
if [ -r "$cfg" ]; then
    missing=""
    for o in CONFIG_GBOS_VEXEMU CONFIG_EROFS_FS CONFIG_ANDROID_BINDER_IPC CONFIG_SECURITY_SELINUX CONFIG_IP_NF_IPTABLES_LEGACY; do
        grep -q "^$o=y" "$cfg" || missing="$missing $o"
    done
    [ -z "$missing" ] || { echo "error: $release lacks GBOS options (not =y):$missing" >&2; exit 1; }
else
    echo "warning: no $cfg - cannot check the kernel has the GBOS options" >&2
fi

mkdir -p "$ROOTPFX$dir" "$BOOT/gbos" "$CONF"
install -m 0755 "$HERE/gbos-init" "$ROOTPFX$dir/gbos-init"
ln -sfn "../vmlinuz-$release"    "$BOOT/gbos/vmlinuz"
ln -sfn "../initrd.img-$release" "$BOOT/gbos/initrd.img"
printf '%s\n' "$release" > "$CONF/kernel-release"
printf '%s\n' "$dir" > "$CONF/dir"
install -m 0755 "$HERE/42_gbos" "$GRUBD/42_gbos"
$UPDATE_GRUB

if [ -f "$ROOTPFX$dir/system.img" ]; then
    echo "GBOS boot entry installed for $release (images in $dir)."
else
    echo "GBOS boot entry staged for $release. It appears in GRUB and Nightfall after"
    echo "the images are in $dir and update-grub runs again."
fi

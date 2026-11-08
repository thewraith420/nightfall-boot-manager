#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# 42_gbos and install-gbos-entry.sh against fixtures, plus the round trip
# that matters: Nightfall's own grub.cfg parser lists the entry with the
# right kernel, initrd and command line. No root, no real /boot.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); GB=$(cd "$HERE/.." && pwd); NF=$(cd "$GB/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failn=$((failn+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qE -- "$3"; then bad "$1"; else ok "$1"; fi; }

cat > "$T/lib" <<'L'
grub_probe=fake_probe
fake_probe() { case "$1" in --target=fs_uuid) echo 1111-root ;; --target=device) echo /dev/fake2 ;; esac; }
make_system_path_relative_to_its_root() { echo "${1#$GBOS_BOOT_DIR}" | sed 's#^#/boot#'; }
prepare_grub_to_access_device() { echo "search --no-floppy --fs-uuid --set=root 1111-root"; }
L
REL=7.2.15-BobZKernel-pixel-slate-dirty
B=$T/boot; R=$T/rootfs; C=$T/etc-gbos; G=$T/grub.d
mkdir -p "$B" "$R/gbos" "$G"
touch "$B/vmlinuz-$REL" "$B/initrd.img-$REL" "$R/gbos/system.img"
printf 'CONFIG_GBOS_VEXEMU=y\nCONFIG_EROFS_FS=y\nCONFIG_ANDROID_BINDER_IPC=y\nCONFIG_SECURITY_SELINUX=y\nCONFIG_IP_NF_IPTABLES_LEGACY=y\n' > "$B/config-$REL"
export GBOS_MKCONFIG_LIB=$T/lib GBOS_BOOT_DIR=$B GBOS_CONF_DIR=$C GBOS_GRUBD_DIR=$G GBOS_ROOT_PREFIX=$R GBOS_UPDATE_GRUB=true
export GRUB_CMDLINE_LINUX_DEFAULT="quiet splash module_blacklist=hid_google_hammer i915.enable_dpcd_backlight=2 i915.enable_psr=0 apparmor=1"
export GRUB_CMDLINE_LINUX=""

out=$("$G/42_gbos" 2>/dev/null); [ -z "$out" ] && ok "no entry before install" || bad "no entry before install"
"$GB/install-gbos-entry.sh" --release "$REL" >/dev/null 2>&1 && ok "install succeeds" || bad "install succeeds"
[ "$(readlink "$B/gbos/vmlinuz")" = "../vmlinuz-$REL" ] && ok "vmlinuz symlink" || bad "vmlinuz symlink"
[ -x "$R/gbos/gbos-init" ] && ok "gbos-init installed executable" || bad "gbos-init installed executable"
out=$("$G/42_gbos" 2>/dev/null)
has  "entry has id gbos"                 "$out" "menuentry 'GBOS \(Android 17\)' .*--id gbos"
has  "linux is the gbos symlink"         "$out" "linux	/boot/gbos/vmlinuz "
has  "initrd is the gbos symlink"        "$out" "initrd	/boot/gbos/initrd.img$"
has  "init= gbos-init, rw, root by UUID" "$out" "root=UUID=1111-root rw init=/gbos/gbos-init"
has  "selinux in lsm=, permissive"       "$out" "lsm=landlock,lockdown,yama,integrity,selinux enforcing=0"
has  "printk.devkmsg=on"                 "$out" "printk.devkmsg=on"
has  "panic reboots"                     "$out" "panic=10"
has  "i915 options kept"                 "$out" "i915.enable_dpcd_backlight=2 i915.enable_psr=0"
has  "module_blacklist kept"             "$out" "module_blacklist=hid_google_hammer"
hasnt "quiet/splash dropped"             "$out" " (quiet|splash)( |$)"
hasnt "apparmor= dropped"                "$out" "apparmor="
printf 'androidboot.foo=bar\n# a comment\n' > "$C/cmdline"
out=$("$G/42_gbos" 2>/dev/null)
has  "extra options from /etc/gbos/cmdline" "$out" "androidboot.foo=bar"
hasnt "comments in /etc/gbos/cmdline ignored" "$out" "a comment"

# Nightfall's own parser lists it
printf '%s\n' "$out" > "$T/grub.cfg"
row=$("$NF/initramfs/discover-kernels.sh" "$T/grub.cfg")
has  "Nightfall lists the entry"         "$row" "^GBOS \(Android 17\)	/boot/gbos/vmlinuz	/boot/gbos/initrd.img	root=UUID=1111-root rw init=/gbos/gbos-init"

rm "$B/initrd.img-$REL"
out=$("$G/42_gbos" 2>/dev/null); [ -z "$out" ] && ok "no entry once the kernel's initrd is gone" || bad "no entry once the kernel's initrd is gone"
touch "$B/initrd.img-$REL"
rm "$R/gbos/system.img"
out=$("$G/42_gbos" 2>/dev/null); [ -z "$out" ] && ok "no entry without the images" || bad "no entry without the images"
touch "$R/gbos/system.img"

sed -i '/GBOS_VEXEMU/d' "$B/config-$REL"
"$GB/install-gbos-entry.sh" --release "$REL" >/dev/null 2>&1 && bad "refuses a kernel without GBOS options" || ok "refuses a kernel without GBOS options"

"$GB/install-gbos-entry.sh" --remove >/dev/null 2>&1 && ok "remove succeeds" || bad "remove succeeds"
[ ! -e "$G/42_gbos" ] && [ ! -e "$B/gbos" ] && [ ! -e "$R/gbos/gbos-init" ] && ok "remove deletes entry, symlinks, gbos-init" || bad "remove deletes entry, symlinks, gbos-init"
[ -f "$R/gbos/system.img" ] && ok "remove leaves the images" || bad "remove leaves the images"
[ -f "$C/cmdline" ] && ok "remove keeps a user's /etc/gbos/cmdline" || bad "remove keeps a user's /etc/gbos/cmdline"
echo "$pass passed, $failn failed"; [ $failn = 0 ]

#!/bin/bash
# discover-bootable-drives.sh against a fake /sys/block.
#
# discover-backup-targets.sh has this exact same /sys/block-walking shape
# and has never had a test at all, because it has no override for it -
# NIGHTFALL_SYSBLOCK exists so this script does not repeat that gap.
set -u
S=$(cd "$(dirname "$0")" && pwd)/discover-bootable-drives.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

setup() {
  SB=$(mktemp -d)
  SYS=$SB/sys-block
  DEV=$SB/dev
  mkdir -p "$SYS" "$DEV" "$SB/bin"
  : > "$SB/root-part"   # stands in for the root device path
}
teardown() { rm -rf "$SB"; }

# $1=disk name  $2=disk sectors  $3+=partition names (each gets its own
# /sys/block/<disk>/<part> dir and its own mount-content directory).
add_disk() {
  d=$1; sectors=$2; shift 2
  mkdir -p "$SYS/$d"
  echo "$sectors" > "$SYS/$d/size"
  for p in "$@"; do
    mkdir -p "$SYS/$d/$p"
    : > "$DEV/$p"       # so the script's [ -e "$devdir/$p" ] check passes
  done
}

# $1 = partition name -> what its mounted content looks like when probed.
esp_with_loader() {
  mkdir -p "$SB/content-$1/EFI/BOOT"
  : > "$SB/content-$1/EFI/BOOT/BOOTX64.EFI"
}
non_esp() {
  mkdir -p "$SB/content-$1"
  : > "$SB/content-$1/some-data-file"
}

write_mount_mock() {
  cat > "$SB/bin/mount" <<EOF
#!/bin/sh
echo "MOUNT \$*" >> "$SB/log"
for a in "\$@"; do dst=\$a; done
src=\$(echo "\$*" | grep -oE '/dev/[a-z0-9]+' | tail -1)
part=\${src##*/}
[ -d "$SB/content-\$part" ] || exit 1
mkdir -p "\$dst"
cp -a "$SB/content-\$part"/. "\$dst"/ 2>/dev/null || true
exit 0
EOF
  printf '#!/bin/sh\necho "UMOUNT \$*" >> "%s/log"\nexit 0\n' "$SB" > "$SB/bin/umount"
  chmod +x "$SB/bin/mount" "$SB/bin/umount"
}

run() {
  PATH="$SB/bin:$PATH" NIGHTFALL_SYSBLOCK="$SYS" NIGHTFALL_DEV="$DEV" \
    NIGHTFALL_ESP_PROBE="$SB/probe" sh "$S" "${1:-/dev/mmcblk0p2}"
}

echo "=== finds a drive carrying the UEFI removable-media loader ==="
setup
add_disk sda 119999120 sda1 sda2
esp_with_loader sda1
non_esp sda2
write_mount_mock
out=$(run)
echo "$out" | grep -q "^/dev/sda1	" && ok "reports the partition that actually has the loader" || bad "not found: $out"
echo "$out" | grep -qF '\EFI\BOOT\BOOTX64.EFI' && ok "and which loader path it is" || bad "loader field wrong: $out"
grep -qE '^MOUNT -t vfat -o ro ' "$SB/log" \
  && ok "mounts explicitly as vfat, never letting the kernel pick a type" \
  || bad "mount call did not pin -t vfat (an ESP is always FAT; anything else risks probing an external disk's real ext4 root - and replaying its journal despite -o ro): $(grep MOUNT "$SB/log")"
echo "$out" | grep -qE '\b57G\b' && ok "sizes the WHOLE DISK, not the small ESP" || bad "wrong size: $out"
teardown

echo "=== ignores a drive with no removable-media loader anywhere on it ==="
setup
add_disk sdb 2000000 sdb1
non_esp sdb1
write_mount_mock
out=$(run)
[ -z "$out" ] && ok "reports nothing" || bad "found a loader that is not there: $out"
teardown

echo "=== the root disk is never offered, even if it looks bootable ==="
setup
add_disk mmcblk0 240000000 mmcblk0p1 mmcblk0p2
esp_with_loader mmcblk0p1
write_mount_mock
out=$(run "/dev/mmcblk0p2")
[ -z "$out" ] && ok "excludes the whole disk this machine boots from" || bad "offered to boot from its own disk: $out"
teardown

echo "=== a partition that will not mount is skipped, not fatal ==="
setup
add_disk sdc 2000000 sdc1
# No content dir at all -> the mount mock's own guard refuses it.
write_mount_mock
out=$(run)
[ -z "$out" ] && ok "an unmountable partition is silently skipped" || bad "should have found nothing: $out"
teardown

echo "=== only the first bootable partition on a disk is reported ==="
setup
add_disk sdd 2000000 sdd1 sdd2
esp_with_loader sdd1
esp_with_loader sdd2
write_mount_mock
out=$(run)
n=$(echo "$out" | grep -c .)
[ "$n" = 1 ] && ok "one row per disk, not one per bootable partition" || bad "reported $n rows for one disk"
teardown

echo "=== case: the 32-bit fallback loader is recognised too ==="
setup
add_disk sde 2000000 sde1
mkdir -p "$SB/content-sde1/EFI/BOOT"; : > "$SB/content-sde1/EFI/BOOT/BOOTIA32.EFI"
write_mount_mock
out=$(run)
echo "$out" | grep -q 'BOOTIA32.EFI' && ok "falls back to the 32-bit loader path" || bad "missed BOOTIA32.EFI: $out"
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

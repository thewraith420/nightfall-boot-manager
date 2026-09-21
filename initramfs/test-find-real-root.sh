#!/bin/bash
# find-real-root.sh against a fake /sys/block - same shape as
# test-discover-bootable-drives.sh, mounting mocked content instead of
# real block devices.
set -u
S=$(cd "$(dirname "$0")" && pwd)/find-real-root.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

setup() {
  SB=$(mktemp -d)
  SYS=$SB/sys-block
  DEV=$SB/dev
  mkdir -p "$SYS" "$DEV" "$SB/bin"
}
teardown() { rm -rf "$SB"; }

add_disk() {
  d=$1; shift
  mkdir -p "$SYS/$d"
  for p in "$@"; do
    mkdir -p "$SYS/$d/$p"
    : > "$DEV/$p"
  done
}

# $1 = partition name, $2 = build-id to plant at boot/nightfall/build-id
# (omitted entirely if $2 is not given, modelling a drive with no
# Nightfall install at all).
content_with_id() {
  mkdir -p "$SB/content-$1/boot/nightfall"
  [ $# -ge 2 ] && printf '%s' "$2" > "$SB/content-$1/boot/nightfall/build-id"
}
plain_content() {
  mkdir -p "$SB/content-$1"
  : > "$SB/content-$1/some-file"
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
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/umount"
  chmod +x "$SB/bin/mount" "$SB/bin/umount"
}

run() {
  PATH="$SB/bin:$PATH" NIGHTFALL_SYSBLOCK="$SYS" NIGHTFALL_DEV="$DEV" \
    NIGHTFALL_ROOT_PROBE="$SB/probe" sh "$S" "${1:-BUILD-ABC}"
}

echo "=== finds the partition whose build-id matches ==="
setup
add_disk sda sda1 sda2
plain_content sda1
content_with_id sda2 BUILD-ABC
write_mount_mock
out=$(run BUILD-ABC); rc=$?
[ "$rc" = 0 ] && ok "exits 0" || bad "exit $rc"
[ "$out" = "/dev/sda2" ] && ok "reports the matching partition" || bad "wrong device: $out"
grep -qE '^MOUNT -t ext4 -o ro,noload ' "$SB/log" \
  && ok "tries ext4 with noload first, not a bare -o ro (a dirty journal would still get replayed - a write - under plain ro)" \
  || bad "did not try ext4,noload: $(grep MOUNT "$SB/log")"
teardown

echo "=== a different build-id on the disk does not count as a match ==="
setup
add_disk sda sda1
content_with_id sda1 SOME-OTHER-BUILD
write_mount_mock
out=$(run BUILD-ABC); rc=$?
[ "$rc" != 0 ] && ok "exits non-zero" || bad "should not have matched: $out"
[ -z "$out" ] && ok "reports nothing" || bad "reported: $out"
teardown

echo "=== a drive with no Nightfall install at all is skipped, not fatal ==="
setup
add_disk sdb sdb1
plain_content sdb1
write_mount_mock
out=$(run BUILD-ABC); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && ok "no match, no crash" || bad "unexpected: rc=$rc out=$out"
teardown

echo "=== a partition that will not mount is skipped, not fatal ==="
setup
add_disk sdc sdc1
# no content dir at all -> the mount mock's own guard refuses it
write_mount_mock
out=$(run BUILD-ABC); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && ok "an unmountable partition does not stop the search" || bad "unexpected: rc=$rc out=$out"
teardown

echo "=== the real install can be on ANY disk, not just the first one walked ==="
setup
add_disk sda sda1
add_disk sdb sdb1
plain_content sda1
content_with_id sdb1 BUILD-ABC
write_mount_mock
out=$(run BUILD-ABC)
[ "$out" = "/dev/sdb1" ] && ok "finds it even when it's on a later disk" || bad "wrong device: $out"
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

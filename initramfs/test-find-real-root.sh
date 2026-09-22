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

# A fake block device carrying just enough of a superblock to be recognised.
# $1 = ext4|xfs|btrfs|f2fs|other  $2 = partition name (in $DEV)
mkimg() {
  local f="$DEV/$2"; : > "$f"
  case "$1" in
    ext4)  printf '\x53\xef'   | dd of="$f" bs=1 seek=1080  conv=notrunc 2>/dev/null ;;
    xfs)   printf 'XFSB'        | dd of="$f" bs=1 seek=0     conv=notrunc 2>/dev/null ;;
    btrfs) printf '_BHRfS_M'    | dd of="$f" bs=1 seek=65600 conv=notrunc 2>/dev/null ;;
    f2fs)  printf '\x10\x20\xf5\xf2' | dd of="$f" bs=1 seek=1024 conv=notrunc 2>/dev/null ;;
    other) printf 'NOT-A-LINUX-FS!!' | dd of="$f" bs=1 seek=0 conv=notrunc 2>/dev/null ;;
  esac
}
# A partition that IS /boot: the marker sits at the top level, no boot/ dir.
content_bootfs() {
  mkdir -p "$SB/content-$1/nightfall"
  printf '%s' "$2" > "$SB/content-$1/nightfall/build-id"
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
[ "$out" = "/dev/sda2 rootfs" ] && ok "reports the matching partition and that it is the real root" || bad "wrong device: $out"
grep -qE '^MOUNT -t ext4 -o ro,noload ' "$SB/log" \
  && ok "mounts as ext4 with noload, never a bare -o ro (a dirty journal would still get replayed - a write - under plain ro)" \
  || bad "did not mount with -t ext4 -o ro,noload: $(grep MOUNT "$SB/log")"
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

echo "=== an ext4 partition that rejects noload is skipped, NEVER retried unprotected ==="
# Models a real ext4 partition that, for whatever reason (an incompatible
# feature flag, say), refuses the noload mount specifically - content_with_id
# would make a BARE mount succeed, proving this only fails because noload
# was rejected, not because the partition is unreadable outright.
setup
add_disk sdd sdd1
content_with_id sdd1 BUILD-ABC
cat > "$SB/bin/mount" <<EOF
#!/bin/sh
echo "MOUNT \$*" >> "$SB/log"
case "\$*" in *noload*) exit 1 ;; esac
for a in "\$@"; do dst=\$a; done
mkdir -p "\$dst"
cp -a "$SB/content-sdd1"/. "\$dst"/ 2>/dev/null || true
exit 0
EOF
chmod +x "$SB/bin/mount"
out=$(run BUILD-ABC); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && ok "the partition is skipped rather than matched" || bad "should not have matched: rc=$rc out=$out"
grep -qE '^MOUNT -o ro /' "$SB/log" \
  && bad "retried with a bare, unprotected mount after noload was rejected" \
  || ok "never falls back to an unprotected mount for a partition noload rejected"
teardown

echo "=== the real install can be on ANY disk, not just the first one walked ==="
setup
add_disk sda sda1
add_disk sdb sdb1
plain_content sda1
content_with_id sdb1 BUILD-ABC
write_mount_mock
out=$(run BUILD-ABC)
[ "$out" = "/dev/sdb1 rootfs" ] && ok "finds it even when it's on a later disk" || bad "wrong device: $out"
teardown

echo "=== each filesystem gets ITS OWN option that stops journal/log replay ==="
for spec in "ext4:ro,noload" "xfs:ro,norecovery" "btrfs:ro,rescue=nologreplay" "f2fs:ro,norecovery"; do
  fs=${spec%%:*}; opts=${spec#*:}
  setup
  add_disk sda sda1
  mkimg "$fs" sda1
  content_with_id sda1 BUILD-ABC
  write_mount_mock
  out=$(run BUILD-ABC)
  [ "$out" = "/dev/sda1 rootfs" ] && ok "$fs is recognised from its superblock and found" || bad "$fs not found: [$out]"
  grep -q "^MOUNT -t $fs -o $opts " "$SB/log" && ok "$fs is mounted -t $fs -o $opts" || bad "$fs mounted wrongly: $(grep MOUNT "$SB/log")"
  grep -qE '^MOUNT -o ro ' "$SB/log" && bad "$fs: a plain type-agnostic mount happened" || ok "$fs: never a plain -o ro"
  teardown
done

echo "=== an unrecognised filesystem is never mounted at all ==="
setup
add_disk sda sda1
mkimg other sda1
content_with_id sda1 BUILD-ABC
write_mount_mock
out=$(run BUILD-ABC); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && ok "a vfat/swap/ntfs/anything-else partition is skipped" || bad "matched something unrecognised: rc=$rc out=$out"
[ -s "$SB/log" ] && bad "it was MOUNTED anyway: $(cat "$SB/log")" || ok "and it was never mounted - sniffed, not tried"
teardown

echo "=== an unreadable/empty device keeps the historical ext4 attempt ==="
setup
add_disk sda sda1
: > "$DEV/sda1"
content_with_id sda1 BUILD-ABC
write_mount_mock
out=$(run BUILD-ABC)
[ "$out" = "/dev/sda1 rootfs" ] && grep -q "^MOUNT -t ext4 -o ro,noload " "$SB/log" \
  && ok "when nothing can be sniffed it still tries ext4,noload - the Slate is never left behind by a misbehaving od" || bad "legacy fallback lost: [$out] $(cat "$SB/log")"
teardown

echo "=== a separate /boot partition is found, and reported as such ==="
setup
add_disk sda sda1 sda2
mkimg ext4 sda1; mkimg ext4 sda2
plain_content sda1
content_bootfs sda2 BUILD-ABC
write_mount_mock
out=$(run BUILD-ABC)
[ "$out" = "/dev/sda2 bootfs" ] && ok "the partition whose marker is at the top level is the /boot partition" || bad "bootfs not found: [$out]"
teardown

echo "=== the real root wins when both layouts exist on one partition ==="
setup
add_disk sda sda1
mkimg ext4 sda1
mkdir -p "$SB/content-sda1/boot/nightfall" "$SB/content-sda1/nightfall"
printf 'BUILD-ABC' > "$SB/content-sda1/boot/nightfall/build-id"
printf 'BUILD-ABC' > "$SB/content-sda1/nightfall/build-id"
write_mount_mock
out=$(run BUILD-ABC)
[ "$out" = "/dev/sda1 rootfs" ] && ok "boot/nightfall is checked first" || bad "wrong layout: [$out]"
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

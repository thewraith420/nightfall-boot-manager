#!/bin/bash
# discover-live-isos.sh against a fake target drive.
#
# Cheap and lenient by design, like every other discover-*.sh here: an
# unmountable drive is an empty list, never a failure, because the whole
# point is this runs on Rescan and must never be the reason the menu
# breaks.
set -u
S=$(cd "$(dirname "$0")" && pwd)/discover-live-isos.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

setup() {
  SB=$(mktemp -d)
  D=$SB/drive
  mkdir -p "$D" "$SB/bin"
  cat > "$SB/bin/mount" <<EOF
#!/bin/sh
echo "MOUNT \$*" >> "$SB/log"
[ -n "\${MOUNT_FAIL:-}" ] && exit 1
mkdir -p "\$4"
# Bind, not mount: this is a test, no privilege to actually mount.
cp -a "$D"/. "\$4"/ 2>/dev/null || true
exit 0
EOF
  printf '#!/bin/sh\necho "UMOUNT \$*" >> "%s/log"\nexit 0\n' "$SB" > "$SB/bin/umount"
  chmod +x "$SB"/bin/*
  : > "$SB/log"
}
teardown() { rm -rf "$SB"; }
run() { PATH="$SB/bin:$PATH" NIGHTFALL_LIVE_ISO_PROBE="$SB/probe" sh "$S" "/dev/fake1" 2>"$SB/err"; }
log() { cat "$SB/log"; }

echo "=== finds an ISO at the root of the drive ==="
setup
: > "$D/ubuntu-24.04-desktop-amd64.iso"
# Real size, since discover-live-isos.sh sizes what it finds. Sparse,
# so this costs no real disk space - only the apparent length matters
# to `ls -l`, which is what the script reads.
truncate -s 5368709120 "$D/ubuntu-24.04-desktop-amd64.iso"
out=$(run)
echo "$out" | grep -q "^ubuntu-24.04-desktop-amd64.iso	" && ok "lists it by its path relative to the drive root" || bad "not found: $out"
echo "$out" | grep -qE "	ubuntu-24.04-desktop-amd64.iso\$" && ok "and reports its bare name too" || bad "no name field: $out"
echo "$out" | grep -qE "	5\.0G	" && ok "sizes it in a human unit" || bad "wrong size: $out"
teardown

echo "=== finds an ISO one directory down ==="
setup
mkdir -p "$D/isos"
truncate -s 1000000 "$D/isos/debian-live-13.iso" 2>/dev/null || : > "$D/isos/debian-live-13.iso"
out=$(run)
echo "$out" | grep -q "^isos/debian-live-13.iso	" && ok "one level of subdirectory is searched" || bad "not found: $out"
teardown

echo "=== does not look two directories down ==="
setup
mkdir -p "$D/a/b"
: > "$D/a/b/buried.iso"
out=$(run)
echo "$out" | grep -q "buried" && bad "found an ISO two levels deep - out of the documented scope" || ok "two levels deep is correctly out of scope"
teardown

echo "=== ignores non-ISO files ==="
setup
: > "$D/readme.txt"
: > "$D/backup.tar"
out=$(run)
[ -z "$out" ] && ok "an empty drive (of ISOs) reports nothing" || bad "listed something that is not an ISO: $out"
teardown

echo "=== an unmountable drive is an empty list, not a failure ==="
setup
MOUNT_FAIL=1
export MOUNT_FAIL
rc=0; out=$(run) || rc=$?
[ "$rc" = 0 ] && ok "exits 0 even though the mount failed" || bad "exited $rc - this must never break the menu"
[ -z "$out" ] && ok "and the list is simply empty" || bad "produced output from a drive that never mounted: $out"
unset MOUNT_FAIL
teardown

echo "=== always unmounts what it mounted ==="
setup
: > "$D/x.iso"
run >/dev/null
log | grep -q "^UMOUNT" && ok "unmounts the probe after reading it" || bad "left the drive mounted"
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

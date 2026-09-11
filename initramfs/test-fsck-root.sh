#!/bin/bash
# fsck-root.sh against mocked mount/umount/e2fsck.
#
# The check itself is e2fsck's problem. What this script has to get right
# is everything around it:
#   - check the device that is REALLY mounted, not a default
#   - unmount before checking, because that is the whole point
#   - REMOUNT afterwards, always, because init kexecs a kernel it reads
#     from <root>/boot and an unmounted root means no boot at all
#   - read e2fsck's exit status as the bitmask it is, so a successful
#     repair is not reported as a failure
set -u
S=$(cd "$(dirname "$0")" && pwd)/fsck-root.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# $1 = e2fsck exit code, $2 = extra lines for the fake /proc/mounts
setup() {
  SB=$(mktemp -d)
  mkdir -p "$SB/root" "$SB/bin"
  printf '/dev/FAKEROOT %s ext4 ro 0 0\n' "$SB/root" > "$SB/mounts"
  [ -n "${2:-}" ] && printf '%s\n' "$2" >> "$SB/mounts"
  cat > "$SB/bin/mount" <<EOF
#!/bin/sh
echo "MOUNT \$*" >> "$SB/log"
exit \${MOUNT_RC:-0}
EOF
  cat > "$SB/bin/umount" <<EOF
#!/bin/sh
echo "UMOUNT \$*" >> "$SB/log"
exit 0
EOF
  cat > "$SB/bin/e2fsck" <<EOF
#!/bin/sh
echo "E2FSCK \$*" >> "$SB/log"
exit $1
EOF
  chmod +x "$SB"/bin/*
  : > "$SB/log"
}
teardown() { rm -rf "$SB"; }
run()  { PATH="$SB/bin:$PATH" NIGHTFALL_MOUNTS="$SB/mounts" NIGHTFALL_FSCK="$SB/bin/e2fsck" \
           sh "$S" "$SB/root" "${1:-preen}" >"$SB/out" 2>&1; echo $?; }
out()  { cat "$SB/out"; }
log()  { cat "$SB/log"; }

echo "=== checks the device that is really mounted ==="
setup 0
rc=$(run)
[ "$rc" = 0 ] && ok "clean filesystem reports success" || bad "failed on a clean fs: $(out | tail -2)"
log | grep -q "E2FSCK.*/dev/FAKEROOT" && ok "checks the device from /proc/mounts" || bad "checked the wrong device: $(log | grep E2FSCK)"
out | grep -q "root filesystem is /dev/FAKEROOT" && ok "says which device it is checking" || bad "silent about the device"
teardown

echo "=== unmounts before checking, remounts after ==="
setup 0
rc=$(run)
u=$(log | grep -n "UMOUNT" | head -1 | cut -d: -f1)
f=$(log | grep -n "E2FSCK" | head -1 | cut -d: -f1)
# ^-anchored: "MOUNT " also matches inside "UMOUNT ", which made this
# read the unmount as the remount and report a remount that had in
# fact happened as missing.
m=$(log | grep -n "^MOUNT " | head -1 | cut -d: -f1)
[ -n "$u" ] && [ -n "$f" ] && [ "$u" -lt "$f" ] \
  && ok "unmounts BEFORE running the check (the whole point)" || bad "checked a mounted filesystem"
[ -n "$m" ] && [ "$m" -gt "$f" ] && ok "remounts AFTER the check" || bad "never remounted the root"
log | grep -q "^MOUNT -o ro /dev/FAKEROOT" && ok "remounts read-only, as it was" || bad "remounted rw: $(log | grep '^MOUNT ')"
teardown

echo "=== ALWAYS remounts, even when the check fails ==="
# If this ever stops being true, a repair attempt turns into a machine
# that cannot boot: init reads the kernel it kexecs from <root>/boot.
for code in 4 8 16; do
  setup "$code"
  rc=$(run)
  log | grep -q "^MOUNT .*/dev/FAKEROOT" \
    && ok "remounts after e2fsck exits $code" || bad "left the root UNMOUNTED after exit $code"
  teardown
done

echo "=== e2fsck's exit status is a bitmask, not a boolean ==="
# 0 clean, 1 corrected, 2 corrected+reboot. Reporting a successful
# repair as a failure is how someone ends up reinstalling a machine that
# had just fixed itself.
for code in 0 1 2 3; do
  setup "$code"
  rc=$(run)
  [ "$rc" = 0 ] && ok "exit $code counts as success" || bad "exit $code reported as failure"
  teardown
done
for code in 4 8; do
  setup "$code"
  rc=$(run)
  [ "$rc" != 0 ] && ok "exit $code counts as failure" || bad "exit $code reported as success"
  teardown
done
setup 1
rc=$(run); out | grep -q "CORRECTED" && ok "says plainly that errors were corrected" || bad "unclear on a repair"
teardown
setup 4
rc=$(run); out | grep -q "NOT fixed" && ok "says plainly when errors remain" || bad "unclear on an unfixed fs"
out | grep -q "Full repair" && ok "points at the action that can fix it" || bad "no next step offered"
teardown

echo "=== the two modes differ in exactly the way that matters ==="
setup 0
rc=$(run preen)
log | grep -q "E2FSCK.*-p" && ok "preen uses -p (no decisions taken for you)" || bad "preen did not use -p"
log | grep -q "E2FSCK.*-y" && bad "preen used -y" || ok "preen does NOT use -y"
teardown
setup 0
rc=$(run force)
log | grep -q "E2FSCK.*-y" && ok "force uses -y (answers yes on your behalf)" || bad "force did not use -y"
out | grep -q "FULL repair" && ok "says out loud that it is the destructive one" || bad "no warning on force"
teardown

echo "=== nested mounts are cleared first ==="
# An interrupted backup or restore leaves <root>/mnt behind, and the
# unmount of the root fails while it is there.
setup 0 "/dev/sda1 $(mktemp -u)/placeholder vfat ro 0 0"
SB2=$SB
setup 0
printf '/dev/sda1 %s/root/mnt exfat ro 0 0\n' "$SB" >> "$SB/mounts"
rc=$(run)
log | grep -q "UMOUNT.*root/mnt" && ok "unmounts what is nested under the root" || bad "left a nested mount in place"
n=$(log | grep -n "UMOUNT.*root/mnt" | head -1 | cut -d: -f1)
r=$(log | grep -nE "UMOUNT $SB/root\$" | head -1 | cut -d: -f1)
[ -n "$n" ] && [ -n "$r" ] && [ "$n" -lt "$r" ] \
  && ok "and does so BEFORE unmounting the root itself" || bad "wrong unmount order"
teardown; SB=$SB2; teardown

echo "=== refuses rather than guessing ==="
setup 0
: > "$SB/mounts"          # nothing mounted at $root
rc=$(run)
[ "$rc" != 0 ] && ok "refuses when it cannot tell which device to check" || bad "checked something anyway"
log | grep -q "E2FSCK" && bad "ran e2fsck on an unknown device" || ok "ran nothing"
teardown

setup 0
rc=$(run sideways)
[ "$rc" != 0 ] && ok "refuses an unknown mode" || bad "accepted a bogus mode"
log | grep -q "E2FSCK" && bad "ran e2fsck anyway" || ok "ran nothing"
teardown

echo "=== a failed remount is shouted about, not swallowed ==="
setup 0
cat > "$SB/bin/mount" <<EOF
#!/bin/sh
echo "MOUNT \$*" >> "$SB/log"
exit 1
EOF
chmod +x "$SB/bin/mount"
rc=$(run)
out | grep -q "COULD NOT REMOUNT" && ok "says the root is not back" || bad "silent about a failed remount"
out | grep -q "Do NOT power off" && ok "tells the user what to do about it" || bad "no guidance"
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

#!/bin/bash
# boot-live-iso.sh against a fake drive and a fake mounted ISO.
#
# The interesting property is ORDER, same as everywhere else destructive
# in this project - except here "destructive" means "about to replace
# the running kernel", so the thing to prove is that kexec -l happens
# while the files it reads are still mounted, and everything is torn
# down before kexec -e, which is the actual point of no return.
set -u
S=$(cd "$(dirname "$0")" && pwd)/boot-live-iso.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# $1 = "casper" | "live" | "none" | "both"  -> which live layout the
# mocked ISO mount presents.
setup() {
  SB=$(mktemp -d)
  DRIVE=$SB/drive-contents
  mkdir -p "$DRIVE" "$SB/bin"
  : > "$SB/target"

  case "${1:-casper}" in
    casper) mkdir -p "$DRIVE/casper"
            : > "$DRIVE/casper/vmlinuz"; : > "$DRIVE/casper/initrd" ;;
    casper-lz) mkdir -p "$DRIVE/casper"
            : > "$DRIVE/casper/vmlinuz"; : > "$DRIVE/casper/initrd.lz" ;;
    live)   mkdir -p "$DRIVE/live"
            : > "$DRIVE/live/vmlinuz"; : > "$DRIVE/live/initrd.img" ;;
    both)   mkdir -p "$DRIVE/casper" "$DRIVE/live"
            : > "$DRIVE/casper/vmlinuz"; : > "$DRIVE/casper/initrd"
            : > "$DRIVE/live/vmlinuz"; : > "$DRIVE/live/initrd.img" ;;
    none)   : > "$DRIVE/some-data-file" ;;
  esac

  cat > "$SB/bin/mount" <<EOF
#!/bin/sh
echo "MOUNT \$*" >> "$SB/log"
# The destination is always the LAST argument, regardless of which flags
# came before it - safer than guessing a fixed position for two calls
# with different argument counts (-o ro dev dst vs -t iso9660 -o ro dev dst).
for dst in "\$@"; do :; done
case "\$*" in
  *iso9660*) [ -n "\${ISO_MOUNT_FAIL:-}" ] && exit 1
             mkdir -p "\$dst"; cp -a "$DRIVE"/. "\$dst"/ 2>/dev/null || true ;;
  *)         [ -n "\${TARGET_MOUNT_FAIL:-}" ] && exit 1
             mkdir -p "\$dst"
             # The "target" partition just needs to contain the ISO file
             # the test asks for, at whatever path the test used.
             mkdir -p "\$dst/isos"
             : > "\$dst/live.iso"
             : > "\$dst/isos/live.iso" ;;
esac
exit 0
EOF
  printf '#!/bin/sh\necho "UMOUNT \$*" >> "%s/log"\nexit 0\n' "$SB" > "$SB/bin/umount"
  cat > "$SB/bin/losetup" <<EOF
#!/bin/sh
echo "LOSETUP \$*" >> "$SB/log"
case "\$1" in
  -f) [ -n "\${LOSETUP_FIND_FAIL:-}" ] && exit 1
      echo "/dev/loop7"; exit 0 ;;
  -d) exit 0 ;;
  -r) [ -n "\${LOSETUP_ATTACH_FAIL:-}" ] && exit 1
      exit 0 ;;
esac
exit 0
EOF
  cat > "$SB/bin/kexec" <<EOF
#!/bin/sh
echo "KEXEC \$*" >> "$SB/log"
[ "\$1" = "-l" ] && { [ -n "\${KEXEC_L_FAIL:-}" ] && exit 1; exit 0; }
[ "\$1" = "-e" ] && exit 0
exit 0
EOF
  chmod +x "$SB"/bin/*
  : > "$SB/log"
}
teardown() { rm -rf "$SB"; }
run() {
  PATH="$SB/bin:$PATH" \
    NIGHTFALL_LIVE_TARGET_MNT="$SB/tmnt" NIGHTFALL_LIVE_ISO_MNT="$SB/imnt" \
    sh "$S" "$SB/target" "${1:-live.iso}" >"$SB/out" 2>&1
  echo $?
}
out() { cat "$SB/out"; }
log() { cat "$SB/log"; }

echo "=== boots a casper (Ubuntu) live image ==="
setup casper
rc=$(run live.iso)
[ "$rc" = 0 ] && ok "succeeds" || bad "failed: $(out | tail -4)"
log | grep -qE "KEXEC -l .*casper/vmlinuz.*--initrd=.*casper/initrd.*--command-line=" \
  && ok "kexec -l gets the casper vmlinuz and initrd" || bad "wrong kexec -l call: $(log | grep 'KEXEC -l')"
log | grep -q "boot=casper iso-scan/filename=/live.iso" \
  && ok "the cmdline tells casper's own initrd where to find the ISO" || bad "wrong cmdline: $(log | grep 'KEXEC -l')"
log | grep -q "^KEXEC -e" && ok "hands off with kexec -e" || bad "never reached kexec -e"
teardown

echo "=== boots a casper image with a compressed initrd name ==="
setup casper-lz
rc=$(run live.iso)
[ "$rc" = 0 ] && ok "succeeds with initrd.lz" || bad "failed: $(out | tail -4)"
log | grep -q "initrd.lz" && ok "found the compressed initrd variant" || bad "missed initrd.lz"
teardown

echo "=== boots a Debian live-boot image ==="
setup live
rc=$(run live.iso)
[ "$rc" = 0 ] && ok "succeeds" || bad "failed: $(out | tail -4)"
log | grep -qE "KEXEC -l .*live/vmlinuz.*--initrd=.*live/initrd.img" \
  && ok "kexec -l gets the live-boot vmlinuz and initrd" || bad "wrong kexec -l call: $(log | grep 'KEXEC -l')"
log | grep -q "boot=live findiso=/live.iso" \
  && ok "the cmdline tells live-boot's own initrd where to find the ISO" || bad "wrong cmdline"
teardown

echo "=== casper is preferred when both layouts are present ==="
setup both
run live.iso >/dev/null
log | grep -q "boot=casper" && ok "picks casper first" || bad "did not prefer casper"
teardown

echo "=== a path one directory down still works ==="
setup casper
rc=$(run isos/live.iso)
[ "$rc" = 0 ] && ok "succeeds" || bad "failed: $(out | tail -4)"
log | grep -q "iso-scan/filename=/isos/live.iso" && ok "the cmdline keeps the subdirectory" || bad "lost the subdirectory: $(log | grep KEXEC)"
teardown

echo "=== refuses an unsupported ISO, and cleans up rather than booting garbage ==="
setup none
rc=$(run live.iso)
[ "$rc" != 0 ] && ok "refuses" || bad "booted an ISO with no recognised live layout"
out | grep -qi "does not look like a supported live image" && ok "says why" || bad "unclear: $(out | tail -2)"
log | grep -q "^KEXEC" && bad "called kexec anyway" || ok "never touched kexec"
log | grep -q "^LOSETUP -d" && ok "still detaches the loop device" || bad "left the loop device attached"
log | grep -q "^UMOUNT" && ok "still unmounts" || bad "left things mounted"
teardown

echo "=== everything stays read-only ==="
setup casper
run live.iso >/dev/null
log | grep -qE "^MOUNT -o ro .*target" && ok "the target partition is mounted read-only" || bad "target not mounted ro: $(log | grep 'MOUNT.*target')"
log | grep -q "^LOSETUP -r " && ok "the loop device is attached read-only" || bad "loop device not read-only"
log | grep -qE "^MOUNT -t iso9660 -o ro" && ok "the ISO itself is mounted read-only" || bad "ISO not mounted ro"
teardown

echo "=== kexec -l happens BEFORE anything is unmounted ==="
# The one ordering that actually matters: kexec -l must read the vmlinuz
# and initrd while the loop mount is still up. Unmounting first would
# have it stage nothing, or stage stale/wrong data.
setup casper
run live.iso >/dev/null
l=$(log | grep -n "^KEXEC -l" | head -1 | cut -d: -f1)
u=$(log | grep -n "^UMOUNT" | head -1 | cut -d: -f1)
[ -n "$l" ] && [ -n "$u" ] && [ "$l" -lt "$u" ] \
  && ok "kexec -l runs before the first unmount" || bad "unmounted before staging the kernel"
teardown

echo "=== everything is torn down BEFORE kexec -e, the actual point of no return ==="
setup casper
run live.iso >/dev/null
e=$(log | grep -n "^KEXEC -e" | head -1 | cut -d: -f1)
lastumount=$(log | grep -n "^UMOUNT" | tail -1 | cut -d: -f1)
lastloop=$(log | grep -n "^LOSETUP -d" | tail -1 | cut -d: -f1)
[ -n "$e" ] && [ -n "$lastumount" ] && [ "$lastumount" -lt "$e" ] \
  && ok "the ISO and target are unmounted before the handoff" || bad "still mounted at kexec -e"
[ -n "$e" ] && [ -n "$lastloop" ] && [ "$lastloop" -lt "$e" ] \
  && ok "the loop device is detached before the handoff" || bad "loop device still attached at kexec -e"
teardown

echo "=== refuses a path-shaped selector, even though the UI only offers real names ==="
setup casper
rc=$(run "../../../etc/passwd")
[ "$rc" != 0 ] && ok "refuses a traversal attempt" || bad "accepted a path with .. components"
log | grep -q "^KEXEC" && bad "called kexec anyway" || ok "never touched kexec"
teardown

setup casper
rc=$(run "/etc/passwd")
[ "$rc" != 0 ] && ok "refuses an absolute path" || bad "accepted an absolute path"
teardown

echo "=== refuses cleanly when a step fails, and changes nothing ==="
setup casper
TARGET_MOUNT_FAIL=1
export TARGET_MOUNT_FAIL
rc=$(run live.iso)
[ "$rc" != 0 ] && ok "refuses when the target will not mount" || bad "proceeded without the target"
log | grep -q "^KEXEC" && bad "called kexec anyway" || ok "never touched kexec"
unset TARGET_MOUNT_FAIL
teardown

setup casper
rc=$(run does-not-exist.iso)
[ "$rc" != 0 ] && ok "refuses when the named ISO is not on the drive" || bad "proceeded with a missing file"
teardown

setup casper
LOSETUP_FIND_FAIL=1
export LOSETUP_FIND_FAIL
rc=$(run live.iso)
[ "$rc" != 0 ] && ok "refuses when no loop device is free" || bad "proceeded with no loop device"
log | grep -q "^KEXEC" && bad "called kexec anyway" || ok "never touched kexec"
log | grep -q "^UMOUNT" && ok "still unmounts the target" || bad "left the target mounted"
unset LOSETUP_FIND_FAIL
teardown

setup casper
ISO_MOUNT_FAIL=1
export ISO_MOUNT_FAIL
rc=$(run live.iso)
[ "$rc" != 0 ] && ok "refuses when the ISO will not mount as iso9660" || bad "proceeded on a mount failure"
log | grep -q "^KEXEC" && bad "called kexec anyway" || ok "never touched kexec"
log | grep -q "^LOSETUP -d" && ok "still detaches the loop device" || bad "left the loop device attached"
unset ISO_MOUNT_FAIL
teardown

setup casper
KEXEC_L_FAIL=1
export KEXEC_L_FAIL
rc=$(run live.iso)
[ "$rc" != 0 ] && ok "refuses when kexec -l itself fails" || bad "reported success when staging failed"
out | grep -qi "nothing was booted" && ok "says the machine is unchanged" || bad "unclear about what happened"
log | grep -q "^KEXEC -e" && bad "reached kexec -e after a failed -l" || ok "never reached the actual handoff"
unset KEXEC_L_FAIL
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

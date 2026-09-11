#!/bin/bash
# repair-system.sh and clear-overrides.sh against a fake root.
#
# These run inside the installed system, so what matters is that they use
# the TARGET's tools by absolute path, prove what can be proved before
# doing anything irreversible, and always put the root back read-only.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
R=$HERE/repair-system.sh
C=$HERE/clear-overrides.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# $1 = grub-probe rc
setup() {
  SB=$(mktemp -d)
  mkdir -p "$SB/root/proc" "$SB/root/sys" "$SB/root/dev/pts" "$SB/root/boot" \
           "$SB/root/usr/bin" "$SB/root/usr/sbin" "$SB/bin"
  for f in usr/bin/dpkg usr/bin/apt-get usr/bin/journalctl usr/sbin/grub-probe usr/sbin/update-grub; do
    : > "$SB/root/$f"; chmod +x "$SB/root/$f"
  done
  cat > "$SB/bin/mount" <<EOF
#!/bin/sh
echo "MOUNT \$*" >> "$SB/log"
exit 0
EOF
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/umount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/sync"
  cat > "$SB/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted"
echo "d 1 1000000 1 1% /"
EOF
  cat > "$SB/bin/chroot" <<EOF
#!/bin/sh
echo "CHROOT \$*" >> "$SB/log"
case "\$*" in *grub-probe*) exit ${1:-0} ;; esac
exit 0
EOF
  chmod +x "$SB"/bin/*
  : > "$SB/log"
}
teardown() { rm -rf "$SB"; }
runr() { PATH="$SB/bin:$PATH" sh "$R" "$SB/root" "$1" >"$SB/out" 2>&1; echo $?; }
runc() { PATH="$SB/bin:$PATH" sh "$C" "$SB/root" "${1:-all}" >"$SB/out" 2>&1; echo $?; }
out()  { cat "$SB/out"; }
log()  { cat "$SB/log"; }

echo "=== repair: packages ==="
setup 0
rc=$(runr dpkg)
[ "$rc" = 0 ] && ok "succeeds" || bad "failed: $(out | tail -2)"
log | grep -q "CHROOT.*/usr/bin/dpkg --configure -a" \
  && ok "runs the target's dpkg by ABSOLUTE path" || bad "bare or wrong dpkg: $(log | grep dpkg)"
log | grep -q "CHROOT.*apt-get.*--no-download" \
  && ok "fixes dependencies offline, not waiting on a network we do not have" || bad "no offline apt fix"
teardown

echo "=== repair: free space ==="
setup 0
rc=$(runr clean)
[ "$rc" = 0 ] && ok "succeeds" || bad "failed: $(out | tail -2)"
log | grep -q "CHROOT.*/usr/bin/apt-get clean" && ok "empties the package cache" || bad "no apt clean"
log | grep -q "CHROOT.*journalctl --vacuum-size" && ok "trims the journal" || bad "no journal trim"
# autoremove would happily delete kernels. Not a thing to do unattended
# from a repair menu on a machine that is already in trouble.
log | grep -q "autoremove" && bad "ran autoremove - that can remove kernels" || ok "does NOT autoremove"
teardown

echo "=== repair: boot menu ==="
setup 0
rc=$(runr grub)
[ "$rc" = 0 ] && ok "succeeds" || bad "failed: $(out | tail -2)"
p=$(log | grep -n "grub-probe" | head -1 | cut -d: -f1)
u=$(log | grep -n "update-grub" | head -1 | cut -d: -f1)
[ -n "$p" ] && [ -n "$u" ] && [ "$p" -lt "$u" ] \
  && ok "proves grub-probe can resolve the disk BEFORE regenerating" || bad "wrong order"
teardown

setup 1     # grub-probe fails
rc=$(runr grub)
[ "$rc" != 0 ] && ok "refuses when grub-probe cannot resolve the disk" || bad "regenerated anyway"
log | grep -q "update-grub" && bad "ran update-grub after a failed probe" || ok "did not touch the menu"
teardown

echo "=== repair: always puts the root back read-only ==="
for a in dpkg clean grub; do
  setup 0
  rc=$(runr "$a")
  log | grep -q "MOUNT -o remount,rw" && ok "$a: remounts rw to work" || bad "$a: never went rw"
  log | grep -q "MOUNT -o remount,ro" && ok "$a: remounts ro afterwards" || bad "$a: LEFT THE ROOT WRITABLE"
  teardown
done

setup 0
rc=$(runr sideways)
[ "$rc" != 0 ] && ok "refuses an unknown repair" || bad "accepted a bogus action"
log | grep -q "CHROOT" && bad "ran something anyway" || ok "ran nothing"
teardown

echo "=== clear: Nightfall's own saved settings ==="
setup 0
echo "/boot/vmlinuz-x" > "$SB/root/boot/nightfall-default"
printf '/boot/vmlinuz-x\tro quiet broken=1\n' > "$SB/root/boot/nightfall-cmdline"
rc=$(runc all)
[ "$rc" = 0 ] && ok "succeeds" || bad "failed: $(out | tail -2)"
[ ! -f "$SB/root/boot/nightfall-default" ] && ok "clears the saved default" || bad "default still there"
[ ! -f "$SB/root/boot/nightfall-cmdline" ] && ok "clears the saved command lines" || bad "cmdline still there"
# Worth reading before it goes: if one of these is what broke the boot,
# this is the only place it is ever shown.
out | grep -q "/boot/vmlinuz-x" && ok "shows what it is throwing away" || bad "cleared silently"
log | grep -q "MOUNT -o remount,ro" && ok "puts the root back read-only" || bad "LEFT THE ROOT WRITABLE"
teardown

setup 0
echo "/boot/vmlinuz-x" > "$SB/root/boot/nightfall-default"
printf '/boot/vmlinuz-x\tro quiet\n' > "$SB/root/boot/nightfall-cmdline"
rc=$(runc default)
[ ! -f "$SB/root/boot/nightfall-default" ] && ok "'default' clears the default" || bad "did not clear it"
[ -f "$SB/root/boot/nightfall-cmdline" ] && ok "'default' leaves command lines alone" || bad "cleared too much"
teardown

setup 0
echo "/boot/vmlinuz-x" > "$SB/root/boot/nightfall-default"
printf '/boot/vmlinuz-x\tro quiet\n' > "$SB/root/boot/nightfall-cmdline"
rc=$(runc cmdline)
[ -f "$SB/root/boot/nightfall-default" ] && ok "'cmdline' leaves the default alone" || bad "cleared too much"
[ ! -f "$SB/root/boot/nightfall-cmdline" ] && ok "'cmdline' clears command lines" || bad "did not clear them"
teardown

setup 0
rc=$(runc all)
[ "$rc" = 0 ] && ok "nothing to clear is not an error" || bad "failed when there was nothing to do"
out | grep -q "nothing needed clearing" && ok "says so plainly" || bad "unclear: $(out | tail -1)"
teardown

setup 0
rc=$(runc sideways)
[ "$rc" != 0 ] && ok "refuses an unknown target" || bad "accepted a bogus target"
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

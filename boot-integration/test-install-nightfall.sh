#!/bin/bash
# install-nightfall.sh, focused on the rename migration.
#
# This is the script that edits a live boot configuration, and two of
# the things it carries over fail SILENTLY if they are missed: the saved
# default kernel and the per-kernel command lines just read as absent,
# and GRUB_DEFAULT stops resolving with no error at all. On a machine
# with no keyboard the second one means you quietly stop booting into
# Nightfall and cannot pick it from the menu.
set -u
S=$(cd "$(dirname "$0")" && pwd)/install-nightfall.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# $1 = GRUB_DEFAULT value, $2 = does update-grub set the new default?
setup() {
  SB=$(mktemp -d)
  mkdir -p "$SB/boot/grub" "$SB/boot/picker" "$SB/etc" "$SB/bin"
  : > "$SB/kernel.img"; : > "$SB/initramfs.img"
  : > "$SB/boot/picker/vmlinuz"; : > "$SB/boot/picker/initramfs.img"
  printf '%s\n' /boot/vmlinuz-7.2.3-BobZKernel-pixel-slate > "$SB/boot/picker-default"
  printf '/boot/vmlinuz-x\troot=x ro quiet\n' > "$SB/boot/picker-cmdline"
  cat > "$SB/boot/grub/custom.cfg" <<EOF
### BEGIN nocturne-boot-picker ###
menuentry 'Boot Picker (touch)' --id picker {
        linux /boot/picker/vmlinuz
}
### END nocturne-boot-picker ###
EOF
  printf 'GRUB_DEFAULT=%s\nGRUB_TIMEOUT=5\n' "$1" > "$SB/etc/grub"
  echo 'set default="picker"' > "$SB/boot/grub/grub.cfg"

  printf '#!/bin/sh\necho "Linux kernel x86 boot executable bzImage"\n' > "$SB/bin/file"
  # findmnt is asked two different questions: the UUID of /boot's
  # filesystem, and where that filesystem is mounted. Answering both with
  # a UUID (as this mock once did) means "is /boot a separate partition?"
  # is always false and that whole branch goes untested - which is exactly
  # how it kept a stale /picker/ path through the rename.
  cat > "$SB/bin/findmnt" <<EOF
#!/bin/sh
case "\$*" in
  *TARGET*) [ -n "\${BOOT_IS_SEPARATE:-}" ] && echo /boot || echo / ;;
  *)        echo 076aa633-aff9-4f0f-98a7-f939eb74e7ff ;;
esac
EOF
  # The script runs update-grub with output suppressed - it verifies the
  # RESULT rather than trusting the chatter - so the mock records that it
  # ran in a file the test can see.
  cat > "$SB/bin/update-grub" <<EOF
#!/bin/sh
: > "$SB/update-grub-ran"
[ "$2" = yes ] && echo 'set default="nightfall"' > "$SB/boot/grub/grub.cfg"
exit 0
EOF
  chmod +x "$SB"/bin/*
}
run() {
  PATH="$SB/bin:$PATH" NIGHTFALL_BOOT="$SB/boot" NIGHTFALL_GRUB_DEFAULT="$SB/etc/grub" \
    BOOT_IS_SEPARATE="${BOOT_IS_SEPARATE:-}" \
    sh "$S" "$SB/kernel.img" "$SB/initramfs.img" >"$SB/out" 2>&1
  echo $?
}
cfg() { cat "$SB/boot/grub/custom.cfg"; }

echo "=== the old entry must go, or GRUB shows two ==="
setup picker yes; rc=$(run)
[ "$rc" = 0 ] && ok "installs" || bad "failed: $(tail -3 "$SB/out")"
cfg | grep -q "nocturne-boot-picker" && bad "left the old marked block behind" || ok "old block removed"
cfg | grep -q "Boot Picker (touch)" && bad "left the old menu entry behind" || ok "old entry gone"
cfg | grep -q "menuentry 'Nightfall (touch)' --id nightfall" && ok "new entry present with the new id" || bad "no new entry"
[ "$(cfg | grep -c menuentry)" = 1 ] && ok "exactly ONE entry, not two" || bad "duplicate entries"

echo "=== saved state carries over (silent loss otherwise) ==="
grep -qx "/boot/vmlinuz-7.2.3-BobZKernel-pixel-slate" "$SB/boot/nightfall-default" 2>/dev/null \
  && ok "saved default kernel carried over intact" || bad "default lost"
grep -q "root=x ro quiet" "$SB/boot/nightfall-cmdline" 2>/dev/null \
  && ok "saved command lines carried over intact" || bad "command lines lost"
[ -e "$SB/boot/picker-default" ] && bad "left the old file behind too" || ok "old copies removed, not duplicated"

echo "=== GRUB_DEFAULT repointed to the new id ==="
grep -q "^GRUB_DEFAULT=nightfall" "$SB/etc/grub" && ok "GRUB_DEFAULT updated" || bad "still points at the old id"
[ -e "$SB/update-grub-ran" ] && ok "ran update-grub, since set default lives in the generated cfg" || bad "did not regenerate"
grep -q 'set default="nightfall"' "$SB/boot/grub/grub.cfg" && ok "and grub.cfg now resolves to Nightfall" || bad "grub.cfg still points elsewhere"
[ -e "$SB/etc/grub.nightfall-bak" ] && bad "left its backup lying around" || ok "backup cleaned up after success"

echo "=== if regeneration does NOT take, roll back rather than leave it broken ==="
setup picker no; run >/dev/null
grep -q "^GRUB_DEFAULT=picker" "$SB/etc/grub" \
  && ok "restored the original GRUB_DEFAULT" || bad "left GRUB_DEFAULT changed with no working default"
grep -q "WARNING" "$SB/out" && ok "says so loudly" || bad "silent about it"

echo "=== an existing new-style file is never clobbered ==="
setup picker yes
printf '%s\n' /boot/vmlinuz-KEEP > "$SB/boot/nightfall-default"
run >/dev/null
grep -qx "/boot/vmlinuz-KEEP" "$SB/boot/nightfall-default" \
  && ok "leaves an existing nightfall-default alone" || bad "overwrote a newer setting with the old one"

echo "=== the entry points at files that actually exist, in both /boot layouts ==="
# Paths in the entry are relative to the filesystem GRUB sees, so the two
# layouts need different strings - and a wrong one here is not a cosmetic
# bug, it is an entry that boots to "file not found".
setup 0 yes; run >/dev/null
cfg | grep -q "linux[[:space:]]*/boot/nightfall/vmlinuz" \
  && ok "shared /boot: entry uses /boot/nightfall/vmlinuz" || bad "wrong path: $(cfg | grep linux)"

setup 0 yes; BOOT_IS_SEPARATE=1 run >/dev/null
cfg | grep -q "linux[[:space:]]*/nightfall/vmlinuz" \
  && ok "separate /boot: entry drops the /boot prefix" || bad "wrong path: $(cfg | grep linux)"
cfg | grep -q "/picker/" && bad "still points into the pre-rename directory" \
  || ok "and points into the renamed directory, not the old one"

echo "=== a machine that never had the old name is unaffected ==="
setup 0 yes
rm -rf "$SB/boot/picker" "$SB/boot/picker-default" "$SB/boot/picker-cmdline"
: > "$SB/boot/grub/custom.cfg"
rc=$(run)
[ "$rc" = 0 ] && ok "installs cleanly with nothing to migrate" || bad "failed on a fresh machine"
[ -e "$SB/update-grub-ran" ] && bad "ran update-grub when it had no reason to" || ok "does not touch grub.cfg when GRUB_DEFAULT is not the old id"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

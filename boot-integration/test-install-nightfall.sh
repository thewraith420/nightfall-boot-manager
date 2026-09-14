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
unset NIGHTFALL_CMDLINE
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
  # A normal Slate boot: the display options Nightfall's entry should get.
  # Tests used to read the HOST's /proc/cmdline, so results depended on
  # which machine ran them.
  echo "BOOT_IMAGE=/boot/vmlinuz-x root=UUID=x ro quiet splash i915.enable_dpcd_backlight=2 i915.enable_psr=0" > "$SB/cmdline"
}
# RUN_CMDLINE, when set, is passed as an explicit NIGHTFALL_CMDLINE.
run() {
  local extra=()
  [ -n "${RUN_CMDLINE+x}" ] && extra=(NIGHTFALL_CMDLINE="$RUN_CMDLINE")
  env PATH="$SB/bin:$PATH" NIGHTFALL_BOOT="$SB/boot" NIGHTFALL_GRUB_DEFAULT="$SB/etc/grub" \
    NIGHTFALL_PROC_CMDLINE="$SB/cmdline" BOOT_IS_SEPARATE="${BOOT_IS_SEPARATE:-}" \
    "${extra[@]}" sh "$S" "$SB/kernel.img" "$SB/initramfs.img" >"$SB/out" 2>&1
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

echo "=== the display options come from a boot that can actually light the panel ==="
# A machine that already has Nightfall installed, with working options.
fresh_installed() {
  setup 0 yes
  rm -rf "$SB/boot/picker" "$SB/boot/picker-default" "$SB/boot/picker-cmdline"
  cat > "$SB/boot/grub/custom.cfg" <<EOF
### BEGIN nightfall-boot-manager ###
menuentry 'Nightfall (touch)' --id nightfall {
        linux   /boot/nightfall/vmlinuz i915.enable_dpcd_backlight=2 i915.enable_psr=0
}
### END nightfall-boot-manager ###
EOF
}
entry_opts() { cfg | grep -E '^[[:space:]]*linux[[:space:]]' | tr ' \t' '\n\n' | grep '^i915\.' | tr '\n' ' '; }

fresh_installed; rc=$(run)
[ "$rc" = 0 ] && ok "a normal boot installs" || bad "normal boot refused: $(tail -3 "$SB/out")"
entry_opts | grep -q "i915.enable_dpcd_backlight=2" && ok "and carries its i915 options into the entry" || bad "options lost: $(entry_opts)"

# THE case: a GRUB recovery entry, straight from docs/nocturne-grub.cfg.
fresh_installed
echo "BOOT_IMAGE=/boot/vmlinuz-x root=UUID=x ro recovery nomodeset dis_ucode_ldr" > "$SB/cmdline"
rc=$(run)
[ "$rc" != 0 ] && ok "refuses to install from a recovery boot" || bad "installed from a recovery boot"
entry_opts | grep -q "i915.enable_dpcd_backlight=2" && ok "the working entry is left exactly as it was" || bad "entry overwritten: $(entry_opts)"
[ ! -e "$SB/boot/nightfall/vmlinuz" ] && ok "refused BEFORE copying anything into /boot" || bad "copied the kernel, then refused - a half-finished install"
grep -q "sudo NIGHTFALL_CMDLINE=" "$SB/out" && ok "says how to override, with sudo in the right place" || bad "no usable override hint"

# The two cases where the word check is the ONLY thing standing in the
# way. Every other recovery fixture also has no i915 options against an
# entry that does, so the "no options while the entry has some" guard
# refused them first - and removing the word check failed nothing.
setup 0 yes
rm -rf "$SB/boot/picker" "$SB/boot/picker-default" "$SB/boot/picker-cmdline"
: > "$SB/boot/grub/custom.cfg"
echo "BOOT_IMAGE=/boot/vmlinuz-x ro recovery nomodeset dis_ucode_ldr" > "$SB/cmdline"
rc=$(run)
[ "$rc" != 0 ] && ok "refuses a FIRST install from a recovery boot (no entry to compare against)" \
  || bad "first install from recovery mode wrote a bare entry"

fresh_installed
echo "ro quiet nomodeset i915.enable_dpcd_backlight=2 i915.enable_psr=0" > "$SB/cmdline"
rc=$(run)
[ "$rc" != 0 ] && ok "refuses nomodeset even when i915 options are present (they mean nothing with KMS off)" \
  || bad "accepted a nomodeset boot because it happened to carry i915 options"

# And `recovery` on its own, WITH i915 options: only the word check
# refuses it, and only its `recovery` half. Without this case, dropping
# `recovery` from the pattern while keeping `nomodeset` passed everything.
fresh_installed
echo "ro recovery i915.enable_dpcd_backlight=2 i915.enable_psr=0" > "$SB/cmdline"
rc=$(run)
[ "$rc" != 0 ] && ok "refuses a recovery boot even when i915 options are present" \
  || bad "accepted a recovery boot because it happened to carry i915 options"

fresh_installed; echo "ro quiet nomodeset" > "$SB/cmdline"; rc=$(run)
[ "$rc" != 0 ] && ok "refuses nomodeset on its own" || bad "accepted nomodeset"

fresh_installed; echo "ro quiet splash" > "$SB/cmdline"; rc=$(run)
[ "$rc" != 0 ] && ok "refuses a boot with no i915 options when the entry has some" || bad "replaced working options with nothing"
entry_opts | grep -q "i915.enable_psr=0" && ok "and keeps the existing options" || bad "existing options lost"

fresh_installed; rm -f "$SB/cmdline"; rc=$(run)
[ "$rc" != 0 ] && ok "refuses when /proc/cmdline cannot be read" || bad "carried on without reading it"

# Word match, not substring: these must NOT trip the guard.
fresh_installed; echo "ro quiet foo.recovery=1 norecovery i915.enable_psr=0" > "$SB/cmdline"; rc=$(run)
[ "$rc" = 0 ] && ok "only the exact words nomodeset/recovery trip it" || bad "tripped on a substring"

echo "=== and still allows what is legitimately different ==="
setup 0 yes
rm -rf "$SB/boot/picker" "$SB/boot/picker-default" "$SB/boot/picker-cmdline"
: > "$SB/boot/grub/custom.cfg"; echo "ro quiet splash" > "$SB/cmdline"; rc=$(run)
[ "$rc" = 0 ] && ok "first install on a panel needing no i915 options" || bad "refused a first install"

fresh_installed; echo "ro quiet i915.enable_psr=0" > "$SB/cmdline"; rc=$(run)
[ "$rc" = 0 ] && ok "fewer options than before (after a revert)" || bad "refused a revert"
entry_opts | grep -q "enable_dpcd_backlight" && bad "kept an option the running boot dropped" || ok "and the entry follows the running boot"

fresh_installed
echo "BOOT_IMAGE=/boot/vmlinuz-x ro recovery nomodeset" > "$SB/cmdline"
rc=$(RUN_CMDLINE="i915.enable_psr=0" run)
[ "$rc" = 0 ] && ok "an explicit NIGHTFALL_CMDLINE overrides the check" || bad "refused an explicit override"
entry_opts | grep -qx "i915.enable_psr=0 *" && ok "and uses exactly what it was given" || bad "override not used: $(entry_opts)"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

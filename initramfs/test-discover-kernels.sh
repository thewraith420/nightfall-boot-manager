#!/bin/bash
# Exercises discover-kernels.sh, mostly on the real grub.cfg off the Slate.
#
# The interesting assertions here are the ones about Nightfall NOT
# listing its own GRUB entry. That is a boot-safety property, not a
# cosmetic one: a self-entry can be chosen as the default kernel, and
# the default is what init boots when the menu itself fails - so the
# rescue path would kexec back into Nightfall, forever, on a machine
# with no keyboard to interrupt it.
#
# It also went wrong silently once: the exclusion matched --id "picker",
# and the rename to --id "nightfall" walked straight past it with every
# other suite still green. Hence this file.
#
#   bash initramfs/test-discover-kernels.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$REPO/initramfs/discover-kernels.sh
FIXTURE=$REPO/docs/nocturne-grub.cfg
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT

# Writes a grub.cfg containing one Nightfall-shaped entry, with the id
# line given as $1 (empty for "no --id at all").
selfcfg() {
  cat > "$SB/self.cfg" <<EOF
menuentry 'Ubuntu' --class ubuntu $1 {
	linux	/boot/vmlinuz-6.8.0-generic root=UUID=aaa ro quiet
	initrd	/boot/initrd.img-6.8.0-generic
}
menuentry 'Nightfall (touch)' $2 {
	linux   $3
	initrd  ${3%vmlinuz}initramfs.img
}
EOF
  sh "$SCRIPT" "$SB/self.cfg"
}

echo "=== 1. the real grub.cfg off the Slate ==="
out=$(sh "$SCRIPT" "$FIXTURE") || bad "exited non-zero on the real fixture"
n=$(printf '%s\n' "$out" | grep -c .)
[ "$n" -gt 20 ] && ok "parsed $n entries" || bad "only $n entries - parser regressed"
printf '%s\n' "$out" | grep -q "^Ubuntu	/boot/vmlinuz-7.1.12" \
  && ok "finds the top-level default entry" || bad "missed the top-level entry"
printf '%s\n' "$out" | grep -q "with Linux 7.0.0-30-generic	" \
  && ok "finds entries nested in the Advanced submenu" || bad "submenu nesting broken"
printf '%s\n' "$out" | grep -q "(recovery mode)	" \
  && ok "keeps recovery rows (the UI folds them into the confirm dialog)" \
  || bad "recovery rows dropped"
printf '%s\n' "$out" | awk -F'\t' '{ if (NF != 4) exit 1 }' \
  && ok "every row has all four fields" || bad "a row is missing fields"
printf '%s\n' "$out" | awk -F'\t' '$2 !~ /vmlinuz/ { exit 1 }' \
  && ok "no row without a kernel image" || bad "emitted a row with no vmlinuz"

echo "=== 2. Nightfall must never list itself ==="
out=$(selfcfg "--id gnulinux-simple" "--id nightfall" "/nightfall/vmlinuz")
printf '%s\n' "$out" | grep -q Nightfall \
  && bad "listed its own entry (--id nightfall)" || ok "excluded by --id nightfall"
printf '%s\n' "$out" | grep -q "^Ubuntu	" \
  && ok "and still lists the real kernel beside it" || bad "excluded too much"

out=$(selfcfg "--id gnulinux-simple" "--id picker" "/picker/vmlinuz")
printf '%s\n' "$out" | grep -q Nightfall \
  && bad "listed a pre-rename --id picker entry" || ok "excluded by the old --id picker"

# A grub.cfg that predates --id, or one someone hand-edited, still must
# not offer us ourselves - the path is the giveaway.
out=$(selfcfg "" "" "/boot/nightfall/vmlinuz")
printf '%s\n' "$out" | grep -q Nightfall \
  && bad "listed a self-entry that carried no --id" || ok "excluded by kernel path when no --id"

out=$(selfcfg "" "" "/boot/picker/vmlinuz")
printf '%s\n' "$out" | grep -q Nightfall \
  && bad "listed an old self-entry with no --id" || ok "old path excluded too"

echo "=== 3. exclusion must not be over-eager ==="
# A real kernel whose name merely contains our name is somebody's build,
# not us. Only our own directory and our own id are ours.
cat > "$SB/near.cfg" <<'EOF'
menuentry 'Ubuntu, with Linux 7.2-nightfall-test' --id gnulinux-nightfall-adv {
	linux	/boot/vmlinuz-7.2-nightfall-test root=UUID=aaa ro
	initrd	/boot/initrd.img-7.2-nightfall-test
}
EOF
sh "$SCRIPT" "$SB/near.cfg" | grep -q "7.2-nightfall-test" \
  && ok "a kernel merely named 'nightfall' is still listed" \
  || bad "over-excluded a real kernel because of its name"

echo "=== 4. degenerate input ==="
: > "$SB/empty.cfg"
out=$(sh "$SCRIPT" "$SB/empty.cfg"); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "empty grub.cfg gives no rows, exit 0" \
  || bad "empty grub.cfg: rc=$rc out=[$out]"
sh "$SCRIPT" "$SB/does-not-exist.cfg" >/dev/null 2>&1 \
  && bad "silently succeeded on a missing grub.cfg" || ok "fails on a missing grub.cfg"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/bin/bash
# Exercises discover-bls.sh against hand-built loader/entries directories -
# no real Fedora/RHEL machine to pull a fixture from, so these are built to
# match the format documented at https://uapi-group.org/specifications/specs/boot_loader_specification/
#
#   bash initramfs/test-discover-bls.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$REPO/initramfs/discover-bls.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
setup() { rm -rf "$SB/boot"; mkdir -p "$SB/boot/loader/entries"; }
entry() {
  # $1 = filename (no .conf)  $2... = body lines
  f="$SB/boot/loader/entries/$1.conf"; shift
  : > "$f"
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
run() { sh "$SCRIPT" "$SB/boot"; }

echo "=== no loader/entries directory at all ==="
rm -rf "$SB/boot"; mkdir -p "$SB/boot"
out=$(run); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && ok "fails cleanly, no output - this boot dir just isn't BLS" || bad "rc=$rc out=[$out]"

echo "=== an empty entries directory ==="
setup
out=$(run); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "exits 0 with nothing to report" || bad "rc=$rc out=[$out]"

echo "=== one ordinary entry ==="
setup
entry 01-linux \
  "title Fedora Linux 40" \
  "version 6.8.0-fc40.x86_64" \
  "linux /vmlinuz-6.8.0-fc40.x86_64" \
  "initrd /initramfs-6.8.0-fc40.x86_64.img" \
  "options root=UUID=aaa ro quiet"
out=$(run)
[ "$out" = "$(printf 'Fedora Linux 40\t/vmlinuz-6.8.0-fc40.x86_64\t/initramfs-6.8.0-fc40.x86_64.img\troot=UUID=aaa ro quiet')" ] \
  && ok "title, linux, initrd and options come through" || bad "got: [$out]"

echo "=== a relative path (no leading /) is anchored to the boot dir ==="
setup
entry 01-linux "title X" "linux vmlinuz-x" "initrd initramfs-x.img" "options ro"
out=$(run)
printf '%s' "$out" | grep -qF $'\t/vmlinuz-x\t' && ok "linux path gets a leading /" || bad "linux path: [$out]"
printf '%s' "$out" | grep -qF $'\t/initramfs-x.img\t' && ok "initrd path gets a leading /" || bad "initrd path: [$out]"

echo "=== missing title falls back to the filename ==="
setup
entry 02-notitle "linux /vmlinuz-y" "initrd /initramfs-y.img" "options ro"
out=$(run)
[ "$(printf '%s' "$out" | cut -f1)" = "02-notitle.conf" ] && ok "uses the entry's filename as the title" || bad "got: [$out]"

echo "=== an entry with no linux line is skipped, not fatal ==="
setup
entry 03-broken "title Broken" "options ro"
entry 01-linux "title Good" "linux /vmlinuz-good" "initrd /initramfs-good.img" "options ro"
out=$(run)
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && ok "only the entry with a linux line is reported" || bad "got: [$out]"
printf '%s' "$out" | grep -q "Broken" && bad "the broken entry leaked through" || ok "the broken entry is absent"

echo "=== multiple initrd lines: only the first is used ==="
setup
entry 01-linux "title Multi" "linux /vmlinuz-m" "initrd /intel-ucode.img" "initrd /initramfs-m.img" "options ro"
out=$(run)
[ "$(printf '%s' "$out" | cut -f3)" = "/intel-ucode.img" ] \
  && ok "the first initrd line wins (a real limit - a separate microcode image is lost)" || bad "got: [$out]"

echo "=== \$kernelopts is resolved from grubenv when present ==="
setup
mkdir -p "$SB/boot/grub2"
printf '# GRUB Environment Block\nkernelopts=root=UUID=bbb ro rhgb quiet\n' > "$SB/boot/grub2/grubenv"
entry 01-linux "title Fedora" "linux /vmlinuz-f" "initrd /initramfs-f.img" 'options $kernelopts extra=1'
out=$(run)
[ "$(printf '%s' "$out" | cut -f4)" = "root=UUID=bbb ro rhgb quiet extra=1" ] \
  && ok "\$kernelopts is substituted from grub2/grubenv" || bad "got: [$out]"

echo "=== grub/grubenv (not grub2/) is also checked ==="
setup
mkdir -p "$SB/boot/grub"
printf 'kernelopts=root=UUID=ccc ro\n' > "$SB/boot/grub/grubenv"
entry 01-linux "title X" "linux /vmlinuz-x" "initrd /initramfs-x.img" 'options ${kernelopts}'
out=$(run)
[ "$(printf '%s' "$out" | cut -f4)" = "root=UUID=ccc ro" ] \
  && ok "the \${braced} form is also substituted, from grub/grubenv" || bad "got: [$out]"

echo "=== no grubenv at all: \$kernelopts with nothing to resolve it just drops out ==="
setup
entry 01-linux "title X" "linux /vmlinuz-x" "initrd /initramfs-x.img" 'options $kernelopts ro'
out=$(run)
[ "$(printf '%s' "$out" | cut -f4)" = "ro" ] \
  && ok "an unresolvable \$kernelopts is dropped, same rule discover-kernels.sh applies to GRUB vars" || bad "got: [$out]"

echo "=== another whole-token GRUB variable in options is dropped, same as \$kernelopts ==="
setup
entry 01-linux "title X" "linux /vmlinuz-x" "initrd /initramfs-x.img" 'options root=UUID=d ${grub_platform} ro'
out=$(run)
[ "$(printf '%s' "$out" | cut -f4)" = "root=UUID=d ro" ] \
  && ok "an unrelated whole-token variable reference is dropped, not passed to the kernel literally" || bad "got: [$out]"

echo "=== newest kernel is listed first, by real version order ==="
setup
entry 01 "title Old"    "version 6.9.0"  "linux /vmlinuz-6.9.0"  "initrd /initramfs-6.9.0.img"  "options ro"
entry 02 "title Newer"  "version 6.10.0" "linux /vmlinuz-6.10.0" "initrd /initramfs-6.10.0.img" "options ro"
entry 03 "title Oldest" "version 6.8.5"  "linux /vmlinuz-6.8.5"  "initrd /initramfs-6.8.5.img"  "options ro"
out=$(run)
got=$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')
[ "$got" = "Newer Old Oldest " ] \
  && ok "6.10 sorts after 6.9 (a plain string sort would get this backwards) - $got" || bad "order: $got"

echo "=== no version line: falls back to sorting by filename ==="
setup
entry 01-a "title A" "linux /vmlinuz-a" "initrd /initramfs-a.img" "options ro"
entry 02-b "title B" "linux /vmlinuz-b" "initrd /initramfs-b.img" "options ro"
out=$(run)
got=$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')
[ "$got" = "B A " ] \
  && ok "without a version line, the newer-looking filename (02) still sorts first" || bad "order: $got"

echo "=== a comment and blank lines inside an entry are ignored ==="
setup
entry 01-linux "# a comment" "" "title X" "linux /vmlinuz-x" "" "initrd /initramfs-x.img" "options ro"
out=$(run)
[ "$out" = "$(printf 'X\t/vmlinuz-x\t/initramfs-x.img\tro')" ] \
  && ok "comments and blank lines do not corrupt the entry" || bad "got: [$out]"

echo "=== boot-dir with no boot/ prefix (a separate /boot partition, bootfs layout) ==="
rm -rf "$SB/boot2"; mkdir -p "$SB/boot2/loader/entries"
: > "$SB/boot2/loader/entries/01-linux.conf"
printf 'title Separate\nlinux /vmlinuz-s\ninitrd /initramfs-s.img\noptions ro\n' > "$SB/boot2/loader/entries/01-linux.conf"
out=$(sh "$SCRIPT" "$SB/boot2")
[ "$out" = "$(printf 'Separate\t/vmlinuz-s\t/initramfs-s.img\tro')" ] \
  && ok "works the same when <boot-dir> IS the boot partition's top level" || bad "got: [$out]"

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

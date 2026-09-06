#!/bin/bash
# apply-cmdline.sh: per-kernel saved command lines.
set -u
S=$(cd "$(dirname "$0")" && pwd)/apply-cmdline.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# A realistic menu: one kernel with three entries (plain, "with Linux",
# recovery) plus a second kernel.
menu() { cat > "$T/menu.tsv" <<EOF
Ubuntu	/boot/vmlinuz-A	/boot/initrd-A	root=x ro quiet splash	
Ubuntu, with Linux A	/boot/vmlinuz-A	/boot/initrd-A	root=x ro quiet splash	
Ubuntu, with Linux A (recovery mode)	/boot/vmlinuz-A	/boot/initrd-A	root=x ro recovery nomodeset	
Ubuntu, with Linux B	/boot/vmlinuz-B	/boot/initrd-B	root=x ro quiet splash	
EOF
}
field4() { awk -F'\t' -v t="$1" '$1==t{print $4}' "$T/out"; }
run() { sh "$S" "$T/menu.tsv" "$T/saved" > "$T/out"; }

echo "=== no saved file: everything passes through ==="
menu; : > "$T/saved"; run
diff -q "$T/menu.tsv" "$T/out" >/dev/null && ok "menu unchanged" || bad "modified without any override"

echo "=== an override applies to that kernel's normal entries ==="
menu; printf '/boot/vmlinuz-A\troot=x ro loglevel=7\n' > "$T/saved"; run
[ "$(field4 'Ubuntu')" = "root=x ro loglevel=7" ] && ok "plain entry overridden" || bad "got: $(field4 'Ubuntu')"
[ "$(field4 'Ubuntu, with Linux A')" = "root=x ro loglevel=7" ] && ok "'with Linux' entry overridden too" || bad "missed the sibling entry"

echo "=== ...but NEVER the recovery entry ==="
[ "$(field4 'Ubuntu, with Linux A (recovery mode)')" = "root=x ro recovery nomodeset" ] \
  && ok "recovery keeps its own command line" || bad "recovery clobbered: $(field4 'Ubuntu, with Linux A (recovery mode)')"

echo "=== per-kernel: another kernel is untouched ==="
[ "$(field4 'Ubuntu, with Linux B')" = "root=x ro quiet splash" ] && ok "kernel B unaffected" || bad "leaked onto kernel B"

echo "=== two kernels can hold different command lines at once ==="
menu
{ printf '/boot/vmlinuz-A\troot=x ro AAA\n'; printf '/boot/vmlinuz-B\troot=x ro BBB\n'; } > "$T/saved"; run
[ "$(field4 'Ubuntu')" = "root=x ro AAA" ] && [ "$(field4 'Ubuntu, with Linux B')" = "root=x ro BBB" ] \
  && ok "each kernel gets its own" || bad "A=$(field4 'Ubuntu') B=$(field4 'Ubuntu, with Linux B')"

echo "=== structure is preserved ==="
[ "$(wc -l < "$T/out")" = 4 ] && ok "no rows lost" || bad "row count changed"
awk -F'\t' 'NF<4{b=1} END{exit b?1:0}' "$T/out" && ok "fields intact" || bad "field structure broken"

echo "=== an empty value is ignored, not applied ==="
# A kernel booting with no arguments at all would not get far; a blank
# line is how a cleared entry would look if one were ever written.
menu; printf '/boot/vmlinuz-A\t\n' > "$T/saved"; run
[ "$(field4 'Ubuntu')" = "root=x ro quiet splash" ] && ok "blank override ignored" || bad "applied an empty command line"

echo "=== a missing file is not fatal ==="
menu; rm -f "$T/saved"; sh "$S" "$T/menu.tsv" "$T/saved" > "$T/out" 2>/dev/null
diff -q "$T/menu.tsv" "$T/out" >/dev/null && ok "passes through rather than failing the boot" || bad "broke on a missing file"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

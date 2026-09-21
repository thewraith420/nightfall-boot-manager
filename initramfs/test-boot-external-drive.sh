#!/bin/bash
# boot-external-drive.sh against a fake, stateful efibootmgr.
#
# The mock keeps NVRAM state in a flat file: one line per entry as
# "<num>\t<label>\t<disk>\t<part>\t<loader>", plus a separate bootnext
# file. It supports exactly the invocations boot-external-drive.sh
# actually makes - listing, -c create, -b/-B delete, -n set BootNext -
# not the whole of efibootmgr's real surface.
set -u
S=$(cd "$(dirname "$0")" && pwd)/boot-external-drive.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

setup() {
  SB=$(mktemp -d)
  mkdir -p "$SB/bin" "$SB/dev"
  : > "$SB/dev/sda" ; : > "$SB/dev/sda1"
  : > "$SB/dev/mmcblk0" ; : > "$SB/dev/mmcblk0p1"
  ENTRIES="$SB/entries"    # num<TAB>label<TAB>disk<TAB>part<TAB>loader
  BOOTNEXT="$SB/bootnext"
  BOOTORDER="$SB/bootorder"
  LOG="$SB/log"
  : > "$ENTRIES"; : > "$BOOTNEXT"; : > "$LOG"
  # A realistic pre-existing order, standing in for "whatever this
  # machine's normal boot sequence already was" - the exact thing that
  # must come back unchanged once the script is done. Deliberately none
  # of next_num()'s low numbers (it always starts handing out 0001,
  # 0002, ... against an empty $ENTRIES): a real efibootmgr can never
  # assign a new entry a number already in use anywhere, but this mock
  # only checks $ENTRIES, so a collision here would make a freshly
  # created entry indistinguishable from an unrelated pre-existing one.
  printf '0010,0020,0030,0040,0050,0060' > "$BOOTORDER"
}
teardown() { rm -rf "$SB"; }

# Seeds an existing NVRAM entry directly, bypassing the mock's own create
# path - stands in for "a real boot entry already there before this
# script ever runs".
seed_entry() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$ENTRIES"; }

# $1: if set, `-c` (create) fails outright, as if efibootmgr itself
# refused (e.g. no efivarfs). $2: if set, `-n` (set BootNext) is a no-op
# that still exits 0 but never actually changes state - simulates
# firmware silently ignoring it, which is exactly why the script reads
# BootNext back rather than trusting the exit code.
write_mock() {
  create_fails=${1:-} noop_bootnext=${2:-}
  cat > "$SB/bin/efibootmgr" <<EOF
#!/bin/bash
echo "efibootmgr \$*" >> "$LOG"
ENTRIES="$ENTRIES"; BOOTNEXT="$BOOTNEXT"; BOOTORDER="$BOOTORDER"

next_num() {
  n=\$(awk -F'\t' 'BEGIN{m=0} {v=strtonum("0x" \$1); if (v>m) m=v} END{printf "%04X", m+1}' "\$ENTRIES")
  [ -n "\$n" ] && [ "\$n" != "0000" ] && echo "\$n" || echo "0001"
}

print_list() {
  echo "BootCurrent: 0000"
  bn=\$(cat "\$BOOTNEXT" 2>/dev/null)
  [ -n "\$bn" ] && echo "BootNext: \$bn"
  echo "BootOrder: \$(cat "\$BOOTORDER" 2>/dev/null)"
  while IFS=\$'\t' read -r num label disk part loader; do
    [ -n "\$num" ] || continue
    echo "Boot\${num}* \${label}"
  done < "\$ENTRIES"
}

case "\$1" in
  -c)
    shift
    d="" p="" l="" lo=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -d) d=\$2; shift 2 ;;
        -p) p=\$2; shift 2 ;;
        -L) l=\$2; shift 2 ;;
        -l) lo=\$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "$create_fails" ]; then
      echo "efibootmgr: could not write NVRAM" >&2
      exit 1
    fi
    n=\$(next_num)
    printf '%s\t%s\t%s\t%s\t%s\n' "\$n" "\$l" "\$d" "\$p" "\$lo" >> "\$ENTRIES"
    # Real efibootmgr prepends a freshly created entry to BootOrder - not
    # a no-op the way an earlier version of this mock modelled it, and
    # exactly the behaviour that caught a real bug in boot-external-drive.sh.
    cur=\$(cat "\$BOOTORDER" 2>/dev/null)
    if [ -n "\$cur" ]; then printf '%s,%s' "\$n" "\$cur" > "\$BOOTORDER"
    else printf '%s' "\$n" > "\$BOOTORDER"; fi
    print_list
    exit 0
    ;;
  -b)
    num=\$2
    if [ "\$3" = "-B" ]; then
      grep -vE "^\${num}"\$'\t' "\$ENTRIES" > "\$ENTRIES.tmp" || true
      mv "\$ENTRIES.tmp" "\$ENTRIES"
      # Real efibootmgr also drops a deleted entry out of BootOrder - a
      # dangling reference to a Boot#### that no longer exists would
      # otherwise be left behind.
      cur=\$(cat "\$BOOTORDER" 2>/dev/null)
      new=\$(printf '%s' "\$cur" | tr ',' '\n' | grep -vx "\$num" | tr '\n' ',' | sed 's/,\$//')
      printf '%s' "\$new" > "\$BOOTORDER"
      exit 0
    fi
    ;;
  -n)
    num=\$2
    if [ -z "$noop_bootnext" ]; then
      echo "\$num" > "\$BOOTNEXT"
    fi
    exit 0
    ;;
  -o)
    printf '%s' "\$2" > "\$BOOTORDER"
    exit 0
    ;;
  "")
    print_list
    exit 0
    ;;
esac
print_list
exit 0
EOF
  chmod +x "$SB/bin/efibootmgr"
}

run() {
  NIGHTFALL_EFIBOOTMGR="$SB/bin/efibootmgr" sh "$S" "${1:-$SB/dev/sda1}" "${2:-\\EFI\\BOOT\\BOOTX64.EFI}"
}

echo "=== the happy path: creates an entry and arms BootNext ==="
setup
write_mock
out=$(run 2>&1); rc=$?
[ "$rc" = 0 ] && ok "exits 0" || bad "exit $rc: $out"
grep -q 'BootNext armed' <<<"$out" && ok "says BootNext was armed" || bad "no confirmation message: $out"
grep -qF "Nightfall-boot-once" "$ENTRIES" && ok "left exactly the entry it created behind" || bad "entries file wrong: $(cat "$ENTRIES")"
bn=$(cat "$BOOTNEXT"); [ -n "$bn" ] && grep -q "^${bn}"$'\t' "$ENTRIES" && ok "BootNext points at the entry it just made" || bad "BootNext ($bn) does not match: $(cat "$ENTRIES")"
[ "$(cat "$BOOTORDER")" = "0010,0020,0030,0040,0050,0060" ] \
  && ok "BootOrder is restored to exactly what it was - efibootmgr -c prepending our entry does not stick" \
  || bad "BootOrder was left changed: $(cat "$BOOTORDER")"
teardown

echo "=== a stale entry from a previous attempt is removed first ==="
setup
seed_entry 0003 "Nightfall-boot-once" /dev/sdz 1 '\EFI\BOOT\BOOTX64.EFI'
write_mock
out=$(run 2>&1)
[ "$(grep -c "Nightfall-boot-once" "$ENTRIES")" = 1 ] && ok "only one Nightfall-boot-once entry remains, not two" || bad "stale entry was not cleaned up: $(cat "$ENTRIES")"
grep -q "^0003" "$ENTRIES" && bad "the OLD stale entry is still there (should have been replaced)" || ok "the old stale entry (0003) is gone"
teardown

echo "=== an unrelated entry with a different label is left alone ==="
setup
seed_entry 0007 "Windows Boot Manager" /dev/sda 2 '\EFI\Microsoft\Boot\bootmgfw.efi'
write_mock
run >/dev/null 2>&1
grep -q "^0007" "$ENTRIES" && ok "an entry that isn't ours survives untouched" || bad "wiped an unrelated boot entry: $(cat "$ENTRIES")"
teardown

echo "=== efibootmgr refusing to create an entry is a clean failure ==="
setup
write_mock create_fails
out=$(run 2>&1); rc=$?
[ "$rc" != 0 ] && ok "exits non-zero" || bad "should have failed: $out"
grep -q 'ERROR' <<<"$out" && ok "reports an error" || bad "no error message: $out"
[ -s "$ENTRIES" ] && bad "an entry was left behind despite the failure: $(cat "$ENTRIES")" || ok "NVRAM has nothing new in it"
teardown

echo "=== BootNext silently not taking is caught, not trusted blindly ==="
setup
write_mock "" noop_bootnext
out=$(run 2>&1); rc=$?
[ "$rc" != 0 ] && ok "exits non-zero (BootNext never actually changed)" || bad "should have failed: $out"
grep -q 'did not take' <<<"$out" && ok "says BootNext did not take" || bad "wrong message: $out"
[ -s "$ENTRIES" ] && bad "the entry it created was not cleaned up after the failure: $(cat "$ENTRIES")" || ok "the just-created entry was rolled back"
[ "$(cat "$BOOTORDER")" = "0010,0020,0030,0040,0050,0060" ] \
  && ok "BootOrder ends up back to normal too (the rollback's own delete cleans it)" \
  || bad "BootOrder left with a dangling reference: $(cat "$BOOTORDER")"
teardown

echo "=== a device with no trailing partition number is refused up front ==="
setup
write_mock
out=$(run "$SB/dev/sda" '\EFI\BOOT\BOOTX64.EFI' 2>&1); rc=$?
[ "$rc" != 0 ] && ok "refuses" || bad "should have refused a whole-disk path: $out"
grep -q 'efibootmgr' "$LOG" 2>/dev/null && bad "called efibootmgr despite the bad input" || ok "never even called efibootmgr"
teardown

echo "=== mmcblk-style partition naming is split correctly ==="
setup
write_mock
run "$SB/dev/mmcblk0p1" '\EFI\BOOT\BOOTX64.EFI' >/dev/null 2>&1
grep -q -- "-d $SB/dev/mmcblk0 -p 1 " "$LOG" && ok "disk=mmcblk0 partition=1, not mmcblk01 or similar" || bad "wrong split: $(cat "$LOG")"
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

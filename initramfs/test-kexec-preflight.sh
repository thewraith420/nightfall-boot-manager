#!/bin/bash
# kexec-preflight.sh against fake lockdown / SecureBoot files.
#
# The property that matters is NOT raising a false alarm: refusing to boot a
# machine that would have worked is worse than the panic this exists to
# replace, so most of these assert exit 0.
set -u
S=$(cd "$(dirname "$0")" && pwd)/kexec-preflight.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
# $1 = lockdown file content (printf format, "" = no file), $2 = SecureBoot
# data byte as an octal escape ("" = no efivar).
run() {
  rm -f "$SB/lockdown" "$SB/sbvar"
  [ -n "$1" ] && printf "$1" > "$SB/lockdown"
  [ -n "${2:-}" ] && printf "\\007\\000\\000\\000$2" > "$SB/sbvar"
  NIGHTFALL_LOCKDOWN_FILE="$SB/lockdown" NIGHTFALL_SECUREBOOT_VAR="$SB/sbvar" sh "$S"
}

echo "=== not blocked: never a false alarm ==="
out=$(run ""); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "no lockdown file at all (cannot tell) is not blocked" || bad "rc=$rc out=[$out]"
out=$(run '[none] integrity confidentiality\n'); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "lockdown 'none' is not blocked" || bad "rc=$rc out=[$out]"
out=$(run '[none] integrity confidentiality\n' '\001'); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "Secure Boot ON but lockdown none is NOT blocked (kexec still works - Secure Boot alone is not the blocker)" || bad "rc=$rc out=[$out]"
out=$(run 'garbage'); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "an unrecognisable lockdown file is not blocked" || bad "rc=$rc out=[$out]"

echo "=== blocked ==="
out=$(run 'none [integrity] confidentiality\n'); rc=$?
[ $rc = 1 ] && ok "lockdown integrity is blocked" || bad "rc=$rc"
echo "$out" | grep -q "'integrity'" && ok "and the message names the mode" || bad "no mode in: $out"
echo "$out" | grep -qi "Secure Boot is enabled" && bad "claimed Secure Boot with no evidence: $out" || ok "and does not claim Secure Boot when there is no efivar"
out=$(run 'none integrity [confidentiality]\n'); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "'confidentiality'" && ok "lockdown confidentiality is blocked" || bad "rc=$rc out=$out"
out=$(run 'none [integrity] confidentiality' ); rc=$?
[ $rc = 1 ] && ok "a newline-less lockdown file is still read (the read() gotcha)" || bad "newline-less lockdown missed: rc=$rc"

echo "=== Secure Boot only shapes the advice ==="
out=$(run 'none [integrity] confidentiality\n' '\001'); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "Secure Boot is enabled. Turn Secure Boot off" && ok "Secure Boot ON + lockdown: says so and tells them to turn it off" || bad "rc=$rc out=$out"
out=$(run 'none [integrity] confidentiality\n' '\000'); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "lockdown= option" && ! echo "$out" | grep -q "Turn Secure Boot off" \
  && ok "Secure Boot OFF + lockdown: points at lockdown= on the command line, NOT at a Secure Boot that is already off" || bad "rc=$rc out=$out"
out=$(run 'none [integrity] confidentiality\n'); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "Secure Boot off in the firmware" && echo "$out" | grep -q "lockdown= option" \
  && ok "Secure Boot state UNKNOWN (no efivar): offers both remedies" || bad "rc=$rc out=$out"

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

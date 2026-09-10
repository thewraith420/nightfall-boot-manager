#!/bin/bash
# remove-backup.sh against a fake target drive.
#
# Same shape as test-remove-kernel.sh, and for the same reason: most of
# what matters here is what it REFUSES. Deleting the wrong 86GB archive
# is not recoverable from a tablet, so every refusal below must also
# leave the drive untouched - "it refused" and "it refused and changed
# nothing" are different claims, and only the second one is worth
# anything.
set -u
S=$(cd "$(dirname "$0")" && pwd)/remove-backup.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# $1 = "ro" to make the mounted target read-only to the script.
setup() {
  SB=$(mktemp -d)
  D=$SB/root/mnt/nocturne-backups
  mkdir -p "$D" "$SB/bin"
  : > "$SB/target"
  # Two complete backups, so a delete leaves something behind and the
  # "how many remain" count has something to count.
  echo archive-a > "$D/bk-a.tar"; echo "created: monday"  > "$D/bk-a.info"
  echo archive-b > "$D/bk-b.tar"; echo "created: tuesday" > "$D/bk-b.info"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/mount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/umount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/sync"
  cat > "$SB/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted"
echo "t 1 1 500000000 1% /mnt"
EOF
  chmod +x "$SB"/bin/*
  if [ "${1:-}" = ro ]; then
    # The trap this stands in for: exFAT and NTFS fall back to read-only
    # on a dirty volume instead of refusing to mount, and a stick with
    # its write-protect switch on mounts perfectly happily. The script
    # must notice before it claims to have deleted anything.
    chmod a-w "$D"
  fi
}
teardown() { [ -n "${D:-}" ] && chmod u+w "$D" 2>/dev/null; rm -rf "$SB"; }
run()  { PATH="$SB/bin:$PATH" sh "$S" "$SB/root" "$SB/target" "$1" >"$SB/out" 2>&1; echo $?; }
out()  { cat "$SB/out"; }
intact() { [ -f "$D/bk-a.tar" ] && [ -f "$D/bk-a.info" ] \
           && [ -f "$D/bk-b.tar" ] && [ -f "$D/bk-b.info" ]; }

echo "=== deletes the backup it was asked to delete ==="
setup
rc=$(run bk-a)
[ "$rc" = 0 ] && ok "reports success" || bad "failed: $(out | tail -2)"
[ ! -f "$D/bk-a.tar" ]  && ok "removed the archive" || bad "archive still there"
[ ! -f "$D/bk-a.info" ] && ok "removed the sidecar" || bad "sidecar still there"
[ -f "$D/bk-b.tar" ] && [ -f "$D/bk-b.info" ] \
  && ok "left the OTHER backup completely alone" || bad "collateral damage to bk-b"
out | grep -q "1 completed backup(s) remain" \
  && ok "says how many backups are left" || bad "no count of what remains: $(out | tail -1)"
out | grep -qE "free on .*->" && ok "reports the space reclaimed" || bad "silent about free space"
teardown

echo "=== deleting the last backup is allowed, not refused ==="
# Deliberately UNLIKE remove-kernel.sh. No kernel means no boot; no
# backup means a machine that is completely fine. Freeing space to take
# a fresh backup is normal, and on a full drive it is the only way.
setup
rm -f "$D/bk-b.tar" "$D/bk-b.info"
rc=$(run bk-a)
[ "$rc" = 0 ] && ok "deletes the only remaining backup" || bad "refused the last backup: $(out | tail -1)"
out | grep -q "0 completed backup(s) remain" && ok "says none are left" || bad "wrong remaining count"
teardown

echo "=== refuses, and changes nothing ==="
setup
rc=$(run no-such-backup)
[ "$rc" != 0 ] && ok "refuses a name that is not there" || bad "claimed to delete a missing backup"
out | grep -q "no such backup" && ok "says which one it could not find" || bad "unclear: $(out | tail -1)"
intact && ok "left both backups intact" || bad "deleted something while refusing"
teardown

setup
# Deliberately a path that RESOLVES. A name that merely fails to exist
# is stopped by the existence check further down, so testing with one
# would pass against no guard at all - the guard's actual job is the
# name that would otherwise be found and deleted outside the backup
# directory.
mkdir -p "$SB/root/mnt/elsewhere"
echo "not a backup" > "$SB/root/mnt/elsewhere/victim.tar"
rc=$(run "../elsewhere/victim")
[ "$rc" != 0 ] && ok "refuses a path-shaped name" || bad "accepted a path as a backup name"
out | grep -q "implausible backup name" && ok "says why" || bad "unclear refusal: $(out | tail -1)"
[ -f "$SB/root/mnt/elsewhere/victim.tar" ] \
  && ok "did not delete a resolvable file outside the backup directory" \
  || bad "escaped the backup directory and deleted a file"
intact && ok "left both backups intact" || bad "deleted something while refusing"
teardown

setup
rc=$(run ".")
[ "$rc" != 0 ] && ok "refuses '.'" || bad "accepted '.' as a backup name"
intact && ok "left both backups intact" || bad "deleted something while refusing"
teardown

echo "=== a read-only drive is caught BEFORE anything is deleted ==="
setup ro
rc=$(run bk-a)
[ "$rc" != 0 ] && ok "refuses rather than half-deleting" || bad "reported success on a read-only drive"
out | grep -q "read-only" && ok "names the actual problem" || bad "unhelpful: $(out | tail -1)"
intact && ok "both backups still there" || bad "deleted from a read-only mount?"
out | grep -q "Nothing was deleted" && ok "says plainly that nothing was deleted" || bad "no reassurance"
teardown

echo "=== refuses when the pieces are missing ==="
setup
rm -rf "$D"
rc=$(run bk-a)
[ "$rc" != 0 ] && ok "refuses when there is no backup directory" || bad "proceeded without one"
teardown

setup
rc=$(PATH="$SB/bin:$PATH" sh "$S" "$SB/root/nope" "$SB/target" bk-a >"$SB/out" 2>&1; echo $?)
[ "$rc" != 0 ] && ok "refuses when the root mount is not a directory" || bad "proceeded anyway"
teardown

setup
cat > "$SB/bin/mount" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$SB/bin/mount"
rc=$(run bk-a)
[ "$rc" != 0 ] && ok "refuses when the drive will not mount" || bad "proceeded without a mount"
out | grep -q "nothing was deleted" && ok "says nothing was deleted" || bad "no reassurance"
intact && ok "left both backups intact" || bad "deleted something without mounting"
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

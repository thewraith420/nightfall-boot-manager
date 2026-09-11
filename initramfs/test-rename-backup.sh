#!/bin/bash
# rename-backup.sh against a fake target drive.
#
# Like the delete tests, most of these are refusals - but the ones that
# matter most are about ORDERING. backup-system.sh sweeps any .tar with
# no .info, so a rename interrupted at the wrong moment does not just
# leave a mess, it arms the next backup to delete an 86GB archive.
set -u
S=$(cd "$(dirname "$0")" && pwd)/rename-backup.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

setup() {
  SB=$(mktemp -d)
  D=$SB/root/mnt/nocturne-backups
  mkdir -p "$D" "$SB/bin"
  : > "$SB/target"
  echo "ARCHIVE-A-CONTENT" > "$D/bk-a.tar"
  printf 'created:  monday\narchive:  nocturne-backups/bk-a.tar\nsize_kb:  123\n' > "$D/bk-a.info"
  echo "ARCHIVE-B-CONTENT" > "$D/bk-b.tar"
  printf 'created:  tuesday\narchive:  nocturne-backups/bk-b.tar\n' > "$D/bk-b.info"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/mount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/umount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/sync"
  chmod +x "$SB"/bin/*
  [ "${1:-}" = ro ] && chmod a-w "$D"
  return 0
}
teardown() { [ -n "${D:-}" ] && chmod u+w "$D" 2>/dev/null; rm -rf "$SB"; }
run()  { PATH="$SB/bin:$PATH" sh "$S" "$SB/root" "$SB/target" "$1" "$2" >"$SB/out" 2>&1; echo $?; }
out()  { cat "$SB/out"; }
intact() { [ -f "$D/bk-a.tar" ] && [ -f "$D/bk-a.info" ] \
           && [ -f "$D/bk-b.tar" ] && [ -f "$D/bk-b.info" ]; }

echo "=== renames the backup it was asked to ==="
setup
rc=$(run bk-a before-the-7.2.4-update)
[ "$rc" = 0 ] && ok "reports success" || bad "failed: $(out | tail -2)"
[ -f "$D/before-the-7.2.4-update.tar" ] && ok "archive is under the new name" || bad "no renamed archive"
[ -f "$D/before-the-7.2.4-update.info" ] && ok "sidecar is under the new name" || bad "no renamed sidecar"
[ ! -e "$D/bk-a.tar" ] && [ ! -e "$D/bk-a.info" ] && ok "nothing left under the old name" || bad "old name still present"
grep -q "ARCHIVE-A-CONTENT" "$D/before-the-7.2.4-update.tar" 2>/dev/null \
  && ok "the archive's contents are the same file, not a copy" || bad "archive content changed"
# The sidecar records the archive path; leaving it stale would make the
# .info describe a file that no longer exists.
grep -q "archive:  nocturne-backups/before-the-7.2.4-update.tar" "$D/before-the-7.2.4-update.info" \
  && ok "the sidecar's archive: line was updated too" || bad "stale archive: line: $(grep archive: "$D/before-the-7.2.4-update.info")"
grep -q "created:  monday" "$D/before-the-7.2.4-update.info" \
  && ok "the rest of the sidecar survived" || bad "lost the created: line"
[ -f "$D/bk-b.tar" ] && [ -f "$D/bk-b.info" ] && ok "left the OTHER backup alone" || bad "collateral damage"
teardown

echo "=== never leaves an archive without a sidecar ==="
# This is the one that matters. backup-system.sh sweeps a .tar with no
# .info, so any moment where the real archive lacks a sidecar is a moment
# where the next backup would delete it.
setup
rc=$(run bk-a renamed)
[ "$rc" = 0 ] && ok "renamed" || bad "failed"
orphans=0
for t in "$D"/*.tar; do
  [ -f "$t" ] || continue
  [ -f "${t%.tar}.info" ] || orphans=$((orphans+1))
done
[ "$orphans" = 0 ] && ok "no archive is left without its sidecar" || bad "$orphans archive(s) a sweep would delete"
teardown

echo "=== interrupted mid-rename, the archive still has a sidecar ==="
# Checking only the END state proves nothing about ordering - a wrong
# order also finishes clean. Force a failure at the move itself, which
# is the moment an interruption would land, and inspect what is left.
setup
cat > "$SB/bin/mv" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$SB/bin/mv"
rc=$(run bk-a newname)
[ "$rc" != 0 ] && ok "reports the failure" || bad "claimed success when the move failed"
[ -f "$D/bk-a.tar" ] && [ -f "$D/bk-a.info" ]   && ok "the backup is still complete under its OLD name" || bad "lost the backup"
# Step 1 wrote newname.info. If that is left behind next to the old
# archive it is merely a stray sidecar - harmless - but the rollback
# should remove it so the drive is exactly as it was.
[ ! -e "$D/newname.info" ] && ok "rolled back the half-written sidecar" || bad "left newname.info behind"
[ ! -e "$D/newname.tar" ] && ok "no archive under the new name" || bad "left a phantom archive"
orphans=0
for t in "$D"/*.tar; do [ -f "$t" ] || continue; [ -f "${t%.tar}.info" ] || orphans=$((orphans+1)); done
[ "$orphans" = 0 ] && ok "no archive a sweep would delete" || bad "$orphans archive(s) left sweepable"
teardown

echo "=== the sidecar is written BEFORE the archive moves ==="
# THIS is the test that actually discriminates the ordering. Failing the
# mv does not: both orders leave the old pair intact in that case. Fail
# the SIDECAR WRITE instead:
#
#   correct order (info, then mv) -> dies before the mv, old pair intact
#   wrong order   (mv, then info) -> the archive has already moved and
#                                    now has no sidecar, so the next
#                                    backup's sweep deletes 86GB
setup
cat > "$SB/bin/awk" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$SB/bin/awk"
rc=$(run bk-a newname)
[ "$rc" != 0 ] && ok "reports the failure" || bad "claimed success when the sidecar could not be written"
[ -f "$D/bk-a.tar" ] && [ -f "$D/bk-a.info" ] \
  && ok "the archive never moved - it still has its sidecar" \
  || bad "the archive moved before its sidecar existed: a sweep would delete it"
[ ! -e "$D/newname.tar" ] && ok "nothing under the new name" || bad "left a sidecar-less archive"
orphans=0
for t in "$D"/*.tar; do [ -f "$t" ] || continue; [ -f "${t%.tar}.info" ] || orphans=$((orphans+1)); done
[ "$orphans" = 0 ] && ok "no archive a sweep would delete" || bad "$orphans archive(s) left sweepable"
teardown

echo "=== refuses, and changes nothing ==="
setup
rc=$(run no-such-backup whatever)
[ "$rc" != 0 ] && ok "refuses a backup that is not there" || bad "renamed something that does not exist"
intact && ok "left both backups intact" || bad "changed something while refusing"
teardown

setup
rc=$(run bk-a bk-b)
[ "$rc" != 0 ] && ok "refuses to rename onto an existing backup" || bad "OVERWROTE another backup"
grep -q "ARCHIVE-B-CONTENT" "$D/bk-b.tar" 2>/dev/null \
  && ok "the backup it would have destroyed is untouched" || bad "destroyed bk-b"
intact && ok "both backups still there" || bad "changed something while refusing"
teardown

setup
rc=$(run bk-a "../escape")
[ "$rc" != 0 ] && ok "refuses a path-shaped NEW name" || bad "accepted a path as the new name"
out | grep -q "implausible backup name" && ok "says why" || bad "unclear: $(out | tail -1)"
intact && ok "left both backups intact" || bad "changed something while refusing"
teardown

setup
rc=$(run "../bk-a" newname)
[ "$rc" != 0 ] && ok "refuses a path-shaped OLD name" || bad "accepted a path as the old name"
intact && ok "left both backups intact" || bad "changed something while refusing"
teardown

setup
rm -f "$D/bk-a.info"
rc=$(run bk-a newname)
[ "$rc" != 0 ] && ok "refuses a backup that never finished" || bad "renamed an incomplete backup"
out | grep -q "did not complete" && ok "says why" || bad "unclear: $(out | tail -1)"
[ -f "$D/bk-a.tar" ] && ok "left the incomplete archive where it was" || bad "moved it anyway"
teardown

echo "=== renaming to the same name is a no-op, not an error ==="
setup
rc=$(run bk-a bk-a)
[ "$rc" = 0 ] && ok "succeeds quietly" || bad "treated a no-op rename as failure"
intact && ok "and changed nothing" || bad "did something"
teardown

echo "=== a read-only drive is caught BEFORE anything moves ==="
setup ro
rc=$(run bk-a newname)
[ "$rc" != 0 ] && ok "refuses rather than half-renaming" || bad "reported success on a read-only drive"
out | grep -q "read-only" && ok "names the actual problem" || bad "unhelpful: $(out | tail -1)"
intact && ok "both backups still there" || bad "renamed on a read-only mount?"
teardown

echo "=== refuses when the drive will not mount ==="
setup
printf '#!/bin/sh\nexit 1\n' > "$SB/bin/mount"; chmod +x "$SB/bin/mount"
rc=$(run bk-a newname)
[ "$rc" != 0 ] && ok "refuses when the drive will not mount" || bad "proceeded without a mount"
out | grep -q "nothing was renamed" && ok "says nothing was renamed" || bad "no reassurance"
intact && ok "left both backups intact" || bad "changed something without mounting"
teardown

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

#!/bin/bash
# restore-system.sh against a fake root and a fake backup drive.
#
# Restore is the second-most destructive thing here, so most of these
# are refusals - and the ones that matter check that nothing was
# extracted when it refused.
set -u
S=$(cd "$(dirname "$0")" && pwd)/restore-system.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# $1 = make .info?  $2 = grub-probe rc  $3 = tar rc
setup() {
  SB=$(mktemp -d)
  mkdir -p "$SB/root/mnt/nocturne-backups" "$SB/root/proc" "$SB/root/sys" \
           "$SB/root/dev/pts" "$SB/bin"
  : > "$SB/root/mnt/nocturne-backups/bk.tar"
  [ "$1" = yes ] && echo "created: whenever" > "$SB/root/mnt/nocturne-backups/bk.info"
  : > "$SB/target"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/mount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/umount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/sync"
  cat > "$SB/bin/chroot" <<EOF
#!/bin/sh
case "\$*" in
  *grub-probe*)  exit $2 ;;
  *tar*)         echo "MARKER_EXTRACT \$*" >&2; exit $3 ;;
  *update-grub*) echo "MARKER_UPDATE_GRUB" >&2; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$SB"/bin/*
}
run() { PATH="$SB/bin:$PATH" sh "$S" "$SB/root" "$SB/target" bk >"$SB/out" 2>&1; echo $?; }
out() { cat "$SB/out"; }

echo "=== refuses an incomplete backup ==="
setup no 0 0
rc=$(run)
[ "$rc" != 0 ] && ok "refuses when the .info sidecar is missing" || bad "restored an unfinished backup"
out | grep -q "did not complete" && ok "explains why" || bad "unclear: $(out | tail -1)"
out | grep -q "MARKER_EXTRACT" && bad "extracted anyway" || ok "extracted NOTHING"

echo "=== refuses a backup that isn't there ==="
setup yes 0 0
rm -f "$SB/root/mnt/nocturne-backups/bk.tar"
rc=$(run)
[ "$rc" != 0 ] && ok "refuses a missing archive" || bad "proceeded without an archive"
out | grep -q "MARKER_EXTRACT" && bad "extracted anyway" || ok "extracted NOTHING"

echo "=== proves the chroot BEFORE overwriting anything ==="
setup yes 1 0
rc=$(run)
[ "$rc" != 0 ] && ok "refuses when grub-probe cannot resolve the disk" || bad "proceeded with a broken chroot"
out | grep -q "MARKER_EXTRACT" && bad "overwrote the system, THEN found the chroot broken" || ok "extracted NOTHING - the ordering lesson holds"

echo "=== the good case ==="
setup yes 0 0
rc=$(run)
[ "$rc" = 0 ] && ok "restores" || bad "failed: $(out | tail -2)"
out | grep -q "MARKER_EXTRACT.*--exclude=/boot/picker" \
  && ok "never restores over the picker itself" || bad "would overwrite /boot/picker"
out | grep -q "MARKER_EXTRACT.*--exclude=/boot/grub/custom.cfg" \
  && ok "keeps the picker's GRUB entry (an old backup would not have it)" || bad "would drop the picker's menu entry"
out | grep -q "MARKER_EXTRACT.*-xpf" && ok "extracts preserving permissions" || bad "no -p"
out | grep -q "MARKER_UPDATE_GRUB" \
  && ok "regenerates the menu so it matches what is actually on disk" || bad "left a stale grub.cfg"

echo "=== a failed extract is reported honestly ==="
setup yes 0 2
rc=$(run)
[ "$rc" != 0 ] && ok "propagates the failure" || bad "reported success after tar failed"
out | grep -q "mix of restored and original" \
  && ok "says the system is in a mixed state, and what to do about it" || bad "no honest description of the state"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

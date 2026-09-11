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
  mkdir -p "$SB/root/usr/bin"; : > "$SB/root/usr/bin/tar"; chmod +x "$SB/root/usr/bin/tar"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/mount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/umount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/sync"
  # The target's own fstab, as it is before a restore overwrites it.
  mkdir -p "$SB/root/etc"
  echo "UUID=TARGET-UUID / ext4 defaults 0 1" > "$SB/root/etc/fstab"
  # What /proc/mounts would say: this device is mounted at the fake root.
  echo "/dev/fake-root $SB/root ext4 rw 0 0" > "$SB/mounts"
  cat > "$SB/bin/chroot" <<EOF
#!/bin/sh
case "\$*" in
  *grub-probe*)  exit $2 ;;
  *blkid*)       echo "\${BLKID_UUID-TARGET-UUID}"; exit \${BLKID_RC-0} ;;
  # A real extract replaces /etc/fstab with the ARCHIVE's copy. Without
  # modelling that, every fstab assertion below would pass against a
  # script that does nothing at all.
  *tar*)         echo "MARKER_EXTRACT \$*" >&2
                 echo "UUID=ARCHIVE-UUID / ext4 defaults 0 1" > "$SB/root/etc/fstab"
                 exit $3 ;;
  *update-grub*) echo "MARKER_UPDATE_GRUB" >&2; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$SB"/bin/*
}
run() { PATH="$SB/bin:$PATH" NIGHTFALL_MOUNTS="$SB/mounts" \
          sh "$S" "$SB/root" "$SB/target" bk >"$SB/out" 2>&1; echo $?; }
fstab() { cat "$SB/root/etc/fstab" 2>/dev/null; }
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
out | grep -q "MARKER_EXTRACT.*--exclude=/boot/nightfall" \
  && ok "never restores over Nightfall itself" || bad "would overwrite /boot/nightfall"
out | grep -q "MARKER_EXTRACT.*--exclude=/boot/grub/custom.cfg" \
  && ok "keeps Nightfall's GRUB entry (an old backup would not have it)" || bad "would drop Nightfall's menu entry"
out | grep -q "MARKER_EXTRACT.*-xpf" && ok "extracts preserving permissions" || bad "no -p"
out | grep -qE "MARKER_EXTRACT [^ ]+ /usr/bin/tar" \
  && ok "runs the target's GNU tar by absolute path, not busybox's applet" \
  || bad "bare or wrong tar path: $(out | grep -oE "MARKER_EXTRACT [^ ]+ [^ ]+" | head -1)"
out | grep -q "MARKER_UPDATE_GRUB" \
  && ok "regenerates the menu so it matches what is actually on disk" || bad "left a stale grub.cfg"

echo "=== a failed extract is reported honestly ==="
setup yes 0 2
rc=$(run)
[ "$rc" != 0 ] && ok "propagates the failure" || bad "reported success after tar failed"
out | grep -q "mix of restored and original" \
  && ok "says the system is in a mixed state, and what to do about it" || bad "no honest description of the state"

echo "=== fstab: a backup from THIS machine is left alone ==="
setup yes 0 0
# blkid reports the UUID the ARCHIVE's fstab names, i.e. same hardware.
export BLKID_UUID=ARCHIVE-UUID
rc=$(run)
[ "$rc" = 0 ] && ok "restores normally" || bad "failed: $(out | tail -2)"
fstab | grep -q "ARCHIVE-UUID" && ok "keeps the restored fstab" || bad "clobbered a correct fstab"
[ ! -f "$SB/root/etc/fstab.from-backup" ] && ok "no needless fstab.from-backup" || bad "saved a copy it did not need to"
out | grep -q "names this disk" && ok "says it checked and it matched" || bad "silent about the check"
unset BLKID_UUID

echo "=== fstab: a backup from DIFFERENT hardware is corrected ==="
# The recovery path this project promises: install a distro, install
# Nightfall, restore. The new filesystem has a different UUID, so the
# archive's fstab names a disk that is not in the machine.
setup yes 0 0
export BLKID_UUID=TARGET-UUID
rc=$(run)
[ "$rc" = 0 ] && ok "still restores" || bad "failed: $(out | tail -2)"
fstab | grep -q "TARGET-UUID" \
  && ok "puts back the fstab that matches the real disk" \
  || bad "left an fstab naming hardware that is not here: $(fstab)"
grep -q "ARCHIVE-UUID" "$SB/root/etc/fstab.from-backup" 2>/dev/null \
  && ok "keeps the archive's fstab as fstab.from-backup" || bad "discarded the archive's fstab"
out | grep -q "different hardware" && ok "explains why it swapped" || bad "swapped silently"
unset BLKID_UUID

echo "=== fstab: refuses to guess when it cannot tell ==="
setup yes 0 0
export BLKID_UUID=""; export BLKID_RC=2
rc=$(run)
[ "$rc" = 0 ] && ok "restore still succeeds" || bad "a blkid failure broke the restore"
fstab | grep -q "ARCHIVE-UUID" \
  && ok "leaves fstab exactly as restored rather than guessing" || bad "changed fstab on no evidence"
out | grep -q "could not read the UUID" && ok "says it could not tell" || bad "silent"
unset BLKID_UUID BLKID_RC

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

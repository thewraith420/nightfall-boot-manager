#!/bin/bash
# backup-system.sh against a fake root and a fake target.
#
# The interesting cases are the refusals: a backup that starts and dies
# 70GB in leaves a truncated archive that looks like a real one, so the
# checks have to happen before anything is written.
set -u
S=$(cd "$(dirname "$0")" && pwd)/backup-system.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# $1 = used KB on source, $2 = free KB on target, $3 = tar exit code
setup() {
  SB=$(mktemp -d)
  mkdir -p "$SB/root/mnt" "$SB/root/proc" "$SB/root/sys" "$SB/root/boot" \
           "$SB/root/usr/bin" "$SB/bin"
  : > "$SB/root/usr/bin/tar"; chmod +x "$SB/root/usr/bin/tar"
  : > "$SB/root/boot/vmlinuz-1.2.3"
  : > "$SB/target"                       # stands in for the block device
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/mount"
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/umount"
  cat > "$SB/bin/df" <<EOF
#!/bin/sh
# \$3 is used, \$4 is avail on the NR==2 line
case "\$*" in
  *mnt*) echo "fs 1 1 $2 1% /mnt" ;;
  *)     echo "fs 1 $1 1 1% /" ;;
esac
EOF
  printf '#!/bin/sh\necho "df header"\nexit 0\n' > /dev/null
  cat > "$SB/bin/chroot" <<EOF
#!/bin/sh
echo "MARKER_TAR \$*" >&2
exit $3
EOF
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/sync"
  chmod +x "$SB"/bin/*
  # df must print a header line first (awk takes NR==2)
  cat > "$SB/bin/df" <<EOF
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted"
case "\$*" in
  *mnt*) echo "t 1 1 $2 1% /mnt" ;;
  *)     echo "s 1 $1 1 1% /" ;;
esac
EOF
  chmod +x "$SB/bin/df"
}
run() { PATH="$SB/bin:$PATH" sh "$S" "$SB/root" "$SB/target" testbk >"$SB/out" 2>&1; echo $?; }
out() { cat "$SB/out"; }

echo "=== refuses when the target is too small ==="
setup 80000000 1000000 0          # 80G used, ~1G free
rc=$(run)
[ "$rc" != 0 ] && ok "refuses rather than filling the drive" || bad "started anyway (rc=$rc)"
out | grep -q "not enough room" && ok "says how much is needed" || bad "unclear: $(out | tail -1)"
out | grep -q "MARKER_TAR" && bad "ran tar before checking space" || ok "checked space BEFORE writing anything"

echo "=== proceeds when there is room ==="
setup 10000000 900000000 0        # 10G used, ~900G free
rc=$(run)
[ "$rc" = 0 ] && ok "runs to completion" || bad "failed with room available: $(out | tail -2)"
out | grep -q "MARKER_TAR.*--exclude=/mnt" && ok "excludes the target mount (no self-swallowing)" || bad "missing /mnt exclusion"
out | grep -q "MARKER_TAR.*--exclude=/proc" && ok "excludes pseudo-filesystems" || bad "missing /proc exclusion"
out | grep -qE "MARKER_TAR.*(-cf|--checkpoint)" && ok "creates the archive with progress reporting" || bad "no checkpoint/create flags"
# Ubuntu's busybox is FEATURE_SH_STANDALONE, so a bare "tar" is resolved
# from busybox's applet table instead of the chroot's GNU tar - which
# printed usage and killed a real backup attempt. The path must be
# absolute.
out | grep -qE "MARKER_TAR [^ ]+ /usr/bin/tar" \
  && ok "runs the target's GNU tar by absolute path, not busybox's applet" \
  || bad "bare or wrong tar path: $(out | grep -oE "MARKER_TAR [^ ]+ [^ ]+" | head -1)"
[ -f "$SB/root/mnt/nocturne-backups/testbk.info" ] && ok "writes an .info sidecar" || bad "no sidecar"
grep -q -- "- 1.2.3" "$SB/root/mnt/nocturne-backups/testbk.info" 2>/dev/null \
  && ok "sidecar records which kernels were in the backup" || bad "sidecar missing kernel list"

echo "=== a failing tar is reported, not silently 'done' ==="
setup 10000000 900000000 2
rc=$(run)
[ "$rc" != 0 ] && ok "propagates tar's failure" || bad "reported success after tar failed"
out | grep -q "should not be trusted" && ok "says the archive is incomplete" || bad "no warning about the partial archive"

echo "=== missing pieces are refused up front ==="
setup 10000000 900000000 0
rm -f "$SB/root/usr/bin/tar"
rc=$(run)
[ "$rc" != 0 ] && ok "refuses when the target system has no tar" || bad "proceeded without tar"

setup 10000000 900000000 0
rmdir "$SB/root/mnt"
rc=$(run)
[ "$rc" != 0 ] && ok "refuses when there is nowhere to mount the target" || bad "proceeded without a mountpoint"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

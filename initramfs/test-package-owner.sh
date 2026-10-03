#!/bin/bash
# Exercises package-owner.sh directly against fake dpkg/pacman/rpm trees.
#
# remove-kernel.sh's own tests (test-remove-kernel.sh) cover dpkg and
# pacman end to end already, since those need no mocking - this file
# adds the rpm path (which DOES need a mock, since nothing here has a
# real rpm binary) and a few edge cases not worth duplicating per-caller.
#
#   bash initramfs/test-package-owner.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$REPO/initramfs/package-owner.sh
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT

echo "=== nothing installed at all ==="
rc=0; out=$(sh "$SCRIPT" "$SB" /boot/vmlinuz-x 2>&1) || rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok "exits 1 with no output - unowned, not an error" || bad "rc=$rc out=[$out]"

echo "=== dpkg ==="
mkdir -p "$SB/var/lib/dpkg/info"
printf '/boot/vmlinuz-5.15\n/boot/initrd.img-5.15\n' > "$SB/var/lib/dpkg/info/linux-image-5.15-generic.list"
out=$(sh "$SCRIPT" "$SB" /boot/vmlinuz-5.15)
[ "$out" = "linux-image-5.15-generic" ] && ok "finds the owning package by exact path" || bad "got: $out"
rc=0; out=$(sh "$SCRIPT" "$SB" /boot/vmlinuz-5.16 2>&1) || rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok "a kernel not in any .list is unowned" || bad "rc=$rc out=[$out]"
printf '/boot/vmlinuz-5.17\n' > "$SB/var/lib/dpkg/info/linux-image-5.17-generic:amd64.list"
out=$(sh "$SCRIPT" "$SB" /boot/vmlinuz-5.17)
[ "$out" = "linux-image-5.17-generic" ] && ok "a multi-arch :amd64.list reports the bare package name" || bad "got: $out"
rm -rf "$SB/var/lib/dpkg"

echo "=== pacman ==="
mkdir -p "$SB/var/lib/pacman/local/linux-6.1.0-1"
printf 'boot/vmlinuz-linux\n' > "$SB/var/lib/pacman/local/linux-6.1.0-1/files"
printf '%%NAME%%\nlinux\n%%VERSION%%\n6.1.0-1\n' > "$SB/var/lib/pacman/local/linux-6.1.0-1/desc"
out=$(sh "$SCRIPT" "$SB" /boot/vmlinuz-linux)
[ "$out" = "linux" ] && ok "finds the owning package via desc, not the versioned directory name" || bad "got: $out"
mkdir -p "$SB/var/lib/pacman/local/orphan-pkg-1"
printf 'boot/vmlinuz-orphan\n' > "$SB/var/lib/pacman/local/orphan-pkg-1/files"
# No desc file at all - falls back to the directory name rather than nothing.
out=$(sh "$SCRIPT" "$SB" /boot/vmlinuz-orphan)
[ "$out" = "orphan-pkg-1" ] && ok "falls back to the versioned directory name when desc is unreadable" || bad "got: $out"
rc=0; out=$(sh "$SCRIPT" "$SB" /boot/vmlinuz-not-in-pacman 2>&1) || rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok "a kernel not in any files list is unowned" || bad "rc=$rc out=[$out]"
rm -rf "$SB/var/lib/pacman"

echo "=== rpm (needs the real binary, so chroot is mocked) ==="
mkdir -p "$SB/usr/bin"
: > "$SB/usr/bin/rpm"; chmod +x "$SB/usr/bin/rpm"
PATH_SAVE=$PATH
mkdir -p "$SB/fakebin"
cat > "$SB/fakebin/chroot" <<'EOF'
#!/bin/sh
# $1=root $2=rpm $3=-qf $4=--qf $5=fmt $6=path
case "$6" in
  /boot/vmlinuz-rpm-owned)  echo "kernel-core" ;;
  /boot/vmlinuz-rpm-orphan) echo "error: file /boot/vmlinuz-rpm-orphan is not owned by any package" >&2; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$SB/fakebin/chroot"
export PATH="$SB/fakebin:$PATH_SAVE"
out=$(sh "$SCRIPT" "$SB" /boot/vmlinuz-rpm-owned)
[ "$out" = "kernel-core" ] && ok "asks rpm via chroot when the binary is present" || bad "got: $out"
rc=0; out=$(sh "$SCRIPT" "$SB" /boot/vmlinuz-rpm-orphan 2>&1) || rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok "'not owned by any package' is reported as unowned, not an error" || bad "rc=$rc out=[$out]"
export PATH=$PATH_SAVE
rm -rf "$SB/usr/bin/rpm"

echo "=== usage ==="
rc=0; sh "$SCRIPT" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && ok "refuses with no arguments" || bad "accepted no arguments"
rc=0; sh "$SCRIPT" "$SB" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && ok "refuses with only a root, no path" || bad "accepted a missing path argument"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

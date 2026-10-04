#!/bin/bash
# Every script that runs INSIDE the initramfs may only call commands the
# image is guaranteed to ship: the $APPLETS list build-initramfs.sh
# refuses to build without, plus the binaries it installs (kexec, e2fsck,
# efibootmgr, nightfall) and the scripts themselves.
#
# Host tests cannot catch a violation - the dev machine has every command
# - and whether an unlisted busybox applet works in the image depends on
# which distro's busybox built it (Ubuntu's shell runs unlinked applets,
# Debian's does not). That is how sed and dirname worked on the Slate and
# failed on the LOQ, breaking drive scans and external-drive boot there.
#
#   bash initramfs/test-runtime-applets.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# The guaranteed list, read from build-initramfs.sh so the two cannot drift.
applets=$(awk '/^APPLETS="/{f=1} f{print} f&&/"$/{exit}' "$here/build-initramfs.sh" \
          | tr -d '"' | sed 's/^APPLETS=//' | tr -s ' \n' '\n')
[ -n "$applets" ] || { echo "could not read APPLETS from build-initramfs.sh"; exit 1; }

# Ordinary commands a shell script might reach for. Any of these that is
# NOT in the guaranteed list must not appear in command position.
candidates='sed tr sort uniq cp ln chmod chown dirname basename readlink realpath find xargs
            lsblk blkid seq stat timeout getopt mktemp install expr touch head tail cut wc
            awk grep od tee mv rm mkdir losetup df dd sha256sum md5sum'
forbidden=""
for c in $candidates; do
    printf '%s\n' "$applets" | grep -qx "$c" || forbidden="$forbidden${forbidden:+|}$c"
done

echo "=== the applets the image guarantees include the ones that broke on the LOQ ==="
for c in sed tr dirname basename; do
    printf '%s\n' "$applets" | grep -qx "$c" && ok "$c is in APPLETS" || bad "$c is not in APPLETS"
done

echo "=== runtime scripts call only what the image guarantees ==="
scripts=$(sed -n 's/.*install -m 0755 "\$here\/\([A-Za-z0-9_.-]*\.sh\)".*/\1/p' "$here/build-initramfs.sh")
for f in $scripts init; do
    [ -f "$here/$f" ] || { bad "$f is installed by build-initramfs.sh but missing"; continue; }
    if [ -z "$forbidden" ]; then ok "$f"; continue; fi
    hits=$(sed 's/#.*$//' "$here/$f" \
           | grep -nE "(^|[;&|(\`]|\\\$\\(|then|else|do)[[:space:]]*($forbidden)([[:space:]]|$)" || true)
    if [ -z "$hits" ]; then ok "$f"; else bad "$f calls something the image may not ship: $hits"; fi
done

echo "=== and the build links every applet busybox has, not only the list ==="
grep -q 'for a in \$(busybox --list)' "$here/build-initramfs.sh" \
  && ok "build-initramfs.sh links the full busybox applet list" \
  || bad "build-initramfs.sh links only \$APPLETS - Debian's busybox will miss the rest"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

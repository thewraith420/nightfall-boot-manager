#!/bin/bash
# Every script that runs INSIDE the initramfs may only call what the
# initramfs actually ships. Host tests cannot catch a violation: the dev
# machine has dirname, basename, etc., so a call that works here silently
# fails on the target - scan-drives.sh read nothing for exactly this reason.
#
#   bash initramfs/test-runtime-applets.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# Commands the initramfs does not have. Add here only with a real reason.
forbidden='dirname|basename|readlink|realpath|find|xargs|lsblk|blkid|seq|stat|timeout|getopt|mktemp|install|cp|ln|chmod|chown|tr|sed|sort|uniq|expr'

for f in scan-drives.sh discover-backup-targets.sh discover-bootable-drives.sh discover-backups.sh \
         discover-tarballs.sh discover-live-isos.sh boot-live-iso.sh remove-kernel.sh \
         install-kernel.sh package-owner.sh apply-cmdline.sh apply-default.sh clear-overrides.sh \
         kexec-preflight.sh init; do
    [ -f "$here/$f" ] || continue
    # Strip comments and quoted text, then look for a forbidden command in command position.
    hits=$(sed 's/#.*$//' "$here/$f" | grep -nE "(^|[;&|(\`]|\\$\\()[[:space:]]*($forbidden)([[:space:]]|$)" || true)
    if [ -z "$hits" ]; then ok "$f"; else bad "$f: $hits"; fi
done

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

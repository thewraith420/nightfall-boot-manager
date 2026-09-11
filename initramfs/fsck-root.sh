#!/bin/sh
# Checks and repairs the root filesystem, from Nightfall.
#
#   fsck-root.sh <root-mount> [preen|force]
#
# THIS IS THE ONE REPAIR NIGHTFALL DOES BETTER THAN UBUNTU'S RECOVERY
# MODE, and the reason is structural rather than clever. Recovery mode
# runs fsck with / still mounted, because recovery mode IS the system on
# that disk - e2fsck then refuses most repairs, since changing a mounted
# filesystem underneath a running kernel corrupts it.
#
# Nightfall lives in the initramfs. Nothing it needs is on the root
# filesystem once the menu is drawn, so it can UNMOUNT the root entirely
# and give e2fsck a filesystem nobody is touching. That is the only
# state in which a full repair is safe.
#
# TWO MODES, because they carry different risk:
#
#   preen (default)  e2fsck -f -p. Fixes only what is unambiguously
#                    safe to fix without asking. Exits 4 if it meets
#                    anything needing a human decision, having changed
#                    nothing about it.
#   force            e2fsck -f -y. Answers yes to everything, including
#                    decisions that can move damaged files to
#                    lost+found. Correct when the alternative is a
#                    machine that will not boot, wrong as a first
#                    resort - hence a separate, clearly-labelled action
#                    rather than an automatic escalation.
#
# THE DANGEROUS PART IS NOT THE CHECK, IT IS THE UNMOUNT. init kexecs a
# kernel it reads from <root>/boot, so leaving the root unmounted turns
# a successful repair into a machine that cannot boot. The remount is
# therefore a trap, it is verified, and a failure to remount is reported
# as loudly as the script can manage.
set -eu

root=${1:?usage: fsck-root.sh <root-mount> [preen|force]}
mode=${2:-preen}

say() { echo "fsck: $*" >&2; }
die() { echo "fsck: ERROR: $*" >&2; exit 1; }

case "$mode" in
    preen|force) ;;
    *) die "unknown mode '$mode' (expected preen or force)" ;;
esac

[ -d "$root" ] || die "root mount $root is not a directory"

FSCK=${NIGHTFALL_FSCK:-/sbin/e2fsck}
[ -x "$FSCK" ] || die "$FSCK is not available in this initramfs"

# The device actually mounted at $root, read from /proc/mounts rather
# than taken on trust. A checker pointed at the wrong block device by a
# stale default is worse than no checker at all.
MOUNTS=${NIGHTFALL_MOUNTS:-/proc/mounts}
dev=$(awk -v m="$root" '$2 == m { print $1; exit }' "$MOUNTS" 2>/dev/null || true)
[ -n "$dev" ] || die "nothing is mounted at $root - cannot tell which device to check"
say "root filesystem is $dev"

# Anything mounted UNDER the root has to go first or the unmount fails.
# A backup or restore leaves <root>/mnt behind if it was interrupted.
for sub in $(awk -v m="$root/" '$2 ~ "^"m { print $2 }' "$MOUNTS" 2>/dev/null | sort -r); do
    say "unmounting $sub first"
    umount "$sub" 2>/dev/null || die "could not unmount $sub - cannot check the filesystem"
done

# ------------------------------------------------------- remount on the way out
# Set BEFORE the unmount, so every path out of here goes through it.
remounted=0
restore_root() {
    [ "$remounted" = 1 ] && return 0
    if mount -o ro "$dev" "$root" 2>/dev/null; then
        remounted=1
        say "root remounted read-only"
    else
        # This is the bad one. Say so in terms that survive being read
        # off a photograph of a tablet screen.
        echo "" >&2
        echo "fsck: ================================================" >&2
        echo "fsck: COULD NOT REMOUNT $dev AT $root." >&2
        echo "fsck: Nightfall needs it to read the kernel it boots." >&2
        echo "fsck: Do NOT power off - go Back and pick a kernel; if" >&2
        echo "fsck: that fails, power-cycle and choose Repair again." >&2
        echo "fsck: ================================================" >&2
    fi
}
trap restore_root EXIT

say "unmounting $root so the check has the filesystem to itself"
umount "$root" || die "could not unmount $root - something is still using it"

if [ "$mode" = force ]; then
    say "running a FULL repair (answers yes to everything, may move damage to lost+found)"
    set -- -f -y -C 0 "$dev"
else
    say "running a safe check (fixes only what needs no decision)"
    set -- -f -p -C 0 "$dev"
fi

rc=0
"$FSCK" "$@" || rc=$?

# e2fsck's exit status is a BITMASK, and 0 is not the only success. A
# repair that worked returns 1; treating "not zero" as failure would
# report a fixed filesystem as a broken one, which is exactly the sort
# of wrong answer that sends someone reinstalling.
case "$rc" in
    0)  say "RESULT: clean - no errors found" ;;
    1)  say "RESULT: errors found and CORRECTED" ;;
    2)  say "RESULT: errors corrected - reboot before using the system" ;;
    3)  say "RESULT: errors corrected, some need a reboot" ;;
    4)  say "RESULT: errors found that were NOT fixed"
        [ "$mode" = preen ] && say "this needs the Full repair action, which answers yes on your behalf" ;;
    8)  say "RESULT: e2fsck could not operate on $dev (is it really ext4?)" ;;
    16) say "RESULT: e2fsck usage error - this is a bug in Nightfall" ;;
    32) say "RESULT: check was cancelled" ;;
    *)  say "RESULT: e2fsck exited $rc" ;;
esac

restore_root

# Only a genuinely unfixed or broken filesystem counts as a failure for
# the caller; a successful repair does not.
case "$rc" in
    0|1|2|3) exit 0 ;;
    *)       exit 1 ;;
esac

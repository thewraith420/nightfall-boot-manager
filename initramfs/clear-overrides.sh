#!/bin/sh
# Clears the settings Nightfall itself persists, from Nightfall.
#
#   clear-overrides.sh <root-mount> [default|cmdline|all]
#
# The escape hatch from self-inflicted breakage, and the one repair
# Ubuntu's recovery menu has no equivalent for - because these are
# Nightfall's own files, not the system's.
#
#   /boot/nightfall-default   the kernel "Set Default" remembered
#   /boot/nightfall-cmdline   per-kernel command line overrides
#
# The reason this needs to exist: apply-cmdline.sh folds a saved command
# line into the menu BEFORE the menu is drawn, so what Edit shows is what
# boots. That is the right design, but it means a saved cmdline which
# stops the machine booting is invisible - the menu looks normal and the
# boot fails anyway. Per-kernel "Forget saved" exists inside Edit, but
# needing to guess WHICH kernel carries the bad line is a poor position
# to be in when nothing boots.
#
# Deleting these files is entirely safe. apply-default.sh treats a
# missing marker as "no marker" and apply-cmdline.sh treats a missing
# file as "no overrides", so the machine simply goes back to booting
# what grub.cfg says.
set -eu

root=${1:?usage: clear-overrides.sh <root-mount> [default|cmdline|all]}
what=${2:-all}

say() { echo "clear: $*" >&2; }
die() { echo "clear: ERROR: $*" >&2; exit 1; }

case "$what" in
    default|cmdline|all) ;;
    *) die "unknown target '$what' (expected default, cmdline or all)" ;;
esac

[ -d "$root" ] || die "root mount $root is not a directory"

cleanup() {
    mount -o remount,ro "$root" 2>/dev/null || \
        say "WARNING: could not remount $root read-only again"
}
trap cleanup EXIT

say "remounting $root read-write"
mount -o remount,rw "$root" || die "could not remount $root read-write"

cleared=0

if [ "$what" = default ] || [ "$what" = all ]; then
    f=$root/boot/nightfall-default
    if [ -f "$f" ]; then
        say "saved default was: $(cat "$f" 2>/dev/null || echo '(unreadable)')"
        rm -f "$f" && { say "cleared the saved default kernel"; cleared=$((cleared + 1)); }
    else
        say "no saved default to clear"
    fi
fi

if [ "$what" = cmdline ] || [ "$what" = all ]; then
    f=$root/boot/nightfall-cmdline
    if [ -f "$f" ]; then
        n=$(wc -l < "$f" 2>/dev/null || echo 0)
        say "saved command lines for $n kernel(s):"
        # Show what is being thrown away. If one of these is what broke
        # the boot, reading it is how you find out what not to do again.
        cut -f1 "$f" 2>/dev/null | while read -r k; do
            [ -n "$k" ] && say "  $k"
        done
        rm -f "$f" && { say "cleared all saved command lines"; cleared=$((cleared + 1)); }
    else
        say "no saved command lines to clear"
    fi
fi

sync

if [ "$cleared" = 0 ]; then
    say "nothing needed clearing - Nightfall was not overriding anything"
else
    say "done - the next boot uses exactly what grub.cfg says"
fi
exit 0

#!/bin/sh
# Installs the picker kernel + initramfs and adds a GRUB menu entry for
# them, without touching anything else about how this machine boots.
#
#   sudo ./install-nightfall.sh <vmlinuz> <initramfs.img>
#   sudo ./install-nightfall.sh --uninstall
#
# Deliberately conservative, because the failure mode is "this laptop
# now boots into a stripped-down kernel by default". Three properties,
# each structural rather than a matter of remembering to be careful:
#
#   1. Files go in /boot/nightfall/, a SUBDIRECTORY. GRUB's 10_linux
#      auto-detection globs /boot/vmlinuz-* and does not recurse, so a
#      kernel here can never be picked up and turned into a menu entry
#      on its own - not now, and not during some future apt upgrade
#      that regenerates grub.cfg at a moment nobody is watching.
#
#   2. The menu entry goes in /boot/grub/custom.cfg, which
#      /etc/grub.d/41_custom sources at boot time. So this NEVER runs
#      update-grub/grub-mkconfig: the existing menu is not regenerated,
#      not reordered, and no other entry changes position. Running the
#      kernel's own install.sh would regenerate the menu, which is what
#      this script exists to avoid.
#
#   3. The entry is appended, so with GRUB_DEFAULT=0 it cannot become
#      the default. The script refuses to run if GRUB_DEFAULT is
#      'saved', where booting the picker once would silently make it
#      the permanent default.
#
# Undo is `--uninstall`, or by hand: delete /boot/nightfall and the marked
# block in /boot/grub/custom.cfg. Nothing else was modified.

set -eu

# Overridable only so the migration can be tested against a sandbox
# rather than a real /boot. The defaults are the real thing.
BOOT=${NIGHTFALL_BOOT:-/boot}
GRUB_DEFAULT_FILE=${NIGHTFALL_GRUB_DEFAULT:-/etc/default/grub}

BEGIN_MARK="### BEGIN nightfall-boot-manager ###"
END_MARK="### END nightfall-boot-manager ###"
# What this project was called until 2026-09-09. Kept so an upgrade can
# find and remove the old block: without this the old "Boot Picker"
# entry would remain in custom.cfg beside the new one, leaving GRUB
# showing two entries when only one still has files behind it.
OLD_BEGIN_MARK="### BEGIN nocturne-boot-picker ###"
OLD_END_MARK="### END nocturne-boot-picker ###"
OLD_DIR=$BOOT/picker

NIGHTFALL_DIR=$BOOT/nightfall
CUSTOM_CFG=$BOOT/grub/custom.cfg

die() { echo "install-nightfall: $*" >&2; exit 1; }
say() { echo "==> $*"; }

# Root is needed because this writes to /boot and /etc/default/grub.
# When BOOT has been pointed at a sandbox it is writing to neither, so
# the check would only stop the migration from being testable.
if [ "$BOOT" = /boot ] && [ "$(id -u)" != 0 ]; then
    die "needs root (writes to /boot). Re-run with sudo."
fi

# --------------------------------------------------------------- uninstall

if [ "${1:-}" = "--uninstall" ]; then
    if [ -f "$CUSTOM_CFG" ]; then
        say "removing the Nightfall entry from $CUSTOM_CFG"
        sed -i "/$BEGIN_MARK/,/$END_MARK/d" "$CUSTOM_CFG"
        sed -i "/$OLD_BEGIN_MARK/,/$OLD_END_MARK/d" "$CUSTOM_CFG"
        # leave an empty custom.cfg rather than deleting it; something
        # else may be relying on it existing
        [ -s "$CUSTOM_CFG" ] || say "$CUSTOM_CFG is now empty (left in place)"
    fi
    for d in "$NIGHTFALL_DIR" "$OLD_DIR"; do
        if [ -d "$d" ]; then
            say "removing $d"
            rm -rf "$d"
        fi
    done
    rm -f "$BOOT"/nightfall-default "$BOOT"/nightfall-cmdline "$BOOT"/nightfall-timeout \
          "$BOOT"/nightfall-rotate "$BOOT"/nightfall-autorotate \
          "$BOOT"/nightfall-last-boot.log \
          "$BOOT"/picker-default "$BOOT"/picker-cmdline "$BOOT"/picker-last-boot.log 2>/dev/null || true
    say "done - no grub regeneration was needed, and nothing else was touched"
    exit 0
fi

# ---------------------------------------------------------------- install

kernel=${1:-}
initramfs=${2:-}
[ -n "$kernel" ] && [ -n "$initramfs" ] || \
    die "usage: install-nightfall.sh <vmlinuz> <initramfs.img>
       install-nightfall.sh --uninstall"
[ -r "$kernel" ]    || die "cannot read kernel image: $kernel"
[ -r "$initramfs" ] || die "cannot read initramfs: $initramfs"

case $(file -b "$kernel" 2>/dev/null) in
    *"Linux kernel"*|*"bzImage"*) : ;;
    *) die "$kernel does not look like a Linux kernel image" ;;
esac

# The one configuration that could still make this the default boot.
grub_default=$(grep -E '^GRUB_DEFAULT=' "$GRUB_DEFAULT_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
case $grub_default in
    saved)
        die "GRUB_DEFAULT=saved on this system.
  With 'saved', booting Nightfall once would make it the permanent
  default - the opposite of the intended rollout. Set GRUB_DEFAULT=0
  first, or add the entry by hand knowing the consequence." ;;
    ''|0) : ;;
    picker|nightfall)
       # Deliberate: Bob made Nightfall the default during testing, and
       # "picker" is the same intent under the old id, migrated below.
       : ;;
    *) echo "install-nightfall: note: GRUB_DEFAULT=$grub_default (not 0)." >&2
       echo "  The Nightfall entry is appended last, so it should not become" >&2
       echo "  the default on its own - double-check that's what you expect." >&2 ;;
esac

# -------------------------------------------- decide the display options
# BEFORE anything is copied into /boot. Everything below can refuse, and
# refusing after the kernel and initramfs had already been replaced would
# leave a half-finished install: new images under an entry still carrying
# the old options. Same rule as everywhere else here - check first, then
# do the irreversible part.

# The picker kernel needs the same panel quirks every other entry on
# this machine already carries. Without i915.enable_dpcd_backlight=2 and
# i915.enable_psr=0 the Slate's panel produces NO VISIBLE OUTPUT - and
# it fails silently in the worst way: drmModeSetCrtc returns success, so
# picker's own error handling has nothing to catch. Modeset works, the
# backlight simply never lights. That cost a boot cycle where the entire
# chain (root mount, discovery, DRM, touch, render, timeout, kexec) ran
# perfectly against a black screen.
#
# Rather than hardcode the quirks, take them from /proc/cmdline: the
# running system is BY DEFINITION a working display configuration on
# this hardware, so whatever makes the panel light up now gets carried
# to the picker. Only i915.* is copied - root=, quiet, splash and
# crashkernel belong to the real OS, not to an initramfs that mounts its
# own root and wants its diagnostics visible.
#
# THAT PREMISE HAS TO BE CHECKED, NOT ASSUMED. It holds for a normal boot
# and fails for exactly the boots someone reinstalls from. A GRUB
# recovery entry is `ro recovery nomodeset dis_ucode_ldr`: with nomodeset
# the panel lights by a non-KMS path and /proc/cmdline carries no i915
# options at all. Reinstalling from there used to write an empty set into
# Nightfall's entry, and on this panel an empty set is a black screen -
# with only a note on stderr to say so. Recovery mode is precisely when
# someone reaches for a reinstall. (Found by the chromebook-linux-fixer
# session, which refuses the same case before calling this script.)
#
# So, unless NIGHTFALL_CMDLINE says explicitly what to use, refuse:
#   - a boot whose cmdline contains nomodeset or recovery
#   - no i915 options on this boot while the existing entry has some
#   - an unreadable /proc/cmdline
# Still allowed: a first install, a panel that genuinely needs none,
# fewer options than before (a revert), and any explicit NIGHTFALL_CMDLINE.
#
# NIGHTFALL_PROC_CMDLINE is a test seam and nothing else.
PROC_CMDLINE=${NIGHTFALL_PROC_CMDLINE:-/proc/cmdline}
override_hint="  If you are sure, say explicitly what to use - note sudo's placement:
    sudo NIGHTFALL_CMDLINE='i915.enable_dpcd_backlight=2 i915.enable_psr=0' $0 ...
  (NIGHTFALL_CMDLINE=... sudo ... loses the variable: sudo resets the environment.)"

if [ -n "${NIGHTFALL_CMDLINE+x}" ]; then
    nightfall_cmdline=$NIGHTFALL_CMDLINE
    say "using NIGHTFALL_CMDLINE from the environment"
else
    [ -r "$PROC_CMDLINE" ] || die "cannot read $PROC_CMDLINE, so the display options for
  Nightfall's entry cannot be derived.
$override_hint"
    running=$(cat "$PROC_CMDLINE")
    for word in $running; do
        case "$word" in
            nomodeset|recovery)
                die "this boot's command line contains '$word' - a recovery or
  non-modesetting boot is not a working display configuration for Nightfall,
  and deriving its options from here would write a set that leaves it dark.
  Reinstall from a normal boot instead.
$override_hint" ;;
        esac
    done
    nightfall_cmdline=$(printf '%s\n' $running | grep '^i915\.' | tr '\n' ' ' | sed 's/ *$//')

    if [ -z "$nightfall_cmdline" ] && [ -f "$CUSTOM_CFG" ]; then
        existing=$(sed -n "/$BEGIN_MARK/,/$END_MARK/p; /$OLD_BEGIN_MARK/,/$OLD_END_MARK/p" "$CUSTOM_CFG" \
                   | grep -E '^[[:space:]]*linux[[:space:]]' | tr ' \t' '\n\n' | grep '^i915\.' \
                   | tr '\n' ' ' | sed 's/ *$//')
        [ -z "$existing" ] || die "this boot has no i915 options, but the current Nightfall
  entry has: $existing
  Replacing them with nothing would very likely leave Nightfall dark.
$override_hint"
    fi
fi

if [ -n "$nightfall_cmdline" ]; then
    say "Nightfall kernel cmdline: $nightfall_cmdline"
else
    echo "install-nightfall: note: no i915.* options found in /proc/cmdline, so the" >&2
    echo "  Nightfall entry gets a bare kernel line. If Nightfall boots to a black" >&2
    echo "  screen but the boot log shows it ran fine, this is the first suspect:" >&2
    echo "  set NIGHTFALL_CMDLINE='...' and re-run." >&2
fi

say "installing into $NIGHTFALL_DIR (invisible to GRUB auto-detection)"
mkdir -p "$NIGHTFALL_DIR"
cp "$kernel"    "$NIGHTFALL_DIR/vmlinuz"
cp "$initramfs" "$NIGHTFALL_DIR/initramfs.img"
chmod 0644 "$NIGHTFALL_DIR/vmlinuz" "$NIGHTFALL_DIR/initramfs.img"

# Resolve the GRUB device spec for whatever /boot lives on, so the
# entry works whether or not /boot is its own partition.
boot_uuid=$(findmnt -no UUID --target /boot 2>/dev/null || true)
[ -n "$boot_uuid" ] || die "could not determine the UUID of the filesystem holding /boot"

# Paths inside the entry must be relative to that filesystem's root:
# with a separate /boot partition the leading /boot is not part of the
# path GRUB sees.
if findmnt -no TARGET --target /boot | grep -qx /boot; then
    kpath=/nightfall/vmlinuz
    ipath=/nightfall/initramfs.img
else
    kpath=/boot/nightfall/vmlinuz
    ipath=/boot/nightfall/initramfs.img
fi

say "adding menu entry to $CUSTOM_CFG (no grub regeneration)"
touch "$CUSTOM_CFG"
# Replace any previous block so re-running doesn't stack duplicates.
sed -i "/$BEGIN_MARK/,/$END_MARK/d" "$CUSTOM_CFG"
sed -i "/$OLD_BEGIN_MARK/,/$OLD_END_MARK/d" "$CUSTOM_CFG"
cat >> "$CUSTOM_CFG" <<EOF
$BEGIN_MARK
# Added by nightfall-boot-manager/boot-integration/install-nightfall.sh
# Remove this block (or run install-nightfall.sh --uninstall) to undo.
# This entry's id is 'nightfall'. Whether it is the DEFAULT is decided
# by GRUB_DEFAULT in /etc/default/grub, not here: set it to 'nightfall'
# to boot this without touching the menu, or to 0 for the first entry.
menuentry 'Nightfall (touch)' --id nightfall {
        insmod gzio
        insmod part_gpt
        insmod ext2
        search --no-floppy --fs-uuid --set=root $boot_uuid
        linux   $kpath $nightfall_cmdline
        initrd  $ipath
}
$END_MARK
EOF

# ------------------------------------------------- migrating from "picker"
# Two things carry over from before the rename, and losing either is
# silent rather than loud, which is why they are handled here rather
# than left to the user.

# 1. Saved state. nightfall-default holds the chosen default kernel and
#    nightfall-cmdline the per-kernel command lines. Under the old names
#    the new code simply reads them as absent - no error, settings just
#    quietly gone. Never overwrites an existing new file.
for pair in "picker-default nightfall-default" "picker-cmdline nightfall-cmdline"; do
    old_f=$BOOT/$(echo "$pair" | cut -d" " -f1)
    new_f=$BOOT/$(echo "$pair" | cut -d" " -f2)
    if [ -f "$old_f" ] && [ ! -f "$new_f" ]; then
        if mv "$old_f" "$new_f"; then
            say "carried over $old_f -> $new_f"
        else
            echo "install-nightfall: could not move $old_f - your saved setting may be lost" >&2
        fi
    fi
done

# 2. GRUB_DEFAULT. The menu entry's --id changed from picker to
#    nightfall, and GRUB_DEFAULT names that id. Left alone it would stop
#    resolving and GRUB would fall back to the first entry - not fatal,
#    but on a machine with no keyboard you cannot pick from the menu, so
#    you would simply stop booting into Nightfall with no obvious cause.
#
#    This is the ONE place this script runs update-grub, against its own
#    rule elsewhere: `set default=` lives in the generated grub.cfg, so
#    changing /etc/default/grub alone would achieve nothing. It only
#    happens when GRUB_DEFAULT is literally the old id, and it verifies
#    the result, restoring the previous file if the regeneration did not
#    take.
if [ "$grub_default" = picker ]; then
    say "GRUB_DEFAULT=picker names the old entry id - updating it to nightfall"
    cp "$GRUB_DEFAULT_FILE" "$GRUB_DEFAULT_FILE.nightfall-bak"
    sed -i 's/^GRUB_DEFAULT=picker[[:space:]]*$/GRUB_DEFAULT=nightfall/' "$GRUB_DEFAULT_FILE"

    if grep -q "^GRUB_DEFAULT=nightfall" "$GRUB_DEFAULT_FILE" && update-grub >/dev/null 2>&1 \
       && grep -q "set default=[\"']*nightfall" "$BOOT/grub/grub.cfg"; then
        say "GRUB default now resolves to the Nightfall entry"
        rm -f "$GRUB_DEFAULT_FILE.nightfall-bak"
    else
        echo "install-nightfall: WARNING: could not repoint GRUB_DEFAULT." >&2
        echo "  Restoring $GRUB_DEFAULT_FILE from the backup taken a moment ago." >&2
        echo "  Nightfall is installed and selectable, but will not be the default" >&2
        echo "  until GRUB_DEFAULT=nightfall and update-grub have both succeeded." >&2
        mv -f "$GRUB_DEFAULT_FILE.nightfall-bak" "$GRUB_DEFAULT_FILE"
    fi
fi

say "installed:"
echo "    $NIGHTFALL_DIR/vmlinuz        ($(du -h "$NIGHTFALL_DIR/vmlinuz" | cut -f1))"
echo "    $NIGHTFALL_DIR/initramfs.img  ($(du -h "$NIGHTFALL_DIR/initramfs.img" | cut -f1))"
echo "    menu entry 'Nightfall (touch)' appended to $CUSTOM_CFG"
echo
echo "  grub.cfg was NOT regenerated and no existing entry moved."
echo "  Reboot and choose 'Nightfall (touch)' from the menu; every"
echo "  normal entry still boots exactly as before. Undo at any time:"
echo "    sudo $0 --uninstall"

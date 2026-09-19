#!/bin/sh
# Lists candidate live-boot ISO files on a target drive.
#
#   discover-live-isos.sh <target-partition>  ->  path\tsize\tname
#
# Cheap on purpose, the same split every other discover-*.sh in this
# project uses: list candidates fast here, validate expensively only on
# selection. Deciding whether a file is actually a bootable casper or
# live-boot image means loop-mounting it and looking inside - too slow to
# do for every .iso on a drive just to draw a list. That real check
# happens in boot-live-iso.sh, once, for the one the user taps.
#
# Ventoy - the case this exists for - stores ISO files as plain files on
# an ordinary exFAT/NTFS partition; it never extracts them. So this is
# nothing more than "list .iso files", at the root and one directory
# down (Ventoy has no required layout, and one level covers how people
# actually organise a stick without walking the whole tree).
set -eu

target=${1:?usage: discover-live-isos.sh <target-partition>}

# NIGHTFALL_LIVE_ISO_PROBE is a test seam and nothing else - the real
# thing is always the fixed /run/nightfall path.
probe=${NIGHTFALL_LIVE_ISO_PROBE:-/run/nightfall/probe-live-isos}
mkdir -p "$probe" 2>/dev/null || true
mount -o ro "$target" "$probe" 2>/dev/null || exit 0

for f in "$probe"/*.iso "$probe"/*/*.iso; do
    [ -f "$f" ] || continue
    rel=${f#"$probe"/}
    size=$(ls -l "$f" 2>/dev/null | awk '{
        b = $5
        if (b >= 1073741824) printf "%.1fG", b/1073741824
        else printf "%.0fM", b/1048576
    }')
    name=${rel##*/}
    printf '%s\t%s\t%s\n' "$rel" "${size:-?}" "$name"
done

umount "$probe" 2>/dev/null || true

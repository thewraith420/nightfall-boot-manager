#!/bin/sh
# Lists kernels from Boot Loader Specification entries - what Fedora, RHEL and
# friends use instead of menuentries in grub.cfg.
#
#   discover-bls.sh <boot-dir>   ->  title<TAB>linux<TAB>initrd<TAB>cmdline
#
# <boot-dir> is the directory that CONTAINS loader/entries: /mnt/root/boot on
# a normal machine, /mnt/root when /boot is its own partition. Same four
# columns discover-kernels.sh emits, so everything downstream is unchanged.
#
# Why it exists: on those distros grub.cfg has no menuentries at all, just a
# `blscfg` command that makes GRUB read /boot/loader/entries/*.conf itself.
# discover-kernels.sh parsing that grub.cfg finds nothing, and init used to
# treat "nothing" as "no kernels" and drop to a rescue shell.
#
# WHAT IS AND IS NOT HANDLED:
#  - paths are passed through as written (relative to the boot filesystem,
#    which is exactly what kexec-boot.sh joins onto the mount point);
#  - options: `$kernelopts` (older Fedora) is replaced from grubenv when it can
#    be found, and any other whole-token variable reference is dropped, the
#    same rule discover-kernels.sh applies - GRUB expands these, we cannot;
#  - an entry may name several initrd images; kexec takes ONE, so only the
#    first is used. That loses e.g. a separate early-microcode image;
#  - newest kernel first, by a natural version compare (6.10 after 6.9, which
#    a plain string sort gets wrong). There is no sort applet in the image, so
#    the sort is in the awk below;
#  - entries with no linux line are skipped.
set -eu

bootdir=${1:?usage: discover-bls.sh <boot-dir>}
entries=$bootdir/loader/entries
[ -d "$entries" ] || exit 1

# Older Fedora keeps the shared options in grubenv rather than in each entry.
kernelopts=""
for env in "$bootdir/grub2/grubenv" "$bootdir/grub/grubenv"; do
    [ -r "$env" ] || continue
    kernelopts=$(awk '/^kernelopts=/ { sub(/^kernelopts=/, ""); print; exit }' "$env")
    break
done

set -- "$entries"/*.conf
[ -e "$1" ] || exit 0

# NO apostrophes anywhere in this program, comments included: it lives inside
# a shell single-quoted string, and one apostrophe ends it.
awk -v kernelopts="$kernelopts" '
# Turns every run of digits into a fixed-width number so that comparing the
# resulting strings compares versions: 6.10 must sort after 6.9.
function vkey(v,   out) {
    out = ""
    while (v != "") {
        if (match(v, /^[0-9]+/)) {
            out = out substr("000000000000", 1, 12 - RLENGTH) substr(v, 1, RLENGTH)
            v = substr(v, RLENGTH + 1)
        } else if (match(v, /^[^0-9]+/)) {
            out = out substr(v, 1, RLENGTH)
            v = substr(v, RLENGTH + 1)
        } else break
    }
    return out
}
function flush(   opts, i, n, tok, t) {
    if (linux == "") { reset(); return }
    if (linux !~ /^\//) linux = "/" linux
    if (initrd != "" && initrd !~ /^\//) initrd = "/" initrd
    n = split(options, tok, /[ \t]+/)
    opts = ""
    for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t == "") continue
        if (t == "$kernelopts" || t == "${kernelopts}") {
            if (kernelopts != "") opts = opts (opts != "" ? " " : "") kernelopts
            continue
        }
        if (t ~ /^\$[{]?[A-Za-z_][A-Za-z0-9_]*[}]?$/) continue
        opts = opts (opts != "" ? " " : "") t
    }
    count++
    key[count]  = vkey(version != "" ? version : lastfile) "\t" lastfile
    row[count]  = (title != "" ? title : lastfile) "\t" linux "\t" initrd "\t" opts
    reset()
}
function reset() { title = ""; version = ""; linux = ""; initrd = ""; options = "" }

FNR == 1 { if (NR > 1) flush(); reset(); lastfile = FILENAME; sub(/.*\//, "", lastfile) }
{
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line == "" || line ~ /^#/) next
    k = line; sub(/[ \t].*$/, "", k)
    v = line; sub(/^[^ \t]+[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
    if (k == "title")        title = v
    else if (k == "version") version = v
    else if (k == "linux")   linux = v
    else if (k == "initrd") { if (initrd == "") { split(v, first, /[ \t]+/); initrd = first[1] } }
    else if (k == "options") options = options (options != "" ? " " : "") v
}
END {
    flush()
    # Newest first: insertion sort, descending on the natural-version key.
    for (i = 2; i <= count; i++) {
        kk = key[i]; rr = row[i]; j = i - 1
        while (j >= 1 && key[j] < kk) { key[j + 1] = key[j]; row[j + 1] = row[j]; j-- }
        key[j + 1] = kk; row[j + 1] = rr
    }
    for (i = 1; i <= count; i++) print row[i]
}
' "$@"

#!/bin/sh
# Applies each kernel's saved command line, if it has one.
#
#   apply-cmdline.sh <menu.tsv> <cmdline-file>   ->  menu.tsv
#
# Runs after apply-default.sh over the same
# title\tlinux\tinitrd\tcmdline\tis_default rows, replacing only the
# cmdline field.
#
# The file is picker-owned state on the real root, one line per kernel:
#
#   /boot/vmlinuz-7.1.12-BobZKernel-pixel-slate<TAB>root=UUID=... ro quiet
#
# A whole-line override rather than a merge, because that is what Edit
# hands back: the user saw the complete command line and edited it, so
# what they saved IS the answer. Merging would mean silently reinstating
# arguments they had just deleted.
#
# Per-kernel by construction, so different kernels can carry different
# arguments - a debug kernel with extra logging beside a normal one,
# say - without either affecting the other.
#
# RECOVERY rows are never overridden. Several menu entries share one
# kernel image (a normal entry, a "with Linux X" entry, and a recovery
# entry), so keying on the image alone would push a saved command line
# onto the recovery entry too - replacing "ro recovery nomodeset" with
# whatever the normal entry carries, and quietly breaking the thing you
# reach for when a saved command line turns out to be a mistake.
#
# grub.cfg is never touched. That matters: this survives update-grub,
# and removing the file (or the kernel) reverts cleanly to whatever
# GRUB says.
#
# A missing or empty file passes every row through untouched - this must
# never be a reason a kernel won't boot.
set -eu

menu=${1:?usage: apply-cmdline.sh <menu.tsv> <cmdline-file>}
saved=${2:-}

[ -r "$menu" ] || exit 1

awk -F'\t' -v OFS='\t' -v sfile="$saved" '
BEGIN {
    if (sfile != "") {
        while ((getline line < sfile) > 0) {
            if (line == "" || line ~ /^[ \t]*#/) continue
            tab = index(line, "\t")
            if (tab == 0) continue
            k = substr(line, 1, tab - 1)
            v = substr(line, tab + 1)
            # An empty value is not an override - it is how a cleared
            # entry looks if one ever gets written. Booting a kernel
            # with no arguments at all would not end well.
            if (k != "" && v != "") want[k] = v
        }
        close(sfile)
    }
}
function is_recovery(title, cmdline) {
    return (cmdline ~ /(^| )recovery( |$)/) || (index(title, "(recovery mode)") > 0)
}
{
    if (($2 in want) && !is_recovery($1, $4)) $4 = want[$2]
    print
}
' "$menu"

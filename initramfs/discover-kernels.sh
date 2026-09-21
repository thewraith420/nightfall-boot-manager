#!/bin/sh
# Parses a GRUB config for menuentry stanzas (at any nesting depth -
# submenu is just a display wrapper, real kernel entries are commonly
# nested one level inside "Advanced options for ..." submenus) and
# emits one "title<TAB>linux-path<TAB>initrd-path<TAB>cmdline" line per
# entry, excluding Nightfall's own entry (--id nightfall, or --id picker
# from before the rename).
#
# Excluding ourselves is not cosmetic. A self-entry in the list can be
# chosen as the DEFAULT kernel, and the default is what init boots when
# the menu fails to come up - so the one path that exists to rescue a
# broken menu would kexec straight back into Nightfall. On a tablet with
# no keyboard there is nothing to interrupt that with.
#
# Usage: discover-kernels.sh /path/to/grub.cfg > menu.tsv

set -eu
cfg="${1:?usage: discover-kernels.sh <grub.cfg>}"

awk '
function is_closing_brace(l,    stripped) {
    stripped = l
    gsub(/\$\{[^}]*\}/, "", stripped)
    return (stripped ~ /}/)
}

BEGIN { depth = 0 }

$1 == "menuentry" {
    depth++
    frame_type[depth] = "menuentry"
    line = $0
    sub(/^[^"'"'"']*['"'"'"]/, "", line)
    sub(/["'"'"'].*/, "", line)
    title[depth] = line
    id[depth] = ""
    for (i = 1; i <= NF; i++) {
        if ($i == "--id" && i < NF) { id[depth] = $(i + 1); break }
    }
    linux[depth] = ""; initrd[depth] = ""; cmdline[depth] = ""
    next
}

$1 == "submenu" {
    depth++
    frame_type[depth] = "submenu"
    next
}

frame_type[depth] == "menuentry" && ($1 == "linux" || $1 == "linuxefi" || $1 == "linux16") {
    linux[depth] = $2
    # A whole-token GRUB variable reference (vt_handoff, foo in braces) is
    # dropped, not passed on: GRUB expands these at its own boot time, this
    # parser cannot, and kexec-boot.sh hands the cmdline over verbatim, so a
    # kexec-booted kernel would receive the literal text. Real, not
    # hypothetical: Ubuntu 10_linux appends a vt_handoff reference to a
    # kernel command line whenever the default cmdline contains the word
    # splash, so an Ubuntu-style regeneration of a grub.cfg (Mint drop-in
    # sets GRUB_DISTRIBUTOR=Ubuntu) puts it on every linux line - seen on the
    # recovery stick after an update-grub, and parsed through verbatim by the
    # old code. Whether a given grub.cfg has it depends on how it was last
    # generated: a later rewrite of the same file left it out. (vt.handoff=7
    # itself means nothing after a kexec - it hands GRUB display state to the
    # kernel, and GRUB is long gone. NO apostrophes in this comment: it lives
    # inside the shell single-quoted awk program.)
    c = ""
    for (i = 3; i <= NF; i++) {
        if ($i ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) continue
        c = c (c != "" ? " " : "") $i
    }
    cmdline[depth] = c
    next
}

frame_type[depth] == "menuentry" && ($1 == "initrd" || $1 == "initrdefi" || $1 == "initrd16") {
    initrd[depth] = $2
    next
}

is_closing_brace($0) {
    if (frame_type[depth] == "menuentry" && title[depth] != "" \
        && id[depth] != "nightfall" && id[depth] != "picker" \
        && linux[depth] !~ /(^|\/)(nightfall|picker)\/vmlinuz/ \
        && linux[depth] ~ /vmlinuz/) {
        printf "%s\t%s\t%s\t%s\n", title[depth], linux[depth], initrd[depth], cmdline[depth]
    }
    delete frame_type[depth]
    depth--
}
' "$cfg"

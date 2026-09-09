#!/bin/sh
# Lists the backups already on a target drive.
#
#   discover-backups.sh <root-mount> <target-partition>  ->  name\tdate\tsize
#
# Mounts read-only, reads the directory, unmounts. Only backups with an
# .info sidecar are listed: backup-system.sh writes that after tar
# succeeds, so anything without one is a run that died part way and must
# not be offered as something to restore from.
set -eu

root=${1:?usage: discover-backups.sh <root-mount> <target-partition>}
target=${2:?usage: discover-backups.sh <root-mount> <target-partition>}

probe=/run/picker/probe-backups
mkdir -p "$probe" 2>/dev/null || true
mount -o ro "$target" "$probe" 2>/dev/null || exit 0

for info in "$probe"/nocturne-backups/*.info; do
    [ -f "$info" ] || continue
    name=${info##*/}
    name=${name%.info}
    tar=$probe/nocturne-backups/$name.tar
    [ -f "$tar" ] || continue          # sidecar without an archive is nothing

    when=$(awk -F': *' '/^created:/{ $1=""; sub(/^ */,""); print; exit }' "$info" 2>/dev/null)
    size=$(ls -l "$tar" 2>/dev/null | awk '{
        b = $5
        if (b >= 1073741824) printf "%.0fG", b/1073741824
        else printf "%.0fM", b/1048576
    }')
    printf '%s\t%s\t%s\n' "$name" "${when:-unknown}" "${size:-?}"
done

umount "$probe" 2>/dev/null || true

#!/bin/sh
# Prints the name of the package that owns a file on the real root, or
# exits 1 with nothing printed if no package manager claims it.
#
#   package-owner.sh <root-mount> <path-within-root>
#
# e.g. package-owner.sh /mnt/root /boot/vmlinuz-7.0.0-34-generic
#
# Used by remove-kernel.sh to refuse removing a kernel a package manager
# still thinks it owns - deleting it out from under dpkg/rpm/pacman
# leaves that package "installed" with its files gone, which a later
# apt/dnf/pacman run (and their own kernel/initramfs hooks) then trips
# over. This script cannot run the real package manager itself (no
# network assumptions, no interactive prompts, and it would make the
# picker a package manager by accident), so the caller's job is to
# refuse and name the real one - this script's job is only to answer
# "does anything claim this file".
#
# Three package managers, in the order most likely on this project's
# actual targets:
#
#   dpkg    /var/lib/dpkg/info/<pkg>.list is a plain file list, one
#           absolute path per line. No dpkg binary needed - this works
#           even with a locked or missing dpkg binary, which matters
#           since this runs from the initramfs, not a full chroot.
#   pacman  /var/lib/pacman/local/<pkg>-<version>/files lists paths
#           WITHOUT a leading slash; the bare package name is read from
#           that same directory's "desc" file, since the directory name
#           itself carries the version too.
#   rpm     the database is a binary format with no plain-text
#           equivalent, so this one genuinely needs the rpm binary - run
#           inside the real root via chroot, same as update-grub
#           elsewhere in this project. Skipped entirely if rpm is not
#           present there.
#
# A file not owned by any package manager this script knows how to check
# is reported as unowned (exit 1). That is deliberate: this is a
# refuse-when-SURE guard, not a refuse-when-UNSURE one. The alternative
# (refuse unless positively cleared) would also refuse on a plain
# hand-copied kernel, which is this project's actual common case - the
# Slate's own BobZKernel builds are never apt/dnf/pacman-installed.
set -eu

root=${1:?usage: package-owner.sh <root-mount> <path-within-root>}
path=${2:?usage: package-owner.sh <root-mount> <path-within-root>}

if [ -d "$root/var/lib/dpkg/info" ]; then
    hit=$(grep -lFx "$path" "$root"/var/lib/dpkg/info/*.list 2>/dev/null | head -n1) || hit=""
    if [ -n "$hit" ]; then
        pkg=${hit##*/}
        pkg=${pkg%.list}
        # Multi-arch packages are named "pkg:arch.list" - report the bare name.
        printf '%s\n' "${pkg%%:*}"
        exit 0
    fi
fi

if [ -d "$root/var/lib/pacman/local" ]; then
    relpath=${path#/}
    for f in "$root"/var/lib/pacman/local/*/files; do
        [ -f "$f" ] || continue
        if grep -qFx "$relpath" "$f" 2>/dev/null; then
            pkgdir=${f%/*}
            pkg=$(awk '/^%NAME%$/{getline; print; exit}' "$pkgdir/desc" 2>/dev/null) || pkg=""
            if [ -n "$pkg" ]; then
                printf '%s\n' "$pkg"
            else
                # Fall back to the versioned directory name rather than
                # reporting nothing - still clearly identifies the package.
                printf '%s\n' "${pkgdir##*/}"
            fi
            exit 0
        fi
    done
fi

if [ -x "$root/usr/bin/rpm" ] || [ -x "$root/bin/rpm" ]; then
    pkg=$(chroot "$root" rpm -qf --qf '%{NAME}\n' "$path" 2>/dev/null) || pkg=""
    case "$pkg" in
        ""|*"not owned by any package"*) : ;;
        *) printf '%s\n' "$pkg"; exit 0 ;;
    esac
fi

exit 1

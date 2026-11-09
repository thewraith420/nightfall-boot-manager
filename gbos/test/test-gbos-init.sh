#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# QEMU test of gbos-init on the real boot path, with FAKE images and a FAKE
# Android init: a stand-in distro initramfs mounts an ext4 root (built from
# this machine's own userland, as the distro's would be) and execs
# /gbos/gbos-init on it as PID 1; gbos-init loads drivers from the root's
# /lib/modules, assembles the images, binds firmware, switches root and execs
# the fake init, which reports what it was handed.
#
#   test-gbos-init.sh BZIMAGE KERNEL_BUILD_TREE
#
# KERNEL_BUILD_TREE is read only: its .ko files are copied into a modules
# tree for the test root and depmod run on the copy. Needs gcc, mkfs.erofs,
# mke2fs, debugfs, depmod, cpio, qemu-system-x86_64. About a minute, 512 MB.
set -euo pipefail
K=${1:?bzImage}; TREE=${2:?kernel build tree}; IMAGES=${3:-}
# Optional third argument: a directory with REAL images (system.img,
# product.img, system_ext.img, vendor.img, optional bind/) from the GBOS image
# builder. The fake checks are then replaced by a long run of Android's real
# init with a virgl display (needs a host GPU and several GB of RAM), judged
# from the kernel log the shim keeps in /gbos/kmsg.log.
HERE=$(cd "$(dirname "$0")" && pwd); GB=$(cd "$HERE/.." && pwd)
PATH=$PATH:/usr/sbin:/sbin
for t in gcc mkfs.erofs mke2fs debugfs depmod cpio qemu-system-x86_64; do
    command -v $t >/dev/null || { echo "need $t"; exit 2; }; done
# The release the bzImage itself reports (its setup header's kernel_version
# string), not the tree's kernel.release: the tree's config can change
# (LOCALVERSION) after the bzImage was built, and modules filed under another
# name are never found.
vo=$(od -An -tu2 -j526 -N2 "$K" | tr -d ' ')
REL=$(dd if="$K" bs=1 skip=$((vo + 512)) count=200 2>/dev/null | tr '\0' '\n' | head -1 | cut -d' ' -f1)
[ -n "$REL" ] || { echo "cannot read the release from $K"; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/gbos-init-test.XXXXXX"); [ -n "${GBOS_TEST_KEEP:-}" ] || trap 'rm -rf "$W"' EXIT
cp "$K" "$W/bzImage"                       # snapshot: the tree may be rebuilt meanwhile
# Real-image mode only: GBOS_TEST_DISK=<file> keeps the test root there. If it
# already exists it is booted again as it is, /data and all, which is how a
# second boot is tested (a first boot under TCG takes more than 30 minutes of
# dexopt and does not finish). The reused disk keeps the gbos-init it was
# built with.
DISK=$W/root.img; REUSE=""
if [ -n "$IMAGES" ] && [ -n "${GBOS_TEST_DISK:-}" ]; then
    DISK=$GBOS_TEST_DISK; [ -f "$DISK" ] && REUSE=1
    # the disk holds modules for one release only: another kernel boots with none
    if [ -n "$REUSE" ] && [ "$(cat "$DISK.release" 2>/dev/null)" != "$REL" ]; then
        echo "$DISK was built for '$(cat "$DISK.release" 2>/dev/null)', not $REL - remove it to build a new one"; exit 2
    fi
fi

if [ -z "$REUSE" ]; then
# --- the distro root: this machine's own userland, as the distro's would be
RT=$W/root
mkdir -p $RT/usr/bin $RT/usr/sbin $RT/usr/lib $RT/usr/lib64 $RT/etc/modprobe.d $RT/dev $RT/proc $RT/sys $RT/run $RT/tmp
ln -s usr/bin $RT/bin; ln -s usr/sbin $RT/sbin; ln -s usr/lib $RT/lib; ln -s usr/lib64 $RT/lib64
copy_bin() {  # copy a program and every library it links, keeping paths
    local b; b=$(readlink -f "$(command -v "$1")")
    mkdir -p "$RT$(dirname "$b")"; cp -n "$b" "$RT$b"
    [ "$(command -v "$1")" = "$b" ] || { mkdir -p "$RT/usr/bin"; ln -sf "$b" "$RT/usr/bin/$1" 2>/dev/null || :; }
    # by the name the program asks for (the soname link), dereferenced
    ldd "$b" 2>/dev/null | grep -o '/[^ ]*' | while read -r l; do
        mkdir -p "$RT$(dirname "$l")"; cp -nL "$l" "$RT$l"
    done
}
for b in dash mount umount mountpoint kmod cat mv mkdir sleep sync find sort xargs wc grep tr cut uname chroot readlink ls; do copy_bin $b; done
ln -sf dash $RT/usr/bin/sh
for m in modprobe insmod lsmod depmod; do ln -sf ../bin/kmod $RT/usr/sbin/$m; done
cp -n /lib64/ld-linux-x86-64.so.2 $RT/usr/lib64/ 2>/dev/null || cp -L /lib64/ld-linux-x86-64.so.2 $RT/usr/lib64/
# kmod's own libraries (zstd/xz) are linked, so ldd caught them

# modules: copy the build tree's .ko files into kernel/, depmod the copy
MD=$RT/usr/lib/modules/$REL; mkdir -p $MD/kernel
# modules.order, not a find: a build tree keeps .ko files from earlier
# configs (hid.ko from before HID was built in), which would shadow the
# kernel's own symbols and fail to load.
sed 's#\.o$#.ko#' "$TREE/modules.order" | while read -r k; do
    [ -f "$TREE/$k" ] || continue
    mkdir -p "$MD/kernel/$(dirname "$k")"; cp "$TREE/$k" "$MD/kernel/$k"; done
cp "$TREE/modules.builtin" "$TREE/modules.builtin.modinfo" $MD/
sed 's#^#kernel/#; s#\.o$#.ko#' "$TREE/modules.order" > $MD/modules.order
depmod -b $RT "$REL"
mkdir -p $RT/usr/lib/firmware; echo "firmware from the distro root" > $RT/usr/lib/firmware/gbos-test.fw

# --- the GBOS images (fake), as the image builder leaves them
gcc -O2 -static -o $W/fakeinit "$HERE/fake-android-init.c"
S=$W/stage; mkdir -p $S/sys/system/bin $S/prod $S/ext $S/ven
cp $W/fakeinit $S/sys/system/bin/init
( cd $S/sys && ln -s /system/bin/init init && mkdir -p dev proc sys data metadata mnt second_stage_resources product system_ext vendor debug_ramdisk )
echo "fake product" > $S/prod/MARKER; echo "fake system_ext" > $S/ext/MARKER; echo "fake vendor" > $S/ven/MARKER
mkdir -p $RT/gbos
if [ -n "$IMAGES" ]; then
    # hard links where possible: mke2fs -d copies them into the root image anyway
    for f in system product system_ext vendor; do
        ln "$IMAGES/$f.img" $RT/gbos/$f.img 2>/dev/null || cp "$IMAGES/$f.img" $RT/gbos/$f.img; done
    [ -d "$IMAGES/bind" ] && cp -a "$IMAGES/bind" $RT/gbos/bind
else
for n in system:sys product:prod system_ext:ext; do mkfs.erofs -zlz4hc "$RT/gbos/${n%%:*}.img" "$S/${n##*:}" >/dev/null; done
mke2fs -q -t ext4 -O ^has_journal -d $S/ven $RT/gbos/vendor.img 16M
fi
install -m 0755 "$GB/gbos-init" $RT/gbos/gbos-init
if [ -z "$IMAGES" ]; then
mkdir -p $RT/gbos/bind/vendor $RT/gbos/bind/product; echo "replaced vendor" > $RT/gbos/bind/vendor/MARKER
echo "no such file" > $RT/gbos/bind/product/NOT-THERE
fi

if [ -n "$IMAGES" ]; then mke2fs -q -t ext4 -L testroot -d $RT "$DISK" 24G; else mke2fs -q -t ext4 -L testroot -d $RT "$DISK" 2G; fi
rm -rf "$RT"                               # the images are in $DISK now
[ -z "$IMAGES" ] || printf '%s\n' "$REL" > "$DISK.release"
fi

# --- the stand-in distro initramfs
gcc -O2 -static -o $W/ird-init "$HERE/distro-initramfs.c"
mkdir -p $W/ird; cp $W/ird-init $W/ird/init
( cd $W/ird && find . | cpio -o -H newc --quiet -R 0:0 ) | gzip -9 > $W/ird.gz

if [ -n "$IMAGES" ]; then
    LOG=${GBOS_TEST_LOG:-$PWD/gbos-init-real.log}; OUT=$(dirname "$LOG")
    CMD="console=ttyS0 panic=-1 loglevel=7 printk.devkmsg=on rw init=/gbos/gbos-init gbos.fail=poweroff lsm=landlock,lockdown,yama,integrity,selinux enforcing=0 androidboot.hardware=android-desktop androidboot.hardware.platform=android-desktop"
    TO=${GBOS_TEST_TIMEOUT:-2400}; SHOT=${GBOS_TEST_SHOT:-300}
    echo "real images: guest ${GBOS_TEST_MEM:-3072} MB, up to ${TO}s, $([ -n "$REUSE" ] && echo "second boot of $DISK" || echo "first boot"), console in $LOG"
    [ "$DISK" = "$W/root.img" ] || echo "disk kept: $DISK (boot it again with the same GBOS_TEST_DISK)"
    # The serial console carries the kernel log only, not logcat, so the
    # screen is the one view of what Android shows: a screendump every $SHOT s.
    rm -f "$OUT"/gbos-init-real-shot-*.ppm
    ( t=0; while sleep "$SHOT"; do t=$((t + SHOT)); [ -S $W/mon ] || continue
        echo "screendump $OUT/gbos-init-real-shot-$(printf %05d $t).ppm" | socat - UNIX-CONNECT:$W/mon >/dev/null 2>&1 || :
      done ) & SHOTPID=$!
    timeout "$TO" qemu-system-x86_64 -accel tcg -cpu Skylake-Client -smp 2 -m "${GBOS_TEST_MEM:-3072}" \
        -display egl-headless -device virtio-vga-gl -serial "file:$LOG" -no-reboot \
        -monitor unix:$W/mon,server,nowait \
        -kernel $W/bzImage -initrd $W/ird.gz -drive file="$DISK",if=virtio,format=raw \
        -device qemu-xhci -device usb-kbd -append "$CMD" || :
    kill $SHOTPID 2>/dev/null || :
    e2fsck -fy "$DISK" >/dev/null 2>&1 || :
    K2=$OUT/gbos-init-real.kmsg.log
    debugfs -R "dump /gbos/kmsg.log $K2" "$DISK" >/dev/null 2>&1
    debugfs -R "dump /gbos/boot.log $OUT/gbos-init-real.boot.log" "$DISK" >/dev/null 2>&1
    echo "kernel log copy: $K2, shim log: $OUT/gbos-init-real.boot.log"
    ls "$OUT"/gbos-init-real-shot-*.ppm 2>/dev/null | sed 's/^/screen: /' || :
    # Markers from the kernel log (logcat never reaches it). bootanim exits
    # when the framework shows its first screen; sys.boot_completed follows.
    [ -s "$K2" ] || K2=$LOG
    for p in "gbos-init: switching root" "init: init second stage started" "starting service 'zygote'" \
             "starting service 'surfaceflinger'" "Service 'bootanim' (pid" \
             "processing action (sys.boot_completed=1) from (/system/etc/init/hw/init.rc" \
             "Unsupported zygote ABI" "InitFatalReboot"; do
        printf '%-50s %s\n' "$p" "$(tr -d '\r' < "$K2" | grep -cF -- "$p" || :)"
    done
    exit 0
fi

LOG=$W/console.log
CMD="console=ttyS0 panic=-1 loglevel=7 printk.devkmsg=on rw init=/gbos/gbos-init gbos.fail=poweroff lsm=landlock,lockdown,yama,integrity,selinux enforcing=0"
# vga=0x318 + -vga std: a VESA framebuffer, so the built-in simpledrm takes
# card0 at boot and bochs-drm (the PCI GPU, loaded by coldplug) comes second,
# as simpledrm and i915 do on the Slate.
timeout 300 qemu-system-x86_64 -accel tcg -cpu Skylake-Client -smp 2 -m 512 -nographic -vga std -no-reboot \
    -kernel $W/bzImage -initrd $W/ird.gz -drive file=$W/root.img,if=virtio,format=raw \
    -device qemu-xhci -device usb-kbd -device virtio-rng-pci \
    -append "$CMD vga=0x318" 2>&1 | tr -d '\r' > $LOG || :

rc=0
chk() { if grep -qE -- "$1" $LOG; then echo "ok   $2"; else echo "FAIL $2"; rc=1; fi; }
chk 'FAKE: pid=1 argv: \[/system/bin/init\] \[selinux_setup\]' "Android init runs as PID 1 with selinux_setup"
chk 'FAKE: stray fds 0'                         "only fds 0-2 reach init"
chk 'FAKE: mount /dev/loop[0-9]+ / erofs ro'    "the system image is the root, read-only"
chk 'FAKE: product marker = fake product'       "product is mounted on top"
chk 'FAKE: system_ext marker = fake system_ext' "system_ext is mounted on top"
chk 'FAKE: vendor marker = replaced vendor'     "vendor is mounted on top, and a bind/ file replaces its file"
chk 'skipped'                                   "a bind/ file with nothing to replace is skipped, not created"
chk 'FAKE: /system read-only'                   "/system cannot be written"
chk 'FAKE: /data writable'                      "/data is writable"
if grep -E 'FAKE: mount proc /proc proc ' $LOG | grep -q 'gid=3009' && grep -E 'FAKE: mount proc /proc proc ' $LOG | grep -qE 'hidepid=(2|invisible)'; then
    echo "ok   proc is mounted hidepid=2,gid=3009"; else echo "FAIL proc is mounted hidepid=2,gid=3009"; rc=1; fi
chk 'FAKE: mount selinuxfs /sys/fs/selinux'     "selinuxfs is mounted"
chk 'FAKE: mount devpts /dev/pts'               "devpts is mounted"
chk 'FAKE: /dev/socket ok, /dev/dm-user ok'     "/dev/socket and /dev/dm-user exist"
chk 'FAKE: firmware_class.path = /debug_ramdisk/gbos-fw' "firmware_class.path points into the new root"
chk 'FAKE: firmware via bind = firmware from the distro root' "the distro's /lib/firmware is readable from the new root"
chk 'FAKE: module usbhid loaded'                "preloaded: usbhid (USB keyboard plugged in later)"
chk 'FAKE: module hid_multitouch loaded'        "preloaded: hid_multitouch (touch)"
chk 'FAKE: module ccm loaded'                   "preloaded: ccm (the Wi-Fi WPA2 key; Android disables on-demand loading)"
chk 'FAKE: module cmac loaded'                  "preloaded: cmac (protected management frames, WPA3)"
chk 'FAKE: module virtio_rng loaded'            "coldplug by modalias loaded a driver for a present device"
chk 'simpledrm.*Initialized|Initialized simpledrm' "test setup: simpledrm took the firmware framebuffer first"
chk 'gbos-init: unbound simple-framebuffer from simple-framebuffer.0' "the firmware framebuffer's DRM driver is unbound before coldplug"
chk 'FAKE: card0 driver = bochs-drm'             "the GPU is card0, where Android's composer looks first"

# what persisted on the distro root
debugfs -R "cat /gbos/data/WRITE-TEST" $W/root.img 2>/dev/null | grep -q "written by android" \
    && echo "ok   what Android wrote to /data is on the distro filesystem" \
    || { echo "FAIL what Android wrote to /data is on the distro filesystem"; rc=1; }
debugfs -R "cat /gbos/boot.log" $W/root.img 2>/dev/null | grep -q "switching root" \
    && echo "ok   gbos-init's own log is on the distro filesystem" \
    || { echo "FAIL gbos-init's own log is on the distro filesystem"; rc=1; }
debugfs -R "cat /gbos/kmsg.log" $W/root.img 2>/dev/null | grep -q "gbos-init: switching root" \
    && echo "ok   the kernel log copy persisted, past the root switch" \
    || { echo "FAIL the kernel log copy persisted, past the root switch"; rc=1; }

fail_boot() {  # boot once more, expecting gbos-init to fail: fail_boot LOG
    timeout 120 qemu-system-x86_64 -accel tcg -cpu Skylake-Client -smp 1 -m 512 -nographic -no-reboot \
        -kernel $W/bzImage -initrd $W/ird.gz -drive file=$W/root.img,if=virtio,format=raw \
        -append "$CMD" 2>&1 | tr -d '\r' > "$1" || :
}

# failure path: no modules for this kernel -> logged, machine goes down
# (otherwise nothing loads and Android crash-loops instead)
e2fsck -fy $W/root.img >/dev/null 2>&1 || :     # replay the journal the poweroff left
M=/usr/lib/modules/$REL
debugfs -w -R "link $M $M.off" $W/root.img >/dev/null 2>&1
debugfs -w -R "unlink $M" $W/root.img >/dev/null 2>&1
fail_boot $W/fail-mod.log
if grep -q "gbos-init: FAILED: no modules for $REL" $W/fail-mod.log && grep -q "Power down" $W/fail-mod.log; then
    echo "ok   missing modules are reported, then the machine goes down instead of booting Android without drivers"
else echo "FAIL missing modules are reported, then the machine goes down"; tail -15 $W/fail-mod.log; rc=1; fi
e2fsck -fy $W/root.img >/dev/null 2>&1 || :
debugfs -w -R "link $M.off $M" $W/root.img >/dev/null 2>&1
debugfs -w -R "unlink $M.off" $W/root.img >/dev/null 2>&1

# failure path: no images -> logged, then the machine goes down (poweroff here)
e2fsck -fy $W/root.img >/dev/null 2>&1 || :
debugfs -w -R "rm /gbos/system.img" $W/root.img >/dev/null 2>&1
debugfs -R "stat /gbos/system.img" $W/root.img 2>&1 | grep -q "File not found" || { echo "FAIL test setup: could not remove system.img"; rc=1; }
fail_boot $W/fail.log
if grep -q "gbos-init: FAILED: /gbos/system.img is missing" $W/fail.log && grep -qE "reboot: Power down|Power down" $W/fail.log; then
    echo "ok   a missing image is reported, then the machine goes down instead of hanging"
else echo "FAIL a missing image is reported, then the machine goes down"; tail -15 $W/fail.log; rc=1; fi

[ $rc = 0 ] || { echo "--- console (last 60 lines)"; tail -60 $LOG; }
exit $rc

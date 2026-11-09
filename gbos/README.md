# GBOS boot entry

Boots GBOS (the modified Android 17 Googlebook image) on bare metal, as a dual
boot beside the distro. GBOS lives in `/gbos/` on the distro's root filesystem.
The plan behind it is `~/buildstuff/GBOS-BARE-METAL-PLAN.md` (items N1-N4), and
the image side is the GBOS project's `docs/baremetal/G3-G4-design.md`.

## How a boot goes

1. GRUB or Nightfall boots the entry `GBOS (Android 17)` (`--id gbos`). Nightfall
   needs no GBOS code: it lists the entry from `grub.cfg` like any other kernel
   and kexecs it.
2. The kernel is the distro's own, for the release in `/etc/gbos/kernel-release`.
   It is reached through `/boot/gbos/vmlinuz` and `/boot/gbos/initrd.img`, which
   are symlinks. Nightfall keys command-line overrides and its default on the
   linux path, so the GBOS entry never shares them with the distro's own entry
   for the same kernel. The kernel must have the GBOS options built in
   (`CONFIG_GBOS_VEXEMU`, EROFS, netfilter): BobZKernel `pixel-slate-7.2`.
3. The distro's own initramfs mounts the root read-write (`rw`) and runs
   `init=/gbos/gbos-init` as PID 1. That takes care of the hardware-specific
   part: the Slate's eMMC driver is a module.
4. `gbos-init`, a distro shell script, never GBOS userland, does the job of
   Android's first stage:
   - unbinds the firmware framebuffer's DRM driver (simpledrm), so the GPU
     becomes `/dev/dri/card0`: Android's composer scans card0, card1, ... and
     stops at the first gap, so with i915 on card1 it finds no display;
   - loads drivers by modalias from this kernel's `/lib/modules`, plus a fixed
     preload list for hot-pluggable input;
   - mounts `system.img` as `/`, with product, system_ext and vendor read-only
     on top;
   - binds `/gbos/data` at `/data`;
   - binds `/lib/firmware` at `/debug_ramdisk/gbos-fw` and points
     `firmware_class.path` there;
   - switches root and execs `/system/bin/init selinux_setup`, with only fds
     0-2 open.
5. On any failure before that exec, it logs the problem and reboots, so GRUB and
   Nightfall are one reboot away.

## Files on the machine

| Path | Written by | What |
|---|---|---|
| `/gbos/{system,product,system_ext,vendor}.img` | GBOS image builder | the images |
| `/gbos/data/` | `gbos-init`, first boot | Android's `/data` (plain directory) |
| `/gbos/bind/<path>` | GBOS image builder, optional | bring-up replacements, each bound read-only over `/<path>` if that file exists, e.g. `bind/system/lib64/libselinux.so` (the permissive-only libselinux). The images stay byte-identical to the download |
| `/gbos/root/` | `gbos-init` | empty mount point for the assembled root |
| `/gbos/gbos-init` | `install-gbos-entry.sh` | the first stage |
| `/gbos/boot.log`, `boot.log.1` | `gbos-init` | its own log, this boot and the previous one |
| `/gbos/kmsg.log`, `kmsg.log.1` | `gbos-init` | a copy of the kernel log, which keeps running under Android (`gbos.kmsglog=0` turns it off) |
| `/etc/gbos/{kernel-release,dir}` | `install-gbos-entry.sh` | which kernel, where GBOS is |
| `/etc/gbos/cmdline` | you, optional | extra options for the entry, one or more per line |
| `/etc/grub.d/42_gbos` | `install-gbos-entry.sh` | generates the entry; prints nothing while the kernel or images are missing |

## Install

```
sudo gbos/install-gbos-entry.sh --release 7.2.15-BobZKernel-pixel-slate-gbos
sudo gbos/install-gbos-entry.sh --remove      # images and data are left alone
```

## Expectations for the first boot

The first boot compiles the system (dexopt) before anything looks finished, so
do not judge it by a short wait. On the Slate it reached `sys.boot_completed` in
about 3 minutes the first time and 1.5 minutes after that. If it reboots instead,
`/gbos/boot.log` and `/gbos/kmsg.log` (and the `.1` copies) say why. Read them
from the distro or from Nightfall.

## Tests

- `test/test-42_gbos.sh`: the entry generator and installer, against fixtures.
  This includes Nightfall's own parser listing the entry. No root needed.
- `test/test-gbos-init.sh BZIMAGE KERNEL_BUILD_TREE`: QEMU (TCG, Skylake-Client).
  A stand-in distro initramfs runs `gbos-init` on an ext4 root built from this
  machine's own userland, with fake images and a fake Android init that reports
  what it was handed. It also covers the failure path. It takes about a minute;
  set `TMPDIR` to a disk directory, because the test root is about 2 GB.

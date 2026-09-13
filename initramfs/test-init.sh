#!/bin/bash
# Exercises initramfs/init against mocked dependencies.
#
# Runs the REAL init file - absolute paths rewritten into a sandbox - so
# it cannot drift from a copy of its own logic. Covers the fallback
# chain, the diagnostics, and the device-wait race.
#
#   bash initramfs/test-init.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
# Absolute, because the busybox pass below re-runs this file. As bare
# "$0" that only worked when $0 happened to contain a slash: run as
# "bash test-init.sh" from this directory it became a PATH lookup, which
# failed - and the failure was a line of noise after "passed: 51", so it
# read as a clean run while silently skipping the busybox half. That
# half is the one that matters, since init runs under busybox for real.
SELF=$REPO/initramfs/$(basename "$0")
pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }

# $1=name  $2=picker behaviour  $3=root-mount rc  $4=discover rc
# $5=devices: "present" (default) | "late" | "never"
setup() {
  SB=$(mktemp -d); export SB
  devmode=${5:-present}
  mkdir -p "$SB"/bin "$SB"/sbin "$SB"/run/nightfall "$SB"/mnt/root
  # mnt/root/boot exists only if the root mount succeeds - that IS what
  # mounting the real root does. Pre-creating it unconditionally made
  # save_log's "is the root actually mounted?" guard untestable.
  [ "$3" = 0 ] && mkdir -p "$SB"/mnt/root/boot

  # Fake device tree. "late" has a helper create the nodes after a
  # delay, modelling a driver that binds just after init gets there.
  mkdir -p "$SB"/dev "$SB"/sys/class/drm/card0-eDP-1
  conn() { echo "$1" > "$SB/sys/class/drm/card0-eDP-1/status"; }
  # picker owns waiting for DRM and touch (NIGHTFALL_WAIT_SECS, ui/nightfall.c)
  # since only touch_open() knows what a usable device is. The ONLY wait
  # left in init is the root device, so that is what these exercise.
  case "$devmode" in
    rootlate)  ( sleep 2; : > "$SB/dev/rootdev" ) & ;;
    rootnever) ;;
    *)         : > "$SB/dev/rootdev" ;;
  esac
  case "$devmode" in
    present) mkdir -p "$SB"/dev/dri "$SB"/dev/input
             : > "$SB/dev/dri/card0"; : > "$SB/dev/input/event0"; conn connected ;;
    # Staggered on purpose: i915 and I2C-HID are separate drivers that
    # bind at different moments, so both waits get exercised. Creating
    # them simultaneously makes the second wait a no-op and silently
    # stops testing it.
    # Three separate arrivals, in the order real hardware does it: the
    # card node, then the panel reporting connected, then the touch
    # controller. Collapsing any two makes the later wait a no-op and
    # silently stops testing it.
    late)    conn disconnected
             ( sleep 2; mkdir -p "$SB"/dev/dri; : > "$SB/dev/dri/card0"
               sleep 1; conn connected
               sleep 1; mkdir -p "$SB"/dev/input; : > "$SB/dev/input/event0" ) & ;;
    # The case waiting on the card node alone would sail straight past:
    # i915 has published cardN, but the panel is not reporting connected
    # yet, so drm_open_first_connected() would still reject it.
    notconn) mkdir -p "$SB"/dev/dri "$SB"/dev/input
             : > "$SB/dev/dri/card0"; : > "$SB/dev/input/event0"; conn disconnected ;;
    never)   conn disconnected ;;
  esac

  # --- mocks -------------------------------------------------------
  cat > "$SB/bin/mount" <<EOF
#!/bin/sh
case "\$*" in
  *remount*) exit 0 ;;
  *rootdev*) exit $3 ;;
esac
exit 0
EOF
  cat > "$SB/bin/sh" <<'EOF'
#!/bin/sh
echo "MARKER_RESCUE_SHELL_REACHED"
exit 0
EOF
  printf '#!/bin/sh\nexit 0\n'                              > "$SB/bin/mdev"
  # Models the real failure: one early probe line, then a flood of
  # later noise. A tailed capture loses the early line - which is
  # exactly what made a real boot log unable to answer whether the
  # touch driver ever probed.
  cat > "$SB/bin/dmesg" <<'EOF'
#!/bin/sh
echo "[    0.100000] i2c_designware i2c_designware.0: MARKER_EARLY_I2C_PROBE"
i=0
while [ $i -lt 300 ]; do echo "[   14.400000] pcieport 0000:00:1c.0: PCIe Bus Error MARKER_SPAM $i"; i=$((i+1)); done
echo "[   34.400000] MARKER_DMESG_LINE late"
EOF
  printf '#!/bin/sh\necho "MARKER_KEXEC root=$1 linux=$2"\nexit 0\n' > "$SB/sbin/kexec-boot.sh"
  cat > "$SB/bin/discover-kernels.sh" <<EOF
#!/bin/sh
[ "$4" = 0 ] || exit 1
printf 'Ubuntu\t/boot/vmlinuz-real\t/boot/initrd.img-real\tro quiet\t\n'
printf 'Ubuntu old\t/boot/vmlinuz-old\t/boot/initrd.img-old\tro quiet\t\n'
EOF
  printf '#!/bin/sh\ncat "$1"\n' > "$SB/bin/apply-default.sh"
  printf '#!/bin/sh\nprintf "%s\\tv1\\t120M\\n" /home/bob/k-installer.tar.gz\n' > "$SB/bin/discover-tarballs.sh"
  printf '#!/bin/sh\necho "MARKER_REBOOT $*" >&2\nexit 0\n'   > "$SB/bin/reboot"
  printf '#!/bin/sh\necho "MARKER_POWEROFF $*" >&2\nexit 0\n' > "$SB/bin/poweroff"
  # Counts its runs, so a refresh that fails to re-scan is visible.
  # Without this mock the call just fails and is swallowed, which looks
  # identical to it never being made.
  cat > "$SB/bin/scan-drives.sh" <<'EOF'
#!/bin/sh
n=$(cat "$SB/scanruns" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$SB/scanruns"
echo "MARKER_SCAN_RAN $n" >&2
printf '/dev/sdx1\texfat\tVentoy\t931G\t21G\n' > "$3"
# The backup list shrinks on the second scan: that is what deleting a
# backup looks like from init's side.
[ "$n" = 1 ] && printf '/dev/sdx1\tbk-old\tmonday\t86G\n' > "$4" || : > "$4"
exit 0
EOF
  # Marks the cmdline so the test can see init used this script's output.
  # awk, not sed: sed is not a busybox applet in the image, so a sed
  # mock silently fails under STRICT_BB and the assertion blames init.
  printf '#!/bin/sh\nawk -F"\\t" -v OFS="\\t" \x27{sub(/ro quiet/,"ro quiet MARKER_SAVED_CL",$4); print}\x27 "$1"\n' > "$SB/bin/apply-cmdline.sh"
  cat > "$SB/bin/install-kernel.sh" <<EOF
#!/bin/sh
echo "MARKER_INSTALL_RAN \$2" >&2
exit ${INSTALL_RC:-0}
EOF
  case "$2" in
    ok)    cat > "$SB/bin/nightfall" <<'EOF'
#!/bin/sh
echo "nightfall mock: drew the menu" >&2
echo 'SELECTED_LINUX=/boot/vmlinuz-chosen'
echo 'SELECTED_INITRD=/boot/initrd.img-chosen'
echo 'SELECTED_CMDLINE=ro quiet'
echo 'SELECTED_BY=timeout'
exit 0
EOF
    ;;
    crash) printf '#!/bin/sh\necho "nightfall mock: MARKER_DRM_OPEN_FAILED /dev/dri/card0" >&2\nexit 3\n' > "$SB/bin/nightfall" ;;
    empty) printf '#!/bin/sh\necho "nightfall mock: chose nothing" >&2\nexit 0\n' > "$SB/bin/nightfall" ;;
    install) cat > "$SB/bin/nightfall" <<'EOF'
#!/bin/sh
# First run asks for an install; later runs boot. Models the real flow,
# where installing returns to the menu instead of booting.
n=$(cat /tmp/pickruns 2>/dev/null || echo 0); n=$((n+1)); echo $n > /tmp/pickruns
if [ "$n" = 1 ]; then
  echo "MARKER_PICKER_RUN_$n" >&2
  echo "INSTALL_TARBALL=/home/bob/k-installer.tar.gz"
else
  echo "MARKER_PICKER_RUN_$n" >&2
  echo 'SELECTED_LINUX=/boot/vmlinuz-chosen'
  echo 'SELECTED_INITRD=/boot/initrd.img-chosen'
  echo 'SELECTED_CMDLINE=ro quiet'
fi
exit 0
EOF
    ;;
    reload) cat > "$SB/bin/nightfall" <<'EOF'
#!/bin/sh
# picker ran the install itself and only wants the menu refreshed.
n=$(cat /tmp/pickruns 2>/dev/null || echo 0); n=$((n+1)); echo $n > /tmp/pickruns
if [ "$n" = 1 ]; then echo "RELOAD=1"
else echo 'SELECTED_LINUX=/boot/vmlinuz-chosen'; echo 'SELECTED_INITRD=x'; echo 'SELECTED_CMDLINE=y'; fi
exit 0
EOF
    ;;
    installfail) cat > "$SB/bin/nightfall" <<'EOF'
#!/bin/sh
n=$(cat /tmp/pickruns 2>/dev/null || echo 0); n=$((n+1)); echo $n > /tmp/pickruns
if [ "$n" = 1 ]; then echo "INSTALL_TARBALL=/home/bob/k-installer.tar.gz"
else echo 'SELECTED_LINUX=/boot/vmlinuz-chosen'; echo 'SELECTED_INITRD=x'; echo 'SELECTED_CMDLINE=y'; fi
exit 0
EOF
    ;;
    # Asks to reload more times than the INSTALL leash allows. Deleting
    # several backups in a row is the normal way to free space on a full
    # drive, and each "Back to menu" is one reload - sharing the install
    # counter meant the fourth tap silently booted instead.
    manyreloads) cat > "$SB/bin/nightfall" <<'EOF'
#!/bin/sh
n=$(cat /tmp/pickruns 2>/dev/null || echo 0); n=$((n+1)); echo $n > /tmp/pickruns
if [ "$n" -le 6 ]; then echo "RELOAD=1"
else echo 'SELECTED_LINUX=/boot/vmlinuz-chosen'; echo 'SELECTED_INITRD=x'; echo 'SELECTED_CMDLINE=y'; fi
exit 0
EOF
    ;;
    restart)  printf '#!/bin/sh\necho "POWER_ACTION=reboot"\nexit 0\n'   > "$SB/bin/nightfall" ;;
    shutdown) printf '#!/bin/sh\necho "POWER_ACTION=poweroff"\nexit 0\n' > "$SB/bin/nightfall" ;;
  esac
  chmod +x "$SB"/bin/* "$SB"/sbin/*

  # Applet dir for BUSYBOX mode. Placed AFTER $SB/bin in PATH so the
  # mocks above still win; this only supplies the real utilities init
  # calls (grep/head/cat/ls/...). init runs under busybox in the actual
  # initramfs, so testing it under dash+coreutils tests the wrong
  # userspace - the same mistake that let the hand-run picker tests miss
  # everything the initramfs later hit.
  if [ -n "${USE_BUSYBOX:-}" ]; then
    mkdir -p "$SB/bbin"
    # APPLETS is a multi-line quoted assignment; pull the whole thing.
    applets=$(sed -n '/^APPLETS="/,/"$/p' "$REPO/initramfs/build-initramfs.sh" \
              | tr '\n' ' ' | sed 's/.*APPLETS="//; s/".*//')
    [ -n "$applets" ] || { echo "TEST BUG: could not parse APPLETS" >&2; exit 2; }
    for a in $applets; do
      busybox --list 2>/dev/null | grep -qx "$a" && ln -sf "$(command -v busybox)" "$SB/bbin/$a"
    done
  fi

  # --- the real init, redirected into the sandbox -------------------
  #
  # In busybox mode the mocks need shell functions, not just PATH.
  # Ubuntu builds busybox with FEATURE_SH_STANDALONE, so `busybox sh`
  # resolves applet names from its OWN table and never consults PATH -
  # a $SB/bin/mount mock is simply ignored and the real mount runs.
  # (Debian's busybox is built without it, so PATH mocking works there:
  # the same suite passed on one machine and failed 28 assertions on the
  # other, for reasons that had nothing to do with init.) Functions are
  # resolved before builtins and applets in every POSIX shell, so
  # shadowing is the one interception that works in both builds.
  shadow=
  if [ -n "${USE_BUSYBOX:-}" ]; then
    # reboot and poweroff are applets too, so PATH mocks for them are
    # bypassed exactly like mount's - which showed up as two failures on
    # the Slate and none here, the same split that cost a debugging round
    # the first time. Production WANTS the applet; only the test needs
    # the shadow.
    for a in mount dmesg mdev reboot poweroff; do
      shadow="$shadow$a() { \"$SB/bin/$a\" \"\$@\"; }
"
    done
  fi
  sed -e "s|/bin/|$SB/bin/|g" -e "s|/sbin/|$SB/sbin/|g" \
      -e "s|/mnt/root|$SB/mnt/root|g" -e "s|/run/nightfall|$SB/run/nightfall|g" \
      -e "s|/dev/dri|$SB/dev/dri|g" -e "s|/dev/input|$SB/dev/input|g" \
      -e "s|/sys/class/drm|$SB/sys/class/drm|g" \
      "$REPO/initramfs/init" > "$SB/init.body"
  { head -n1 "$SB/init.body"; printf '%s' "$shadow"; tail -n +2 "$SB/init.body"; } > "$SB/init"
}

# NB: run the interpreter by ABSOLUTE path. $SB/bin/sh is the mocked
# rescue shell and is first in PATH, so a bare `sh` here silently runs
# the mock instead of init - which looks exactly like "init dropped to
# rescue immediately" and cost a debugging round.
run() {
  # PATH: mocks first (they must win), then busybox applets in busybox
  # mode, then the host - unless STRICT_BB, which drops the host
  # entirely so busybox has to supply everything. Built with plain
  # logic: a nested ${VAR:+...}${VAR:-...} pair here silently produced
  # "$SB/bbin1" and 10 bogus failures, which is the same expansion trap
  # that duplicated the log outcome line earlier.
  _path="$SB/bin:$SB/sbin"
  if [ -n "${USE_BUSYBOX:-}" ]; then _path="$_path:$SB/bbin"; fi
  if [ -z "${STRICT_BB:-}" ];  then _path="$_path:$PATH"; fi

  PATH="$_path" \
  REAL_ROOT_DEV="$SB/dev/rootdev" NIGHTFALL_FALLBACK_PAUSE=0 \
  NIGHTFALL_WAIT_ROOT=${W:-3} NIGHTFALL_WAIT_DRM=${W:-3} NIGHTFALL_WAIT_INPUT=${W:-3} \
  NIGHTFALL_INSTALL_PAUSE=0 \
    ${TEST_SH:-/bin/sh} "$SB/init" >"$SB/out" 2>"$SB/err"
}

log()  { cat "$SB/mnt/root/boot/nightfall-last-boot.log" 2>/dev/null; }
both() { cat "$SB/out" "$SB/err" 2>/dev/null; }

echo "=== 1. happy path: nightfall returns a selection ==="
setup happy ok 0 0; run
both | grep -q "MARKER_KEXEC.*vmlinuz-chosen" && ok "kexecs the user's choice" || bad "did not kexec the choice"
log  | grep -qx "outcome:  booted user selection" && ok "log outcome line exact" || bad "outcome wrong: [$(log | grep outcome)]"
log  | grep -q "MARKER_DMESG_LINE"    && ok "log captures dmesg" || bad "no dmesg in log"
log  | grep -q "MARKER_EARLY_I2C_PROBE" && ok "early probe line survives 300 later lines (was lost to tail -150)" || bad "early dmesg line lost - the log cannot answer 'did the driver bind'"
log  | sed -n "/hardware probe lines/,/full, up to/p" | grep -q "MARKER_EARLY_I2C_PROBE" && ok "probe lines pulled into their own section" || bad "no probe summary section"
log  | sed -n "/hardware probe lines/,/full, up to/p" | grep -q "MARKER_SPAM" && bad "probe section polluted with unrelated noise" || ok "probe section excludes unrelated spam"
log  | grep -q "drew the menu"        && ok "log captures nightfall stderr" || bad "no nightfall stderr in log"
log  | grep -qx "chosen_by=timeout"   && ok "log distinguishes timeout auto-boot from a real tap" || bad "chosen_by wrong: [$(log | grep chosen_by)]"
both | grep -q "MARKER_RESCUE"        && bad "unexpectedly hit rescue" || ok "no rescue on happy path"
log  | grep -q "waiting for"          && bad "waited despite devices being present" || ok "no wait when devices already there"

echo "=== 2. nightfall crashes (the first-boot suspect) ==="
setup crash crash 0 0; run
both | grep -q "MARKER_KEXEC.*vmlinuz-real"  && ok "falls back to first discovered kernel" || bad "no fallback kexec"
both | grep -q "the menu could not be shown" && ok "says so ON SCREEN (was silent before)" || bad "still silent on screen"
both | grep -q "MARKER_DRM_OPEN_FAILED"      && ok "replays nightfall stderr to screen" || bad "stderr not shown on screen"
log  | grep -q "nightfall exit code: 3"         && ok "log records exit code 3" || bad "exit code missing"
log  | grep -qx "outcome:  fell back: nightfall exited 3" && ok "log outcome exact (no duplication)" || bad "outcome wrong: [$(log | grep outcome)]"

echo "=== 3. nightfall exits 0 but selects nothing ==="
setup empty empty 0 0; run
both | grep -q "MARKER_KEXEC.*vmlinuz-real" && ok "falls back" || bad "no fallback"
log  | grep -qx "outcome:  fell back: nightfall produced no selection" && ok "distinguished from a crash" || bad "outcome wrong: [$(log | grep outcome)]"

echo "=== 4. root mount fails -> rescue ==="
setup mountfail ok 1 0; run
both | grep -q "MARKER_RESCUE_SHELL_REACHED" && ok "drops to rescue shell" || bad "no rescue shell"
both | grep -q "cannot save a boot log"      && ok "explains the missing log" || bad "silent about no log"
both | grep -q "MARKER_KEXEC"                && bad "kexec'd despite no root!" || ok "does not kexec"

echo "=== 5. discovery fails -> rescue, root mounted so log survives ==="
setup discfail ok 0 1; run
both | grep -q "MARKER_RESCUE_SHELL_REACHED" && ok "drops to rescue shell" || bad "no rescue shell"
log  | grep -q "outcome:  rescue: no kernel entries found" && ok "log records rescue reason" || bad "outcome wrong"
log  | grep -q "mounting real root"          && ok "log shows stage trail" || bad "no stage trail"

echo "=== 6. THE RACE: root device appears 2s late ==="
W=10 setup rootlate ok 0 0 rootlate; W=10 run
both | grep -q "waiting for root device"  && ok "waits instead of sampling once" || bad "did not wait"
log  | grep -qE "root device .* appeared after [0-9]+s" && ok "records how long it took" || bad "no timing: [$(log | grep -i root | head -2)]"
both | grep -q "MARKER_KEXEC.*vmlinuz-chosen" && ok "goes on to boot normally" || bad "did not boot"
log  | grep -q "TIMEOUT"                  && bad "spurious timeout" || ok "no spurious timeout"

echo "=== 7. root device never appears: must NOT hang ==="
W=2 setup rootnever ok 1 0 rootnever; W=2 run
log  | grep -q "TIMEOUT: root device"        && bad "log unreachable when root never mounts" || ok "no log (root never mounted - nothing to write to)"
both | grep -q "TIMEOUT: root device"        && ok "reports the timeout on screen" || bad "timeout not reported"
both | grep -q "MARKER_RESCUE_SHELL_REACHED" && ok "drops to rescue rather than hanging" || bad "did not reach rescue"
both | grep -q "MARKER_KEXEC"                && bad "kexec'd with no root!" || ok "does not kexec"

echo "=== 8. Install: nightfall asks to install, then boots ==="
rm -f /tmp/pickruns; setup inst install 0 0; run
both | grep -q "MARKER_INSTALL_RAN /home/bob/k-installer.tar.gz" && ok "runs install-kernel.sh with the chosen tarball" || bad "install-kernel.sh not run"
log  | grep -q "MARKER_PICKER_RUN_2"        && ok "returns to the menu instead of booting straight away" || bad "did not re-show the menu"
both | grep -q "MARKER_KEXEC.*vmlinuz-chosen" && ok "boots what was picked on the second pass" || bad "did not boot after install"
log  | grep -q "install succeeded"          && ok "log records the install" || bad "install not in the log"

echo "=== 9. Install fails: must still boot, nothing stranded ==="
rm -f /tmp/pickruns; INSTALL_RC=1 setup instfail installfail 0 0; INSTALL_RC=1 run
both | grep -q "install FAILED"             && ok "says so on screen" || bad "silent about the failure"
both | grep -q "MARKER_KEXEC"               && ok "still boots afterwards" || bad "failed install left it unable to boot"
both | grep -q "MARKER_RESCUE"              && bad "dropped to rescue over a failed install" || ok "does not drop to rescue"
log  | grep -q "INSTALL FAILED"             && ok "log records the failure" || bad "failure not in the log"
log  | grep -q "MARKER_INSTALL_RAN"          && ok "log captures the install output, not just that it failed" || bad "install output missing from the log"

echo "=== 10. saved per-kernel command lines ==="
setup cl ok 0 0; run
log | grep -q "MARKER_SAVED_CL" && ok "apply-cmdline.sh output reaches the booted cmdline" || bad "saved command line not applied"

setup clfail ok 0 0; rm -f "$SB/bin/apply-cmdline.sh"; run
both | grep -q "MARKER_KEXEC" && ok "boots even with apply-cmdline.sh missing" || bad "an optional script broke the boot"
both | grep -q "MARKER_RESCUE" && bad "dropped to rescue over an optional feature" || ok "no rescue"

echo "=== 11. SET_CMDLINE: save, then forget ==="
setup clset ok 0 0
cat > "$SB/bin/nightfall" <<'EOF'
#!/bin/sh
printf 'SELECTED_LINUX=/boot/vmlinuz-chosen\nSELECTED_INITRD=x\nSELECTED_CMDLINE=y\n'
printf "SET_CMDLINE='/boot/vmlinuz-chosen\troot=x ro loglevel=7'\n"
exit 0
EOF
chmod +x "$SB/bin/nightfall"; run
grep -qx "/boot/vmlinuz-chosen	root=x ro loglevel=7" "$SB/mnt/root/boot/nightfall-cmdline" 2>/dev/null \
  && ok "saves the kernel's command line" || bad "not saved: [$(cat "$SB/mnt/root/boot/nightfall-cmdline" 2>/dev/null)]"
log | grep -q "saved command line for" && ok "the boot log records it" || bad "not logged"

setup clclr ok 0 0
printf '/boot/vmlinuz-chosen\told\n/boot/vmlinuz-other\tkeep_me\n' > "$SB/mnt/root/boot/nightfall-cmdline"
cat > "$SB/bin/nightfall" <<'EOF'
#!/bin/sh
printf 'SELECTED_LINUX=/boot/vmlinuz-chosen\nSELECTED_INITRD=x\nSELECTED_CMDLINE=y\n'
printf "SET_CMDLINE='/boot/vmlinuz-chosen\t'\n"
exit 0
EOF
chmod +x "$SB/bin/nightfall"; run
grep -q "vmlinuz-chosen" "$SB/mnt/root/boot/nightfall-cmdline" 2>/dev/null \
  && bad "forgetting left the old entry behind" || ok "an empty value forgets that kernel"
grep -qx "/boot/vmlinuz-other	keep_me" "$SB/mnt/root/boot/nightfall-cmdline" 2>/dev/null \
  && ok "another kernel's saved line is untouched" || bad "clobbered a different kernel"
log | grep -q "cleared the saved command line" && ok "logged as a clear, not a save" || bad "wrong log line"

echo "=== 10. RELOAD: nightfall installed it itself, only wants a refresh ==="
rm -f /tmp/pickruns; setup rel reload 0 0; run
both | grep -q "MARKER_INSTALL_RAN"          && bad "installed AGAIN - RELOAD must not re-install" || ok "does NOT re-install (RELOAD is not INSTALL_TARBALL)"
log  | grep -q "reloading the menu"          && ok "refreshes the kernel list" || bad "no refresh recorded"
both | grep -q "MARKER_KEXEC.*vmlinuz-chosen" && ok "boots the choice from the refreshed menu" || bad "did not boot"
# Taking or deleting a backup changes the drive lists exactly the way
# installing a kernel changes the kernel list. Coming back to a menu
# that still lists the backup you just deleted looks precisely like the
# delete having done nothing.
[ "$(cat "$SB/scanruns" 2>/dev/null || echo 0)" -ge 2 ] \
  && ok "re-scans the drives on refresh, not just the kernels" \
  || bad "drive lists left stale after a reload"
[ -s "$SB/run/nightfall/backups.tsv" ] \
  && bad "backups.tsv still lists the deleted backup" \
  || ok "the refreshed backup list reflects the deletion"

echo "=== 11. several reloads in a row still return to the menu ==="
rm -f /tmp/pickruns; setup rel manyreloads 0 0; run
# Six reloads, which is past the install leash of three.
both | grep -q "MARKER_KEXEC.*vmlinuz-chosen" \
  && ok "still reaches the menu choice after 6 reloads" \
  || bad "gave up and booted early: $(log | grep -i 'too many' | head -1)"
log | grep -q "too many reloads" && bad "hit the install leash on plain reloads" \
  || ok "does not treat reloads as install rounds"

echo "=== 12. Restart and Power off leave without booting anything ==="
# Nightfall had no way out except booting a kernel, which on a
# keyboardless tablet meant holding the power button. Restart is also
# how you reach the GRUB menu, since GRUB is long gone by the time
# Nightfall runs.
setup pwr restart 0 0; run
both | grep -q "MARKER_REBOOT" && ok "reboots when asked to restart" || bad "did not reboot"
both | grep -q "MARKER_KEXEC" && bad "booted a kernel instead of restarting" || ok "does NOT kexec anything"
log  | grep -q "reboot requested" && ok "the boot log records why" || bad "no log entry"

setup pwr shutdown 0 0; run
both | grep -q "MARKER_POWEROFF" && ok "powers off when asked" || bad "did not power off"
both | grep -q "MARKER_REBOOT" && bad "rebooted instead of powering off" || ok "does not confuse the two"
both | grep -q "MARKER_KEXEC" && bad "booted a kernel instead" || ok "does NOT kexec anything"

echo "=== 13. the menu timeout is settable from /boot, and validated hard ==="
# The one knob where bad input is dangerous rather than merely wrong:
# Nightfall treats 0 as "disable auto-boot", so garbage becoming 0 would
# leave a keyboardless tablet sitting at a menu forever if touch failed.
setup happy ok 0 0
echo "45" > "$SB/mnt/root/boot/nightfall-timeout"
run
both | grep -q "menu timeout 45s" && ok "a plain number is applied" || bad "timeout not applied"

# Everything below must be treated as though the file were absent.
for junk in "" "  " "abc" "30s" "-5" "3.5" "# 30" "99999"; do
  setup happy ok 0 0
  printf '%s\n' "$junk" > "$SB/mnt/root/boot/nightfall-timeout"
  run
  if both | grep -q "NIGHTFALL_TIMEOUT_SECS="; then
    bad "junk timeout '$junk' was exported anyway"
  else
    ok "rejects '$junk'"
  fi
done

# Deliberate 0 is legal - it is a documented choice, and the guard is
# against garbage BECOMING 0, not against meaning it.
setup happy ok 0 0
echo "0" > "$SB/mnt/root/boot/nightfall-timeout"
run
log | grep -q "menu timeout 0s" && ok "a deliberate 0 is honoured" || bad "0 was rejected"

# Absent file must change nothing at all.
setup happy ok 0 0
run
both | grep -q "NIGHTFALL_TIMEOUT_SECS" && bad "exported a timeout with no file" \
  || ok "no file means Nightfall's compiled default, untouched"
both | grep -q "MARKER_KEXEC" && ok "and the boot still works" || bad "broke the normal path"

echo
echo "passed: $pass   failed: $fail  (${MODE_NAME:-dash + coreutils})"
[ "$fail" -eq 0 ] || exit 1

# init runs under BUSYBOX in the real initramfs, so a pass under
# dash+coreutils proves less than it looks. Re-run the whole suite
# against busybox with the host PATH removed, so busybox has to supply
# everything. Testing the wrong userspace is how the hand-run picker
# tests missed every problem the initramfs later hit.
if [ -z "${USE_BUSYBOX:-}" ]; then
  if command -v busybox >/dev/null 2>&1; then
    echo
    USE_BUSYBOX=1 STRICT_BB=1 MODE_NAME="busybox (host PATH removed)" \
      TEST_SH="$(command -v busybox) sh" bash "$SELF" "$@"
  else
    echo
    echo "NOTE: busybox not installed - skipped the busybox pass, which is"
    echo "      the userspace init actually runs under. Install busybox-static."
  fi
fi

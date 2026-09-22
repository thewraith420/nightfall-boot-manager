#!/bin/sh
# Says up front whether kexec can work on this boot.
#
#   kexec-preflight.sh    exit 0: fine, or cannot tell - print nothing
#                         exit 1: blocked - one line of reason on stdout
#
# WHY: under kernel lockdown the legacy kexec_load syscall (what
# kexec-boot.sh uses, `kexec -l`) is refused with EPERM. init exec()s
# kexec-boot.sh in place of PID 1, so that refusal used to end in a kernel
# panic with nothing on screen to say why. Asking first turns it into a
# sentence a person can act on.
#
# LOCKDOWN is the decisive signal, not Secure Boot: lockdown is what actually
# refuses kexec_load. A Secure Boot machine whose kernel came up with lockdown
# "none" can still kexec, so keying on Secure Boot alone would raise a false
# alarm. Secure Boot only shapes the ADVICE: on distribution kernels it is
# often why lockdown is on, but the Nightfall kernel does not lock down under
# Secure Boot (LOCK_DOWN_KERNEL_FORCE_NONE), so here lockdown mostly means a
# lockdown= option on the command line - and telling someone to turn off a
# Secure Boot that is already off would send them the wrong way.
#
# Cannot tell (no lockdown file: no securityfs, or a kernel without the
# lockdown LSM) means "not blocked" - the failure mode of guessing wrong the
# other way is refusing to boot a machine that would have worked.
#
# NIGHTFALL_LOCKDOWN_FILE / NIGHTFALL_SECUREBOOT_VAR are test seams and
# nothing else.
set -eu

LOCKDOWN=${NIGHTFALL_LOCKDOWN_FILE:-/sys/kernel/security/lockdown}
SBVAR=${NIGHTFALL_SECUREBOOT_VAR:-/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c}

mode=""
if [ -r "$LOCKDOWN" ]; then
    line=""
    # `|| :`: read returns 1 at EOF on a newline-less file even though it
    # assigned the value (the same gotcha init hit six times).
    read -r line < "$LOCKDOWN" 2>/dev/null || :
    # The active mode is the bracketed one: "none [integrity] confidentiality".
    case "$line" in
        *"[integrity]"*)       mode=integrity ;;
        *"[confidentiality]"*) mode=confidentiality ;;
    esac
fi
[ -n "$mode" ] || exit 0

# An efivar is 4 attribute bytes then the data; SecureBoot's data is one byte,
# 1 when enabled. od is in the initramfs for exactly this.
secure_boot=unknown
if [ -r "$SBVAR" ]; then
    v=$(tail -c1 "$SBVAR" 2>/dev/null | od -An -tu1 2>/dev/null) || v=""
    set -- $v
    if [ "${1:-}" = 1 ]; then secure_boot=on; else secure_boot=off; fi
fi

case "$secure_boot" in
    on)  advice="Secure Boot is enabled. Turn Secure Boot off in the firmware settings to boot kernels from Nightfall." ;;
    off) advice="Secure Boot is off, so this comes from a lockdown= option: remove it from the kernel command line to boot kernels from Nightfall." ;;
    *)   advice="Turn Secure Boot off in the firmware settings, or remove any lockdown= option from the kernel command line, to boot kernels from Nightfall." ;;
esac
echo "kernel lockdown is '$mode', which refuses kexec. $advice"
exit 1

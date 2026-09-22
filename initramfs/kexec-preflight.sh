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
# alarm. Secure Boot only enriches the message (it is usually WHY lockdown is
# on, and it is what the person has to turn off).
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
secure_boot=""
if [ -r "$SBVAR" ]; then
    v=$(tail -c1 "$SBVAR" 2>/dev/null | od -An -tu1 2>/dev/null) || v=""
    set -- $v
    [ "${1:-}" = 1 ] && secure_boot=" Secure Boot is enabled."
fi

echo "kernel lockdown is '$mode', which refuses kexec.$secure_boot Turn Secure Boot off in the firmware settings to boot kernels from Nightfall."
exit 1

/* Exercises picker's install plumbing: the child process, its output
 * reaching the progress screen, the exit status, and the fallback when
 * the install script isn't runnable.
 *
 * Includes nightfall.c so these are the real functions - start_install()
 * really forks, really execs, and the output really comes back down a
 * pipe. Only the script is a stand-in.
 */
#include <sys/stat.h>
#define main picker_real_main
#include "nightfall.c"
#undef main

static int fails, passes;
static void ck(int c, const char *m) { printf(c ? "  [ok] %s\n" : "  [FAIL] %s\n", m); c ? passes++ : fails++; }

static void dummy_flush(lv_display_t *d, const lv_area_t *a, uint8_t *p) {
    (void)a; (void)p; lv_display_flush_ready(d);
}

/* Drains the child through the REAL loop - install_pump() in nightfall.c -
 * rather than a copy of it. The copy that used to live here carried the
 * same buffer-full bug as the original, which is precisely why having two
 * of them was worthless. */
static int drain(void) {
    char buf[512];
    size_t len = 0;
    while (install_pump(buf, sizeof(buf), &len))
        ;
    return g_child_exit_ok;
}

int main(void) {
    lv_init();
    lv_display_t *disp = lv_display_create(600, 900);
    static uint8_t buf[600 * 10 * 4];
    lv_display_set_buffers(disp, buf, NULL, sizeof(buf), LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(disp, dummy_flush);

    static struct entry e[1] = {{ "Ubuntu", "/boot/vmlinuz-x", "/boot/initrd-x", "ro", 0 }};
    static struct tarball tb[1] = {{ "/tmp/fake-installer.tar.gz", "9.9.9-test", "1M" }};
    g_tarballs = tb; g_tarball_n = 1;
    lv_obj_t *cd = NULL;
    build_ui(e, 1, 0, &cd);

    /* --- fallback when the script cannot run --- */
    setenv("NIGHTFALL_INSTALL_SH", "/nonexistent/install-kernel.sh", 1);
    ck(start_install(0) == -1, "falls back when the install script is missing (init does it instead)");

    /* --- a script that succeeds --- */
    FILE *f = fopen("/tmp/mock-install-ok.sh", "w");
    fprintf(f, "#!/bin/sh\necho \"install-kernel: reading $2\"\n"
               "echo 'install-kernel: extracting kernel and modules'\n"
               "echo 'install-kernel: update-initramfs -c -k 9.9.9-test'\n"
               "exit 0\n");
    fclose(f); chmod("/tmp/mock-install-ok.sh", 0755);
    setenv("NIGHTFALL_INSTALL_SH", "/tmp/mock-install-ok.sh", 1);
    setenv("NIGHTFALL_ROOT", "/mnt/root", 1);

    ck(start_install(0) == 0, "starts the child when the script is runnable");
    ck(g_install_fd >= 0 && g_install_pid > 0, "has a live pipe and pid");
    int ok = drain();
    ck(ok, "reports success for an exit-0 install");
    ck(g_prog_n >= 3, "captured the child's output lines");
    ck(strstr(g_prog_lines[0], "/tmp/fake-installer.tar.gz") != NULL,
       "passed the chosen tarball to the script");
    ck(strstr(g_prog_lines[g_prog_n - 1], "update-initramfs") != NULL,
       "last line is the most recent step (this is what the user sees)");
    ck(g_installing == 1, "install sets the no-auto-boot interlock");
    install_finished(ok);
    ck(g_prog_spinner == NULL, "spinner removed once finished");
    ck(g_reload == 0, "does not ask for a reload until the user taps Back");

    /* --- a script that fails --- */
    f = fopen("/tmp/mock-install-bad.sh", "w");
    fprintf(f, "#!/bin/sh\necho 'install-kernel: ERROR: update-initramfs failed'\nexit 1\n");
    fclose(f); chmod("/tmp/mock-install-bad.sh", 0755);
    setenv("NIGHTFALL_INSTALL_SH", "/tmp/mock-install-bad.sh", 1);
    g_prog_n = 0;
    ck(start_install(0) == 0, "starts a failing install too");
    ck(drain() == 0, "reports FAILURE for an exit-1 install (not silently ok)");

    /* --- a line longer than the read buffer --- */
    /* tar and the chroot tools can emit a very long path on one line, and
     * the buffer only holds 511 bytes of it. Getting this wrong is not a
     * cosmetic truncation: with the buffer full and no newline there is no
     * room left, read() is handed a count of 0, and 0 is what read()
     * returns at EOF - so the UI used to close the pipe and announce the
     * job had finished while it was still running. */
    f = fopen("/tmp/mock-install-long.sh", "w");
    fprintf(f, "#!/bin/sh\n"
               "i=0; while [ $i -lt 90 ]; do printf '0123456789'; i=$((i+1)); done\n"
               "printf '\\n'\n"
               "echo LAST_LINE_AFTER_THE_LONG_ONE\n"
               "exit 0\n");
    fclose(f); chmod("/tmp/mock-install-long.sh", 0755);
    setenv("NIGHTFALL_INSTALL_SH", "/tmp/mock-install-long.sh", 1);
    g_prog_n = 0;
    ck(start_install(0) == 0, "starts a child that emits a 900-byte line");
    ck(drain() == 1, "still reports the real exit status, not a phantom EOF");
    ck(g_prog_n >= 2, "kept reading past the over-long line");
    ck(strstr(g_prog_lines[g_prog_n - 1], "LAST_LINE_AFTER_THE_LONG_ONE") != NULL,
       "output written AFTER the long line still reaches the screen");

    /* --- recovery entries fold into their kernel's dialog --- */
    static struct entry rec[4] = {
        { "Ubuntu, with Linux 7.1.12",           "/boot/vmlinuz-7.1.12", "/boot/initrd.img-7.1.12", "ro quiet splash", 0 },
        { "Ubuntu, with Linux 7.1.12 (recovery mode)", "/boot/vmlinuz-7.1.12", "/boot/initrd.img-7.1.12", "ro recovery nomodeset", 0 },
        { "Ubuntu, with Linux 7.1.9",            "/boot/vmlinuz-7.1.9",  "/boot/initrd.img-7.1.9",  "ro quiet splash", 0 },
        /* the trap: "discovery" contains "recovery" as a substring */
        { "Ubuntu with disk discovery",          "/boot/vmlinuz-7.1.8",  "/boot/initrd.img-7.1.8",  "ro discovery=on", 0 },
    };
    g_entries = rec; g_entry_n = 4;
    ck(is_recovery(&rec[1]), "recognises a recovery entry by its cmdline");
    ck(!is_recovery(&rec[0]), "a normal entry is not recovery");
    ck(!is_recovery(&rec[3]), "'discovery' in the cmdline is NOT recovery (substring trap)");
    ck(!has_word("ro nomodeset", "recovery"), "has_word does not match an absent word");
    ck(has_word("recovery nomodeset", "recovery"), "matches at the start");
    ck(has_word("ro recovery", "recovery"), "matches at the end");
    ck(find_recovery_for(0) == 1, "pairs a kernel with its recovery variant by image path");
    ck(find_recovery_for(2) == -1, "a kernel with no recovery variant reports none");
    ck(find_recovery_for(1) == -1, "a recovery entry does not pair with itself");
    ck(count_bootable_rows() == 3, "recovery entries are not counted as menu rows");

    /* --- backup targets and existing backups --- */
    {
        FILE *tf = fopen("/tmp/mock-targets", "w");
        fprintf(tf, "/dev/sda1\texfat\tVentoy\t931G\t742G\n");
        fprintf(tf, "/dev/sda2\tvfat\tVTOYEFI\t32M\t30M\n");
        fprintf(tf, "\n");                       /* blank line, must be skipped */
        fclose(tf);
        static struct target tg[8];
        int tn = load_targets("/tmp/mock-targets", tg, 8);
        ck(tn == 2, "parses the Ventoy layout, skipping blank lines");
        ck(!strcmp(tg[0].label, "Ventoy") && !strcmp(tg[0].fstype, "exfat"),
           "label and filesystem survive the round trip");
        ck(!strcmp(tg[0].freespace, "742G"), "free space is carried through for the dialog");

        FILE *bf = fopen("/tmp/mock-backups", "w");
        fprintf(bf, "/dev/sda1\tnightfall-backup-20260909-1200\tTue Sep 9 12:00\t84G\n");
        fprintf(bf, "/dev/sda1\tonly-a-name\n");   /* short row: still usable */
        fprintf(bf, "\tno-target\n");             /* no target: unusable, skip */
        fclose(bf);
        static struct backup bk[8];
        int bn = load_backups("/tmp/mock-backups", bk, 8);
        ck(bn == 2, "a row without a target device is skipped, a short one is not");
        ck(!strcmp(bk[0].target, "/dev/sda1"), "restore knows which drive to mount");
        ck(!strcmp(bk[0].name, "nightfall-backup-20260909-1200"), "and which archive to use");
        ck(!strcmp(bk[1].when, "unknown"), "a missing date degrades rather than breaking");

        /* The launchers must pass the drive and the archive separately -
         * restore-system.sh takes <root> <target> <name>. */
        g_targets = tg; g_target_n = tn; g_backups = bk; g_backup_n = bn;
        setenv("NIGHTFALL_BACKUP_SH", "/nonexistent", 1);
        setenv("NIGHTFALL_RESTORE_SH", "/nonexistent", 1);
        ck(start_backup(0) == -1, "backup falls back cleanly when its script is missing");
        ck(start_restore(0) == -1, "restore falls back cleanly when its script is missing");

        FILE *mf = fopen("/tmp/mock-restore.sh", "w");
        fprintf(mf, "#!/bin/sh\necho \"restore: root=$1 target=$2 name=$3\"\nexit 0\n");
        fclose(mf); chmod("/tmp/mock-restore.sh", 0755);
        setenv("NIGHTFALL_RESTORE_SH", "/tmp/mock-restore.sh", 1);
        g_prog_n = 0;
        ck(start_restore(0) == 0, "starts the restore child");
        ck(drain() == 1, "reports success");
        ck(strstr(g_prog_lines[0], "target=/dev/sda1") != NULL, "passes the drive as argument 2");
        ck(strstr(g_prog_lines[0], "name=nightfall-backup-20260909-1200") != NULL,
           "passes the archive name as argument 3");
        /* --- deleting a backup takes the same two arguments --- */
        /* Restore and delete have identical signatures and adjacent
         * rows in the same menu, so a swapped or shifted argument would
         * still "work" right up to deleting the wrong 86GB archive. */
        setenv("NIGHTFALL_REMOVE_BACKUP_SH", "/nonexistent", 1);
        ck(start_remove_backup(0) == -1,
           "delete falls back cleanly when its script is missing");

        FILE *df = fopen("/tmp/mock-rmbackup.sh", "w");
        fprintf(df, "#!/bin/sh\necho \"remove-backup: root=$1 target=$2 name=$3\"\nexit 0\n");
        fclose(df); chmod("/tmp/mock-rmbackup.sh", 0755);
        setenv("NIGHTFALL_REMOVE_BACKUP_SH", "/tmp/mock-rmbackup.sh", 1);
        g_prog_n = 0;
        ck(start_remove_backup(0) == 0, "starts the delete child");
        ck(drain() == 1, "reports success");
        ck(strstr(g_prog_lines[0], "target=/dev/sda1") != NULL,
           "passes the drive as argument 2");
        ck(strstr(g_prog_lines[0], "name=nightfall-backup-20260909-1200") != NULL,
           "passes the archive name as argument 3, not the drive");
        remove("/tmp/mock-rmbackup.sh");

        /* --- rename takes FOUR arguments, not three --- */
        /* The only child that does. start_child grew a third slot for
         * it, so a silent regression there would send the new name as
         * nothing and rename the backup to the empty string. */
        setenv("NIGHTFALL_RENAME_BACKUP_SH", "/nonexistent", 1);
        snprintf(g_rename_to, sizeof(g_rename_to), "before-the-update");
        ck(start_rename_backup(0) == -1,
           "rename falls back cleanly when its script is missing");

        FILE *nf = fopen("/tmp/mock-rename.sh", "w");
        fprintf(nf, "#!/bin/sh\necho \"rename: root=$1 target=$2 old=$3 new=$4\"\nexit 0\n");
        fclose(nf); chmod("/tmp/mock-rename.sh", 0755);
        setenv("NIGHTFALL_RENAME_BACKUP_SH", "/tmp/mock-rename.sh", 1);
        g_prog_n = 0;
        ck(start_rename_backup(0) == 0, "starts the rename child");
        ck(drain() == 1, "reports success");
        ck(strstr(g_prog_lines[0], "target=/dev/sda1") != NULL,
           "drive as argument 2");
        ck(strstr(g_prog_lines[0], "old=nightfall-backup-20260909-1200") != NULL,
           "the CURRENT name as argument 3");
        ck(strstr(g_prog_lines[0], "new=before-the-update") != NULL,
           "the NEW name as argument 4 - the slot start_child grew for this");
        remove("/tmp/mock-rename.sh");
        g_rename_to[0] = '\0';

        remove("/tmp/mock-restore.sh"); remove("/tmp/mock-targets"); remove("/tmp/mock-backups");
        g_targets = NULL; g_target_n = 0; g_backups = NULL; g_backup_n = 0;
    }

    /* --- tar's checkpoints, made readable --- */
    {
        /* tar counts RECORDS and prints "Write checkpoint 4900000",
         * which during a real backup read as alarming rather than
         * informative. With the total announced up front this becomes
         * "50.2 GB of 86.0 GB (58%)". */
        show_progress("head", "subj", "warn");

        prog_append("backup: nightfall-total-kb: 90177536");        /* ~86 GiB */
        ck(g_prog_n == 0, "the total line is internal and stays out of the log");

        prog_append("/usr/bin/tar: Write checkpoint 4900000");
        ck(g_prog_n == 0, "checkpoints stay out of the log too, or they flood it");
        /* The status label is LONG_DOT; without a resolved width it
         * ellipsises to "..." and every assertion below would be
         * testing LVGL's truncation rather than our formatting. */
        lv_obj_update_layout(lv_screen_active());
        {
            const char *shown = lv_label_get_text(g_prog_status);
            ck(strstr(shown, "GB") != NULL, "progress is shown in GB, not records");
            ck(strstr(shown, "of") != NULL && strstr(shown, "%") != NULL,
               "and as a fraction of the whole job");
            /* 4900000 * 10240 = 50.176e9 bytes = 46.7 GiB of 86 GiB = 54% */
            ck(strstr(shown, "46.7 GB") != NULL, "converts records to bytes correctly");
            ck(strstr(shown, "(54%)") != NULL, "and the percentage matches");
        }

        /* Real steps must still reach the log. */
        prog_append("backup: mounting /dev/sda1");
        ck(g_prog_n == 1 && strstr(g_prog_lines[0], "mounting") != NULL,
           "ordinary output still lands in the rolling log");

        /* Without a total it degrades to a plain byte count. */
        show_progress("h", "s", "w");
        prog_append("/usr/bin/tar: Write checkpoint 100000");
        lv_obj_update_layout(lv_screen_active());
        ck(strstr(lv_label_get_text(g_prog_status), "written") != NULL,
           "with no total known it still reports how much has been written");
    }

    /* --- rescan: the drive cannot be present at boot --- */
    {
        /* With no keyboard, plugging the Ventoy stick in before reboot
         * makes the firmware boot Ventoy instead of the picker. So the
         * drive arrives while the picker is already running, and a scan
         * done once at startup would never see it. */
        setenv("NIGHTFALL_SCAN_SH", "/nonexistent/scan-drives.sh", 1);
        ck(rescan_drives() == -1, "rescan fails cleanly when the scan script is missing");

        FILE *sf = fopen("/tmp/mock-scan.sh", "w");
        fprintf(sf,
            "#!/bin/sh\n"
            "printf '/dev/sdb1\\texfat\\t\\t931G\\t742G\\n' > \"$3\"\n"
            "printf '/dev/sdb1\\tafter-hotplug\\tnow\\t84G\\n' > \"$4\"\n"
            "printf '/dev/sdb1\\t\\\\EFI\\\\BOOT\\\\BOOTX64.EFI\\t\\t931G\\n' > \"$5\"\n"
            "exit 0\n");
        fclose(sf); chmod("/tmp/mock-scan.sh", 0755);
        setenv("NIGHTFALL_SCAN_SH", "/tmp/mock-scan.sh", 1);

        snprintf(g_targets_path, sizeof(g_targets_path), "/tmp/mock-t.tsv");
        snprintf(g_backups_path, sizeof(g_backups_path), "/tmp/mock-b.tsv");
        snprintf(g_bootable_path, sizeof(g_bootable_path), "/tmp/mock-boot.tsv");
        g_target_n = 0; g_targets = NULL;
        g_backup_n = 0; g_backups = NULL;
        g_bootable_n = 0; g_bootable = NULL;

        ck(rescan_drives() == 0, "rescan runs the scan script");
        ck(g_target_n == 1, "a drive plugged in AFTER boot is now found");
        ck(!strcmp(g_targets[0].dev, "/dev/sdb1"), "with the right device");
        ck(g_backup_n == 1 && !strcmp(g_backups[0].name, "after-hotplug"),
           "and the backups on it are picked up too");
        ck(g_bootable_n == 1 && !strcmp(g_bootable[0].dev, "/dev/sdb1"),
           "and whether that same drive can be handed to firmware to boot");

        /* Unplugged again: the lists must empty, not keep stale entries
         * pointing at a device that is gone. */
        sf = fopen("/tmp/mock-scan.sh", "w");
        fprintf(sf, "#!/bin/sh\n: > \"$3\"\n: > \"$4\"\n: > \"$5\"\nexit 0\n");
        fclose(sf); chmod("/tmp/mock-scan.sh", 0755);
        ck(rescan_drives() == 0, "rescan runs again");
        ck(g_target_n == 0 && g_targets == NULL, "an unplugged drive disappears from the list");
        ck(g_backup_n == 0 && g_backups == NULL, "and so do its backups");
        ck(g_bootable_n == 0 && g_bootable == NULL, "and its boot-external entry too");

        remove("/tmp/mock-scan.sh"); remove("/tmp/mock-t.tsv"); remove("/tmp/mock-b.tsv"); remove("/tmp/mock-boot.tsv");
        g_targets_path[0] = '\0'; g_backups_path[0] = '\0'; g_bootable_path[0] = '\0';
    }

    /* --- boot an external drive: discovery TSV + the confirm --- */
    {
        FILE *bf = fopen("/tmp/mock-bootable", "w");
        fprintf(bf, "/dev/sda1\t\\EFI\\BOOT\\BOOTX64.EFI\t\t57G\n");
        fprintf(bf, "/dev/sdc1\t\\EFI\\BOOT\\BOOTIA32.EFI\tRESCUE\t8G\n");
        fclose(bf);
        static struct bootable_drive bd[8];
        int bn = load_bootable_drives("/tmp/mock-bootable", bd, 8);
        ck(bn == 2, "parses one row per bootable drive");
        ck(!strcmp(bd[0].dev, "/dev/sda1") && !strcmp(bd[0].loader, "\\EFI\\BOOT\\BOOTX64.EFI"),
           "device and loader path round-trip");
        ck(bd[0].label[0] == '\0', "an empty label field stays empty - the UI falls back to the device name");
        ck(!strcmp(bd[1].label, "RESCUE"), "a real label is kept when the drive has one");

        /* Confirming must end the running process the same way a live-USB
         * or kernel choice does - via the flags the main loop's break
         * condition reads - since this is a genuine boot (of a sort),
         * not a child job like backup/restore. */
        g_bootable = bd; g_bootable_n = bn;
        g_boot_external = 0; g_boot_external_part[0] = '\0'; g_boot_external_loader[0] = '\0';
        confirm_boot_external(1);
        ck(g_boot_external == 1, "confirming sets the flag that ends the main loop");
        ck(!strcmp(g_boot_external_part, "/dev/sdc1"), "records which partition, for the BOOT_EXTERNAL_PART contract");
        ck(!strcmp(g_boot_external_loader, "\\EFI\\BOOT\\BOOTIA32.EFI"), "and which loader, for BOOT_EXTERNAL_LOADER");
        g_boot_external = 0; g_boot_external_part[0] = '\0'; g_boot_external_loader[0] = '\0';

        remove("/tmp/mock-bootable");
        g_bootable = NULL; g_bootable_n = 0;
    }

    /* --- boot a live USB: discovery, scanning, and the confirm --- */
    {
        FILE *lf = fopen("/tmp/mock-isos", "w");
        fprintf(lf, "ubuntu-24.04.iso\t5.0G\tubuntu-24.04.iso\n");
        fprintf(lf, "isos/debian-live.iso\t980M\tdebian-live.iso\n");
        fprintf(lf, "bare-path-only.iso\n");   /* short row: name defaults to path */
        fclose(lf);
        static struct live_iso li[8];
        int ln = load_live_isos("/tmp/mock-isos", li, 8);
        ck(ln == 3, "parses one row per candidate ISO");
        ck(!strcmp(li[0].path, "ubuntu-24.04.iso") && !strcmp(li[0].size, "5.0G"),
           "path and size round-trip");
        ck(!strcmp(li[1].path, "isos/debian-live.iso"),
           "a subdirectory in the path survives - it is what the cmdline needs later");
        ck(!strcmp(li[2].name, "bare-path-only.iso"),
           "a row with no separate name field falls back to the path");

        /* scan_live_isos() is the on-demand equivalent of rescan_drives():
         * one drive, on tap, not folded into the periodic scan. */
        setenv("NIGHTFALL_LIVE_ISOS_SH", "/nonexistent/discover-live-isos.sh", 1);
        ck(scan_live_isos("/dev/sdb1") == -1, "fails cleanly when the discovery script is missing");

        FILE *df = fopen("/tmp/mock-discover-isos.sh", "w");
        fprintf(df, "#!/bin/sh\necho \"MARKER_DEV=$1\" >&2\n"
                    "printf 'live.iso\\t3.2G\\tlive.iso\\n'\nexit 0\n");
        fclose(df); chmod("/tmp/mock-discover-isos.sh", 0755);
        setenv("NIGHTFALL_LIVE_ISOS_SH", "/tmp/mock-discover-isos.sh", 1);
        setenv("NIGHTFALL_LIVE_ISOS_TSV", "/tmp/mock-live-isos.tsv", 1);

        g_live_iso_n = 0; g_live_isos = NULL;
        ck(scan_live_isos("/dev/sdb1") == 0, "scans the named drive");
        ck(g_live_iso_n == 1 && !strcmp(g_live_isos[0].path, "live.iso"),
           "and loads what it found");

        /* Confirming an ISO must end the running process the same way a
         * kernel choice or Restart does - via the flags the main loop's
         * break condition reads - not spawn a child like backup/restore. */
        g_live_boot = 0; g_live_iso_path[0] = '\0';
        confirm_live_boot(0);
        ck(g_live_boot == 1, "confirming sets the flag that ends the main loop");
        ck(!strcmp(g_live_iso_path, "live.iso"), "and records which ISO, for the LIVE_BOOT_ISO contract");
        g_live_boot = 0; g_live_iso_path[0] = '\0';

        remove("/tmp/mock-isos"); remove("/tmp/mock-discover-isos.sh"); remove("/tmp/mock-live-isos.tsv");
        g_live_isos = NULL; g_live_iso_n = 0;
    }

    /* --- saved per-kernel command lines --- */
    {
        FILE *sf = fopen("/tmp/mock-saved-cmdline", "w");
        fprintf(sf, "/boot/vmlinuz-7.1.12\troot=x ro loglevel=7\n");
        fprintf(sf, "/boot/vmlinuz-EMPTY\t\n");          /* not an override */
        fprintf(sf, "no-tab-here\n");                      /* malformed */
        fclose(sf);
        g_saved_n = 0;
        load_saved_cmdlines("/tmp/mock-saved-cmdline");
        ck(g_saved_n == 1, "only well-formed, non-empty entries count as saved");
        ck(has_saved_cmdline("/boot/vmlinuz-7.1.12"), "recognises a kernel with a saved command line");
        ck(!has_saved_cmdline("/boot/vmlinuz-EMPTY"), "an empty value is not an override");
        ck(!has_saved_cmdline("/boot/vmlinuz-nope"), "an unknown kernel has none");

        g_setcl_set = 0;
        remember_cmdline("/boot/vmlinuz-7.1.12", "root=x ro debug");
        ck(g_setcl_set, "saving marks a change to persist");
        ck(strchr(g_setcl, '\t') != NULL, "SET_CMDLINE is tab-separated as init expects");
        ck(!strcmp(strchr(g_setcl, '\t') + 1, "root=x ro debug"), "carries the edited text");
        remember_cmdline("/boot/vmlinuz-7.1.12", "");
        ck(*(strchr(g_setcl, '\t') + 1) == '\0', "forgetting sends an empty value");
        remove("/tmp/mock-saved-cmdline");
        g_saved_n = 0; g_setcl_set = 0;
    }

    /* --- confirm dialog layout: Boot spans the bottom row --- */
    {
        g_entries = rec; g_entry_n = 4;
        /* idx 0 has a recovery variant (idx 1); idx 2 does not. */
        for (int variant = 0; variant < 2; variant++) {
            int idx = variant ? 2 : 0;
            open_confirm_dialog(idx);
            lv_obj_update_layout(lv_layer_top());

            lv_obj_t *top = lv_layer_top();
            lv_obj_t *bd  = lv_obj_get_child(top, lv_obj_get_child_count(top) - 1);
            lv_obj_t *mb  = lv_obj_get_child(bd, 0);
            lv_obj_t *ft  = lv_msgbox_get_footer(mb);
            uint32_t nb = lv_obj_get_child_count(ft);
            /* FOUR either way now. Recovery is deliberately not offered:
             * Ubuntu's recovery mode is an ncurses menu, and on a tablet
             * with no keyboard tapping it reaches a screen nothing can
             * be done with. Asserted for BOTH cases on purpose - a
             * kernel that HAS a recovery variant must still show four,
             * so quietly bringing the button back trips this. */
            ck(nb == 4u,
               variant ? "no recovery variant: four buttons"
                       : "recovery variant present: still four buttons, no Recovery");

            /* Boot is created last, so it is the final child. */
            lv_obj_t *boot = lv_obj_get_child(ft, nb - 1);
            lv_area_t ba, fa;
            lv_obj_get_coords(boot, &ba);
            lv_obj_get_coords(ft, &fa);

            int lowest = 1;
            for (uint32_t i = 0; i + 1 < nb; i++) {
                lv_area_t oa; lv_obj_get_coords(lv_obj_get_child(ft, i), &oa);
                if (oa.y1 >= ba.y1) lowest = 0;
            }
            ck(lowest, variant ? "Boot is the bottom-most button (no recovery variant)"
                               : "Boot is the bottom-most button (recovery variant exists)");
            ck(lv_area_get_width(&ba) > (lv_area_get_width(&fa) * 3) / 4,
               variant ? "Boot spans the row (no recovery variant)"
                       : "Boot spans the row (recovery variant exists)");
            lv_obj_delete(bd);
            lv_obj_update_layout(lv_layer_top());
        }
    }

    /* --- removal: the distinct-kernel list --- */
    /* Real menus repeat each release as a plain entry, a "with Linux X"
     * entry and a recovery entry. Removal must offer each RELEASE once,
     * not each menu entry - deleting the same files three times would
     * be both confusing and wrong. */
    static struct entry many[5] = {
        { "Ubuntu",                    "/boot/vmlinuz-7.1.12", "/boot/initrd.img-7.1.12", "ro", 0 },
        { "Ubuntu, with Linux 7.1.12", "/boot/vmlinuz-7.1.12", "/boot/initrd.img-7.1.12", "ro", 0 },
        { "Ubuntu, 7.1.12 (recovery)", "/boot/vmlinuz-7.1.12", "/boot/initrd.img-7.1.12", "ro", 0 },
        { "Ubuntu, with Linux 7.1.9",  "/boot/vmlinuz-7.1.9",  "/boot/initrd.img-7.1.9",  "ro", 0 },
        { "memtest-ish (no vmlinuz)",  "/boot/memtest86+.bin", "",                        "",   0 },
    };
    g_entries = many; g_entry_n = 5;
    build_kernel_list();
    ck(g_kernel_n == 2, "five menu entries collapse to two distinct kernels");
    ck(!strcmp(g_kernels[0].release, "7.1.12") && g_kernels[0].refs == 3,
       "release parsed from the vmlinuz name, with its 3 menu entries counted");
    ck(!strcmp(g_kernels[1].release, "7.1.9") && g_kernels[1].refs == 1,
       "the second kernel is listed once");
    for (int i = 0; i < g_kernel_n; i++)
        if (strstr(g_kernels[i].release, "memtest")) ck(0, "non-vmlinuz entry leaked into the removal list");
    ck(1, "non-vmlinuz entries are not offered for removal");

    /* --- removal runs the right script with the RELEASE, not a path --- */
    f = fopen("/tmp/mock-remove.sh", "w");
    fprintf(f, "#!/bin/sh\necho \"remove-kernel: removing $2\"\nexit 0\n");
    fclose(f); chmod("/tmp/mock-remove.sh", 0755);
    setenv("NIGHTFALL_REMOVE_SH", "/tmp/mock-remove.sh", 1);
    g_prog_n = 0;
    ck(start_remove(0) == 0, "starts the removal child");
    ck(drain() == 1, "reports success");
    ck(strstr(g_prog_lines[0], "removing 7.1.12") != NULL,
       "passes the kernel RELEASE to the script, not a file path");

    setenv("NIGHTFALL_REMOVE_SH", "/nonexistent/remove-kernel.sh", 1);
    ck(start_remove(0) == -1, "refuses to pretend when the remove script is missing");

    /* --- backup names are typed by a person, so they are untrusted --- */
    {
        char out[128];

        sanitize_backup_name("before-kernel-7.2.4", out, sizeof(out));
        ck(!strcmp(out, "before-kernel-7.2.4"), "leaves a sensible name alone");

        sanitize_backup_name("before big update", out, sizeof(out));
        ck(!strcmp(out, "before-big-update"), "spaces become dashes");

        /* The one that matters: a name is ONE path component. Anything
         * with a slash would write the archive outside the backup
         * directory, where discovery never finds it and the delete list
         * can never offer it. */
        sanitize_backup_name("../../etc/passwd", out, sizeof(out));
        ck(strchr(out, '/') == NULL, "a path-shaped name cannot keep its slashes");

        sanitize_backup_name("-rf", out, sizeof(out));
        ck(out[0] != '-', "never starts with a dash (it would read as an option)");

        sanitize_backup_name(".hidden", out, sizeof(out));
        ck(out[0] != '.', "never starts with a dot (it would hide the archive)");

        sanitize_backup_name("a///b", out, sizeof(out));
        ck(!strcmp(out, "a-b"), "runs of bad characters collapse to one dash");

        sanitize_backup_name("trailing---", out, sizeof(out));
        ck(!strcmp(out, "trailing"), "no trailing dash");

        /* Empty, or nothing but punctuation, must still produce a usable
         * filename rather than an empty one. */
        sanitize_backup_name("", out, sizeof(out));
        ck(strstr(out, "nightfall-backup-") == out, "an empty name falls back to the default");
        sanitize_backup_name("///", out, sizeof(out));
        ck(strstr(out, "nightfall-backup-") == out, "so does a name that sanitises to nothing");

        /* Must not run off the end of a short buffer. */
        char small[8];
        sanitize_backup_name("abcdefghijklmnop", small, sizeof(small));
        ck(strlen(small) < sizeof(small), "respects the buffer size");
    }

    remove("/tmp/mock-remove.sh");
    remove("/tmp/mock-install-ok.sh"); remove("/tmp/mock-install-bad.sh");
    /* --- tapping to stop the countdown must not move the menu --- */
    /* The countdown line used to be HIDDEN on the first tap. The screen is
     * a flex column, so every button below it jumped up one line - which
     * Bob saw as a glitch. Asserted as the thing a person notices: the
     * menu's position, before and after. */
    {
        lv_obj_t *scr = lv_obj_create(NULL);
        lv_screen_load(scr);
        static struct entry e2[3] = {
            { "Ubuntu", "/boot/vmlinuz-a", "/boot/initrd-a", "ro", 0 },
            { "Ubuntu old", "/boot/vmlinuz-b", "/boot/initrd-b", "ro", 0 },
            { "Ubuntu older", "/boot/vmlinuz-c", "/boot/initrd-c", "ro", 0 },
        };
        lv_obj_t *cd2 = NULL;
        build_ui(e2, 3, 30, &cd2);
        lv_label_set_text_fmt(cd2, "Booting default in %ds - tap or press a key to choose", 30);
        lv_obj_update_layout(scr);
        ck(cd2 != NULL, "a timeout draws the countdown line");

        lv_area_t before, after;
        lv_obj_get_coords(g_list, &before);
        int32_t cd_h = lv_obj_get_height(cd2);

        countdown_silence(cd2);            /* what the first tap does */
        lv_obj_update_layout(scr);
        lv_obj_get_coords(g_list, &after);

        ck(before.y1 == after.y1, "the menu does not move when the countdown is dismissed");
        ck(lv_obj_get_height(cd2) == cd_h, "the countdown keeps its height");
        ck(lv_obj_get_style_opa(cd2, 0) == LV_OPA_TRANSP, "and is no longer visible");
        ck(!lv_obj_has_flag(cd2, LV_OBJ_FLAG_HIDDEN), "by transparency, not by removing it from the layout");
    }

    /* --- the boot screens follow rotation --- */
    /* The splash and the booting screen run outside the main loop, so they
     * only rotate if the pump that drives them polls the accelerometer.
     * Driven through the REAL lvgl_pump() with a fake IIO device. */
    {
        char dir[] = "/tmp/nf-rot-XXXXXX";
        if (mkdtemp(dir)) {
            char pth[256]; FILE *af;
            snprintf(pth, sizeof pth, "%s/in_accel_x_raw", dir);
            af = fopen(pth, "w"); if (af) { fprintf(af, "0\n"); fclose(af); }
            /* +Y down: held upright landscape, measured on the Slate. */
            snprintf(pth, sizeof pth, "%s/in_accel_y_raw", dir);
            af = fopen(pth, "w"); if (af) { fprintf(af, "7800\n"); fclose(af); }

            setenv("NIGHTFALL_ACCEL", dir, 1);
            g_accel_dir[0] = '\0';
            accel_find();
            g_autorotate = 1;

            static struct drm_dev rdd;
            rdd.width = 3000; rdd.height = 2000; rdd.stride = 3000 * 4;
            static struct nightfall_ctx rctx;
            rctx.drm = &rdd; rctx.rot = ROT_270; rctx.cw = 2000; rctx.ch = 3000;
            g_ctx = &rctx;

            /* Long enough for the debounce: readings are 250ms apart and
             * three in a row are needed before the screen turns. */
            for (int i = 0; i < 70 && rctx.rot == ROT_270; i++) {
                lvgl_pump();
                usleep(30 * 1000);
            }
            ck(rctx.rot == ROT_0, "a boot screen rotates when the tablet is turned");
            ck(rctx.cw == 3000 && rctx.ch == 2000,
               "and the canvas swaps with it, so the screen is not left blank");

            snprintf(pth, sizeof pth, "%s/in_accel_x_raw", dir); unlink(pth);
            snprintf(pth, sizeof pth, "%s/in_accel_y_raw", dir); unlink(pth);
            rmdir(dir);
            unsetenv("NIGHTFALL_ACCEL");
            g_accel_dir[0] = '\0';
            g_autorotate = 0;
        }
    }

    /* --- kexec blocked by kernel lockdown: explained, never offered --- */
    {
        /* Helper: footer button count of the topmost dialog on layer_top. */
        #define TOP_FOOTER_BTNS() ({ \
            lv_obj_t *_top = lv_layer_top(); \
            lv_obj_t *_bd  = lv_obj_get_child(_top, lv_obj_get_child_count(_top) - 1); \
            lv_obj_t *_mb  = lv_obj_get_child(_bd, 0); \
            (int)lv_obj_get_child_count(lv_msgbox_get_footer(_mb)); })

        static struct entry ke[1] = {{ "Ubuntu", "/boot/vmlinuz-x", "/boot/initrd-x", "ro", 0 }};
        g_entries = ke; g_entry_n = 1;

        unsetenv("NIGHTFALL_KEXEC_BLOCKED");
        ck(kexec_blocked_reason() == NULL, "not blocked when init did not say so");
        setenv("NIGHTFALL_KEXEC_BLOCKED", "", 1);
        ck(kexec_blocked_reason() == NULL, "an EMPTY value is not blocked either - never refuse with nothing to say");

        lv_obj_clean(lv_layer_top());
        unsetenv("NIGHTFALL_KEXEC_BLOCKED");
        ck(kernel_row_tapped(0) == 1, "an unblocked tap opens the confirm dialog");
        lv_obj_update_layout(lv_layer_top());
        ck(TOP_FOOTER_BTNS() == 4, "and it is the four-button boot dialog");

        lv_obj_clean(lv_layer_top());
        setenv("NIGHTFALL_KEXEC_BLOCKED", "kernel lockdown is 'integrity', which refuses kexec.", 1);
        ck(kernel_row_tapped(0) == 0, "a blocked tap does NOT open the boot dialog");
        lv_obj_update_layout(lv_layer_top());
        ck(TOP_FOOTER_BTNS() == 1, "it explains instead, with a single OK");

        /* The explanation carries the reason and says what still works. */
        {
            lv_obj_t *top = lv_layer_top();
            lv_obj_t *bd  = lv_obj_get_child(top, lv_obj_get_child_count(top) - 1);
            lv_obj_t *mb  = lv_obj_get_child(bd, 0);
            lv_obj_t *ct  = lv_msgbox_get_content(mb);
            int has_reason = 0, has_still = 0;
            for (uint32_t i = 0; i < lv_obj_get_child_count(ct); i++) {
                lv_obj_t *c = lv_obj_get_child(ct, i);
                if (!lv_obj_check_type(c, &lv_label_class)) continue;
                const char *t = lv_label_get_text(c);
                if (strstr(t, "lockdown is 'integrity'")) has_reason = 1;
                if (strstr(t, "drive") && strstr(t, "still work")) has_still = 1;
            }
            ck(has_reason, "the notice carries init's reason verbatim");
            ck(has_still, "and says booting a drive, backups and repairs still work");
        }

        /* A live-ISO boot is also a kexec, so it is refused the same way. */
        {
            static struct live_iso lis[1] = {{ "live.iso", "3.2G", "live.iso" }};
            g_live_isos = lis; g_live_iso_n = 1;
            lv_obj_clean(lv_layer_top());
            ck(live_iso_tapped(0) == 0, "a blocked live-ISO tap is refused too");
            lv_obj_update_layout(lv_layer_top());
            ck(TOP_FOOTER_BTNS() == 1, "with the same single-OK explanation");
            lv_obj_clean(lv_layer_top());
            unsetenv("NIGHTFALL_KEXEC_BLOCKED");
            ck(live_iso_tapped(0) == 1, "and opens the normal confirm when kexec works");
            lv_obj_update_layout(lv_layer_top());
            ck(TOP_FOOTER_BTNS() == 2, "which is the two-button Cancel/Boot dialog");
            setenv("NIGHTFALL_KEXEC_BLOCKED", "kernel lockdown is 'integrity', which refuses kexec.", 1);
            g_live_isos = NULL; g_live_iso_n = 0;
        }

        /* The Boot screen warns at the top. */
        lv_obj_clean(lv_layer_top());
        show_kernel_list();
        {
            int banner = 0;
            for (uint32_t i = 0; i < lv_obj_get_child_count(g_list); i++) {
                lv_obj_t *c = lv_obj_get_child(g_list, i);
                if (lv_obj_check_type(c, &lv_label_class) &&
                    strstr(lv_label_get_text(c), "cannot be booted from here")) banner = 1;
            }
            ck(banner, "the Boot screen shows a banner when kernels cannot be booted");
        }
        unsetenv("NIGHTFALL_KEXEC_BLOCKED");
        show_kernel_list();
        {
            int banner = 0;
            for (uint32_t i = 0; i < lv_obj_get_child_count(g_list); i++) {
                lv_obj_t *c = lv_obj_get_child(g_list, i);
                if (lv_obj_check_type(c, &lv_label_class) &&
                    strstr(lv_label_get_text(c), "cannot be booted from here")) banner = 1;
            }
            ck(!banner, "and no banner at all when they can");
        }
        lv_obj_clean(lv_layer_top());
        show_main_menu();
        #undef TOP_FOOTER_BTNS
    }

    /* --- keyboard navigation and mouse --- */
    {
        unsetenv("NIGHTFALL_KEXEC_BLOCKED");
        static struct entry ne[2] = {{ "Ubuntu", "/boot/vmlinuz-x", "/boot/initrd-x", "ro", 0 },
                                     { "Ubuntu old", "/boot/vmlinuz-y", "/boot/initrd-y", "ro", 0 }};
        g_entries = ne; g_entry_n = 2;
        #define HDR() lv_label_get_text(g_header)
        #define ON_MAIN() (strstr(HDR(), "Nightfall") != NULL)
        #define PUMP() do { lv_timer_handler(); lv_timer_handler(); } while (0)
        struct input_event kev = { .type = EV_KEY };

        /* the key table */
        ck(nav_action_for_key(KEY_DOWN, 0) == NAV_DOWN && nav_action_for_key(KEY_UP, 0) == NAV_UP, "Down/Up are their own actions, not aliases of Right/Left");
        ck(nav_action_for_key(KEY_RIGHT, 0) == NAV_NEXT && nav_action_for_key(KEY_LEFT, 0) == NAV_PREV, "Right/Left step through creation order, one at a time");
        ck(nav_action_for_key(KEY_TAB, 0) == NAV_NEXT && nav_action_for_key(KEY_TAB, 1) == NAV_PREV, "Tab goes forward and Shift+Tab back");
        ck(nav_action_for_key(KEY_ENTER, 0) == NAV_ACTIVATE && nav_action_for_key(KEY_KPENTER, 0) == NAV_ACTIVATE &&
           nav_action_for_key(KEY_SPACE, 0) == NAV_ACTIVATE, "Enter, keypad Enter and Space activate");
        ck(nav_action_for_key(KEY_ESC, 0) == NAV_ESCAPE && nav_action_for_key(KEY_BACKSPACE, 0) == NAV_ESCAPE, "Escape and Backspace go back");
        ck(nav_action_for_key(KEY_A, 0) == NAV_NONE, "an ordinary letter does nothing");

        /* moving around the main menu */
        lv_obj_clean(lv_layer_top()); nav_set_focus(NULL);
        show_main_menu();
        lv_obj_t *c[NAV_MAX];
        int n = nav_candidates(c);
        ck(n >= 6, "the main menu's rows are all reachable candidates");
        ck(g_nav_focus == NULL, "no focus is drawn until a key is used (touch users never see one)");
        nav_do(NAV_ACTIVATE);
        ck(g_nav_focus == c[0] && ON_MAIN(), "Enter with nothing focused only SHOWS focus, it does not fire a button");
        nav_do(NAV_NEXT);
        ck(g_nav_focus == c[1], "Right moves to the next row");
        nav_do(NAV_PREV); nav_do(NAV_PREV);
        ck(g_nav_focus == c[n - 1], "Left from the first row wraps to the last");
        nav_do(NAV_FIRST);
        ck(g_nav_focus == c[0], "Home goes to the first row");
        nav_do(NAV_LAST);
        ck(g_nav_focus == c[n - 1], "End goes to the last");
        ck(nav_do(NAV_ESCAPE) == 0, "Escape on the main menu (no Back row) does nothing");

        /* Down/Up on a PLAIN LIST: one candidate per visual row, so this
         * must behave exactly like Next/Prev - the one thing the whole
         * row-width design promises not to change. */
        nav_do(NAV_FIRST);
        nav_do(NAV_DOWN);
        ck(g_nav_focus == c[1], "on a plain list, Down moves exactly one row - same as Right");
        nav_do(NAV_UP);
        ck(g_nav_focus == c[0], "and Up moves back exactly one - same as Left");
        nav_do(NAV_UP);
        ck(g_nav_focus == c[0], "but unlike Left, Up does NOT wrap off the top of a list");
        nav_do(NAV_LAST);
        nav_do(NAV_DOWN);
        ck(g_nav_focus == c[n - 1], "and Down does not wrap off the bottom either - it just stays, clamped");

        /* activating a row runs the same handler a tap does */
        nav_do(NAV_FIRST);
        nav_do(NAV_ACTIVATE);
        ck(!ON_MAIN(), "Enter on the first row opens the Boot screen");
        ck(g_nav_focus == NULL, "and the deleted row does not leave a dangling focus behind");
        nav_do(NAV_ESCAPE);
        ck(ON_MAIN(), "Escape on a sub-screen presses its Back row");

        /* key semantics */
        nav_set_focus(NULL);
        kev.code = KEY_DOWN; kev.value = 1;
        ck(kb_handle_event(&kev) == 1 && g_nav_focus != NULL, "a key press moves focus and counts as the person being present");
        kev.value = 0;
        ck(kb_handle_event(&kev) == 0, "a key RELEASE does nothing");
        nav_do(NAV_FIRST);
        kev.code = KEY_ENTER; kev.value = 2;
        kb_handle_event(&kev);
        ck(ON_MAIN(), "a HELD Enter (auto-repeat) does not fire the button again");
        kev.value = 1;
        kb_handle_event(&kev);
        ck(!ON_MAIN(), "the first Enter press does");
        nav_do(NAV_ESCAPE);
        kev.code = KEY_LEFTSHIFT; kev.value = 1; kb_handle_event(&kev);
        nav_set_focus(NULL);
        nav_candidates(c);
        kev.code = KEY_TAB; kev.value = 1; kb_handle_event(&kev);
        n = nav_candidates(c);
        ck(g_nav_focus == c[n - 1], "Shift is tracked: Shift+Tab starts from the end");
        kev.code = KEY_LEFTSHIFT; kev.value = 0; kb_handle_event(&kev);

        /* modality: an open dialog owns the keyboard */
        lv_obj_clean(lv_layer_top()); nav_set_focus(NULL);
        show_main_menu();
        nav_candidates(c);
        nav_do(NAV_FIRST);
        lv_obj_t *behind = g_nav_focus;
        open_confirm_dialog(0);
        lv_obj_update_layout(lv_layer_top());
        n = nav_candidates(c);
        ck(n == 4, "with a dialog open only ITS four buttons are reachable, not the menu behind it");
        nav_do(NAV_NEXT);
        ck(g_nav_focus != behind && nav_index_of(c, n, g_nav_focus) >= 0, "focus left behind the dialog is dropped and moves into it");

        /* The real hardware bug: this dialog is a genuine 2x2 grid (Edit,
         * Set Default over Cancel, Boot). Right/Left step through creation
         * order, which happens to also be row order for THIS dialog's two
         * rows - so Right always looked correct even before row_width
         * existed. Down did not: aliased to the same action as Right, it
         * moved Edit -> Set Default (next in creation order) instead of
         * Edit -> Cancel (next ROW), and could never reach Boot from Set
         * Default at all. Asserted on the buttons' own text, not raw
         * indices, so this fails loudly if the creation order in
         * open_confirm_dialog ever changes without this being revisited. */
        nav_do(NAV_FIRST);
        ck(!strcmp(nav_button_text(g_nav_focus), "Edit"), "starts on Edit, top-left of the grid");
        nav_do(NAV_DOWN);
        ck(!strcmp(nav_button_text(g_nav_focus), "Cancel"), "Down from Edit reaches Cancel - the button BELOW it, not Set Default");
        nav_do(NAV_UP);
        ck(!strcmp(nav_button_text(g_nav_focus), "Edit"), "and Up from Cancel goes back to Edit");
        nav_do(NAV_NEXT);
        ck(!strcmp(nav_button_text(g_nav_focus), "Set Default"), "Right from Edit still moves along the top row");
        nav_do(NAV_DOWN);
        /* Cancel is ITS OWN full-width row here (this dialog has no
         * Recovery button, the common case) - the row immediately below
         * Edit/Set Default's shared row either one of them steps down
         * into, same as Down from Edit did. Boot, one more row down
         * still, is reached by pressing Down again below. */
        ck(!strcmp(nav_button_text(g_nav_focus), "Cancel"), "and Down from Set Default reaches the very next row too, same Cancel Edit did");
        nav_do(NAV_DOWN);
        ck(!strcmp(nav_button_text(g_nav_focus), "Boot"), "one more Down reaches Boot, the row after that");
        nav_do(NAV_DOWN);
        ck(!strcmp(nav_button_text(g_nav_focus), "Boot"), "Down from the bottom row of the grid is clamped, not wrapped back to the top");

        /* The focus ring has to actually WIN on every button, which is not
         * automatic: Cancel and Boot carry a decorative 1px top divider set
         * as LOCAL style properties, and in LVGL a local property beats a
         * style added with lv_obj_add_style at the same selector. With the
         * ring added as a shared style those two silently kept their 1px
         * TOP border and never highlighted - exactly the two buttons that
         * matter most, and exactly what Bob hit: "its a blind selection
         * right now though i cant see what i'm on". Asserted on the
         * COMPUTED border, so it fails if the ring ever stops winning. */
        for (int i = 0; i < n; i++) {
            nav_set_focus(c[i]);
            int w = (int)lv_obj_get_style_border_width(c[i], LV_PART_MAIN);
            int side = (int)lv_obj_get_style_border_side(c[i], LV_PART_MAIN);
            ck(w == ui_px(8) && side == LV_BORDER_SIDE_FULL,
               nav_button_text(c[i])[0] ? "the focus ring wins over a button's own local border decoration" : "focus ring applies");
        }
        /* ...and leaving a button puts ITS decoration back, rather than
         * stripping the divider Cancel and Boot are drawn with. */
        nav_set_focus(c[0]);
        nav_set_focus(NULL);
        {
            int restored_any = 0;
            for (int i = 0; i < n; i++)
                if ((int)lv_obj_get_style_border_width(c[i], LV_PART_MAIN) == 1 &&
                    (int)lv_obj_get_style_border_side(c[i], LV_PART_MAIN) == LV_BORDER_SIDE_TOP) restored_any++;
            ck(restored_any == 2, "unfocusing restores each button's own decoration - Cancel and Boot get their divider back");
        }

        nav_do(NAV_FIRST);
        ck(nav_do(NAV_ESCAPE) == 1, "Escape finds the dialog's Cancel");
        PUMP();
        ck(lv_obj_get_child_count(lv_layer_top()) == 0, "and the dialog closes");
        nav_set_focus(NULL);

        /* --- typing into a textarea with a REAL keyboard ---
         * The on-screen keyboard every text dialog puts up is tap-driven;
         * on hardware the physical keyboard did nothing at all, because
         * every printable key resolves to NAV_NONE. Built as the same
         * shape those dialogs use (a textarea plus an lv_keyboard bound to
         * it on lv_layer_top()) rather than by driving edit_cb, so it
         * tests the mechanism active_textarea() actually relies on. */
        {
            /* the pure key table first - no UI needed */
            ck(key_to_char(KEY_A, 0) == 'a' && key_to_char(KEY_A, 1) == 'A', "letters, and Shift makes them upper case");
            ck(key_to_char(KEY_1, 0) == '1' && key_to_char(KEY_1, 1) == '!', "digits, and their shifted symbols");
            ck(key_to_char(KEY_0, 0) == '0' && key_to_char(KEY_0, 1) == ')', "zero sits at the END of the digit row, not the start");
            ck(key_to_char(KEY_MINUS, 0) == '-' && key_to_char(KEY_MINUS, 1) == '_' &&
               key_to_char(KEY_EQUAL, 0) == '=' && key_to_char(KEY_DOT, 0) == '.' &&
               key_to_char(KEY_SLASH, 0) == '/', "the punctuation a kernel command line is actually made of");
            ck(key_to_char(KEY_SPACE, 0) == ' ', "Space types a space");
            ck(key_to_char(KEY_BACKSPACE, 0) == LV_KEY_BACKSPACE && key_to_char(KEY_DELETE, 0) == LV_KEY_DEL,
               "Backspace and Delete map to LVGL's own editing codes");
            ck(key_to_char(KEY_LEFT, 0) == LV_KEY_LEFT && key_to_char(KEY_RIGHT, 0) == LV_KEY_RIGHT,
               "Left/Right move the cursor while typing");
            ck(key_to_char(KEY_UP, 0) == 0 && key_to_char(KEY_DOWN, 0) == 0 && key_to_char(KEY_ENTER, 0) == 0 &&
               key_to_char(KEY_ESC, 0) == 0 && key_to_char(KEY_TAB, 0) == 0,
               "Up/Down/Enter/Escape/Tab are NOT typing keys - they stay navigation, to reach the dialog's buttons");

            /* Drive the REAL Edit dialog rather than a hand-built stand-in:
             * open the confirm dialog and activate its Edit button, which
             * is what a person does, and what puts up the actual textarea,
             * on-screen keyboard and footer buttons together. */
            lv_obj_clean(lv_layer_top()); nav_set_focus(NULL);
            open_confirm_dialog(0);
            lv_obj_update_layout(lv_layer_top());
            nav_candidates(c);
            nav_do(NAV_FIRST);
            ck(!strcmp(nav_button_text(g_nav_focus), "Edit"), "the confirm dialog's Edit button is reachable");
            nav_do(NAV_ACTIVATE);
            PUMP();
            lv_obj_update_layout(lv_layer_top());

            lv_obj_t *ta = active_textarea();
            ck(ta != NULL, "activating Edit opens a textarea, found via the on-screen keyboard bound to it");

            /* Guarded: every assertion below dereferences it, and a test
             * that segfaults on a regression reports NOTHING - not even the
             * suite's own tally. Fail the rest loudly instead. */
            struct input_event tev = { .type = EV_KEY, .value = 1 };
            if (!ta) {
                ck(0, "SKIPPED (no textarea): typing into the edit dialog");
            } else {
            lv_textarea_set_text(ta, "");
            tev.code = KEY_R; kb_handle_event(&tev);
            tev.code = KEY_O; kb_handle_event(&tev);
            ck(!strcmp(lv_textarea_get_text(ta), "ro"), "a real keypress types into the textarea instead of doing nothing");

            /* The three that mean something DIFFERENT while typing. */
            tev.code = KEY_SPACE; kb_handle_event(&tev);
            ck(!strcmp(lv_textarea_get_text(ta), "ro "), "Space types a space rather than activating a button");
            tev.code = KEY_BACKSPACE; kb_handle_event(&tev);
            ck(!strcmp(lv_textarea_get_text(ta), "ro"), "Backspace deletes a character rather than acting as Escape");
            nav_set_focus(NULL);
            tev.code = KEY_LEFT; kb_handle_event(&tev);
            ck(g_nav_focus == NULL, "Left moves the cursor rather than stepping between buttons");

            /* ...and the ones that must NOT be swallowed by the textarea,
             * or there is no way out of it to the dialog's own buttons.
             * This is the case that found the nav_scope() bug: the
             * on-screen keyboard is the LAST child of lv_layer_top() (it
             * has to be, to draw above the backdrop), so taking the
             * topmost child as the modal scope picked the KEYBOARD - a
             * buttonmatrix with no button children - and left every text
             * dialog with zero reachable candidates. */
            int n_dlg = nav_candidates(c);
            ck(n_dlg > 0, "the edit dialog's own buttons are reachable - the keyboard on top does not become the nav scope");
            tev.code = KEY_DOWN; kb_handle_event(&tev);
            ck(g_nav_focus != NULL, "Down still navigates - it is how you leave the text for the buttons");
            }

            lv_obj_clean(lv_layer_top());
            ck(active_textarea() == NULL, "with the dialog gone, typing keys go back to navigation");
            nav_set_focus(NULL);

            /* With a REAL keyboard there should be no on-screen one at
             * all: it costs 45% of the screen to duplicate a keyboard the
             * person is already touching. Bob, on hardware: "the osk still
             * showing up". Typing has to keep working without it, which is
             * why the open textarea is tracked directly rather than looked
             * up through the on-screen keyboard that may not exist. */
            int saved_n = g_input_n;
            g_input_n = 1;
            g_inputs[0].kind = IN_KEYBOARD;
            snprintf(g_inputs[0].name, sizeof(g_inputs[0].name), "fake-kbd");
            ck(have_physical_keyboard() == 1, "a keyboard in the input list is what counts as having a real one");

            lv_obj_clean(lv_layer_top()); nav_set_focus(NULL);
            open_confirm_dialog(0);
            lv_obj_update_layout(lv_layer_top());
            nav_candidates(c);
            nav_do(NAV_FIRST);
            nav_do(NAV_ACTIVATE);
            PUMP();
            lv_obj_update_layout(lv_layer_top());

            int osk = 0;
            for (uint32_t i = 0; i < lv_obj_get_child_count(lv_layer_top()); i++)
                if (lv_obj_check_type(lv_obj_get_child(lv_layer_top(), i), &lv_keyboard_class)) osk++;
            ck(osk == 0, "no on-screen keyboard is put up when a real keyboard is present");

            lv_obj_t *ta2 = active_textarea();
            ck(ta2 != NULL, "the textarea is still found without an on-screen keyboard to find it through");
            if (!ta2) {
                ck(0, "SKIPPED (no textarea): the real keyboard still types into it");
            } else {
                lv_textarea_set_text(ta2, "");
                tev.code = KEY_R; kb_handle_event(&tev);
                tev.code = KEY_W; kb_handle_event(&tev);
                ck(!strcmp(lv_textarea_get_text(ta2), "rw"), "and the real keyboard still types into it");
            }
            ck(nav_candidates(c) > 0, "the dialog's buttons stay reachable too");

            lv_obj_clean(lv_layer_top());
            nav_set_focus(NULL);
            g_input_n = saved_n;
        }

        /* the mouse */
        struct nightfall_ctx mc = { .rot = ROT_270, .cw = 600, .ch = 900 };
        g_mouse_seen = 0;
        mouse_move(&mc, 10, -5);
        ck(mc.touch_x == 310 && mc.touch_y == 445, "the first motion starts from the middle of the screen");
        mouse_move(&mc, 5000, 5000);
        ck(mc.touch_x == 599 && mc.touch_y == 899, "the pointer is clamped to the bottom-right edge");
        mouse_move(&mc, -9000, -9000);
        ck(mc.touch_x == 0 && mc.touch_y == 0, "and to the top-left edge");
        mouse_move(&mc, 20, 30);
        ck(mc.touch_x == 20 && mc.touch_y == 30, "motion is applied unrotated even with ROT_270: a mouse moves in the room, not the panel");
        ck(g_cursor && !lv_obj_has_flag(g_cursor, LV_OBJ_FLAG_HIDDEN), "a cursor is drawn once the mouse moves");
        mouse_cursor_hide();
        ck(lv_obj_has_flag(g_cursor, LV_OBJ_FLAG_HIDDEN), "and hidden again when touch takes over");
        {
            struct input_event mev = { .type = EV_REL, .code = REL_X, .value = 7 };
            int dx = 0, dy = 0;
            ck(mouse_handle_event(&mc, &mev, &dx, &dy) == 1 && dx == 7, "REL_X accumulates into dx");
            mev.code = REL_Y; mev.value = -3;
            mouse_handle_event(&mc, &mev, &dx, &dy);
            ck(dy == -3, "and REL_Y into dy");
            mev.type = EV_KEY; mev.code = BTN_LEFT; mev.value = 1;
            mouse_handle_event(&mc, &mev, &dx, &dy);
            ck(mc.touch_down == 1, "the left button presses at the pointer");
            mev.value = 0;
            mouse_handle_event(&mc, &mev, &dx, &dy);
            ck(mc.touch_down == 0, "and releases");
            mev.code = BTN_RIGHT; mev.value = 1;
            ck(mouse_handle_event(&mc, &mev, &dx, &dy) == 0 && mc.touch_down == 0, "the right button does nothing");
        }
        {
            int nullfd = open("/dev/null", O_RDONLY);
            int cx = -1, cy = -1;
            ck(classify_input(nullfd, &cx, &cy) == 0, "a file that is not an input device is never adopted");
            close(nullfd);
        }
        /* the trackpad - a touchpad's absolute reports converted to relative
         * motion, since classify_input()/touch_open() together mean a
         * non-direct multitouch device is never treated as touch and this
         * is the only path left to make one usable at all (see the real
         * hardware finding this whole feature is built on: an Elan
         * touchpad reporting INPUT_PROP_DIRECT=no whose OWN separate
         * "Mouse" companion node turned out to never emit a single real
         * event on this kernel). */
        {
            struct nightfall_ctx tc = { .rot = ROT_270, .cw = 2000, .ch = 2000 };
            struct input_src ts = { .code_x = ABS_MT_POSITION_X, .code_y = ABS_MT_POSITION_Y,
                                     .abs_x = { .minimum = 0, .maximum = 1000 },
                                     .abs_y = { .minimum = 0, .maximum = 1000 },
                                     .last_x = -1, .last_y = -1 };
            int dx = 0, dy = 0;
            struct input_event tev = { .type = EV_ABS, .code = ABS_MT_POSITION_X, .value = 100 };
            ck(trackpad_handle_event(&tc, &ts, &tev, &dx, &dy) == 1 && dx == 0,
               "the first sample after a touch-down only records a position, no motion yet - nothing to diff against");
            tev.value = 150;
            trackpad_handle_event(&tc, &ts, &tev, &dx, &dy);
            /* screen_short=2000, pad range=1000, TRACKPAD_SWEEPS_PER_SCREEN=2 -> scale is exactly 1:1 here */
            ck(dx == 50, "a later sample is scaled by screen-vs-pad range - here a clean 1:1");
            tev.code = ABS_MT_POSITION_Y; tev.value = 200;
            trackpad_handle_event(&tc, &ts, &tev, &dx, &dy);
            ck(dy == 0, "Y tracks its own axis independently, still no motion on its first sample");
            tev.value = 220;
            trackpad_handle_event(&tc, &ts, &tev, &dx, &dy);
            ck(dy == 20, "and produces motion on the next one, same as X");

            tev.type = EV_ABS; tev.code = ABS_MT_TRACKING_ID; tev.value = -1;
            trackpad_handle_event(&tc, &ts, &tev, &dx, &dy);
            ck(ts.last_x == -1 && ts.last_y == -1, "lifting the finger (tracking id -1) forgets the last position");
            dx = dy = 0;
            tev.code = ABS_MT_POSITION_X; tev.value = 900;
            trackpad_handle_event(&tc, &ts, &tev, &dx, &dy);
            ck(dx == 0, "so touching back down somewhere else does not read as one huge jump");

            struct input_src ts_touch = { .code_x = ABS_X, .code_y = ABS_Y,
                                           .abs_x = { .minimum = 0, .maximum = 1000 },
                                           .abs_y = { .minimum = 0, .maximum = 1000 },
                                           .last_x = 500, .last_y = 500 };
            struct input_event bev = { .type = EV_KEY, .code = BTN_TOUCH, .value = 0 };
            trackpad_handle_event(&tc, &ts_touch, &bev, &dx, &dy);
            ck(ts_touch.last_x == -1 && ts_touch.last_y == -1,
               "a single-touch pad (plain ABS_X/Y, no tracking id) resets on BTN_TOUCH release instead");

            struct input_src ts_noscale = { .code_x = ABS_MT_POSITION_X, .code_y = ABS_MT_POSITION_Y,
                                             .abs_x = { .minimum = 0, .maximum = 0 },
                                             .abs_y = { .minimum = 0, .maximum = 0 },
                                             .last_x = -1, .last_y = -1 };
            dx = 0;
            tev.value = 10;
            trackpad_handle_event(&tc, &ts_noscale, &tev, &dx, &dy);
            tev.value = 18;
            trackpad_handle_event(&tc, &ts_noscale, &tev, &dx, &dy);
            ck(dx == 2000, "a device with no usable reported range falls back to a fixed divisor, not a crash");

            dx = 0; dy = 0;
            struct input_event cev = { .type = EV_KEY, .code = BTN_LEFT, .value = 1 };
            trackpad_handle_event(&tc, &ts, &cev, &dx, &dy);
            ck(tc.touch_down == 1, "BTN_LEFT (a clickpad's physical click) presses, same as an ordinary mouse");
            cev.value = 0;
            trackpad_handle_event(&tc, &ts, &cev, &dx, &dy);
            ck(tc.touch_down == 0, "and releases");
        }
        lv_obj_clean(lv_layer_top());
        show_main_menu();
        #undef HDR
        #undef ON_MAIN
        #undef PUMP
    }

    /* --- resolution scaling --- */
    {
        unsetenv("NIGHTFALL_UI_SCALE");
        /* The Slate is the reference: it must not change by a single pixel. */
        ck(ui_scale_pct_for(3000, 2000) == 100 && ui_scale_pct_for(2000, 3000) == 100,
           "the Slate's panel, in either orientation, is exactly 100%");
        ui_scale_init(3000, 2000);
        ck(ROW_H == 130 && MENU_ROW_H == 260 && DIALOG_BTN_H == 115 && DIALOG_BTN_GAP == 28 && EDIT_TA_H == 220,
           "and every size the UI was tuned to is EXACTLY what it was before scaling existed");
        ck(ui_px(16) == 16 && ui_px(8) == 8 && ui_px(260) == 260, "including the small paddings and the spinner");
        ck(ui_font_for_pct(g_scale_pct) == &lv_font_montserrat_36, "and the font is still the 36px one");
        ck(ui_scale_pct_for(1999, 3000) == 100 && ui_scale_pct_for(2100, 3000) == 100,
           "a panel within 5% of the reference snaps to it, so 1999 does not nudge every size");

        /* Other machines. */
        ck(ui_scale_pct_for(1920, 1080) == 54, "1080p is 54%");
        ck(ui_scale_pct_for(1366, 768) == 38, "a 1366x768 laptop is 38%");
        ck(ui_scale_pct_for(3840, 2160) == 108, "4K is 108%");
        ck(ui_scale_pct_for(320, 200) == 30 && ui_scale_pct_for(20000, 16000) == 250,
           "absurd sizes are clamped, so a bad EDID cannot collapse or balloon the UI");

        ui_scale_init(1920, 1080);
        ck(g_scale_pct == 54 && ROW_H == 70 && DIALOG_BTN_H == 62, "at 1080p rows and buttons shrink proportionally");
        ck(MENU_ROW_H * 7 <= 1080, "and the seven main-menu rows alone fit a 1080p screen without scrolling");
        show_main_menu();
        lv_obj_update_layout(lv_screen_active());
        ck((int)lv_obj_get_height(lv_obj_get_child(g_list, 0)) == MENU_ROW_H, "the rows actually built use the scaled height, not a baked-in one");
        show_kernel_list();
        lv_obj_update_layout(lv_screen_active());
        ck((int)lv_obj_get_height(lv_obj_get_child(g_list, 0)) == ROW_H, "sub-screen rows too");

        /* Fonts: the closest compiled size. */
        ck(ui_font_for_pct(38) == &lv_font_montserrat_14 && ui_font_for_pct(54) == &lv_font_montserrat_20 &&
           ui_font_for_pct(72) == &lv_font_montserrat_28 && ui_font_for_pct(108) == &lv_font_montserrat_36 &&
           ui_font_for_pct(140) == &lv_font_montserrat_48, "the font follows the scale through all five compiled sizes");
        ck(ui_font_for_pct(84) == &lv_font_montserrat_28 && ui_font_for_pct(85) == &lv_font_montserrat_36, "with the boundary where it is documented");

        /* The override. */
        setenv("NIGHTFALL_UI_SCALE", "150", 1);
        ui_scale_init(1920, 1080);
        ck(g_scale_pct == 150, "NIGHTFALL_UI_SCALE overrides the computed value");
        setenv("NIGHTFALL_UI_SCALE", "abc", 1); ui_scale_init(1920, 1080);
        ck(g_scale_pct == 54, "garbage is ignored");
        setenv("NIGHTFALL_UI_SCALE", "10", 1); ui_scale_init(1920, 1080);
        ck(g_scale_pct == 54, "a value below 25 is ignored");
        setenv("NIGHTFALL_UI_SCALE", "999", 1); ui_scale_init(1920, 1080);
        ck(g_scale_pct == 54, "and one above 300");
        unsetenv("NIGHTFALL_UI_SCALE");

        ui_scale_init(3000, 2000);   /* leave the reference scale for anything after */
        lv_obj_clean(lv_layer_top());
        show_main_menu();
    }

    /* --- Back up / Restore is a Slate feature --- */
    {
        #define HAS_BACKUP_ROW() ({ int _f = 0; lv_obj_update_layout(lv_screen_active()); \
            for (uint32_t _i = 0; _i < lv_obj_get_child_count(g_list); _i++) { \
                lv_obj_t *_r = lv_obj_get_child(g_list, _i); lv_obj_t *_l = lv_obj_get_child(_r, 0); \
                if (_l && lv_obj_check_type(_l, &lv_label_class) && strstr(lv_label_get_text(_l), "Back up / Restore")) _f = 1; } _f; })
        unsetenv("NIGHTFALL_BACKUP");
        ck(backup_enabled() == 1, "unset means shown: a hand-run Nightfall, the tests and an older image keep the row");
        show_main_menu();
        int rows_on = (int)lv_obj_get_child_count(g_list);
        ck(HAS_BACKUP_ROW(), "the main menu has its Back up / Restore row");
        setenv("NIGHTFALL_BACKUP", "0", 1);
        ck(backup_enabled() == 0, "init's 0 turns it off");
        show_main_menu();
        ck(!HAS_BACKUP_ROW() && (int)lv_obj_get_child_count(g_list) == rows_on - 1, "and it is exactly that one row that goes");
        setenv("NIGHTFALL_BACKUP", "off", 1);
        ck(backup_enabled() == 0, "'off' works too");
        setenv("NIGHTFALL_BACKUP", "1", 1);
        show_main_menu();
        ck(backup_enabled() == 1 && HAS_BACKUP_ROW(), "1 shows it");
        setenv("NIGHTFALL_BACKUP", "0", 1);
        show_main_menu();
        lv_obj_t *c[NAV_MAX];
        int nn = nav_candidates(c);
        ck(nn == rows_on - 1, "the keyboard skips a row that is not there");
        unsetenv("NIGHTFALL_BACKUP");
        show_main_menu();
        #undef HAS_BACKUP_ROW
    }

    /* --- Install/Remove/Repair are hidden on a boot-only mount (separate
     * /boot partition, find-real-root.sh's "bootfs" layout): those scripts
     * chroot into $root as the real Linux install, and a boot-only mount
     * has no userland there at all to chroot into. --- */
    {
        #define HAS_ROW(txt) ({ int _f = 0; lv_obj_update_layout(lv_screen_active()); \
            for (uint32_t _i = 0; _i < lv_obj_get_child_count(g_list); _i++) { \
                lv_obj_t *_r = lv_obj_get_child(g_list, _i); lv_obj_t *_l = lv_obj_get_child(_r, 0); \
                if (_l && lv_obj_check_type(_l, &lv_label_class) && strstr(lv_label_get_text(_l), txt)) _f = 1; } _f; })
        unsetenv("NIGHTFALL_BOOT_ONLY");
        ck(boot_only() == 0, "unset means a normal root - every machine before this existed, and the Slate");
        show_main_menu();
        int rows_on = (int)lv_obj_get_child_count(g_list);
        ck(HAS_ROW("Install a kernel") && HAS_ROW("Remove a kernel") && HAS_ROW("Repair"),
           "all three rows present on a normal (non-boot-only) root");
        setenv("NIGHTFALL_BOOT_ONLY", "1", 1);
        ck(boot_only() == 1, "init's 1 (set only for the bootfs layout) is recognised");
        show_main_menu();
        ck(!HAS_ROW("Install a kernel") && !HAS_ROW("Remove a kernel") && !HAS_ROW("Repair"),
           "all three are hidden - none of them can work with no real root mounted");
        ck((int)lv_obj_get_child_count(g_list) == rows_on - 3, "and it is exactly those three rows that go");
        lv_obj_t *c[NAV_MAX];
        int nn = nav_candidates(c);
        ck(nn == rows_on - 3, "the keyboard skips the rows that are not there");
        unsetenv("NIGHTFALL_BOOT_ONLY");
        show_main_menu();
        ck(HAS_ROW("Install a kernel") && HAS_ROW("Remove a kernel") && HAS_ROW("Repair"),
           "unsetting it again brings all three back");
        #undef HAS_ROW
    }

    printf("\npassed: %d  failed: %d\n", passes, fails);
    return fails ? 1 : 0;
}

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

/* Drains the child exactly the way the main loop does. */
static int drain(void) {
    char buf[512]; size_t len = 0;
    for (;;) {
        ssize_t got = read(g_install_fd, buf + len, sizeof(buf) - len - 1);
        if (got > 0) {
            len += (size_t)got; buf[len] = '\0';
            char *start = buf, *nl;
            while ((nl = strchr(start, '\n'))) { *nl = '\0'; prog_append(start); start = nl + 1; }
            len = strlen(start); memmove(buf, start, len + 1);
        } else {
            close(g_install_fd); g_install_fd = -1;
            if (len) { buf[len] = '\0'; prog_append(buf); }
            int st = 0;
            waitpid(g_install_pid, &st, 0);
            g_install_pid = -1;
            return WIFEXITED(st) && WEXITSTATUS(st) == 0;
        }
    }
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
        fprintf(bf, "/dev/sda1\tpicker-backup-20260909-1200\tTue Sep 9 12:00\t84G\n");
        fprintf(bf, "/dev/sda1\tonly-a-name\n");   /* short row: still usable */
        fprintf(bf, "\tno-target\n");             /* no target: unusable, skip */
        fclose(bf);
        static struct backup bk[8];
        int bn = load_backups("/tmp/mock-backups", bk, 8);
        ck(bn == 2, "a row without a target device is skipped, a short one is not");
        ck(!strcmp(bk[0].target, "/dev/sda1"), "restore knows which drive to mount");
        ck(!strcmp(bk[0].name, "picker-backup-20260909-1200"), "and which archive to use");
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
        ck(strstr(g_prog_lines[0], "name=picker-backup-20260909-1200") != NULL,
           "passes the archive name as argument 3");
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

        prog_append("backup: picker-total-kb: 90177536");        /* ~86 GiB */
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
            "exit 0\n");
        fclose(sf); chmod("/tmp/mock-scan.sh", 0755);
        setenv("NIGHTFALL_SCAN_SH", "/tmp/mock-scan.sh", 1);

        snprintf(g_targets_path, sizeof(g_targets_path), "/tmp/mock-t.tsv");
        snprintf(g_backups_path, sizeof(g_backups_path), "/tmp/mock-b.tsv");
        g_target_n = 0; g_targets = NULL;
        g_backup_n = 0; g_backups = NULL;

        ck(rescan_drives() == 0, "rescan runs the scan script");
        ck(g_target_n == 1, "a drive plugged in AFTER boot is now found");
        ck(!strcmp(g_targets[0].dev, "/dev/sdb1"), "with the right device");
        ck(g_backup_n == 1 && !strcmp(g_backups[0].name, "after-hotplug"),
           "and the backups on it are picked up too");

        /* Unplugged again: the lists must empty, not keep stale entries
         * pointing at a device that is gone. */
        sf = fopen("/tmp/mock-scan.sh", "w");
        fprintf(sf, "#!/bin/sh\n: > \"$3\"\n: > \"$4\"\nexit 0\n");
        fclose(sf); chmod("/tmp/mock-scan.sh", 0755);
        ck(rescan_drives() == 0, "rescan runs again");
        ck(g_target_n == 0 && g_targets == NULL, "an unplugged drive disappears from the list");
        ck(g_backup_n == 0 && g_backups == NULL, "and so do its backups");

        remove("/tmp/mock-scan.sh"); remove("/tmp/mock-t.tsv"); remove("/tmp/mock-b.tsv");
        g_targets_path[0] = '\0'; g_backups_path[0] = '\0';
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
            ck(nb == (variant ? 4u : 5u),
               variant ? "no recovery variant: four buttons"
                       : "recovery variant present: five buttons");

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
            ck(lowest, variant ? "Boot is the bottom-most button (no recovery)"
                               : "Boot is the bottom-most button (with recovery)");
            ck(lv_area_get_width(&ba) > (lv_area_get_width(&fa) * 3) / 4,
               variant ? "Boot spans the row (no recovery)"
                       : "Boot spans the row (with recovery)");
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

    remove("/tmp/mock-remove.sh");
    remove("/tmp/mock-install-ok.sh"); remove("/tmp/mock-install-bad.sh");
    printf("\npassed: %d  failed: %d\n", passes, fails);
    return fails ? 1 : 0;
}

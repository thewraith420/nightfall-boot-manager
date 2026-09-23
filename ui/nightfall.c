/*
 * picker: the touch menu itself. Reads a menu.tsv (produced by
 * initramfs/discover-kernels.sh) of "title\tlinux\tinitrd\tcmdline"
 * lines, draws a TWRP-style list on the first connected DRM output
 * using LVGL (main README decision #2, reopened after real-hardware
 * feedback that a plain text list wasn't the goal - see ui/README.md),
 * waits for tap -> confirm-dialog -> confirm on one entry, and writes
 * the selection back out as shell-sourceable
 * SELECTED_LINUX/SELECTED_INITRD/SELECTED_CMDLINE assignments on
 * stdout for initramfs/init to `.` source.
 *
 * LVGL is deliberately kept rotation-agnostic (lv_display_set_rotation
 * is never called): testing showed LVGL's own rotation support hands
 * flush_cb a buffer still laid out in *logical* (unrotated) space, and
 * separately hangs outright when combined with
 * LV_DISPLAY_RENDER_MODE_FULL. Rather than depend on that and a second,
 * possibly differently-conventioned rotation implementation inside
 * LVGL, NIGHTFALL_ROTATE is handled by this file's own logical_to_physical
 * / physical_to_logical transform (bijectivity verified with a
 * standalone test harness) at exactly two points: the flush callback
 * (logical LVGL render -> physical framebuffer) and touch input
 * (physical touch digitizer -> logical LVGL coordinates). LVGL's own
 * display is created at the already-swapped *logical* resolution and
 * never told about rotation at all.
 *
 * Safety net: if nothing is tapped within NIGHTFALL_TIMEOUT_SECS (default
 * 30, 0 disables it), auto-boots the first entry - GRUB's own menu has
 * exactly this timeout-to-default behavior, and a keyboardless device
 * with no escape hatch otherwise has no recovery path if touch ever
 * fails to register. Also cooperates with VT-switch requests
 * (VT_SETMODE/signalfd, dropping and reacquiring DRM master) so a
 * foreground console switch during development/debugging doesn't wedge
 * the display - found by testing on real hardware: without this,
 * Ctrl+Alt+F1 hung the VT switch hard enough to need a power cycle.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/vt.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/signalfd.h>
#include <sys/wait.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#include "lvgl.h"

#define MAX_ENTRIES 128
/* Generous on purpose: this is a failsafe for a dead touchscreen, not
 * a hurry-up. At 10s the menu felt like it was rushing you into a
 * choice. Any tap cancels it permanently, so a long value costs
 * nothing once you are actually interacting. */
#define DEFAULT_TIMEOUT_SECS 30
/* Pixel Slate panel: 3000x2000 @ 12.3" -> sqrt(3000^2+2000^2)/12.3
 * =~ 293 px/inch. The theme scales its padding/spacing from this, and
 * it's what makes the size constants below mean real-world distances. */
#define PANEL_DPI 293

/* SCALING. Every fixed pixel size in this file was tuned against the Slate's
 * panel (short side 2000px, 293 PPI, 36px font). Other machines get those
 * sizes scaled by how their short side compares - a 1080p screen would
 * otherwise show a handful of huge rows. ui_px() is the ONE place a
 * Slate-tuned size becomes a real one. Pixels, not EDID physical size: EDID
 * dimensions are missing or wrong on TVs, projectors and VMs, and a layout
 * that depends on them is unpredictable. */
#define REF_SHORT_SIDE 2000
static int g_scale_pct = 100;
static int ui_px(int v) {
    int r = (int)(((long)v * g_scale_pct + 50) / 100);
    return (r < 1 && v > 0) ? 1 : r;
}

/* Percent for a logical display size. The Slate must come out at EXACTLY 100
 * (so nothing on it changes by a pixel), so anything within 5% snaps to it;
 * the rest is clamped so a strange EDID can neither collapse nor balloon the UI. */
static int ui_scale_pct_for(int cw, int ch) {
    int side = cw < ch ? cw : ch;
    int pct = (int)((long)side * 100 / REF_SHORT_SIDE);
    if (pct >= 95 && pct <= 105) pct = 100;
    if (pct < 30) pct = 30;
    if (pct > 250) pct = 250;
    return pct;
}

/* The closest compiled Montserrat size. The bitmap fonts cannot be scaled,
 * so the UI picks the one whose proportion to the row height is nearest the
 * Slate's (36px in a 130px row). */
static const lv_font_t *ui_font_for_pct(int pct) {
    if (pct >= 130) return &lv_font_montserrat_48;
    if (pct >= 85)  return &lv_font_montserrat_36;
    if (pct >= 62)  return &lv_font_montserrat_28;
    if (pct >= 45)  return &lv_font_montserrat_20;
    return &lv_font_montserrat_14;
}

/* NIGHTFALL_UI_SCALE=<percent> overrides the computed value (25-300): the
 * escape hatch for a display whose size is misjudged, settable from the
 * kernel command line like the other NIGHTFALL_* knobs. */
static void ui_scale_init(int cw, int ch) {
    g_scale_pct = ui_scale_pct_for(cw, ch);
    const char *e = getenv("NIGHTFALL_UI_SCALE");
    if (e && *e) {
        int v = atoi(e);
        if (v >= 25 && v <= 300) g_scale_pct = v;
    }
}

#define DIALOG_BTN_H ui_px(115)   /* ~1cm at 293 PPI - comfortable touch target */
#define ROW_H ui_px(130)          /* kernel list row: ~1.1cm, fits the 36px font */
/* The top menu has two entries on a 3000px-tall screen, so list-sized
 * rows leave it looking like an error state. Double height reads as a
 * deliberate choice and gives a bigger target for the one screen you
 * always touch. */
#define MENU_ROW_H (ROW_H * 2)
/* Edit dialog. The keyboard takes the bottom of the screen and the
 * dialog is capped to what remains, so these two are related: raising
 * one shrinks the other. 45% of a 3000px-tall logical display leaves
 * ~337px per key row, comfortably over the ~1cm touch target. */
#define KEYBOARD_PCT_H 45
#define EDIT_TA_H ui_px(220)   /* ~4 wrapped lines of the 36px font */
/* Confirm dialog's 2x2 button grid. These two are coupled: the row has
 * to fit 2*DIALOG_BTN_W plus one DIALOG_BTN_GAP, so widening the
 * buttons back to 50% makes any nonzero gap overflow and wrap the grid
 * into a 4x1 stack. 47%+47% leaves 6% of the footer for the gap, which
 * at this dialog width is ~60px of room for a 28px gap. Asserted in
 * test-edit-layout.c so the pair cannot drift apart unnoticed. */
#define DIALOG_BTN_W_PCT 47
#define DIALOG_BTN_GAP ui_px(28)
#define VT_RELEASE_SIG SIGUSR1
#define VT_ACQUIRE_SIG SIGUSR2
#define POLL_PERIOD_MS 30

struct entry {
    char title[256];
    char linux_path[256];
    char initrd_path[256];
    char cmdline[512];
    int is_default;
};

/* An installable kernel tarball, as found by
 * initramfs/discover-tarballs.sh. Same "shell finds it, picker only
 * draws it" split as menu.tsv. */
struct tarball {
    char path[256];
    char version[128];
    char size[32];
};

/* An external drive the picker could back up to, and a backup already
 * on one. Both found by shell (discover-backup-targets.sh,
 * discover-backups.sh) so picker never mounts anything itself. */
struct target {
    char dev[128];
    char fstype[32];
    char label[64];
    char size[16];
    char freespace[16];
};

struct backup {
    char target[128];
    char name[128];
    char when[64];
    char size[16];
};

struct live_iso {
    char path[256];   /* relative to the drive's own root, e.g. "isos/ubuntu.iso" */
    char size[16];
    char name[128];   /* bare filename, for display */
};

/* A whole external drive that can be handed to FIRMWARE to boot next -
 * a Ventoy stick, another live-USB tool's drive, or a separate OS on an
 * external disk - found by discover-bootable-drives.sh. `loader` is the
 * UEFI removable-media fallback path on `dev` (e.g. '\EFI\BOOT\BOOTX64.EFI'),
 * exactly what boot-external-drive.sh points a fresh boot entry at. */
struct bootable_drive {
    char dev[128];
    char loader[64];
    char label[64];
    char size[16];
};

/* ---------------- menu.tsv ---------------- */

static int load_entries(const char *path, struct entry *entries, int max) {
    FILE *fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "nightfall: cannot open %s: %s\n", path, strerror(errno));
        return -1;
    }
    char line[1200];
    int n = 0;
    while (n < max && fgets(line, sizeof(line), fp)) {
        line[strcspn(line, "\n")] = '\0';
        char *fields[5] = {0};
        char *p = line;
        for (int i = 0; i < 5 && p; i++) {
            fields[i] = p;
            char *tab = strchr(p, '\t');
            if (tab) { *tab = '\0'; p = tab + 1; } else { p = NULL; }
        }
        if (!fields[0] || fields[0][0] == '\0') continue;
        snprintf(entries[n].title, sizeof(entries[n].title), "%s", fields[0] ? fields[0] : "");
        snprintf(entries[n].linux_path, sizeof(entries[n].linux_path), "%s", fields[1] ? fields[1] : "");
        snprintf(entries[n].initrd_path, sizeof(entries[n].initrd_path), "%s", fields[2] ? fields[2] : "");
        snprintf(entries[n].cmdline, sizeof(entries[n].cmdline), "%s", fields[3] ? fields[3] : "");
        entries[n].is_default = (fields[4] && fields[4][0] == '1');
        n++;
    }
    fclose(fp);
    return n;
}

/* path\tversion\tsize, one per line. Missing file is not an error -
 * it just means the Install menu comes up empty. */
static int load_tarballs(const char *path, struct tarball *tb, int max) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char line[600];
    int n = 0;
    while (n < max && fgets(line, sizeof(line), fp)) {
        line[strcspn(line, "\n")] = '\0';
        char *f[3] = {0};
        char *p = line;
        for (int i = 0; i < 3 && p; i++) {
            f[i] = p;
            char *tab = strchr(p, '\t');
            if (tab) { *tab = '\0'; p = tab + 1; } else { p = NULL; }
        }
        if (!f[0] || f[0][0] == '\0') continue;
        snprintf(tb[n].path, sizeof(tb[n].path), "%s", f[0]);
        snprintf(tb[n].version, sizeof(tb[n].version), "%s", f[1] ? f[1] : f[0]);
        snprintf(tb[n].size, sizeof(tb[n].size), "%s", f[2] ? f[2] : "?");
        n++;
    }
    fclose(fp);
    return n;
}

/* Both files are "one record per line, tab separated"; this fills n
 * fixed-size fields from one line and ignores anything extra. */
static int split_tsv(char *line, char *out[], int n) {
    char *p = line;
    int i = 0;
    for (; i < n && p; i++) {
        out[i] = p;
        char *tab = strchr(p, '\t');
        if (tab) { *tab = '\0'; p = tab + 1; } else { p = NULL; }
    }
    return i;
}

static int load_targets(const char *path, struct target *t, int max) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char line[600];
    int n = 0;
    while (n < max && fgets(line, sizeof(line), fp)) {
        line[strcspn(line, "\n")] = '\0';
        char *f[5] = {0};
        if (split_tsv(line, f, 5) < 1 || !f[0] || !*f[0]) continue;
        snprintf(t[n].dev, sizeof(t[n].dev), "%.127s", f[0]);
        snprintf(t[n].fstype, sizeof(t[n].fstype), "%.31s", f[1] ? f[1] : "?");
        snprintf(t[n].label, sizeof(t[n].label), "%.63s", f[2] ? f[2] : "");
        snprintf(t[n].size, sizeof(t[n].size), "%.15s", f[3] ? f[3] : "?");
        snprintf(t[n].freespace, sizeof(t[n].freespace), "%.15s", f[4] ? f[4] : "?");
        n++;
    }
    fclose(fp);
    return n;
}

static int load_backups(const char *path, struct backup *b, int max) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char line[600];
    int n = 0;
    while (n < max && fgets(line, sizeof(line), fp)) {
        line[strcspn(line, "\n")] = '\0';
        char *f[4] = {0};
        if (split_tsv(line, f, 4) < 2 || !f[0] || !*f[0] || !f[1] || !*f[1]) continue;
        snprintf(b[n].target, sizeof(b[n].target), "%.127s", f[0]);
        snprintf(b[n].name, sizeof(b[n].name), "%.127s", f[1]);
        snprintf(b[n].when, sizeof(b[n].when), "%.63s", f[2] ? f[2] : "unknown");
        snprintf(b[n].size, sizeof(b[n].size), "%.15s", f[3] ? f[3] : "?");
        n++;
    }
    fclose(fp);
    return n;
}

/* dev\tloader\tlabel\tsize, one per line - discover-bootable-drives.sh's
 * own contract (same shape as load_targets, different fields). */
static int load_bootable_drives(const char *path, struct bootable_drive *d, int max) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char line[600];
    int n = 0;
    while (n < max && fgets(line, sizeof(line), fp)) {
        line[strcspn(line, "\n")] = '\0';
        char *f[4] = {0};
        if (split_tsv(line, f, 4) < 2 || !f[0] || !*f[0] || !f[1] || !*f[1]) continue;
        snprintf(d[n].dev, sizeof(d[n].dev), "%.127s", f[0]);
        snprintf(d[n].loader, sizeof(d[n].loader), "%.63s", f[1]);
        snprintf(d[n].label, sizeof(d[n].label), "%.63s", f[2] ? f[2] : "");
        snprintf(d[n].size, sizeof(d[n].size), "%.15s", f[3] ? f[3] : "?");
        n++;
    }
    fclose(fp);
    return n;
}

/* path\tsize\tname, one per line - discover-live-isos.sh's own contract. */
static int load_live_isos(const char *path, struct live_iso *isos, int max) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char line[600];
    int n = 0;
    while (n < max && fgets(line, sizeof(line), fp)) {
        line[strcspn(line, "\n")] = '\0';
        char *f[3] = {0};
        if (split_tsv(line, f, 3) < 1 || !f[0] || !*f[0]) continue;
        snprintf(isos[n].path, sizeof(isos[n].path), "%.255s", f[0]);
        snprintf(isos[n].size, sizeof(isos[n].size), "%.15s", f[1] ? f[1] : "?");
        snprintf(isos[n].name, sizeof(isos[n].name), "%.127s", f[2] ? f[2] : f[0]);
        n++;
    }
    fclose(fp);
    return n;
}

/* ---------------- rotation (see file header - LVGL is not told about this) ---------------- */

/* Changing rotation while running.
 *
 * Cheap by construction: rotation is applied at exactly two points, the
 * flush callback and touch input, both of which read ctx->rot every
 * time. Nothing caches it, so the transform follows immediately.
 *
 * The part that is NOT free is the canvas. A 90-degree turn swaps the
 * logical dimensions, and flush_cb refuses to draw when the canvas does
 * not match the framebuffer for the current rotation - it skips the
 * flush rather than scribble. So the resolution has to move in the same
 * breath as ctx->rot, or the screen simply goes black.
 *
 * Layout comes along for free because every screen is built with
 * percentages and flex rather than fixed pixel sizes;
 * lv_display_set_resolution re-runs layout on the active screen.
 * lv_layer_top() is invalidated too, for the same reason the Edit
 * dialog needs it: this display is driven manually, so nothing else
 * decides a repaint is due, and a dialog open across a rotation would
 * otherwise keep its old geometry on screen. */
static void apply_rotation(int rot);


enum { ROT_0, ROT_90, ROT_180, ROT_270 };

static int parse_rotation(void) {
    const char *s = getenv("NIGHTFALL_ROTATE");
    if (!s) return ROT_0;
    if (!strcmp(s, "90")) return ROT_90;
    if (!strcmp(s, "180")) return ROT_180;
    if (!strcmp(s, "270")) return ROT_270;
    return ROT_0;
}

/* Logical (LVGL's render space, cw x ch) -> physical framebuffer
 * (ch x cw for 90/270, cw x ch for 0/180). Verified bijective with
 * clean round-trips for all four values via a standalone test harness. */
static void logical_to_physical(int rot, int cw, int ch, int lx, int ly, int *px, int *py) {
    switch (rot) {
    case ROT_90:  *px = ch - 1 - ly; *py = lx; break;
    case ROT_180: *px = cw - 1 - lx; *py = ch - 1 - ly; break;
    case ROT_270: *px = ly; *py = cw - 1 - lx; break;
    default:      *px = lx; *py = ly; break;
    }
}

static void physical_to_logical(int rot, int cw, int ch, int px, int py, int *lx, int *ly) {
    switch (rot) {
    case ROT_90:  *lx = py;          *ly = ch - 1 - px; break;
    case ROT_180: *lx = cw - 1 - px; *ly = ch - 1 - py; break;
    case ROT_270: *lx = cw - 1 - py; *ly = px;          break;
    default:      *lx = px;          *ly = py;          break;
    }
}

/* ---------------- DRM/KMS ---------------- */

struct drm_dev {
    int fd;
    uint32_t conn_id, crtc_id, fb_id, handle;
    uint32_t width, height, stride, size;
    uint8_t *map;
    drmModeModeInfo mode;
    drmModeCrtc *saved_crtc;
};

static int drm_try_open(struct drm_dev *d, const char *path) {
    memset(d, 0, sizeof(*d));
    d->fd = open(path, O_RDWR | O_CLOEXEC);
    if (d->fd < 0) {
        fprintf(stderr, "nightfall: %s: open failed: %s\n", path, strerror(errno));
        return -1;
    }

    drmModeRes *res = drmModeGetResources(d->fd);
    if (!res) {
        fprintf(stderr, "nightfall: %s: drmModeGetResources failed: %s\n", path, strerror(errno));
        close(d->fd);
        return -1;
    }

    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(d->fd, res->connectors[i]);
        if (!c) continue;
        if (c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) { conn = c; break; }
        drmModeFreeConnector(c);
    }
    if (!conn) {
        fprintf(stderr, "nightfall: %s: no connected connector with a mode\n", path);
        drmModeFreeResources(res);
        close(d->fd);
        return -1;
    }

    d->mode = conn->modes[0];
    for (int i = 0; i < conn->count_modes; i++) {
        if (conn->modes[i].type & DRM_MODE_TYPE_PREFERRED) { d->mode = conn->modes[i]; break; }
    }
    d->conn_id = conn->connector_id;

    uint32_t crtc_id = 0;
    drmModeEncoder *enc = conn->encoder_id ? drmModeGetEncoder(d->fd, conn->encoder_id) : NULL;
    if (enc && enc->crtc_id) {
        crtc_id = enc->crtc_id;
    } else {
        for (int i = 0; i < res->count_encoders && !crtc_id; i++) {
            drmModeEncoder *e = drmModeGetEncoder(d->fd, res->encoders[i]);
            if (!e) continue;
            for (int j = 0; j < res->count_crtcs; j++) {
                if (e->possible_crtcs & (1u << j)) { crtc_id = res->crtcs[j]; break; }
            }
            drmModeFreeEncoder(e);
        }
    }
    if (enc) drmModeFreeEncoder(enc);
    if (!crtc_id) {
        fprintf(stderr, "nightfall: %s: connector %u has no usable encoder/crtc\n", path, d->conn_id);
        drmModeFreeConnector(conn);
        drmModeFreeResources(res);
        close(d->fd);
        return -1;
    }
    d->crtc_id = crtc_id;
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);

    struct drm_mode_create_dumb creq = {0};
    creq.width = d->mode.hdisplay;
    creq.height = d->mode.vdisplay;
    creq.bpp = 32;
    if (drmIoctl(d->fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
        fprintf(stderr, "nightfall: %s: DRM_IOCTL_MODE_CREATE_DUMB failed: %s\n", path, strerror(errno));
        close(d->fd);
        return -1;
    }
    d->width = creq.width;
    d->height = creq.height;
    d->stride = creq.pitch;
    d->size = creq.size;
    d->handle = creq.handle;

    if (drmModeAddFB(d->fd, d->width, d->height, 24, 32, d->stride, d->handle, &d->fb_id) < 0) {
        fprintf(stderr, "nightfall: %s: drmModeAddFB failed: %s\n", path, strerror(errno));
        close(d->fd);
        return -1;
    }

    struct drm_mode_map_dumb mreq = {0};
    mreq.handle = d->handle;
    if (drmIoctl(d->fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) {
        fprintf(stderr, "nightfall: %s: DRM_IOCTL_MODE_MAP_DUMB failed: %s\n", path, strerror(errno));
        close(d->fd);
        return -1;
    }

    d->map = mmap(0, d->size, PROT_READ | PROT_WRITE, MAP_SHARED, d->fd, (off_t)mreq.offset);
    if (d->map == MAP_FAILED) {
        fprintf(stderr, "nightfall: %s: mmap of dumb buffer failed: %s\n", path, strerror(errno));
        close(d->fd);
        return -1;
    }
    memset(d->map, 0, d->size);

    d->saved_crtc = drmModeGetCrtc(d->fd, d->crtc_id);
    if (drmModeSetCrtc(d->fd, d->crtc_id, d->fb_id, 0, 0, &d->conn_id, 1, &d->mode) < 0) {
        fprintf(stderr, "nightfall: %s: drmModeSetCrtc failed: %s (need DRM master - "
                        "is another display server running?)\n", path, strerror(errno));
        munmap(d->map, d->size);
        close(d->fd);
        return -1;
    }
    return 0;
}

static int drm_open_first_connected(struct drm_dev *d) {
    for (int i = 0; i < 4; i++) {
        char path[32];
        snprintf(path, sizeof(path), "/dev/dri/card%d", i);
        if (access(path, F_OK) != 0) continue;
        if (drm_try_open(d, path) == 0) return 0;
    }
    return -1;
}

static void drm_close(struct drm_dev *d) {
    if (d->saved_crtc) {
        drmModeSetCrtc(d->fd, d->saved_crtc->crtc_id, d->saved_crtc->buffer_id,
                        d->saved_crtc->x, d->saved_crtc->y, &d->conn_id, 1, &d->saved_crtc->mode);
        drmModeFreeCrtc(d->saved_crtc);
    }
    if (d->map) munmap(d->map, d->size);
    if (d->fd >= 0) close(d->fd);
}

/* ---------------- VT switch cooperation ----------------
 *
 * Without this, holding DRM master through a VT switch (Ctrl+Alt+Fn,
 * or anything else that asks the kernel to change the active VT) hung
 * hard on real hardware - confirmed on the Slate, needed a power cycle
 * to recover. VT_PROCESS mode makes the kernel ask us via a signal
 * instead of just switching, so we can drop master first.
 */

static int vt_setup(void) {
    int vt_fd = open("/dev/tty0", O_RDWR);
    if (vt_fd < 0) {
        fprintf(stderr, "nightfall: cannot open /dev/tty0 for VT switch cooperation: %s "
                        "(continuing without it)\n", strerror(errno));
        return -1;
    }
    struct vt_mode mode = {0};
    mode.mode = VT_PROCESS;
    mode.relsig = VT_RELEASE_SIG;
    mode.acqsig = VT_ACQUIRE_SIG;
    if (ioctl(vt_fd, VT_SETMODE, &mode) < 0) {
        fprintf(stderr, "nightfall: VT_SETMODE failed: %s (continuing without VT switch cooperation)\n",
                strerror(errno));
        close(vt_fd);
        return -1;
    }
    return vt_fd;
}

static int signalfd_setup(void) {
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, VT_RELEASE_SIG);
    sigaddset(&mask, VT_ACQUIRE_SIG);
    if (sigprocmask(SIG_BLOCK, &mask, NULL) < 0) return -1;
    return signalfd(-1, &mask, SFD_NONBLOCK);
}

/* ---------------- touch input ---------------- */

static int bit_set(const unsigned long *bits, unsigned n) {
    return (bits[n / (sizeof(long) * 8)] >> (n % (sizeof(long) * 8))) & 1;
}

struct touch_dev {
    int fd;
    int code_x, code_y;
    struct input_absinfo abs_x, abs_y;
};

static int device_is_direct(int fd) {
    unsigned long propbits[(INPUT_PROP_MAX / (sizeof(long) * 8)) + 1] = {0};
    if (ioctl(fd, EVIOCGPROP(sizeof(propbits)), propbits) < 0) return 0;
    return bit_set(propbits, INPUT_PROP_DIRECT);
}

/* Some hardware exposes several /dev/input/eventN nodes that all
 * satisfy some capability check - e.g. a combo Wacom pen+touch
 * controller advertising multiple pen/stylus/mouse sub-interfaces
 * alongside the actual finger digitizer. Capability bits alone aren't
 * enough to tell them apart. Two real-hardware rounds were needed to
 * find the right signal:
 *
 * 1. INPUT_PROP_DIRECT ("touchscreen, not pointer device") rules out
 *    plain pointer/mouse-emulation sub-interfaces - but on this
 *    hardware *three* of the five Wacom nodes report DIRECT (the real
 *    finger digitizer, plus two pen/stylus telemetry channels that
 *    also happen to be DIRECT), so DIRECT alone still isn't unique.
 * 2. True multitouch capability (ABS_MT_SLOT/ABS_MT_TRACKING_ID, not
 *    just a plain ABS_X/ABS_Y fallback) is what actually distinguishes
 *    the real finger digitizer from the pen-telemetry DIRECT nodes,
 *    which only ever report ABS_X/ABS_Y/ABS_PRESSURE/ABS_TILT_* -
 *    confirmed by decoding a real /proc/bus/input/devices dump: only
 *    one of the five nodes has ABS_MT_SLOT/ABS_MT_POSITION_X/
 *    ABS_MT_TRACKING_ID at all, and it's not the one either prior fix
 *    picked.
 *
 * So this scores every candidate as direct*2 + is_mt*1 and keeps the
 * highest, which puts a true-MT+DIRECT device above a DIRECT-but-
 * ABS_X-only one, which is in turn above a non-DIRECT match - ties go
 * to whichever is found first. */
static int touch_open(struct touch_dev *t) {
    DIR *dir = opendir("/dev/input");
    if (!dir) return -1;
    struct dirent *de;
    int found_fd = -1, found_direct = 0, found_is_mt = 0, found_score = -1;
    int found_code_x = 0, found_code_y = 0;
    struct input_absinfo found_abs_x = {0}, found_abs_y = {0};
    char found_path[300] = "";
    char found_name[256] = "?";

    while ((de = readdir(dir))) {
        if (strncmp(de->d_name, "event", 5) != 0) continue;
        char path[300];
        snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        unsigned long absbits[(ABS_MAX / (sizeof(long) * 8)) + 1] = {0};
        if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits) < 0) {
            close(fd);
            continue;
        }
        int code_x, code_y, is_mt;
        if (bit_set(absbits, ABS_MT_POSITION_X)) {
            code_x = ABS_MT_POSITION_X;
            code_y = ABS_MT_POSITION_Y;
            is_mt = 1;
        } else if (bit_set(absbits, ABS_X)) {
            code_x = ABS_X;
            code_y = ABS_Y;
            is_mt = 0;
        } else {
            close(fd);
            continue;
        }
        struct input_absinfo ax, ay;
        if (ioctl(fd, EVIOCGABS(code_x), &ax) < 0 || ioctl(fd, EVIOCGABS(code_y), &ay) < 0) {
            close(fd);
            continue;
        }

        int is_direct = device_is_direct(fd);
        /* INPUT_PROP_DIRECT is exactly the kernel's own signal for "this
         * digitizer is fixed to the screen" (a touchscreen) vs "this
         * reports absolute coordinates but is not the screen" (a
         * touchpad). It was already read here and logged, but only fed
         * into the SCORE - meaning with no genuinely direct candidate at
         * all, a non-direct-but-multitouch device (a modern Precision
         * Touchpad, say - confirmed on real hardware: an Elan touchpad
         * enumerating with INPUT_PROP_DIRECT=no, multitouch=yes) could
         * still win as "the best available", and get driven as if finger
         * position mapped 1:1 onto the screen. It doesn't: a touchpad
         * has no fixed relationship to the display at all, so every
         * stroke landed at an unrelated absolute point with no cursor to
         * show where - "unusable" was the accurate word for it. A
         * touchpad's own genuinely relative sub-interface (this same
         * Elan hardware also exposes one, confirmed in the same boot)
         * already works fine as an ordinary mouse via classify_input()/
         * IN_MOUSE - so this is not a case that needs a fallback,
         * DIRECT is simply a real, hard requirement for anything called
         * touch, never merely a tiebreaker. */
        if (!is_direct) { close(fd); continue; }
        int score = is_mt;
        if (score > found_score) {
            if (found_fd >= 0) close(found_fd);
            found_fd = fd;
            found_code_x = code_x;
            found_code_y = code_y;
            found_abs_x = ax;
            found_abs_y = ay;
            found_direct = is_direct;
            found_is_mt = is_mt;
            found_score = score;
            snprintf(found_path, sizeof(found_path), "%s", path);
            char name[256] = "?";
            ioctl(fd, EVIOCGNAME(sizeof(name)), name);
            snprintf(found_name, sizeof(found_name), "%s", name);
        } else {
            close(fd);
        }
    }
    closedir(dir);
    if (found_fd < 0) return -1;

    fprintf(stderr, "nightfall: touch device: %s (\"%s\"), INPUT_PROP_DIRECT=%s, multitouch=%s\n",
            found_path, found_name, found_direct ? "yes" : "no", found_is_mt ? "yes" : "no");

    t->fd = found_fd;
    t->code_x = found_code_x;
    t->code_y = found_code_y;
    t->abs_x = found_abs_x;
    t->abs_y = found_abs_y;
    return 0;
}

/* Raw touch device coordinates arrive in the panel's fixed physical
 * orientation (the digitizer is laminated to the panel) - scale into
 * physical framebuffer space first, then into LVGL's logical space via
 * physical_to_logical (see file header on why LVGL itself is never
 * told about rotation). */
static void touch_to_logical(const struct touch_dev *t, int rot, int cw, int ch,
                              uint32_t phys_w, uint32_t phys_h, int raw_x, int raw_y, int *lx, int *ly) {
    int px = (t->abs_x.maximum > t->abs_x.minimum)
        ? (int)((int64_t)(raw_x - t->abs_x.minimum) * (int)phys_w / (t->abs_x.maximum - t->abs_x.minimum))
        : raw_x;
    int py = (t->abs_y.maximum > t->abs_y.minimum)
        ? (int)((int64_t)(raw_y - t->abs_y.minimum) * (int)phys_h / (t->abs_y.maximum - t->abs_y.minimum))
        : raw_y;
    physical_to_logical(rot, cw, ch, px, py, lx, ly);
}

/* ---------------- LVGL display + input glue ---------------- */

struct nightfall_ctx {
    struct drm_dev *drm;
    int rot;
    int cw, ch; /* logical dims, as passed to lv_display_create */
    lv_indev_t *indev;
    int touch_x, touch_y, touch_down;
};

/* TEMPORARY diagnostic, NIGHTFALL_DEBUG_INPUT only - bobzkernel-79 asked for
 * two /proc/interrupts snapshots, one right as the menu appears and one
 * right after the countdown expires (spanning the whole window a person
 * would have been pressing keys), to tell apart two different real causes
 * of "keyboard fd never shows POLLIN": if the IRQ's own count does not
 * move between the two, the interrupt never reaches the CPU at all (an
 * IOAPIC/interrupt-remap/EC-gating question, on the kernel side); if it
 * DOES move but Nightfall still sees nothing, the break is downstream in
 * the serio/evdev data path instead. Dumped verbatim rather than
 * pre-filtered to i8042's own line, since which line is i8042's is itself
 * part of what's being checked. Remove once that's answered. */
static void dump_interrupts(const char *label) {
    if (!getenv("NIGHTFALL_DEBUG_INPUT")) return;
    FILE *f = fopen("/proc/interrupts", "r");
    if (!f) { fprintf(stderr, "nightfall: /proc/interrupts (%s): open failed: %s\n", label, strerror(errno)); return; }
    fprintf(stderr, "nightfall: --- /proc/interrupts (%s) ---\n", label);
    char line[512];
    while (fgets(line, sizeof(line), f)) fprintf(stderr, "nightfall: %s", line);
    fprintf(stderr, "nightfall: --- end /proc/interrupts (%s) ---\n", label);
    fclose(f);
}

/* TEMPORARY diagnostic, NIGHTFALL_DEBUG_INPUT only - first-ever hardware
 * test of keyboard/mouse navigation (e70b290) found NOTHING responds once
 * inside the actual menu, on real hardware that isn't touch at all. Logs
 * every raw event this process actually reads from a keyboard/mouse fd,
 * and what nav_action (if any) it resolved to - so the next boot's log
 * says whether events are arriving at all, arriving with codes nothing
 * maps, or arriving and mapping correctly but never having any visible
 * effect (which would point back at rendering, not input). Remove once
 * that's answered. */
static int input_dbg(void) {
    static int v = -1;
    if (v < 0) v = getenv("NIGHTFALL_DEBUG_INPUT") ? 1 : 0;
    return v;
}

/* TEMPORARY diagnostic, NIGHTFALL_DEBUG_FLUSH only - see main()'s
 * NIGHTFALL_DEBUG_FILL comment for the hardware symptom this is chasing.
 * The fill test proved raw writes into d->map reach the whole panel, so
 * the question left is what LVGL actually asks THIS function to draw -
 * every call, every early-exit, so a hardware boot can show it directly
 * instead of guessing from what does or doesn't appear on screen. Remove
 * once that's answered. */
static int flush_dbg(void) {
    static int v = -1;
    if (v < 0) v = getenv("NIGHTFALL_DEBUG_FLUSH") ? 1 : 0;
    return v;
}

static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map) {
    struct nightfall_ctx *ctx = lv_display_get_user_data(disp);
    struct drm_dev *d = ctx->drm;
    const int cw = ctx->cw, ch = ctx->ch;
    const int aw = area->x2 - area->x1 + 1;   /* source row stride */
    const int dbg = flush_dbg();
    if (dbg)
        fprintf(stderr, "nightfall: flush called area=(%d,%d)-(%d,%d) rot=%d cw=%d ch=%d fb=%ux%u\n",
                area->x1, area->y1, area->x2, area->y2, ctx->rot, cw, ch, d->width, d->height);

    /* Clamp once rather than bounds-testing every pixel. Given the
     * cw/ch invariant (they are the drm dimensions, swapped for 90/270)
     * a logical point inside the display always maps to a physical one
     * inside the framebuffer, so this is the only check needed. */
    const int x1 = area->x1 < 0 ? 0 : area->x1;
    const int y1 = area->y1 < 0 ? 0 : area->y1;
    const int x2 = area->x2 >= cw ? cw - 1 : area->x2;
    const int y2 = area->y2 >= ch ? ch - 1 : area->y2;
    if (x1 > x2 || y1 > y2) {
        if (dbg) fprintf(stderr, "nightfall: flush SKIPPED - degenerate area after clamp\n");
        lv_display_flush_ready(disp);
        return;
    }

    /* The fast paths below drop the old per-pixel bounds test, which
     * is only safe while cw/ch really are the framebuffer dimensions
     * (swapped for 90/270). That holds wherever picker sets them up,
     * but "holds today" is not a memory-safety argument: if it were
     * ever violated the specialised loops would write past the
     * framebuffer, trading a visible glitch for silent corruption. So
     * check it once per flush - two comparisons - and skip the frame
     * rather than scribble. A dropped frame in an impossible
     * configuration is a cheap price for that guarantee. */
    const int exp_cw = (ctx->rot == ROT_90 || ctx->rot == ROT_270) ? (int)d->height : (int)d->width;
    const int exp_ch = (ctx->rot == ROT_90 || ctx->rot == ROT_270) ? (int)d->width  : (int)d->height;
    if (cw != exp_cw || ch != exp_ch) {
        static int warned;
        if (!warned) {
            warned = 1;
            fprintf(stderr, "nightfall: display %dx%d does not match framebuffer %ux%u "
                            "for rotation - skipping flush\n", cw, ch, d->width, d->height);
        }
        if (dbg) fprintf(stderr, "nightfall: flush SKIPPED - dimension mismatch\n");
        lv_display_flush_ready(disp);
        return;
    }

    const int w = x2 - x1 + 1;
    uint8_t *const map = d->map;
    const size_t stride = d->stride;

    /* Specialised per rotation, with the case hoisted out of the inner
     * loop. Previously this called logical_to_physical() per pixel - a
     * switch and two multiplies six million times for a full-screen
     * refresh. Rotation is fixed for the life of the process, so the
     * work is loop-invariant; for ROT_0 the row is contiguous and
     * becomes a memcpy, and 90/270 walk a physical column by adding or
     * subtracting the stride. Proven pixel-identical to the old
     * per-pixel version for all four rotations in test-flush.c. */
    for (int ly = y1; ly <= y2; ly++) {
        const uint32_t *srow = (const uint32_t *)px_map
                             + (size_t)(ly - area->y1) * aw + (x1 - area->x1);
        switch (ctx->rot) {
        case ROT_90: {
            /* px = ch-1-ly (constant down the row), py = lx */
            uint8_t *p = map + (size_t)x1 * stride + (size_t)(ch - 1 - ly) * 4;
            for (int i = 0; i < w; i++, p += stride) *(uint32_t *)p = srow[i];
            break;
        }
        case ROT_180: {
            uint32_t *drow = (uint32_t *)(map + (size_t)(ch - 1 - ly) * stride)
                           + (cw - 1 - x1);
            for (int i = 0; i < w; i++) drow[-i] = srow[i];
            break;
        }
        case ROT_270: {
            /* px = ly (constant), py = cw-1-lx */
            uint8_t *p = map + (size_t)(cw - 1 - x1) * stride + (size_t)ly * 4;
            for (int i = 0; i < w; i++, p -= stride) *(uint32_t *)p = srow[i];
            break;
        }
        default:
            memcpy((uint32_t *)(map + (size_t)ly * stride) + x1, srow, (size_t)w * 4);
            break;
        }
    }
    /* Every write above lands straight in the buffer already bound to the
     * CRTC by drmModeSetCrtc - never through a page flip, never through
     * drmModeDirtyFB, for the whole life of this codebase. That has always
     * been enough on the Slate's panel, which apparently keeps re-scanning
     * the same buffer at its own fixed rate regardless. A 144Hz panel with
     * variable refresh (this one is: intel_dp_set_edid logged "VRR capable:
     * yes") has a real reason to behave differently - with no explicit
     * "new frame" signal, a VRR-capable display can lock onto the last
     * frame it was explicitly told about and simply stop re-reading the
     * buffer, which would show exactly what real hardware showed: the very
     * first paint (driven by drmModeSetCrtc's own modeset) lands, and nothing
     * written after it - proven landing correctly in memory by
     * NIGHTFALL_DEBUG_FLUSH's own trace - ever reaches the panel again.
     * drmModeDirtyFB is the correct, standard way to say "this framebuffer's
     * content changed" without a full modeset or page flip.
     *
     * A single logical redraw can span many chunks - up to 17 for a full
     * screen at this buffer size - and flush_cb is called once per chunk.
     * Calling drmModeDirtyFB per chunk means up to 17 ioctls (each one
     * potentially waiting on the panel/AUX channel on a VRR display) for
     * ONE frame's worth of change, which is exactly what made the first
     * working version choppy compared to the Slate. Accumulate the dirty
     * region instead and fire ONE call, covering everything written since
     * the last one, right before the last chunk of the current refresh
     * (lv_display_flush_is_last) - the display never needs to know about
     * work still in flight, only about the complete result. */
    {
        static int have_dirty;
        static int dx1, dy1, dx2, dy2;
        if (!have_dirty) { dx1 = x1; dy1 = y1; dx2 = x2; dy2 = y2; have_dirty = 1; }
        else {
            if (x1 < dx1) dx1 = x1;
            if (y1 < dy1) dy1 = y1;
            if (x2 > dx2) dx2 = x2;
            if (y2 > dy2) dy2 = y2;
        }
        if (lv_display_flush_is_last(disp) && d->fd >= 0) {
            static int dirty_fb_unsupported;
            if (!dirty_fb_unsupported) {
                drmModeClip clip = {
                    .x1 = (unsigned short)dx1, .y1 = (unsigned short)dy1,
                    .x2 = (unsigned short)(dx2 + 1), .y2 = (unsigned short)(dy2 + 1),
                };
                int rc = drmModeDirtyFB(d->fd, d->fb_id, &clip, 1);
                if (dbg) fprintf(stderr, "nightfall: drmModeDirtyFB (%d,%d)-(%d,%d) rc=%d%s\n",
                                  dx1, dy1, dx2, dy2, rc, rc < 0 ? strerror(errno) : "");
                if (rc < 0 && errno == ENOSYS) dirty_fb_unsupported = 1;
            }
            have_dirty = 0;
        }
    }
    if (dbg) fprintf(stderr, "nightfall: flush OK, wrote y=%d..%d x=%d..%d\n", y1, y2, x1, x2);
    lv_display_flush_ready(disp);
}

static void indev_read_cb(lv_indev_t *indev, lv_indev_data_t *data) {
    struct nightfall_ctx *ctx = lv_indev_get_user_data(indev);
    data->point.x = ctx->touch_x;
    data->point.y = ctx->touch_y;
    data->state = ctx->touch_down ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

/* ---------------- UI ---------------- */

/* ---------------- screenshots ----------------
 *
 * picker already mmaps the scanout buffer for its flush path, so a
 * screenshot is just a copy of memory it is already holding - no second
 * DRM readback path, no extra ioctls.
 *
 * Dumped in LOGICAL orientation (un-rotated through the same transform
 * flush_cb uses), so the file comes out the way the tablet is held
 * rather than the way the panel scans. A sideways screenshot needs
 * hand-rotating before it is any use in a README.
 *
 * Triggered by NIGHTFALL_SCREENSHOT_DIR rather than a signal: in the real
 * boot there is no shell in the initramfs to send one from, and
 * event-triggered dumps are repeatable across test rounds in a way that
 * "press the thing at the right moment" is not.
 *
 * PPM because it is ~15 lines of code and needs no zlib in the
 * initramfs; ui/ppm-to-png.sh converts afterwards on a normal machine. */
static struct nightfall_ctx *g_ctx;

/* ---------------- auto-rotate: reading the display accelerometer ----------------
 *
 * The sensor is cros-ec-accel, reached through the EC's sensorhub and
 * exposed as an IIO device. Polled by sysfs rather than using IIO's
 * buffered/triggered capture: orientation changes at human speed, and a
 * couple of reads per second costs nothing next to standing up a
 * trigger and a ring buffer inside an initramfs.
 *
 * There may be more than one accelerometer - a detachable base can
 * carry its own - so the DISPLAY one is selected by label, not by
 * taking whichever device turns up first. */
#define ACCEL_LABEL "accel-display"
#define ACCEL_NAME  "cros-ec-accel"

/* Which rotation each "this edge is down" case means.
 *
 * CALIBRATION LIVES HERE, and deliberately in one place: the mapping
 * from sensor axes to screen orientation depends on how the panel is
 * physically mounted, which no amount of reasoning settles - it takes
 * one observation on the real tablet. The poll logs the raw values and
 * the orientation it picked, so a single run holding the device each
 * way says whether these four entries are right, and fixing them is
 * editing this table rather than unpicking logic.
 *
 * Index: 0 = +Y down, 1 = -Y down, 2 = +X down, 3 = -X down. */
static const int ACCEL_ROT[4] = { ROT_0, ROT_180, ROT_90, ROT_270 };
/* Where each entry comes from, so the next person knows which are
 * measured and which are inferred:
 *
 *   [3] -X down -> ROT_270   MEASURED. Held upright portrait on the
 *                            Slate: x=-7363 y=459 z=2537. Bob confirms
 *                            270 is upright portrait.
 *   [2] +X down -> ROT_90    DERIVED, and safe: +X is the opposite of
 *                            -X, so it must be the opposite rotation,
 *                            270 + 180 = 90.
 *   [0] +Y down -> ROT_0     UNVERIFIED. Bob confirms 0 is upright
 *   [1] -Y down -> ROT_180   landscape, so one of these two is ROT_0
 *                            and the other ROT_180 - but WHICH depends
 *                            on the handedness of the sensor relative
 *                            to the panel, and a single reading cannot
 *                            tell. One boot held upright LANDSCAPE
 *                            settles it: if x is then near zero and y
 *                            is strongly positive, this is right; if y
 *                            is strongly negative, swap [0] and [1].
 *
 * Getting the Y pair backwards is not subtle in use - landscape would
 * come up upside down - so it will be obvious rather than silent. */

/* Below this, the device is lying too flat for X/Y to mean anything and
 * the current orientation is kept.
 *
 * In raw counts, and MEASURED rather than assumed: a reading taken on
 * the Slate held upright portrait was x=-7363 y=459 z=2537, magnitude
 * 7801, so 1g is about 7800 counts here - not the ~1024 originally
 * guessed. At that scale a threshold of 200 would have been a 1.5
 * degree tilt, sensitive enough to flip orientation on sensor noise
 * alone. 2000 counts is about 15 degrees off flat, which a tablet
 * exceeds the moment it is picked up. */
#define ACCEL_FLAT 2000

/* Orientation implied by one reading, or `fallback` when it is too flat
 * to say. Pure function of its inputs - all the testing lives here. */
static int accel_orientation(long ax, long ay, int fallback) {
    long axm = ax < 0 ? -ax : ax;
    long aym = ay < 0 ? -ay : ay;
    if (axm < ACCEL_FLAT && aym < ACCEL_FLAT) return fallback;
    if (aym >= axm) return ACCEL_ROT[ay > 0 ? 0 : 1];
    return ACCEL_ROT[ax > 0 ? 2 : 3];
}

/* Debounce. A tablet passes through other orientations on the way to
 * the one you meant, and rotating the UI at every transient is worse
 * than not rotating at all - so a new orientation has to persist before
 * it counts. Returns 1 when `want` has been steady long enough to act
 * on. */
struct accel_debounce { int cand; int n; };
static int accel_settled(struct accel_debounce *d, int want, int current, int need) {
    if (want == current) { d->cand = want; d->n = 0; return 0; }
    if (want != d->cand) { d->cand = want; d->n = 1; return 0; }
    if (++d->n < need) return 0;
    d->n = 0;
    return 1;
}

/* The sysfs directory of the display accelerometer, or empty when there
 * is none - every picker kernel before 2026-09-12 lacked the cros-ec
 * IIO chain, and Nightfall has to stay perfectly usable on those.
 * NIGHTFALL_ACCEL points it somewhere else for testing. */
static char g_accel_dir[160];
static int  g_autorotate;          /* 0 disables the whole thing */

static void accel_find(void) {
    const char *over = getenv("NIGHTFALL_ACCEL");
    if (over && *over) { snprintf(g_accel_dir, sizeof g_accel_dir, "%.159s", over); return; }

    DIR *dir = opendir("/sys/bus/iio/devices");
    if (!dir) return;
    struct dirent *e;
    while ((e = readdir(dir))) {
        if (strncmp(e->d_name, "iio:device", 10) != 0) continue;
        char path[200], name[64] = {0};
        snprintf(path, sizeof path, "/sys/bus/iio/devices/%.40s/name", e->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        if (!fgets(name, sizeof name, f)) { fclose(f); continue; }
        fclose(f);
        name[strcspn(name, "\n")] = '\0';
        /* By name AND label: a detachable base can carry its own
         * accelerometer, and rotating the screen to match the keyboard's
         * idea of down would be worse than not rotating at all. */
        if (strcmp(name, ACCEL_NAME) != 0) continue;
        char lpath[200], label[64] = {0};
        snprintf(lpath, sizeof lpath, "/sys/bus/iio/devices/%.40s/label", e->d_name);
        FILE *lf = fopen(lpath, "r");
        if (lf) {
            if (fgets(label, sizeof label, lf)) label[strcspn(label, "\n")] = '\0';
            fclose(lf);
        }
        if (label[0] && strcmp(label, ACCEL_LABEL) != 0) continue;
        snprintf(g_accel_dir, sizeof g_accel_dir, "/sys/bus/iio/devices/%.40s", e->d_name);
        break;
    }
    closedir(dir);
}

static int accel_read_raw(const char *axis, long *out) {
    char path[224];
    snprintf(path, sizeof path, "%.160s/in_accel_%s_raw", g_accel_dir, axis);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    long v;
    int ok = (fscanf(f, "%ld", &v) == 1);
    fclose(f);
    if (!ok) return -1;
    *out = v;
    return 0;
}

/* Called from the event loop. Cheap: two small sysfs reads, and only
 * every ACCEL_POLL_MS rather than every wakeup. */
#define ACCEL_POLL_MS  250
#define ACCEL_SETTLE   3        /* ~750ms held before the screen turns */

static void accel_poll(void) {
    static struct accel_debounce deb;
    static uint32_t last;
    if (!g_autorotate || !g_accel_dir[0] || !g_ctx) return;

    uint32_t now = lv_tick_get();
    if (last && (uint32_t)(now - last) < ACCEL_POLL_MS) return;
    last = now ? now : 1;

    long ax, ay;
    if (accel_read_raw("x", &ax) != 0 || accel_read_raw("y", &ay) != 0) return;

    int want = accel_orientation(ax, ay, g_ctx->rot);
    if (accel_settled(&deb, want, g_ctx->rot, ACCEL_SETTLE)) {
        fprintf(stderr, "nightfall: auto-rotate %d -> %d (accel x=%ld y=%ld)\n",
                g_ctx->rot, want, ax, ay);
        apply_rotation(want);
    }
}

static void apply_rotation(int rot) {
    if (!g_ctx) return;
    if (rot == g_ctx->rot) return;
    lv_display_t *disp = lv_display_get_default();
    if (!disp) return;

    struct drm_dev *d = g_ctx->drm;
    const int swapped = (rot == ROT_90 || rot == ROT_270);
    g_ctx->rot = rot;
    g_ctx->cw = swapped ? (int)d->height : (int)d->width;
    g_ctx->ch = swapped ? (int)d->width  : (int)d->height;

    lv_display_set_resolution(disp, g_ctx->cw, g_ctx->ch);
    lv_obj_invalidate(lv_screen_active());
    lv_obj_invalidate(lv_layer_top());
}

static const char *g_shot_dir;
static const char *g_shot_pending;
static int g_shot_n;

static void screenshot(const char *tag) {
    if (!g_shot_dir || !g_ctx || !g_ctx->drm->map) return;
    struct drm_dev *d = g_ctx->drm;
    int cw = g_ctx->cw, ch = g_ctx->ch;

    char path[512];
    snprintf(path, sizeof(path), "%s/%02d-%s.ppm", g_shot_dir, ++g_shot_n, tag);
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "nightfall: screenshot %s: %s\n", path, strerror(errno));
        return;
    }
    fprintf(f, "P6\n%d %d\n255\n", cw, ch);

    unsigned char *row = malloc((size_t)cw * 3);
    if (!row) { fclose(f); return; }
    for (int ly = 0; ly < ch; ly++) {
        for (int lx = 0; lx < cw; lx++) {
            int px, py;
            logical_to_physical(g_ctx->rot, cw, ch, lx, ly, &px, &py);
            uint32_t c = 0;
            if (px >= 0 && py >= 0 && (uint32_t)px < d->width && (uint32_t)py < d->height)
                c = *(uint32_t *)(d->map + (size_t)py * d->stride + (size_t)px * 4);
            row[lx * 3 + 0] = (c >> 16) & 0xff;  /* XRGB8888 */
            row[lx * 3 + 1] = (c >> 8) & 0xff;
            row[lx * 3 + 2] = c & 0xff;
        }
        fwrite(row, 1, (size_t)cw * 3, f);
    }
    free(row);
    fclose(f);
    fprintf(stderr, "nightfall: screenshot -> %s (%dx%d)\n", path, cw, ch);
}

/* Requested from inside an event callback, taken by the main loop after
 * the next lv_timer_handler(): the dialog that triggered it has not
 * been drawn yet at callback time, and forcing a redraw from inside
 * LVGL's own event dispatch is asking for re-entrancy trouble. */
static void screenshot_soon(const char *tag) {
    if (g_shot_dir) g_shot_pending = tag;
}

static volatile int g_selected = -1;
/* Set instead of g_selected when the user picks a tarball to install.
 * The main loop exits on either, and exactly one of SELECTED_LINUX or
 * INSTALL_TARBALL is written on stdout, so init can tell what to do. */
static volatile int g_install = -1;
static volatile int g_set_default = 0;
static struct entry *g_entries;

/* Declared up here because the recovery helpers below need it. */
static int g_entry_n;

/* GRUB emits a recovery variant beside most normal entries - same
 * kernel, same initrd, a cmdline with "recovery nomodeset". Listing
 * both doubles the menu for something you want maybe once a year, and
 * separates the recovery option from the kernel it belongs to. So they
 * are folded into the confirm dialog for their own kernel instead.
 *
 * Detected from the CMDLINE rather than the title: "recovery" as a
 * kernel argument is what actually makes it a recovery boot, whereas
 * the "(recovery mode)" suffix is display text GRUB could localise.
 * The title is kept as a fallback for configs that word it differently.
 * Verified against the Slate's real grub.cfg: all 12 recovery entries
 * carry the cmdline word, none of the 13 normal ones do. */
static int has_word(const char *hay, const char *word) {
    size_t wl = strlen(word);
    for (const char *p = strstr(hay, word); p; p = strstr(p + 1, word)) {
        char before = (p == hay) ? ' ' : p[-1];
        char after  = p[wl];
        if ((before == ' ' || before == '\0') && (after == ' ' || after == '\0'))
            return 1;
    }
    return 0;
}

static int is_recovery(const struct entry *e) {
    return has_word(e->cmdline, "recovery") || strstr(e->title, "(recovery mode)") != NULL;
}

/* The recovery entry for the same kernel, or -1. Matched on the kernel
 * image path - the pair differ only in cmdline. */
static int find_recovery_for(int idx) {
    if (idx < 0 || idx >= g_entry_n || is_recovery(&g_entries[idx])) return -1;
    for (int i = 0; i < g_entry_n; i++)
        if (i != idx && is_recovery(&g_entries[i]) &&
            !strcmp(g_entries[i].linux_path, g_entries[idx].linux_path))
            return i;
    return -1;
}

static int count_bootable_rows(void) {
    int n = 0;
    for (int i = 0; i < g_entry_n; i++) if (!is_recovery(&g_entries[i])) n++;
    return n;
}

static void open_confirm_dialog(int idx);

/* Nothing else to do here: the main loop exits as soon as g_selected
 * is set (checked right after this fires, since click handling happens
 * inside lv_timer_handler()), so there's no need to close the msgbox -
 * the whole display is torn down immediately after anyway. */
static void confirm_cb(lv_event_t *e) {
    lv_obj_t *mbox = lv_event_get_user_data(e);
    g_selected = (int)(intptr_t)lv_obj_get_user_data(mbox);
}

/* Boots the recovery variant. The index carries everything - initrd and
 * cmdline come from that entry - so this needs no special handling
 * downstream; it is just a different entry to select. */
static void recovery_cb(lv_event_t *e) {
    g_selected = (int)(intptr_t)lv_event_get_user_data(e);
}

/* Set Default also boots into this entry now, same as Boot - the user
 * is already looking at the confirm dialog for this specific entry, so
 * "remember this AND go" is the natural reading, not "remember this
 * but stay on the menu". initramfs/init persists the preference (see
 * initramfs/README.md) before kexec once it sees SET_DEFAULT=1. */
static void set_default_cb(lv_event_t *e) {
    lv_obj_t *mbox = lv_event_get_user_data(e);
    g_set_default = 1;
    g_selected = (int)(intptr_t)lv_obj_get_user_data(mbox);
}

static void cancel_cb(lv_event_t *e) {
    lv_msgbox_close_async(lv_event_get_user_data(e));
}

/* ---------------- kexec blocked (kernel lockdown) ----------------
 *
 * Under kernel lockdown the legacy kexec_load syscall is refused, so no
 * kernel can be booted from here - and init exec()s kexec-boot.sh in place
 * of PID 1, so finding that out at the last moment used to end in a kernel
 * panic with nothing on screen to say why. init asks kexec-preflight.sh
 * once, up front, and hands the reason over in NIGHTFALL_KEXEC_BLOCKED
 * (unset when kexec works or when it simply cannot tell). Only kexec paths
 * are affected: booting a DRIVE goes through firmware, and backups and
 * repairs never kexec, so those stay available and the message says so. */
static const char *kexec_blocked_reason(void) {
    const char *r = getenv("NIGHTFALL_KEXEC_BLOCKED");
    return (r && *r) ? r : NULL;
}

/* A plain one-button explanation. */
static void show_notice(const char *title, const char *body) {
    lv_obj_t *m = lv_msgbox_create(NULL);
    lv_obj_set_width(m, lv_pct(72));
    lv_msgbox_add_title(m, title);
    lv_msgbox_add_text(m, body);
    lv_obj_t *b = lv_msgbox_add_footer_button(m, "OK");
    lv_obj_set_height(lv_msgbox_get_footer(m), LV_SIZE_CONTENT);
    lv_obj_set_height(lv_msgbox_get_header(m), LV_SIZE_CONTENT);
    lv_obj_set_height(b, DIALOG_BTN_H);
    lv_obj_set_width(b, lv_pct(100));
    lv_obj_add_event_cb(b, cancel_cb, LV_EVENT_CLICKED, m);
}

static void show_kexec_blocked_notice(void) {
    const char *why = kexec_blocked_reason();
    if (!why) return;
    char body[560];
    snprintf(body, sizeof(body),
             "%.400s\n\nBooting a drive from the Boot screen, backups and "
             "repairs still work.", why);
    show_notice("Can't boot a kernel from here", body);
}

/* Edit: GRUB-style one-time cmdline tweak, never persisted - just
 * mutates this entry's in-memory copy for the rest of this run, same
 * as GRUB's own 'e' edit-before-boot. */
/* Defined further down, next to the input devices it reads. */
static int have_physical_keyboard(void);

/* The textarea a REAL keyboard should type into, if one is open.
 *
 * Tracked explicitly rather than found via the on-screen keyboard, because
 * the on-screen keyboard is no longer always there: on a machine with a
 * real keyboard it is not created at all (it costs KEYBOARD_PCT_H of the
 * screen and duplicates a keyboard the person is already touching - Bob, on
 * hardware: "the osk still showing up"). Cleared by the textarea's own
 * delete event, so no dialog close path has to remember to do it and a
 * stale pointer cannot outlive the dialog. */
static lv_obj_t *g_text_input;

static void text_input_deleted_cb(lv_event_t *e) {
    if (lv_event_get_target(e) == g_text_input) g_text_input = NULL;
}

/* What every text dialog does with its textarea: remember it for the real
 * keyboard, and put up an on-screen one only for a machine with no other
 * way to type. Returns that on-screen keyboard, or NULL when there is a
 * real keyboard - the caller needs to know only so it can decide whether to
 * reserve the bottom of the screen for it. */
static lv_obj_t *text_input_begin(lv_obj_t *ta) {
    g_text_input = ta;
    lv_obj_add_event_cb(ta, text_input_deleted_cb, LV_EVENT_DELETE, NULL);
    if (have_physical_keyboard()) return NULL;
    /* Parented to lv_layer_top(), NOT lv_screen_active(): lv_msgbox_create
     * puts a 100%x100% backdrop on lv_layer_top() with the dialog inside,
     * so a keyboard on the screen layer sits UNDERNEATH it entirely -
     * drawn greyed out behind the dim, with the backdrop swallowing every
     * tap meant for its keys. Found on real hardware: the keyboard drew
     * perfectly and was completely dead. Created after the msgbox so as a
     * later sibling it draws above the backdrop and receives touches, and
     * deliberately a SIBLING rather than a child, because the dialogs
     * delete it explicitly and as a child it would be deleted a second
     * time when the msgbox tears its backdrop down. */
    lv_obj_t *kb = lv_keyboard_create(lv_layer_top());
    lv_obj_set_size(kb, lv_pct(100), lv_pct(KEYBOARD_PCT_H));
    lv_obj_align(kb, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_keyboard_set_textarea(kb, ta);
    return kb;
}

struct edit_ctx {
    int idx;
    lv_obj_t *mbox;
    lv_obj_t *kb;
    lv_obj_t *ta;
};

static void edit_close(struct edit_ctx *ctx) {
    /* NULL whenever there is a real keyboard - see text_input_begin(). */
    if (ctx->kb) lv_obj_delete_async(ctx->kb);
    lv_msgbox_close_async(ctx->mbox);
    free(ctx);
}

/* Kernels that already have a saved command line, read from the same
 * file init applies. picker cannot infer this from the menu, because by
 * the time it sees a row the override has already been folded into the
 * cmdline field - which is deliberate (what Edit shows is what boots),
 * but leaves no way to tell "saved" from "straight out of grub.cfg".
 * Only used to decide whether to offer "Forget saved". */
static char g_saved_keys[MAX_ENTRIES][256];
static int  g_saved_n;

static void load_saved_cmdlines(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) return;
    char line[1200];
    while (g_saved_n < MAX_ENTRIES && fgets(line, sizeof(line), fp)) {
        line[strcspn(line, "\n")] = '\0';
        char *tab = strchr(line, '\t');
        if (!tab || tab == line) continue;
        *tab = '\0';
        if (tab[1] == '\0') continue;         /* empty value is not an override */
        /* Bounded explicitly - the line buffer is far larger than the
         * key. A path this long is not a real kernel path anyway. */
        snprintf(g_saved_keys[g_saved_n], sizeof(g_saved_keys[0]), "%.255s", line);
        g_saved_n++;
    }
    fclose(fp);
}

static int has_saved_cmdline(const char *kernel) {
    for (int i = 0; i < g_saved_n; i++)
        if (!strcmp(g_saved_keys[i], kernel)) return 1;
    return 0;
}

/* Persisted on exit, so an edit survives the trip back through the
 * confirm dialog. "<kernel>\t<cmdline>", or "<kernel>\t" to forget. */
static char g_setcl[1024];
static int  g_setcl_set;

static void remember_cmdline(const char *kernel, const char *cmdline) {
    snprintf(g_setcl, sizeof(g_setcl), "%s\t%s", kernel, cmdline ? cmdline : "");
    g_setcl_set = 1;
}

/* Applies the edited text to this boot. Shared by both accept paths -
 * saving without also using it now would be a surprise. */
static void edit_apply(struct edit_ctx *ctx, int persist) {
    const char *text = lv_textarea_get_text(ctx->ta);
    int idx = ctx->idx;
    snprintf(g_entries[idx].cmdline, sizeof(g_entries[idx].cmdline), "%s", text);
    if (persist) remember_cmdline(g_entries[idx].linux_path, text);
    edit_close(ctx);
    open_confirm_dialog(idx);
}

static void edit_once_cb(lv_event_t *e)  { edit_apply(lv_event_get_user_data(e), 0); }
static void edit_save_cb(lv_event_t *e)  { edit_apply(lv_event_get_user_data(e), 1); }

/* Forgets the saved command line without changing this boot: the
 * original text is gone by now (init folded the override into the menu
 * before picker ever saw it), so there is nothing to restore here. The
 * next boot reads grub.cfg again. */
static void edit_forget_cb(lv_event_t *e) {
    struct edit_ctx *ctx = lv_event_get_user_data(e);
    int idx = ctx->idx;
    remember_cmdline(g_entries[idx].linux_path, "");
    edit_close(ctx);
    open_confirm_dialog(idx);
}

static void edit_cancel_cb(lv_event_t *e) {
    struct edit_ctx *ctx = lv_event_get_user_data(e);
    int idx = ctx->idx;
    edit_close(ctx);
    open_confirm_dialog(idx);
}

static void edit_cb(lv_event_t *e) {
    lv_obj_t *confirm_mbox = lv_event_get_user_data(e);
    int idx = (int)(intptr_t)lv_obj_get_user_data(confirm_mbox);
    lv_msgbox_close_async(confirm_mbox);

    struct edit_ctx *ctx = malloc(sizeof(*ctx));
    ctx->idx = idx;

    ctx->mbox = lv_msgbox_create(NULL);
    /* lv_msgbox's class default width is a hardcoded LV_DPI_DEF*2
     * (260px), unrelated to the real display size - unreadably small
     * on this panel, so both dialogs size themselves explicitly. */
    /* Wider than the confirm dialog: this one has to show a 250+
     * character command line, not a kernel title. */
    lv_obj_set_width(ctx->mbox, lv_pct(92));
    lv_msgbox_add_title(ctx->mbox, "Edit boot command line");
    lv_msgbox_add_text(ctx->mbox, "Use once, or save it for this kernel on every boot.");

    ctx->ta = lv_textarea_create(lv_msgbox_get_content(ctx->mbox));
    /* NOT one_line: a real cmdline here is 250+ characters, and in
     * one-line mode the textarea shows a narrow horizontally-scrolled
     * slice of it - you cannot see what you are editing. Wrapped over a
     * few lines shows the whole thing. */
    lv_textarea_set_one_line(ctx->ta, false);
    /* Size BEFORE text: the text wraps against whatever width the
     * textarea has at set_text time, so setting it first wraps against
     * the default width and re-wraps later. Harmless here (measured -
     * the layout comes out identical either way) but there is no reason
     * to depend on the re-wrap. */
    lv_obj_set_width(ctx->ta, lv_pct(100));
    lv_obj_set_height(ctx->ta, EDIT_TA_H);
    lv_textarea_set_text(ctx->ta, g_entries[idx].cmdline);
    /* set_text leaves the cursor at the end; show the START of the
     * command line, which is the part worth reading first. */
    lv_textarea_set_cursor_pos(ctx->ta, 0);
    lv_obj_scroll_to_y(ctx->ta, 0, LV_ANIM_OFF);

    ctx->kb = text_input_begin(ctx->ta);

    /* The on-screen keyboard owns the bottom half of the screen, so a
     * centred dialog fights it for space: pin the dialog to the top and
     * cap its height at what is left. With a real keyboard there is no
     * on-screen one and none of that applies - the dialog gets the whole
     * screen and its normal centred position, which is also more room to
     * read a 250-character command line in. */
    if (ctx->kb) {
        lv_obj_set_style_max_height(ctx->mbox, lv_pct(100 - KEYBOARD_PCT_H - 4), 0);
        lv_obj_align(ctx->mbox, LV_ALIGN_TOP_MID, 0, ui_px(16));
    }

    /* Two ways to accept, because they mean different things: use it
     * for this boot, or remember it for this kernel every boot. The
     * old single "Save" was the former while reading like the latter. */
    int saved = has_saved_cmdline(g_entries[idx].linux_path);
    lv_obj_t *once_btn   = lv_msgbox_add_footer_button(ctx->mbox, "Use once");
    lv_obj_t *save_btn   = lv_msgbox_add_footer_button(ctx->mbox, "Save for this kernel");
    lv_obj_t *forget_btn = saved ? lv_msgbox_add_footer_button(ctx->mbox, "Forget saved") : NULL;
    lv_obj_t *cancel_btn = lv_msgbox_add_footer_button(ctx->mbox, "Cancel");

    lv_obj_t *efooter = lv_msgbox_get_footer(ctx->mbox);
    /* Same 43px hardcoded footer/header height as the confirm dialog. */
    lv_obj_set_height(efooter, LV_SIZE_CONTENT);
    lv_obj_set_height(lv_msgbox_get_header(ctx->mbox), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(efooter, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_style_pad_column(efooter, DIALOG_BTN_GAP, 0);
    lv_obj_set_style_pad_row(efooter, DIALOG_BTN_GAP, 0);

    lv_obj_t *ebtns[4] = { once_btn, save_btn, forget_btn, cancel_btn };
    for (int i = 0; i < 4; i++) {
        if (!ebtns[i]) continue;
        lv_obj_set_width(ebtns[i], lv_pct(DIALOG_BTN_W_PCT));
        lv_obj_set_height(ebtns[i], DIALOG_BTN_H);
    }
    /* With no saved override there are three buttons, so Cancel would
     * sit alone at 47% beside a gap - span it instead, same rule the
     * confirm dialog uses. */
    if (!forget_btn) lv_obj_set_width(cancel_btn, lv_pct(100));
    if (forget_btn) lv_obj_set_style_text_color(forget_btn, lv_color_hex(0xd9c48a), 0);

    lv_obj_add_event_cb(once_btn, edit_once_cb, LV_EVENT_CLICKED, ctx);
    lv_obj_add_event_cb(save_btn, edit_save_cb, LV_EVENT_CLICKED, ctx);
    if (forget_btn) lv_obj_add_event_cb(forget_btn, edit_forget_cb, LV_EVENT_CLICKED, ctx);
    lv_obj_add_event_cb(cancel_btn, edit_cancel_cb, LV_EVENT_CLICKED, ctx);

    /* On hardware the textarea came up blank until the first keystroke,
     * even though the text was set and - measured in the headless
     * harness - laid out correctly and inside the visible content area.
     * So it is not layout or scrolling: the content simply was not
     * painted until some later event forced a redraw. Force it here,
     * the same remedy the VT-reacquire path above needs, and for the
     * same underlying reason: this display is driven manually, so
     * nothing else will decide a repaint is due.
     *
     * NOT verified headlessly - a dummy flush callback cannot reproduce
     * a real partial-render pass, which is exactly why this one had to
     * be found on a panel. */
    lv_obj_update_layout(ctx->mbox);
    lv_obj_invalidate(lv_layer_top());
    screenshot_soon("edit-dialog");
}

/* 2x2 footer grid (Edit/Set Default on top, Boot/Cancel below),
 * matching the approved mockup - lv_msgbox's footer is a plain flex
 * row by default, so it's wrapped into two rows of two by giving each
 * button 50% width. */
static void open_confirm_dialog(int idx) {
    lv_obj_t *mbox = lv_msgbox_create(NULL);
    /* Same hardcoded-260px default as the edit dialog. */
    lv_obj_set_width(mbox, lv_pct(55));
    lv_obj_set_user_data(mbox, (void *)(intptr_t)idx);
    lv_msgbox_add_title(mbox, "Confirm boot");
    char body[300];
    snprintf(body, sizeof(body), "Boot into:\n\n%s", g_entries[idx].title);
    lv_msgbox_add_text(mbox, body);

    /* Creation order is layout order, and Boot is created LAST so it
     * spans the bottom row: it is the action taken on virtually every
     * visit, and the bottom edge is where a thumb already rests on a
     * tablet this size. The row above pairs Recovery with Cancel when
     * there is a recovery variant, and otherwise lets Cancel span - a
     * lone 47% button beside an empty gap reads as a layout bug. */
    /* RECOVERY IS DELIBERATELY NOT OFFERED HERE.
     *
     * Ubuntu's recovery mode is an ncurses menu. Tapping it on a tablet
     * with no keyboard reaches a screen nothing can be done with, and
     * the only way out is holding the power button - a button whose one
     * outcome is a dead machine is worse than no button.
     *
     * Nothing is lost by hiding it: GRUB still lists the recovery
     * entries, and with a keyboard attached that is the normal way in.
     * Restart on the main menu goes there. The Repair menu covers what
     * recovery mode was actually wanted for.
     *
     * find_recovery_for() stays, and so do the tests around it: the
     * recovery ENTRY still matters elsewhere - apply-cmdline.sh must
     * never override it, which is what keeps a bad saved command line
     * from breaking the fallback too. */
    int rec = -1;
    (void)find_recovery_for;
    lv_obj_t *edit_btn = lv_msgbox_add_footer_button(mbox, "Edit");
    lv_obj_t *default_btn = lv_msgbox_add_footer_button(mbox, "Set Default");
    lv_obj_t *recovery_btn = (rec >= 0) ? lv_msgbox_add_footer_button(mbox, "Recovery") : NULL;
    lv_obj_t *cancel_btn = lv_msgbox_add_footer_button(mbox, "Cancel");
    lv_obj_t *confirm_btn = lv_msgbox_add_footer_button(mbox, "Boot");

    lv_obj_t *footer = lv_msgbox_get_footer(mbox);
    /* The footer and header classes default to a hardcoded
     * LV_DPI_DEF/3 (43px) height - same "constant unrelated to the
     * real display" problem as lv_msgbox's width. Two rows of
     * DIALOG_BTN_H buttons need ~230px, so without this they render
     * as a squashed unreadable strip (seen on hardware). Let both
     * size to their content instead. */
    lv_obj_set_height(footer, LV_SIZE_CONTENT);
    lv_obj_set_height(lv_msgbox_get_header(mbox), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(footer, LV_FLEX_FLOW_ROW_WRAP);
    /* The gap and the button width are a matched pair. Two 50%-width
     * buttons plus ANY nonzero gap exceed the row, so the grid wraps
     * into a 4x1 stack - found by testing, and the reason this was
     * pinned to zero gap and 50% width for a while. Narrowing the
     * buttons to DIALOG_BTN_W_PCT buys the room for a real gap, so the
     * buttons are no longer edge-to-edge. Change one, check the other. */
    lv_obj_set_style_pad_column(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_style_pad_row(footer, DIALOG_BTN_GAP, 0);
    lv_obj_t *footer_btns[5] = {edit_btn, default_btn, confirm_btn, cancel_btn, recovery_btn};
    int nbtn = recovery_btn ? 5 : 4;
    for (int i = 0; i < nbtn; i++) {
        lv_obj_set_width(footer_btns[i], lv_pct(DIALOG_BTN_W_PCT));
        /* Explicit touch target: the theme sizes these from the font
         * alone, which left them ~13px (about 1mm) tall on this panel -
         * measured, not guessed. DIALOG_BTN_H is ~1cm at the panel's
         * real DPI, which is a comfortable finger target. */
        lv_obj_set_height(footer_btns[i], DIALOG_BTN_H);
    }

    lv_obj_set_style_text_color(edit_btn, lv_color_hex(0xc9d3db), 0);
    lv_obj_set_style_text_color(default_btn, lv_color_hex(0xc9d3db), 0);
    lv_obj_set_style_text_color(cancel_btn, lv_color_hex(0x93a0aa), 0);
    lv_obj_set_style_text_color(confirm_btn, lv_color_hex(0xdce9fb), 0);
    lv_obj_set_style_bg_color(confirm_btn, lv_color_hex(0x3d7ee8), 0);
    lv_obj_set_style_bg_opa(confirm_btn, LV_OPA_30, 0);
    lv_obj_set_style_border_side(confirm_btn, LV_BORDER_SIDE_TOP, 0);
    lv_obj_set_style_border_side(cancel_btn, LV_BORDER_SIDE_TOP, 0);
    lv_obj_set_style_border_width(confirm_btn, 1, 0);
    lv_obj_set_style_border_width(cancel_btn, 1, 0);
    lv_obj_set_style_border_color(confirm_btn, lv_color_hex(0x232c35), 0);
    lv_obj_set_style_border_color(cancel_btn, lv_color_hex(0x232c35), 0);

    /* Boot spans the bottom. Cancel only spans when it has no Recovery
     * to sit beside. */
    lv_obj_set_width(confirm_btn, lv_pct(100));
    if (!recovery_btn) lv_obj_set_width(cancel_btn, lv_pct(100));

    if (recovery_btn) {
        /* Muted rather than accented: it is a deliberate, occasional
         * choice, not something to draw the eye on every boot. */
        lv_obj_set_style_bg_color(recovery_btn, lv_color_hex(0x2a3a4d), 0);
        lv_obj_set_style_text_color(recovery_btn, lv_color_hex(0xd9c48a), 0);
        lv_obj_add_event_cb(recovery_btn, recovery_cb, LV_EVENT_CLICKED, (void *)(intptr_t)rec);
    }

    lv_obj_add_event_cb(edit_btn, edit_cb, LV_EVENT_CLICKED, mbox);
    lv_obj_add_event_cb(default_btn, set_default_cb, LV_EVENT_CLICKED, mbox);
    lv_obj_add_event_cb(confirm_btn, confirm_cb, LV_EVENT_CLICKED, mbox);
    lv_obj_add_event_cb(cancel_btn, cancel_cb, LV_EVENT_CLICKED, mbox);
    screenshot_soon("confirm-dialog");
}

/* The testable core of a kernel-row tap: 1 if the confirm dialog opened, 0
 * if kexec is blocked and an explanation was shown instead. */
static int kernel_row_tapped(int idx) {
    if (kexec_blocked_reason()) { show_kexec_blocked_notice(); return 0; }
    open_confirm_dialog(idx);
    return 1;
}

static void row_click_cb(lv_event_t *e) {
    kernel_row_tapped((int)(intptr_t)lv_event_get_user_data(e));
}

static lv_obj_t *g_list;      /* the container the screens rebuild */
static lv_obj_t *g_header;
static struct tarball *g_tarballs;
static int g_tarball_n;

/* ---------------- install progress ----------------
 *
 * The install runs as a CHILD of picker rather than after it exits, so
 * the UI survives to report on it. Previously picker exited the moment
 * you confirmed, tearing down DRM, and the only feedback for several
 * minutes was console text behind a restored framebuffer - which looks
 * a lot like a hang on a machine you have just been told not to power
 * off.
 *
 * If the install script is not executable - hand-running picker from a
 * VT, say - none of this engages and picker falls back to writing
 * INSTALL_TARBALL for init to act on, exactly as before. */
static int   g_install_fd  = -1;      /* read end of the child's output */
static int   g_child_exit_ok = 0;     /* set by install_pump when the child is reaped */
static pid_t g_install_pid = -1;
static int   g_reload = 0;            /* finished: ask init to re-scan */
/* finished: ask init to restart or power off. Nightfall cannot do it
 * itself and should not: init owns the mount, so it is the one that can
 * unmount the root cleanly first. Same split as SET_DEFAULT. */
static const char *g_power_action = NULL;
static lv_obj_t *g_prog_status;
static lv_obj_t *g_prog_log;
static lv_obj_t *g_prog_spinner;
static lv_obj_t *g_countdown;         /* so the install can silence it */

/* Takes the countdown off the screen WITHOUT giving up its space.
 *
 * It used to be hidden (LV_OBJ_FLAG_HIDDEN), and its text blanked. The
 * screen is a flex column, so a hidden child is removed from the layout
 * and everything below it - every menu button - jumped up by one line the
 * moment you tapped. Bob: "all the buttons shift up, it just feels like a
 * glitch". Hiding was right, because stale "Booting default in 12s" text
 * used to follow you into every submenu; it is only the reflow that was
 * wrong. Fully transparent keeps the line's height, so nothing moves, and
 * the text is left alone because an empty label is shorter than a full
 * one. */
static void countdown_silence(lv_obj_t *label) {
    if (label) lv_obj_set_style_opa(label, LV_OPA_TRANSP, 0);
}
/* Hard interlock: nothing may auto-boot while an install is running.
 * In practice the countdown is already cancelled - reaching the install
 * screen takes several taps and the first one kills it - but "in
 * practice" is not what you want standing between update-initramfs and
 * a kexec. A timeout firing mid-install would cut the initramfs write
 * in half. */
static volatile int g_installing;
static char  g_prog_lines[8][160];    /* rolling tail of the output */
static int   g_prog_n;

/* The menu lists ~25 GRUB entries but far fewer actual kernels - each
 * release appears as a plain entry, a "with Linux X" entry and a
 * recovery entry. Removal operates on RELEASES, not menu entries:
 * offering the same kernel three times and deleting the same files
 * thrice would be both confusing and wrong. */
struct kernelfile { char release[128]; char path[256]; int refs; };
static struct kernelfile g_kernels[MAX_ENTRIES];
static int g_kernel_n;

static void build_kernel_list(void) {
    g_kernel_n = 0;
    for (int i = 0; i < g_entry_n; i++) {
        const char *p = g_entries[i].linux_path;
        const char *base = strrchr(p, '/');
        base = base ? base + 1 : p;
        if (strncmp(base, "vmlinuz-", 8) != 0) continue;

        int seen = -1;
        for (int k = 0; k < g_kernel_n; k++)
            if (!strcmp(g_kernels[k].path, p)) { seen = k; break; }
        if (seen >= 0) { g_kernels[seen].refs++; continue; }
        if (g_kernel_n >= MAX_ENTRIES) break;
        snprintf(g_kernels[g_kernel_n].release, sizeof(g_kernels[0].release), "%s", base + 8);
        snprintf(g_kernels[g_kernel_n].path, sizeof(g_kernels[0].path), "%s", p);
        g_kernels[g_kernel_n].refs = 1;
        g_kernel_n++;
    }
}

static const char *remove_script(void) {
    const char *s = getenv("NIGHTFALL_REMOVE_SH");
    return s ? s : "/bin/remove-kernel.sh";
}

static const char *install_script(void) {
    const char *s = getenv("NIGHTFALL_INSTALL_SH");
    return s ? s : "/bin/install-kernel.sh";
}

static void prog_done_cb(lv_event_t *e) { (void)e; g_reload = 1; }

/* tar's default blocking factor is 20 records of 512 bytes, and nothing
 * here changes it, so one checkpoint unit is 10240 bytes. */
#define TAR_RECORD_BYTES 10240.0

static double g_prog_total;   /* bytes, 0 when unknown */
static double g_prog_done;

static void human_bytes(double b, char *out, size_t n) {
    if (b >= 1073741824.0)   snprintf(out, n, "%.1f GB", b / 1073741824.0);
    else if (b >= 1048576.0) snprintf(out, n, "%.0f MB", b / 1048576.0);
    else                     snprintf(out, n, "%.0f KB", b / 1024.0);
}

/* Turns tar's checkpoint lines into something a person can read.
 *
 * tar counts RECORDS, so it emits "Write checkpoint 4900000" - a number
 * in units nobody thinks in, which during the first real backup looked
 * alarming enough to nearly stop a run that was working perfectly. The
 * scripts now announce the total up front, so this can say
 * "50.2 GB of 86.0 GB (58%)" instead.
 *
 * Returns 1 if the line was progress and should not go in the log:
 * checkpoints arrive every 500MB and would otherwise flood the rolling
 * tail, pushing out the steps that actually say what is happening. */
static int prog_consume_progress(const char *line) {
    const char *p;

    if ((p = strstr(line, "nightfall-total-kb:")) != NULL) {
        g_prog_total = strtod(p + strlen("nightfall-total-kb:"), NULL) * 1024.0;
        return 1;
    }
    if ((p = strstr(line, "Write checkpoint ")) == NULL) return 0;

    g_prog_done = strtod(p + strlen("Write checkpoint "), NULL) * TAR_RECORD_BYTES;
    if (!g_prog_status) return 1;

    char done[32], total[32], msg[128];
    human_bytes(g_prog_done, done, sizeof(done));
    if (g_prog_total > 0) {
        int pct = (int)((g_prog_done / g_prog_total) * 100.0);
        if (pct > 99) pct = 99;      /* the last of it is headers and flush */
        human_bytes(g_prog_total, total, sizeof(total));
        snprintf(msg, sizeof(msg), "%s of %s  (%d%%)", done, total, pct);
    } else {
        snprintf(msg, sizeof(msg), "%s written", done);
    }
    lv_label_set_text(g_prog_status, msg);
    return 1;
}

static void prog_append(const char *line) {
    if (!*line) return;
    if (prog_consume_progress(line)) return;
    if (g_prog_n < 8) {
        snprintf(g_prog_lines[g_prog_n++], sizeof(g_prog_lines[0]), "%s", line);
    } else {
        for (int i = 1; i < 8; i++)
            memcpy(g_prog_lines[i - 1], g_prog_lines[i], sizeof(g_prog_lines[0]));
        snprintf(g_prog_lines[7], sizeof(g_prog_lines[0]), "%s", line);
    }
    if (g_prog_status) lv_label_set_text(g_prog_status, line);
    if (g_prog_log) {
        char all[8 * 160];
        size_t used = 0;
        for (int i = 0; i < g_prog_n && used < sizeof(all) - 1; i++)
            used += (size_t)snprintf(all + used, sizeof(all) - used, "%s\n", g_prog_lines[i]);
        lv_label_set_text(g_prog_log, all);
    }
}

static void show_progress(const char *heading, const char *subject, const char *warning) {
    lv_obj_clean(g_list);
    g_prog_n = 0;
    g_prog_total = 0;
    g_prog_done = 0;
    g_installing = 1;
    countdown_silence(g_countdown);
    lv_label_set_text(g_header, heading);

    lv_obj_t *title = lv_label_create(g_list);
    lv_label_set_text(title, subject);
    lv_obj_set_style_text_color(title, lv_color_hex(0xe8eef4), 0);

    g_prog_spinner = lv_spinner_create(g_list);
    lv_obj_set_size(g_prog_spinner, ui_px(160), ui_px(160));

    g_prog_status = lv_label_create(g_list);
    lv_label_set_text(g_prog_status, "starting...");
    lv_obj_set_style_text_color(g_prog_status, lv_color_hex(0x8ec6ff), 0);
    lv_label_set_long_mode(g_prog_status, LV_LABEL_LONG_DOT);
    lv_obj_set_width(g_prog_status, lv_pct(100));

    lv_obj_t *warn = lv_label_create(g_list);
    lv_label_set_text(warn, warning);
    lv_obj_set_style_text_color(warn, lv_color_hex(0x93a0aa), 0);

    g_prog_log = lv_label_create(g_list);
    lv_label_set_text(g_prog_log, "");
    lv_obj_set_style_text_color(g_prog_log, lv_color_hex(0x6f7b86), 0);
    lv_label_set_long_mode(g_prog_log, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(g_prog_log, lv_pct(100));
}

/* Which child ran, so the outcome can say something true about it. */
static const char *g_child_what = "Install";
static const char *g_child_ok_msg = "";
static const char *g_child_bad_msg = "";

static void install_finished(int ok) {
    if (g_prog_spinner) { lv_obj_delete(g_prog_spinner); g_prog_spinner = NULL; }
    char h[64];
    snprintf(h, sizeof(h), "%s  %s %s", ok ? LV_SYMBOL_OK : LV_SYMBOL_WARNING,
             g_child_what, ok ? "finished" : "failed");
    lv_label_set_text(g_header, h);
    if (g_prog_status) {
        lv_label_set_text(g_prog_status, ok ? g_child_ok_msg : g_child_bad_msg);
        lv_obj_set_style_text_color(g_prog_status,
                                    lv_color_hex(ok ? 0x8ec6ff : 0xffb4a2), 0);
    }
    lv_obj_t *done = lv_button_create(g_list);
    lv_obj_set_width(done, lv_pct(100));
    lv_obj_set_height(done, DIALOG_BTN_H);
    lv_obj_set_style_bg_color(done, lv_color_hex(0x3d7ee8), 0);
    lv_obj_set_style_bg_opa(done, LV_OPA_30, 0);
    lv_obj_t *l = lv_label_create(done);
    lv_label_set_text(l, "Back to menu");
    lv_obj_center(l);
    lv_obj_add_event_cb(done, prog_done_cb, LV_EVENT_CLICKED, NULL);
    screenshot_soon(ok ? "child-done" : "child-failed");
}

/* Consumes whatever the running child has written, dispatching complete
 * lines to the progress screen. `buf` and `*len` carry the tail of a partial
 * line between calls - the child writes whenever it likes, so a read
 * landing mid-line is normal and printing fragments would be wrong.
 *
 * Returns 1 while the child is still going, 0 once it has finished - at
 * which point the pipe is closed, the child reaped, g_child_exit_ok set
 * and install_finished() called.
 *
 * This lives in one place on purpose. The test used to carry its own
 * copy of this loop, which meant the copy could drift from what really
 * runs on the device - and it did: both had the bug below, so no test
 * could ever have found it. */
static int install_pump(char *buf, size_t bufsz, size_t *len)
{
    /* Never hand read() a count of zero. A line longer than the buffer
     * fills it with no newline to flush, leaving no room - and
     * read(fd, p, 0) returns 0, which is indistinguishable from EOF. The
     * UI would close the pipe and announce the job had finished while
     * tar was still running. Flush the over-long line and carry on. */
    if (*len >= bufsz - 1) {
        buf[bufsz - 1] = '\0';
        prog_append(buf);
        *len = 0;
    }

    ssize_t got = read(g_install_fd, buf + *len, bufsz - 1 - *len);
    if (got > 0) {
        *len += (size_t)got;
        buf[*len] = '\0';
        char *start = buf, *nl;
        while ((nl = strchr(start, '\n'))) {
            *nl = '\0';
            prog_append(start);
            start = nl + 1;
        }
        *len = strlen(start);
        memmove(buf, start, *len + 1);
        return 1;
    }

    /* EOF: the child closed its output, so it is done. */
    close(g_install_fd);
    g_install_fd = -1;
    if (*len) { buf[*len] = '\0'; prog_append(buf); *len = 0; }
    int st = 0;
    if (g_install_pid > 0) waitpid(g_install_pid, &st, 0);
    g_install_pid = -1;
    g_child_exit_ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
    install_finished(g_child_exit_ok);
    return 0;
}

/* 0: child started, the UI takes over. -1: caller should fall back to
 * exiting and letting init do the work. */
static int start_child(const char *script, const char *arg, const char *arg2,
                       const char *arg3,
                       const char *heading, const char *subject,
                       const char *warning) {
    if (access(script, X_OK) != 0) return -1;

    int pfd[2];
    if (pipe(pfd) != 0) return -1;

    pid_t pid = fork();
    if (pid < 0) { close(pfd[0]); close(pfd[1]); return -1; }
    if (pid == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        dup2(pfd[1], STDERR_FILENO);
        close(pfd[1]);
        const char *root = getenv("NIGHTFALL_ROOT");
        if (!root) root = "/mnt/root";
        /* rename-backup.sh needs four: root, drive, old name, new name.
         * Everything else stops at two or three. */
        if (arg3)      execl(script, script, root, arg, arg2, arg3, (char *)NULL);
        else if (arg2) execl(script, script, root, arg, arg2, (char *)NULL);
        else           execl(script, script, root, arg, (char *)NULL);
        _exit(127);
    }
    close(pfd[1]);
    g_install_fd = pfd[0];
    g_install_pid = pid;
    show_progress(heading, subject, warning);
    return 0;
}

static int start_install(int idx) {
    g_child_what = "Install";
    g_child_ok_msg  = "Installed. It will appear in the kernel list.";
    g_child_bad_msg = "Failed - nothing was removed, existing kernels still boot.";
    return start_child(install_script(), g_tarballs[idx].path, NULL, NULL,
                       LV_SYMBOL_DOWNLOAD "  Installing",
                       g_tarballs[idx].version,
                       "This takes several minutes. Do not power off.");
}

static int start_remove(int idx) {
    g_child_what = "Removal";
    g_child_ok_msg  = "Removed. The menu entries are gone too.";
    /* NOT "nothing changed": by the time update-grub can fail the files
     * are already gone. Claiming otherwise sent me looking in the wrong
     * place on the first real failure. */
    g_child_bad_msg = "Failed - see the output above before rebooting.";
    return start_child(remove_script(), g_kernels[idx].release, NULL, NULL,
                       LV_SYMBOL_TRASH "  Removing",
                       g_kernels[idx].release,
                       "Deleting the kernel, its modules and its menu entries.");
}

static void remove_confirm_cb(lv_event_t *e) {
    lv_obj_t *mbox = lv_event_get_user_data(e);
    int idx = (int)(intptr_t)lv_obj_get_user_data(mbox);
    lv_msgbox_close_async(mbox);
    if (start_remove(idx) != 0) {
        /* No script to run it with (hand-run from a VT). Removal is
         * destructive and there is no init-side fallback for it, so say
         * so rather than appearing to have done something. */
        lv_obj_t *m = lv_msgbox_create(NULL);
        lv_obj_set_width(m, lv_pct(70));
        lv_msgbox_add_title(m, "Cannot remove");
        lv_msgbox_add_text(m, "remove-kernel.sh is not available in this "
                              "environment, so nothing was changed.");
        lv_obj_t *b = lv_msgbox_add_footer_button(m, "OK");
        lv_obj_set_height(lv_msgbox_get_footer(m), LV_SIZE_CONTENT);
        lv_obj_set_height(b, DIALOG_BTN_H);
        lv_obj_add_event_cb(b, cancel_cb, LV_EVENT_CLICKED, m);
    }
}

static struct target *g_targets;
static int g_target_n;
static struct backup *g_backups;
static int g_backup_n;
static struct bootable_drive *g_bootable;
static int g_bootable_n;

/* Re-runs drive discovery while the picker is running.
 *
 * This is not a convenience. The Ventoy drive cannot be plugged in at
 * boot: with no keyboard there is no way to tell the firmware to skip a
 * bootable USB stick, so the machine boots Ventoy instead of the picker.
 * The drive has to arrive afterwards, which makes a scan done once at
 * startup useless for the only workflow available.
 *
 * Synchronous on purpose. It takes about a second - it mounts each
 * candidate read-only to identify it - and a progress screen for that
 * would be more machinery than the wait deserves. The label is changed
 * and the screen forced to repaint first, so the UI does not simply
 * freeze with no explanation. */
static const char *scan_script(void) {
    const char *s = getenv("NIGHTFALL_SCAN_SH");
    return s ? s : "/bin/scan-drives.sh";
}

static char g_targets_path[256];
static char g_backups_path[256];
static char g_bootable_path[256];

static int rescan_drives(void) {
    const char *script = scan_script();
    if (access(script, X_OK) != 0) return -1;
    if (!g_targets_path[0] || !g_backups_path[0] || !g_bootable_path[0]) return -1;

    const char *rootdev = getenv("REAL_ROOT_DEV");
    const char *rootmnt = getenv("NIGHTFALL_ROOT");

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        /* The scan's own chatter would land on picker's stderr and end
         * up in the boot log for no reason; it reports through the
         * files it writes. */
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, STDOUT_FILENO); dup2(devnull, STDERR_FILENO); }
        execl(script, script,
              rootdev ? rootdev : "/dev/mmcblk0p2",
              rootmnt ? rootmnt : "/mnt/root",
              g_targets_path, g_backups_path, g_bootable_path, (char *)NULL);
        _exit(127);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    if (!(WIFEXITED(st) && WEXITSTATUS(st) == 0)) return -1;

    /* Reload all three lists from what the scan just wrote. */
    static struct target targets[16];
    static struct backup backups[64];
    static struct bootable_drive bootables[16];
    g_target_n = load_targets(g_targets_path, targets, 16);
    g_targets = g_target_n ? targets : NULL;
    g_backup_n = load_backups(g_backups_path, backups, 64);
    g_backups = g_backup_n ? backups : NULL;
    g_bootable_n = load_bootable_drives(g_bootable_path, bootables, 16);
    g_bootable = g_bootable_n ? bootables : NULL;
    return 0;
}

static struct live_iso *g_live_isos;
static int g_live_iso_n;

static const char *live_isos_script(void) {
    const char *s = getenv("NIGHTFALL_LIVE_ISOS_SH");
    return s ? s : "/bin/discover-live-isos.sh";
}

/* Lists the ISO files on ONE drive, on demand rather than as part of
 * scan-drives.sh's own sweep. Deliberately not folded into the periodic
 * rescan: unlike backups, a drive can carry several large ISOs, and
 * nobody needs that list until they actually open "Boot a live USB" for
 * that specific drive.
 *
 * discover-live-isos.sh writes to STDOUT (same contract as
 * discover-backups.sh), so unlike scan-drives.sh this redirects the
 * child's own stdout to a fixed scratch file rather than passing an
 * output path as an argument - there was no existing convention worth
 * inventing a second one to avoid. */
static char g_live_isos_path[256];

static int scan_live_isos(const char *dev) {
    const char *script = live_isos_script();
    if (access(script, X_OK) != 0) return -1;

    const char *override = getenv("NIGHTFALL_LIVE_ISOS_TSV");
    snprintf(g_live_isos_path, sizeof(g_live_isos_path), "%s",
             override ? override : "/run/nightfall/live-isos.tsv");

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int fd = open(g_live_isos_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) dup2(fd, STDOUT_FILENO);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) dup2(devnull, STDERR_FILENO);
        execl(script, script, dev, (char *)NULL);
        _exit(127);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    if (!(WIFEXITED(st) && WEXITSTATUS(st) == 0)) return -1;

    static struct live_iso isos[64];
    g_live_iso_n = load_live_isos(g_live_isos_path, isos, 64);
    g_live_isos = g_live_iso_n ? isos : NULL;
    return 0;
}

static const char *backup_script(void) {
    const char *s = getenv("NIGHTFALL_BACKUP_SH");
    return s ? s : "/bin/backup-system.sh";
}
static const char *restore_script(void) {
    const char *s = getenv("NIGHTFALL_RESTORE_SH");
    return s ? s : "/bin/restore-system.sh";
}

/* The name the next backup is written under. Empty means "let
 * backup-system.sh generate one", which is what happened before this
 * was nameable at all. */
static char g_backup_name[128];

/* Builds the default, which is also what the name box starts with. */
static void default_backup_name(char *out, size_t n) {
    time_t t = time(NULL);
    struct tm tmv;
    if (localtime_r(&t, &tmv))
        strftime(out, n, "nightfall-backup-%Y%m%d-%H%M", &tmv);
    else
        snprintf(out, n, "nightfall-backup-manual");
}

/* A backup name becomes a filename on a drive that other machines will
 * read, so keep it to characters that mean the same thing everywhere:
 * exFAT, ext4, and a shell that will later pass it to tar.
 *
 * Anything else becomes '-' rather than being dropped, so a name stays
 * roughly the length the person typed and two different names cannot
 * silently collapse into one. A '/' would escape the backup directory
 * entirely - backup-system.sh refuses that too, but it should never get
 * that far. */
static void sanitize_backup_name(const char *in, char *out, size_t n) {
    size_t o = 0;
    int prev_dash = 0;
    for (const char *p = in; *p && o + 1 < n; p++) {
        char c = *p;
        int keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                   (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!keep) c = '-';
        /* Collapse runs, and never lead with a dash or dot: a leading
         * dash reads as an option to anything later, and a leading dot
         * hides the archive from a plain ls. */
        if (c == '-') {
            if (prev_dash || o == 0) continue;
            prev_dash = 1;
        } else {
            prev_dash = 0;
        }
        if (o == 0 && c == '.') continue;
        out[o++] = c;
    }
    while (o > 0 && out[o - 1] == '-') o--;   /* no trailing dash either */
    out[o] = '\0';
    if (o == 0) default_backup_name(out, n);  /* all punctuation, or empty */
}

static int start_backup(int idx) {
    g_child_what = "Backup";
    g_child_ok_msg  = "Backed up. The archive is on the drive.";
    g_child_bad_msg = "Failed - see the output above. Nothing on this machine changed.";
    return start_child(backup_script(), g_targets[idx].dev,
                       g_backup_name[0] ? g_backup_name : NULL, NULL,
                       LV_SYMBOL_SAVE "  Backing up",
                       g_backup_name[0] ? g_backup_name
                                        : (g_targets[idx].label[0] ? g_targets[idx].label
                                                                   : g_targets[idx].dev),
                       "Reads the whole system. Minutes, not seconds. Do not unplug the drive.");
}

static int start_restore(int idx) {
    g_child_what = "Restore";
    g_child_ok_msg  = "Restored. Reboot when you are ready.";
    g_child_bad_msg = "Failed - see the output above before rebooting.";
    return start_child(restore_script(), g_backups[idx].target, g_backups[idx].name, NULL,
                       LV_SYMBOL_UPLOAD "  Restoring",
                       g_backups[idx].name,
                       "Writes over the running system. Do not power off.");
}

static const char *remove_backup_script(void) {
    const char *s = getenv("NIGHTFALL_REMOVE_BACKUP_SH");
    return s ? s : "/bin/remove-backup.sh";
}

static int start_remove_backup(int idx) {
    g_child_what = "Delete";
    g_child_ok_msg  = "Deleted. The space is free on the drive.";
    /* Deliberately not "nothing changed": the archive is deleted before
     * anything else can fail, so a failure here still means it is gone.
     * Same lesson the kernel removal screen learned - a reassuring
     * message that is false points diagnosis the wrong way. */
    g_child_bad_msg = "Failed - see the output above. The backup may be partly deleted.";
    return start_child(remove_backup_script(), g_backups[idx].target, g_backups[idx].name, NULL,
                       LV_SYMBOL_TRASH "  Deleting",
                       g_backups[idx].name,
                       "Deletes the archive from the drive. This machine is not touched.");
}

static const char *repair_script(void) {
    const char *s = getenv("NIGHTFALL_REPAIR_SH");
    return s ? s : "/bin/repair-system.sh";
}
static const char *fsck_script(void) {
    const char *s = getenv("NIGHTFALL_FSCK_SH");
    return s ? s : "/bin/fsck-root.sh";
}
static const char *clear_script(void) {
    const char *s = getenv("NIGHTFALL_CLEAR_SH");
    return s ? s : "/bin/clear-overrides.sh";
}

static int start_fsck(const char *mode) {
    g_child_what = "Check";
    g_child_ok_msg  = "Finished. Read the RESULT line above.";
    /* Not "nothing changed": a check that exits non-zero may still have
     * repaired plenty before hitting what it could not fix. */
    g_child_bad_msg = "Errors remain - see the RESULT line above.";
    return start_child(fsck_script(), mode, NULL, NULL,
                       LV_SYMBOL_REFRESH "  Checking the filesystem",
                       strcmp(mode, "force") == 0 ? "full repair" : "safe check",
                       "The root is unmounted while this runs. Do not power off.");
}

static int start_repair(const char *action, const char *heading, const char *subject) {
    g_child_what = "Repair";
    g_child_ok_msg  = "Finished.";
    g_child_bad_msg = "Failed - see the output above.";
    return start_child(repair_script(), action, NULL, NULL,
                       heading, subject,
                       "Runs inside the installed system. Do not power off.");
}

static int start_clear(void) {
    g_child_what = "Clear";
    g_child_ok_msg  = "Cleared. The next boot uses what grub.cfg says.";
    g_child_bad_msg = "Failed - see the output above.";
    return start_child(clear_script(), "all", NULL, NULL,
                       LV_SYMBOL_TRASH "  Clearing saved settings",
                       "default and command lines",
                       "Removes only Nightfall's own saved settings.");
}

static const char *rename_backup_script(void) {
    const char *s = getenv("NIGHTFALL_RENAME_BACKUP_SH");
    return s ? s : "/bin/rename-backup.sh";
}

/* The name a rename is heading for. Filled in by the dialog just before
 * the child starts, for the same reason g_backup_name exists: the
 * script takes it as an argument, and picker never touches the drive. */
static char g_rename_to[128];

static int start_rename_backup(int idx) {
    g_child_what = "Rename";
    g_child_ok_msg  = "Renamed. The new name is on the drive.";
    /* Not "nothing changed": the sidecar is written first, so a failure
     * can leave a stray one behind. It is harmless - the next backup
     * sweeps it - but claiming nothing happened would be false. */
    g_child_bad_msg = "Failed - see the output above. The backup itself is intact.";
    return start_child(rename_backup_script(), g_backups[idx].target,
                       g_backups[idx].name, g_rename_to,
                       LV_SYMBOL_EDIT "  Renaming",
                       g_rename_to,
                       "Renames the archive on the drive. This machine is not touched.");
}

/* A plain two-button confirm. The install and remove dialogs predate it
 * and carry extra wording of their own; these two are simple enough to
 * share one. */
static lv_obj_t *simple_confirm(int idx, const char *title, const char *body,
                                const char *go_label, lv_event_cb_t go_cb,
                                int destructive) {
    lv_obj_t *mbox = lv_msgbox_create(NULL);
    lv_obj_set_width(mbox, lv_pct(72));
    lv_obj_set_user_data(mbox, (void *)(intptr_t)idx);
    lv_msgbox_add_title(mbox, title);
    lv_msgbox_add_text(mbox, body);

    lv_obj_t *no = lv_msgbox_add_footer_button(mbox, "Cancel");
    lv_obj_t *go = lv_msgbox_add_footer_button(mbox, go_label);
    lv_obj_t *footer = lv_msgbox_get_footer(mbox);
    lv_obj_set_height(footer, LV_SIZE_CONTENT);
    lv_obj_set_height(lv_msgbox_get_header(mbox), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(footer, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_style_pad_column(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_style_pad_row(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_width(no, lv_pct(100));
    lv_obj_set_width(go, lv_pct(100));
    lv_obj_set_height(no, DIALOG_BTN_H);
    lv_obj_set_height(go, DIALOG_BTN_H);
    /* Same convention as the rest: the action sits at the bottom, and a
     * destructive one looks dangerous rather than default. */
    lv_obj_set_style_bg_color(go, lv_color_hex(destructive ? 0xc0392b : 0x3d7ee8), 0);
    lv_obj_set_style_bg_opa(go, destructive ? LV_OPA_40 : LV_OPA_30, 0);
    lv_obj_add_event_cb(no, cancel_cb, LV_EVENT_CLICKED, mbox);
    lv_obj_add_event_cb(go, go_cb, LV_EVENT_CLICKED, mbox);
    return mbox;
}

/* Backup has no simple_confirm callback: its confirm step is the name
 * dialog (backup_click_cb), which does the same job and collects a name
 * on the way through. */

static void restore_confirm_cb(lv_event_t *e) {
    lv_obj_t *mbox = lv_event_get_user_data(e);
    int idx = (int)(intptr_t)lv_obj_get_user_data(mbox);
    lv_msgbox_close_async(mbox);
    start_restore(idx);
}

/* Naming a backup, which is also the confirm step.
 *
 * Deliberately one dialog rather than confirm-then-name: every backup
 * gets a name whether or not you care, so the box arrives pre-filled
 * with the generated one and tapping straight through behaves exactly
 * as it did before names existed. Only someone who wants a name pays
 * for the keyboard.
 *
 * Same structure as the Edit dialog, for the same hard-won reasons -
 * see edit_cb: the keyboard is a later SIBLING on lv_layer_top(), the
 * dialog is pinned to the top because the keyboard owns the bottom
 * 45%, and lv_layer_top() is invalidated at the end or the textarea
 * comes up blank until the first keystroke. */
struct bkname_ctx {
    int idx;
    lv_obj_t *mbox;
    lv_obj_t *kb;
    lv_obj_t *ta;
};

static void bkname_close(struct bkname_ctx *ctx) {
    /* NULL whenever there is a real keyboard - see text_input_begin(). */
    if (ctx->kb) lv_obj_delete_async(ctx->kb);
    lv_msgbox_close_async(ctx->mbox);
    free(ctx);
}

static void bkname_cancel_cb(lv_event_t *e) {
    bkname_close(lv_event_get_user_data(e));
}

static void bkname_go_cb(lv_event_t *e) {
    struct bkname_ctx *ctx = lv_event_get_user_data(e);
    int idx = ctx->idx;                      /* ctx is freed below */
    const char *typed = lv_textarea_get_text(ctx->ta);
    sanitize_backup_name(typed ? typed : "", g_backup_name, sizeof(g_backup_name));
    bkname_close(ctx);
    start_backup(idx);
}

/* Renaming reuses the backup-naming dialog wholesale - same keyboard,
 * same layering rules, same repaint fix. Only the title, the prefill and
 * what happens on OK differ, so it is one more callback rather than a
 * second copy of a dialog that took three rounds on hardware to get
 * right. */
static void rename_go_cb(lv_event_t *e) {
    struct bkname_ctx *ctx = lv_event_get_user_data(e);
    int idx = ctx->idx;
    const char *typed = lv_textarea_get_text(ctx->ta);
    sanitize_backup_name(typed ? typed : "", g_rename_to, sizeof(g_rename_to));
    bkname_close(ctx);
    start_rename_backup(idx);
}

static void rename_click_cb(lv_event_t *e) {
    int idx = (int)(intptr_t)lv_event_get_user_data(e);

    struct bkname_ctx *ctx = malloc(sizeof(*ctx));
    if (!ctx) return;
    ctx->idx = idx;

    ctx->mbox = lv_msgbox_create(NULL);
    lv_obj_set_width(ctx->mbox, lv_pct(92));
    lv_msgbox_add_title(ctx->mbox, "Rename this backup");

    char body[400];
    snprintf(body, sizeof(body), "%.60s  (%.16s)\n\nNew name:",
             g_backups[idx].when, g_backups[idx].size);
    lv_msgbox_add_text(ctx->mbox, body);

    ctx->ta = lv_textarea_create(lv_msgbox_get_content(ctx->mbox));
    lv_textarea_set_one_line(ctx->ta, true);
    lv_obj_set_width(ctx->ta, lv_pct(100));
    /* Prefilled with the CURRENT name, not blank: most renames are an
     * edit of what is there, and it also shows what you are renaming. */
    lv_textarea_set_text(ctx->ta, g_backups[idx].name);
    lv_textarea_set_cursor_pos(ctx->ta, 0);

    ctx->kb = text_input_begin(ctx->ta);
    if (ctx->kb) {
        lv_obj_set_style_max_height(ctx->mbox, lv_pct(100 - KEYBOARD_PCT_H - 4), 0);
        lv_obj_align(ctx->mbox, LV_ALIGN_TOP_MID, 0, ui_px(16));
    }

    lv_obj_t *go = lv_msgbox_add_footer_button(ctx->mbox, "Rename");
    lv_obj_t *no = lv_msgbox_add_footer_button(ctx->mbox, "Cancel");
    lv_obj_t *footer = lv_msgbox_get_footer(ctx->mbox);
    lv_obj_set_height(footer, LV_SIZE_CONTENT);
    lv_obj_set_height(lv_msgbox_get_header(ctx->mbox), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(footer, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_style_pad_column(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_style_pad_row(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_width(go, lv_pct(100));
    lv_obj_set_width(no, lv_pct(100));
    lv_obj_set_height(go, DIALOG_BTN_H);
    lv_obj_set_height(no, DIALOG_BTN_H);
    lv_obj_set_style_bg_color(go, lv_color_hex(0x3d7ee8), 0);
    lv_obj_set_style_bg_opa(go, LV_OPA_30, 0);

    lv_obj_add_event_cb(go, rename_go_cb, LV_EVENT_CLICKED, ctx);
    lv_obj_add_event_cb(no, bkname_cancel_cb, LV_EVENT_CLICKED, ctx);

    lv_obj_invalidate(lv_layer_top());
    screenshot_soon("rename-dialog");
}

static void backup_click_cb(lv_event_t *e) {
    int idx = (int)(intptr_t)lv_event_get_user_data(e);

    struct bkname_ctx *ctx = malloc(sizeof(*ctx));
    if (!ctx) return;
    ctx->idx = idx;

    ctx->mbox = lv_msgbox_create(NULL);
    lv_obj_set_width(ctx->mbox, lv_pct(92));
    lv_msgbox_add_title(ctx->mbox, "Back up to this drive?");

    char body[500];
    snprintf(body, sizeof(body),
             "%.60s  (%.20s, %.20s free)\n\n"
             "The system is read-only while this runs, so nothing is "
             "changing underneath it.\n\nName this backup:",
             g_targets[idx].label[0] ? g_targets[idx].label : g_targets[idx].dev,
             g_targets[idx].fstype, g_targets[idx].freespace);
    lv_msgbox_add_text(ctx->mbox, body);

    ctx->ta = lv_textarea_create(lv_msgbox_get_content(ctx->mbox));
    /* one_line IS right here, unlike the cmdline editor: a name is
     * short, and a single line makes it obvious this is not a place for
     * a paragraph. */
    lv_textarea_set_one_line(ctx->ta, true);
    lv_obj_set_width(ctx->ta, lv_pct(100));
    char def[sizeof(g_backup_name)];
    default_backup_name(def, sizeof(def));
    lv_textarea_set_text(ctx->ta, def);
    lv_textarea_set_cursor_pos(ctx->ta, 0);

    ctx->kb = text_input_begin(ctx->ta);
    if (ctx->kb) {
        lv_obj_set_style_max_height(ctx->mbox, lv_pct(100 - KEYBOARD_PCT_H - 4), 0);
        lv_obj_align(ctx->mbox, LV_ALIGN_TOP_MID, 0, ui_px(16));
    }

    lv_obj_t *go = lv_msgbox_add_footer_button(ctx->mbox, "Back up");
    lv_obj_t *no = lv_msgbox_add_footer_button(ctx->mbox, "Cancel");
    lv_obj_t *footer = lv_msgbox_get_footer(ctx->mbox);
    lv_obj_set_height(footer, LV_SIZE_CONTENT);
    lv_obj_set_height(lv_msgbox_get_header(ctx->mbox), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(footer, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_style_pad_column(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_style_pad_row(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_width(go, lv_pct(100));
    lv_obj_set_width(no, lv_pct(100));
    lv_obj_set_height(go, DIALOG_BTN_H);
    lv_obj_set_height(no, DIALOG_BTN_H);
    lv_obj_set_style_bg_color(go, lv_color_hex(0x3d7ee8), 0);
    lv_obj_set_style_bg_opa(go, LV_OPA_30, 0);

    lv_obj_add_event_cb(go, bkname_go_cb, LV_EVENT_CLICKED, ctx);
    lv_obj_add_event_cb(no, bkname_cancel_cb, LV_EVENT_CLICKED, ctx);

    /* Without this the name box is blank until the first keystroke. */
    lv_obj_invalidate(lv_layer_top());
    screenshot_soon("backup-dialog");
}

static void restore_click_cb(lv_event_t *e) {
    int idx = (int)(intptr_t)lv_event_get_user_data(e);
    char body[600];
    snprintf(body, sizeof(body),
             "%.60s\n%.60s  (%.16s)\n\n"
             "Writes this backup over the current system. Files created "
             "since the backup are NOT removed - this puts the system "
             "back, it does not rewind it.\n\n"
             "Nightfall itself is never overwritten.",
             g_backups[idx].name, g_backups[idx].when, g_backups[idx].size);
    simple_confirm(idx, "Restore this backup?", body, "Restore", restore_confirm_cb, 1);
    screenshot_soon("restore-dialog");
}

static void delete_backup_confirm_cb(lv_event_t *e) {
    lv_obj_t *mbox = lv_event_get_user_data(e);
    int idx = (int)(intptr_t)lv_obj_get_user_data(mbox);
    lv_msgbox_close_async(mbox);
    start_remove_backup(idx);
}

static void delete_backup_click_cb(lv_event_t *e) {
    int idx = (int)(intptr_t)lv_event_get_user_data(e);
    char body[600];
    /* Being down to one backup is worth saying out loud, but it is not
     * worth refusing over - see the header of remove-backup.sh. Freeing
     * the space to take a fresh one is a normal thing to want, and on a
     * full drive it is the only way to do it. */
    snprintf(body, sizeof(body),
             "%.60s\n%.60s  (%.16s)\n\n"
             "Deletes this archive from the drive, freeing %.16s. "
             "Nothing on this machine is touched.\n\n"
             "%s",
             g_backups[idx].name, g_backups[idx].when, g_backups[idx].size,
             g_backups[idx].size,
             g_backup_n == 1
                 ? "This is your only backup. There will be none left."
                 : "This cannot be undone.");
    simple_confirm(idx, "Delete this backup?", body, "Delete",
                   delete_backup_confirm_cb, 1);
    screenshot_soon("delete-backup-dialog");
}

static void remove_click_cb(lv_event_t *e) {
    int idx = (int)(intptr_t)lv_event_get_user_data(e);

    lv_obj_t *mbox = lv_msgbox_create(NULL);
    lv_obj_set_width(mbox, lv_pct(72));
    lv_obj_set_user_data(mbox, (void *)(intptr_t)idx);
    lv_msgbox_add_title(mbox, "Remove this kernel?");

    char body[600];
    snprintf(body, sizeof(body),
             "%s\n\n"
             "Deletes the kernel, its initramfs and its modules, and removes "
             "its %d menu entr%s.\n\n"
             "This cannot be undone from here - you would have to reinstall "
             "it. %d other kernel%s would remain.",
             g_kernels[idx].release, g_kernels[idx].refs,
             g_kernels[idx].refs == 1 ? "y" : "ies",
             g_kernel_n - 1, g_kernel_n - 1 == 1 ? "" : "s");
    lv_msgbox_add_text(mbox, body);

    lv_obj_t *go = lv_msgbox_add_footer_button(mbox, "Remove");
    lv_obj_t *no = lv_msgbox_add_footer_button(mbox, "Cancel");
    lv_obj_t *footer = lv_msgbox_get_footer(mbox);
    lv_obj_set_height(footer, LV_SIZE_CONTENT);
    lv_obj_set_height(lv_msgbox_get_header(mbox), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(footer, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_style_pad_column(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_style_pad_row(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_width(go, lv_pct(DIALOG_BTN_W_PCT));
    lv_obj_set_width(no, lv_pct(DIALOG_BTN_W_PCT));
    lv_obj_set_height(go, DIALOG_BTN_H);
    lv_obj_set_height(no, DIALOG_BTN_H);
    /* Destructive action, so it is the one that looks dangerous rather
     * than the one that looks default. */
    lv_obj_set_style_bg_color(go, lv_color_hex(0xc0392b), 0);
    lv_obj_set_style_bg_opa(go, LV_OPA_40, 0);

    lv_obj_add_event_cb(go, remove_confirm_cb, LV_EVENT_CLICKED, mbox);
    lv_obj_add_event_cb(no, cancel_cb, LV_EVENT_CLICKED, mbox);
    screenshot_soon("remove-dialog");
}

static void install_confirm_cb(lv_event_t *e) {
    lv_obj_t *mbox = lv_event_get_user_data(e);
    int idx = (int)(intptr_t)lv_obj_get_user_data(mbox);
    lv_msgbox_close_async(mbox);
    if (start_install(idx) != 0) g_install = idx;   /* let init do it */
}

static void install_click_cb(lv_event_t *e) {
    int idx = (int)(intptr_t)lv_event_get_user_data(e);

    lv_obj_t *mbox = lv_msgbox_create(NULL);
    lv_obj_set_width(mbox, lv_pct(70));
    lv_obj_set_user_data(mbox, (void *)(intptr_t)idx);
    lv_msgbox_add_title(mbox, "Install this kernel?");

    char body[600];
    snprintf(body, sizeof(body),
             "%s\n\n"
             "Copies the kernel and modules onto the real system, then runs "
             "depmod, update-initramfs and update-grub inside it.\n\n"
             "This writes to the running system and takes a few minutes. "
             "Nothing is removed - existing kernels stay bootable.",
             g_tarballs[idx].version);
    lv_msgbox_add_text(mbox, body);

    lv_obj_t *go = lv_msgbox_add_footer_button(mbox, "Install");
    lv_obj_t *no = lv_msgbox_add_footer_button(mbox, "Cancel");
    lv_obj_t *footer = lv_msgbox_get_footer(mbox);
    lv_obj_set_height(footer, LV_SIZE_CONTENT);
    lv_obj_set_height(lv_msgbox_get_header(mbox), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(footer, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_style_pad_column(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_style_pad_row(footer, DIALOG_BTN_GAP, 0);
    lv_obj_set_width(go, lv_pct(DIALOG_BTN_W_PCT));
    lv_obj_set_width(no, lv_pct(DIALOG_BTN_W_PCT));
    lv_obj_set_height(go, DIALOG_BTN_H);
    lv_obj_set_height(no, DIALOG_BTN_H);
    lv_obj_set_style_bg_color(go, lv_color_hex(0x3d7ee8), 0);
    lv_obj_set_style_bg_opa(go, LV_OPA_30, 0);

    lv_obj_add_event_cb(go, install_confirm_cb, LV_EVENT_CLICKED, mbox);
    lv_obj_add_event_cb(no, cancel_cb, LV_EVENT_CLICKED, mbox);
    screenshot_soon("install-dialog");
}

/* ---------------- screens ----------------
 *
 * Three screens share one scrollable container, rebuilt in place rather
 * than using separate lv_screen objects: the dialogs live on
 * lv_layer_top() and the countdown label has to survive navigation, so
 * swapping screens underneath them would mean re-parenting both. The
 * list is the only part that actually changes.
 *
 * The countdown only runs on the main menu. Navigating anywhere
 * requires a tap, and the first tap cancels the countdown for good, so
 * this needs no special handling - you cannot be auto-booted out from
 * under a submenu you are reading. */
static void show_main_menu(void);
static void show_kernel_list(void);
static void show_install_list(void);
static void show_remove_list(void);
static void show_backup_menu(void);
static void show_backup_targets(void);
static void rescan_cb(lv_event_t *e);
static void show_restore_list(void);
static void show_delete_backup_list(void);
static void show_rename_backup_list(void);
static void show_repair_menu(void);
static void show_live_boot_targets(void);
static void show_live_iso_list(void);
static void restart_cb(lv_event_t *e);
static void poweroff_cb(lv_event_t *e);

static lv_obj_t *make_row_h(const char *icon, const char *text, int dimmed, int h) {
    lv_obj_t *btn = lv_button_create(g_list);
    lv_obj_set_width(btn, lv_pct(100));
    lv_obj_set_height(btn, h);
    lv_obj_set_style_bg_color(btn, lv_color_hex(dimmed ? 0x161d26 : 0x1c2530), 0);
    lv_obj_set_style_bg_color(btn, lv_color_hex(0x2a3a4d), LV_STATE_PRESSED);
    lv_obj_set_style_radius(btn, ui_px(10), 0);

    lv_obj_t *label = lv_label_create(btn);
    lv_label_set_text_fmt(label, "%s  %s", icon, text);
    lv_obj_set_style_text_color(label, lv_color_hex(dimmed ? 0x93a0aa : 0xe8eef4), 0);
    lv_label_set_long_mode(label, LV_LABEL_LONG_DOT);
    lv_obj_set_width(label, lv_pct(100));
    lv_obj_align(label, LV_ALIGN_LEFT_MID, ui_px(16), 0);
    return btn;
}

static lv_obj_t *make_row(const char *icon, const char *text, int dimmed) {
    return make_row_h(icon, text, dimmed, ROW_H);
}

static void nav_cb(lv_event_t *e) {
    void (*fn)(void) = (void (*)(void))lv_event_get_user_data(e);
    fn();
}

static void add_back_row(void (*target)(void)) {
    lv_obj_t *b = make_row(LV_SYMBOL_LEFT, "Back", 1);
    lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)target);
    /* What Escape presses; see nav_is_escape(). */
    lv_obj_add_flag(b, LV_OBJ_FLAG_USER_1);
}

/* Back up / Restore is a Slate feature (init sets NIGHTFALL_BACKUP=0 on any
 * other board). Unset means ON: a hand-run Nightfall, the tests and an image
 * from before this existed all keep the row. Only the menu row is gated. */
static int backup_enabled(void) {
    const char *b = getenv("NIGHTFALL_BACKUP");
    return !(b && (!strcmp(b, "0") || !strcmp(b, "off")));
}

/* Set by init only when the real root it mounted is a SEPARATE /boot
 * partition, not the actual Linux install (find-real-root.sh's "bootfs"
 * layout). Install/Remove/Repair all run install-kernel.sh, remove-kernel.sh
 * or repair-system.sh against that mount as if it were the real root -
 * chroot "$root" /usr/sbin/update-grub, apt, dpkg, the lot - which on a
 * boot-only mount has no userland to chroot into at all. That is not a
 * missing feature to work around here; there is no real root known to
 * Nightfall to point those scripts at. Unset (the historical case, and
 * every machine where /boot lives on the real root) keeps all three rows. */
static int boot_only(void) {
    const char *b = getenv("NIGHTFALL_BOOT_ONLY");
    return b && !strcmp(b, "1");
}

static void show_main_menu(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_POWER "  Nightfall Boot Manager");

    char buf[96];
    /* "Boot", not "Boot a kernel": the same row now leads to installed
     * kernels AND external drives found by discover-bootable-drives.sh
     * (a Ventoy stick, another live-USB drive, a separate OS on a USB
     * disk) - it stopped being kernels-only the day a drive could be
     * offered from here too. */
    if (g_bootable_n > 0)
        snprintf(buf, sizeof(buf), "Boot   (%d kernel%s, %d drive%s)",
                 count_bootable_rows(), count_bootable_rows() == 1 ? "" : "s",
                 g_bootable_n, g_bootable_n == 1 ? "" : "s");
    else
        snprintf(buf, sizeof(buf), "Boot   (%d kernel%s installed)",
                 count_bootable_rows(), count_bootable_rows() == 1 ? "" : "s");
    lv_obj_t *b = make_row_h(LV_SYMBOL_USB, buf, 0, MENU_ROW_H);
    lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_kernel_list);

    if (!boot_only()) {
        if (g_tarball_n > 0)
            snprintf(buf, sizeof(buf), "Install a kernel   (%d available)", g_tarball_n);
        else
            snprintf(buf, sizeof(buf), "Install a kernel   (none found)");
        b = make_row_h(LV_SYMBOL_DOWNLOAD, buf, g_tarball_n == 0, MENU_ROW_H);
        lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_install_list);

        build_kernel_list();
        snprintf(buf, sizeof(buf), "Remove a kernel   (%d installed)", g_kernel_n);
        b = make_row_h(LV_SYMBOL_TRASH, buf, g_kernel_n <= 1, MENU_ROW_H);
        lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_remove_list);
    }

    if (backup_enabled()) {
        if (g_backup_n > 0)
            snprintf(buf, sizeof(buf), "Back up / Restore   (%d backup%s)",
                     g_backup_n, g_backup_n == 1 ? "" : "s");
        else
            snprintf(buf, sizeof(buf), "Back up / Restore   (%d drive%s)",
                     g_target_n, g_target_n == 1 ? "" : "s");
        b = make_row_h(LV_SYMBOL_SAVE, buf, g_target_n == 0 && g_backup_n == 0, MENU_ROW_H);
        lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_backup_menu);
    }

    if (!boot_only()) {
        b = make_row_h(LV_SYMBOL_SETTINGS, "Repair", 0, MENU_ROW_H);
        lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_repair_menu);
    }

    b = make_row_h(LV_SYMBOL_REFRESH, "Restart   (to the GRUB menu)", 0, MENU_ROW_H);
    lv_obj_add_event_cb(b, restart_cb, LV_EVENT_CLICKED, NULL);

    b = make_row_h(LV_SYMBOL_POWER, "Power off", 0, MENU_ROW_H);
    lv_obj_add_event_cb(b, poweroff_cb, LV_EVENT_CLICKED, NULL);
}

static void rescan_cb(lv_event_t *e) {
    lv_obj_t *btn = lv_event_get_target(e);
    lv_obj_t *lbl = lv_obj_get_child(btn, 0);
    /* Say what is happening and get it on screen BEFORE blocking - this
     * display is driven manually, so without the forced repaint the UI
     * would simply sit still for a second with the old label showing. */
    if (lbl) lv_label_set_text(lbl, LV_SYMBOL_REFRESH "  Scanning...");
    lv_refr_now(NULL);

    rescan_drives();
    void (*rescan_back_to)(void) = (void (*)(void))lv_event_get_user_data(e);
    (rescan_back_to ? rescan_back_to : show_backup_menu)();
}

/* ---------------- Boot an external drive ----------------
 *
 * Hands the WHOLE drive to firmware, instead of Nightfall trying to
 * understand what is on it - a Ventoy stick (which then shows Ventoy's
 * own menu), any other live-USB-creation-tool drive, or a separate OS
 * installed on an external disk. See boot-external-drive.sh's own header
 * for the mechanism (a one-shot UEFI BootNext entry).
 *
 * Unlike Boot a live USB, this is NOT a kexec and does not end this
 * process the way a kernel choice does: boot-external-drive.sh only arms
 * BootNext, and getting to the drive from there needs an actual reboot -
 * init performs it, the same reboot sequence Restart already uses, once
 * BootNext is confirmed armed. See initramfs/init. */
static int g_boot_external;
static char g_boot_external_part[128];
static char g_boot_external_loader[64];

/* The testable core, same split as confirm_live_boot(): the *_cb wrapper
 * only unwraps the LVGL event, this does the actual work. */
static void confirm_boot_external(int idx) {
    snprintf(g_boot_external_part, sizeof(g_boot_external_part), "%.127s", g_bootable[idx].dev);
    snprintf(g_boot_external_loader, sizeof(g_boot_external_loader), "%.63s", g_bootable[idx].loader);
    g_boot_external = 1;
}

static void boot_external_go_cb(lv_event_t *e) {
    lv_obj_t *mbox = lv_event_get_user_data(e);
    int idx = (int)(intptr_t)lv_obj_get_user_data(mbox);
    lv_msgbox_close_async(mbox);
    confirm_boot_external(idx);
}

static void boot_external_click_cb(lv_event_t *e) {
    int idx = (int)(intptr_t)lv_event_get_user_data(e);
    char body[400];
    snprintf(body, sizeof(body),
             "%.60s  (%.16s)\n\n"
             "This machine will restart and boot straight from this "
             "drive - the same as choosing it from a firmware boot menu. "
             "Nightfall does not look at what is on it: whatever the "
             "drive's own bootloader shows next (a Ventoy menu, a live "
             "system, an installed OS) is what you will see.\n\n"
             "Nothing on this machine is changed.",
             g_bootable[idx].label[0] ? g_bootable[idx].label : g_bootable[idx].dev,
             g_bootable[idx].size);
    simple_confirm(idx, "Restart into this drive?", body, "Restart", boot_external_go_cb, 0);
    screenshot_soon("boot-external-drive-dialog");
}

/* Each repair is a confirm then a child, so they share one pattern. The
 * index carried through simple_confirm() is unused here - these act on
 * the machine, not on a row - so it is passed as 0. */
static void fsck_safe_go_cb(lv_event_t *e) {
    lv_msgbox_close_async(lv_event_get_user_data(e)); start_fsck("preen");
}
static void fsck_force_go_cb(lv_event_t *e) {
    lv_msgbox_close_async(lv_event_get_user_data(e)); start_fsck("force");
}
static void dpkg_go_cb(lv_event_t *e) {
    lv_msgbox_close_async(lv_event_get_user_data(e));
    start_repair("dpkg", LV_SYMBOL_DOWNLOAD "  Repairing packages", "dpkg --configure -a");
}
static void clean_go_cb(lv_event_t *e) {
    lv_msgbox_close_async(lv_event_get_user_data(e));
    start_repair("clean", LV_SYMBOL_TRASH "  Freeing disk space", "package cache and journal");
}
static void grubup_go_cb(lv_event_t *e) {
    lv_msgbox_close_async(lv_event_get_user_data(e));
    start_repair("grub", LV_SYMBOL_REFRESH "  Updating the boot menu", "update-grub");
}
static void clear_go_cb(lv_event_t *e) {
    lv_msgbox_close_async(lv_event_get_user_data(e)); start_clear();
}

static void fsck_safe_cb(lv_event_t *e) { (void)e;
    simple_confirm(0, "Check the filesystem?",
        "Unmounts the root filesystem and checks it with nothing else "
        "touching it - which is why this works here and not in Ubuntu's "
        "recovery mode.\n\n"
        "Fixes only what needs no decision. Nothing is thrown away.",
        "Check", fsck_safe_go_cb, 0);
}
static void fsck_force_cb(lv_event_t *e) { (void)e;
    simple_confirm(0, "Full repair?",
        "Answers YES to every repair e2fsck offers, including ones that "
        "move damaged files into /lost+found.\n\n"
        "Right when the alternative is a machine that will not boot. "
        "Try Check first - it will say if this is needed.",
        "Full repair", fsck_force_go_cb, 1);
}
static void dpkg_cb(lv_event_t *e) { (void)e;
    simple_confirm(0, "Repair packages?",
        "Finishes configuring packages left half-installed by an "
        "interrupted update, and fixes what it can from what is already "
        "on disk.\n\nNeeds no network.",
        "Repair", dpkg_go_cb, 0);
}
static void clean_cb(lv_event_t *e) { (void)e;
    simple_confirm(0, "Free disk space?",
        "Empties the package cache and trims the systemd journal to "
        "50M.\n\nDoes NOT remove any packages or kernels - use Remove a "
        "kernel for that.",
        "Free space", clean_go_cb, 0);
}
static void grubup_cb(lv_event_t *e) { (void)e;
    simple_confirm(0, "Update the boot menu?",
        "Regenerates grub.cfg from the kernels actually on disk.\n\n"
        "The fix when the menu lists kernels that are gone, or misses "
        "ones that are there.",
        "Update", grubup_go_cb, 0);
}
static void clear_cb(lv_event_t *e) { (void)e;
    simple_confirm(0, "Clear Nightfall's saved settings?",
        "Forgets the saved default kernel and every saved command "
        "line.\n\nThe way out if a saved command line is what stops the "
        "machine booting - after this, every entry boots exactly what "
        "grub.cfg says.",
        "Clear", clear_go_cb, 1);
}

/* Restart and Power off. Nightfall had no way to leave without booting
 * a kernel, which on a keyboardless tablet meant holding the power
 * button. Restart is also the honest answer to "take me to the GRUB
 * menu": GRUB handed off long before Nightfall existed, so there is
 * nothing to return to - you reboot, and GRUB's menu comes up on the
 * way back, where a keyboard reaches Ubuntu's real recovery. */
static void power_go_cb(lv_event_t *e) {
    lv_obj_t *mbox = lv_event_get_user_data(e);
    g_power_action = (int)(intptr_t)lv_obj_get_user_data(mbox) ? "poweroff" : "reboot";
}

static void restart_cb(lv_event_t *e) { (void)e;
    simple_confirm(0, "Restart?",
        "Reboots the machine. GRUB's menu appears on the way back - with "
        "a keyboard attached that is where Ubuntu's own recovery entries "
        "are.\n\nNothing on disk is changed.",
        "Restart", power_go_cb, 0);
}
static void poweroff_cb(lv_event_t *e) { (void)e;
    lv_obj_t *m = simple_confirm(1, "Power off?",
        "Shuts the machine down.\n\nNothing on disk is changed.",
        "Power off", power_go_cb, 0);
    (void)m;
}

static void show_repair_menu(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_SETTINGS "  Repair");
    add_back_row(show_main_menu);

    lv_obj_t *b;
    b = make_row(LV_SYMBOL_REFRESH, "Check the filesystem", 0);
    lv_obj_add_event_cb(b, fsck_safe_cb, LV_EVENT_CLICKED, NULL);

    b = make_row(LV_SYMBOL_WARNING, "Full repair   (last resort)", 0);
    lv_obj_add_event_cb(b, fsck_force_cb, LV_EVENT_CLICKED, NULL);

    b = make_row(LV_SYMBOL_DOWNLOAD, "Repair packages", 0);
    lv_obj_add_event_cb(b, dpkg_cb, LV_EVENT_CLICKED, NULL);

    b = make_row(LV_SYMBOL_TRASH, "Free disk space", 0);
    lv_obj_add_event_cb(b, clean_cb, LV_EVENT_CLICKED, NULL);

    b = make_row(LV_SYMBOL_REFRESH, "Update the boot menu", 0);
    lv_obj_add_event_cb(b, grubup_cb, LV_EVENT_CLICKED, NULL);

    b = make_row(LV_SYMBOL_SETTINGS, "Clear Nightfall's saved settings", 0);
    lv_obj_add_event_cb(b, clear_cb, LV_EVENT_CLICKED, NULL);

    lv_obj_t *l = lv_label_create(g_list);
    lv_label_set_text(l, "These replace Ubuntu's recovery menu, which needs\n"
                         "a keyboard this machine does not have.\n\n"
                         "For the real recovery menu, restart and pick a\n"
                         "recovery entry in GRUB with a keyboard attached.");
    lv_obj_set_style_text_color(l, lv_color_hex(0x93a0aa), 0);
}

static void show_backup_menu(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_SAVE "  Back up / Restore");
    add_back_row(show_main_menu);

    /* First row, because with no keyboard the drive cannot be present
     * at boot - this is the normal way to get here, not a recovery
     * path. */
    lv_obj_t *rs = make_row(LV_SYMBOL_REFRESH, "Rescan for drives", 0);
    lv_obj_add_event_cb(rs, rescan_cb, LV_EVENT_CLICKED, NULL);

    char buf[96];
    snprintf(buf, sizeof(buf), "Back up now   (%d drive%s found)",
             g_target_n, g_target_n == 1 ? "" : "s");
    lv_obj_t *b = make_row(LV_SYMBOL_SAVE, buf, g_target_n == 0);
    lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_backup_targets);

    /* Same drive list as above, for a different reason to want one
     * plugged in: the drive cannot be present at boot either way, so
     * this belongs next to Back up now rather than as its own top-level
     * menu with a second "no drive found" screen to keep in sync. The
     * ISO list itself is not counted here - scanning every drive for
     * .iso files just to draw this row would cost exactly what
     * scan-drives.sh's own header explains backups avoid by being
     * listed lazily, and here there is no cached list to show at all
     * until a drive is actually picked. */
    snprintf(buf, sizeof(buf), "Boot a live USB   (%d drive%s found)",
             g_target_n, g_target_n == 1 ? "" : "s");
    b = make_row(LV_SYMBOL_USB, buf, g_target_n == 0);
    lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_live_boot_targets);

    snprintf(buf, sizeof(buf), "Restore a backup   (%d available)", g_backup_n);
    b = make_row(LV_SYMBOL_UPLOAD, buf, g_backup_n == 0);
    lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_restore_list);

    snprintf(buf, sizeof(buf), "Rename a backup   (%d available)", g_backup_n);
    b = make_row(LV_SYMBOL_EDIT, buf, g_backup_n == 0);
    lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_rename_backup_list);

    /* Last, and after Restore: two 86GB archives fill a 1TB stick, and
     * with no keyboard there is no other way to clear one. Reaching for
     * Delete when you meant Restore would be an expensive slip, so it
     * does not sit above the thing it could be mistaken for. Rename sits
     * between them: it is the harmless one, and it keeps Delete from
     * being adjacent to Restore. */
    /* Same phrasing as Restore above: the count is of backups, not of
     * drives, and pluralising "drive" on the backup count read as "2 on
     * the drives" for two backups on one stick. */
    snprintf(buf, sizeof(buf), "Delete a backup   (%d available)", g_backup_n);
    b = make_row(LV_SYMBOL_TRASH, buf, g_backup_n == 0);
    lv_obj_add_event_cb(b, nav_cb, LV_EVENT_CLICKED, (void *)show_delete_backup_list);

    if (g_target_n == 0) {
        lv_obj_t *l = lv_label_create(g_list);
        lv_label_set_text(l, "No external drive found.\n\n"
                             "Plug the drive in now, then tap Rescan.\n\n"
                             "It cannot be plugged in before booting: with no\n"
                             "keyboard attached the firmware would boot the\n"
                             "USB stick instead of Nightfall.");
        lv_obj_set_style_text_color(l, lv_color_hex(0x93a0aa), 0);
    }
}

static void show_backup_targets(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_SAVE "  Back up to which drive?");
    add_back_row(show_backup_menu);

    for (int i = 0; i < g_target_n; i++) {
        char row[220];
        snprintf(row, sizeof(row), "%.40s  %.10s  %.10s free",
                 g_targets[i].label[0] ? g_targets[i].label : g_targets[i].dev,
                 g_targets[i].fstype, g_targets[i].freespace);
        lv_obj_t *b = make_row(LV_SYMBOL_DRIVE, row, 0);
        lv_obj_add_event_cb(b, backup_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }
}

/* ---------------- Boot a live USB ----------------
 *
 * The one thing the drive is plugged in for that is not backup/restore:
 * kexec into a live image on it, via boot-live-iso.sh. Two taps deep
 * because it is genuinely two choices - which drive, then which ISO on
 * it - and unlike backups there is nothing to list until a drive is
 * picked (see the comment on the menu row above).
 *
 * This ends the running Nightfall process rather than returning to the
 * menu, the same shape as Restart/Power off/a normal kernel choice, not
 * the "child runs, progress shows, menu comes back" shape backup/repair
 * use - because it IS a boot, and deserves the same on-screen treatment,
 * except for one deliberate difference: no booting splash. See
 * boot-live-iso.sh's own header for why it stays verbose. */
static int g_live_boot;
static char g_live_target_dev[128];
static char g_live_iso_path[256];

/* The testable core, same split as start_restore()/start_rename_backup():
 * the *_cb wrapper only unwraps the LVGL event, this does the actual
 * work. Ends the running Nightfall process via the main loop's break
 * condition, the same way choosing a kernel or tapping Restart does -
 * there is no child to watch, so unlike backup/restore/repair there is
 * no start_* launcher either, just this. */
static void confirm_live_boot(int idx) {
    snprintf(g_live_iso_path, sizeof(g_live_iso_path), "%s", g_live_isos[idx].path);
    g_live_boot = 1;
}

static void live_iso_go_cb(lv_event_t *e) {
    lv_obj_t *mbox = lv_event_get_user_data(e);
    int idx = (int)(intptr_t)lv_obj_get_user_data(mbox);
    lv_msgbox_close_async(mbox);
    confirm_live_boot(idx);
}

/* Testable core, same split as kernel_row_tapped(): 1 if the confirm opened,
 * 0 if this kexec is refused under lockdown and a notice was shown instead. */
static int live_iso_tapped(int idx) {
    if (kexec_blocked_reason()) { show_kexec_blocked_notice(); return 0; }
    char body[400];
    snprintf(body, sizeof(body),
             "%.60s  (%.16s)\n\n"
             "Boots straight into this image - nothing on this machine "
             "changes, and Nightfall is not touched.\n\n"
             "This is a rescue boot, so it is not quiet: if the live "
             "system has trouble finding itself after the handoff, you "
             "will see it happen rather than stare at a blank screen.",
             g_live_isos[idx].name, g_live_isos[idx].size);
    simple_confirm(idx, "Boot this image?", body, "Boot", live_iso_go_cb, 0);
    screenshot_soon("boot-live-iso-dialog");
    return 1;
}

static void live_iso_click_cb(lv_event_t *e) {
    live_iso_tapped((int)(intptr_t)lv_event_get_user_data(e));
}

static void show_live_iso_list(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_USB "  Boot a live USB");
    add_back_row(show_live_boot_targets);

    if (g_live_iso_n == 0) {
        lv_obj_t *l = lv_label_create(g_list);
        lv_label_set_text(l, "No ISO files found on this drive.\n\n"
                             "Looked at the top level and one folder\n"
                             "down. A Ventoy stick works as-is; other\n"
                             "drives just need the .iso file copied on.");
        lv_obj_set_style_text_color(l, lv_color_hex(0x93a0aa), 0);
        return;
    }
    for (int i = 0; i < g_live_iso_n; i++) {
        char row[240];
        snprintf(row, sizeof(row), "%.60s   %.10s", g_live_isos[i].name, g_live_isos[i].size);
        lv_obj_t *b = make_row(LV_SYMBOL_USB, row, 0);
        lv_obj_add_event_cb(b, live_iso_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }
}

static void live_target_click_cb(lv_event_t *e) {
    int idx = (int)(intptr_t)lv_event_get_user_data(e);
    snprintf(g_live_target_dev, sizeof(g_live_target_dev), "%s", g_targets[idx].dev);

    /* Same treatment as Rescan: say what is happening and force a
     * repaint before the blocking scan, since this display is driven
     * manually and would otherwise just sit still with no explanation. */
    lv_obj_t *btn = lv_event_get_target(e);
    lv_obj_t *lbl = lv_obj_get_child(btn, 0);
    if (lbl) lv_label_set_text(lbl, LV_SYMBOL_USB "  Looking for ISO files...");
    lv_refr_now(NULL);

    scan_live_isos(g_live_target_dev);
    show_live_iso_list();
}

static void show_live_boot_targets(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_USB "  Boot from which drive?");
    add_back_row(show_backup_menu);

    for (int i = 0; i < g_target_n; i++) {
        char row[220];
        snprintf(row, sizeof(row), "%.40s  %.10s  %.10s free",
                 g_targets[i].label[0] ? g_targets[i].label : g_targets[i].dev,
                 g_targets[i].fstype, g_targets[i].freespace);
        lv_obj_t *b = make_row(LV_SYMBOL_DRIVE, row, 0);
        lv_obj_add_event_cb(b, live_target_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }
}

static void show_restore_list(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_UPLOAD "  Restore a backup");
    add_back_row(show_backup_menu);

    if (g_backup_n == 0) {
        lv_obj_t *l = lv_label_create(g_list);
        lv_label_set_text(l, "No backups found on the attached drives.\n\n"
                             "Only completed backups are listed - one that\n"
                             "stopped part way is not offered.");
        lv_obj_set_style_text_color(l, lv_color_hex(0x93a0aa), 0);
        return;
    }
    for (int i = 0; i < g_backup_n; i++) {
        char row[240];
        snprintf(row, sizeof(row), "%.40s   %.30s   %.10s",
                 g_backups[i].name, g_backups[i].when, g_backups[i].size);
        lv_obj_t *b = make_row(LV_SYMBOL_UPLOAD, row, 0);
        lv_obj_add_event_cb(b, restore_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }
}

static void show_rename_backup_list(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_EDIT "  Rename a backup");
    add_back_row(show_backup_menu);

    if (g_backup_n == 0) {
        lv_obj_t *l = lv_label_create(g_list);
        lv_label_set_text(l, "No backups found on the attached drives.\n\n"
                             "Tap Rescan on the previous screen if the\n"
                             "drive was plugged in after Nightfall started.");
        lv_obj_set_style_text_color(l, lv_color_hex(0x93a0aa), 0);
        return;
    }
    for (int i = 0; i < g_backup_n; i++) {
        char row[240];
        snprintf(row, sizeof(row), "%.40s   %.30s   %.10s",
                 g_backups[i].name, g_backups[i].when, g_backups[i].size);
        lv_obj_t *b = make_row(LV_SYMBOL_EDIT, row, 0);
        lv_obj_add_event_cb(b, rename_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }
}

static void show_delete_backup_list(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_TRASH "  Delete a backup");
    add_back_row(show_backup_menu);

    if (g_backup_n == 0) {
        lv_obj_t *l = lv_label_create(g_list);
        /* The second paragraph is the honest answer to "the drive is
         * full but this list is empty". A run that died part way leaves
         * an archive with no sidecar, which is hidden everywhere on
         * purpose - so say where it goes instead of leaving someone
         * hunting for a delete button that will never appear. */
        lv_label_set_text(l, "No backups found on the attached drives.\n\n"
                             "A backup that stopped part way is not listed\n"
                             "here. Those are cleared automatically the next\n"
                             "time you take a backup.");
        lv_obj_set_style_text_color(l, lv_color_hex(0x93a0aa), 0);
        return;
    }
    for (int i = 0; i < g_backup_n; i++) {
        char row[240];
        snprintf(row, sizeof(row), "%.40s   %.30s   %.10s",
                 g_backups[i].name, g_backups[i].when, g_backups[i].size);
        lv_obj_t *b = make_row(LV_SYMBOL_TRASH, row, 0);
        lv_obj_add_event_cb(b, delete_backup_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }
}

static void show_remove_list(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_TRASH "  Remove a kernel");
    add_back_row(show_main_menu);

    build_kernel_list();

    /* The last kernel is never offered. remove-kernel.sh refuses it too
     * - that is the guard that actually matters - but a button you are
     * not allowed to press is worse than no button. */
    if (g_kernel_n <= 1) {
        lv_obj_t *l = lv_label_create(g_list);
        lv_label_set_text(l, "Only one kernel is installed.\n\n"
                             "Removing it would leave nothing to boot,\n"
                             "so it is not offered here.");
        lv_obj_set_style_text_color(l, lv_color_hex(0x93a0aa), 0);
        return;
    }

    for (int i = 0; i < g_kernel_n; i++) {
        char row[220];
        /* Bounded explicitly: gcc cannot prove the index is in range,
         * so it assumes the whole array might be one unterminated
         * string. Harmless - snprintf truncates - but a precision here
         * states the intent and keeps the build warning-free. */
        snprintf(row, sizeof(row), "%.120s   (%d menu entr%s)",
                 g_kernels[i].release, g_kernels[i].refs,
                 g_kernels[i].refs == 1 ? "y" : "ies");
        lv_obj_t *b = make_row(LV_SYMBOL_TRASH, row, 0);
        lv_obj_add_event_cb(b, remove_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }
}

/* Renamed from "Select a kernel to boot": this screen now lists every
 * way to boot something, not only installed kernels - an installed
 * kernel and an external drive found by discover-bootable-drives.sh
 * (Ventoy stick, other live-USB drive, separate OS on a USB disk) sit in
 * the same list, because from here they are genuinely the same kind of
 * choice: pick one, this machine boots into it. */
static void show_kernel_list(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_USB "  Boot");
    add_back_row(show_main_menu);

    if (kexec_blocked_reason()) {
        lv_obj_t *w = lv_label_create(g_list);
        lv_label_set_long_mode(w, LV_LABEL_LONG_WRAP);
        lv_obj_set_width(w, lv_pct(100));
        lv_label_set_text_fmt(w, LV_SYMBOL_WARNING "  Kernels cannot be booted from here: %s", kexec_blocked_reason());
        lv_obj_set_style_text_color(w, lv_color_hex(0xe6c07b), 0);
    }

    /* Drives cannot be present at boot - see scan-drives.sh's own header -
     * so unlike the kernel list above, this can go stale the moment
     * something is plugged in after Nightfall started. Same affordance
     * Back up/Restore already has, just also offered here now that this
     * screen is where a drive's boot option actually shows up. */
    lv_obj_t *rs = make_row(LV_SYMBOL_REFRESH, "Rescan for drives", 0);
    lv_obj_add_event_cb(rs, rescan_cb, LV_EVENT_CLICKED, (void *)show_kernel_list);

    for (int i = 0; i < g_entry_n; i++) {
        /* Recovery variants live in their kernel's confirm dialog. */
        if (is_recovery(&g_entries[i])) continue;

        lv_obj_t *btn = lv_button_create(g_list);
        lv_obj_set_width(btn, lv_pct(100));
        lv_obj_set_height(btn, ROW_H);
        lv_obj_set_style_bg_color(btn, lv_color_hex(0x1c2530), 0);
        lv_obj_set_style_bg_color(btn, lv_color_hex(0x2a3a4d), LV_STATE_PRESSED);
        lv_obj_set_style_radius(btn, ui_px(10), 0);

        /* The default-entry checkmark sits at a fixed spot on the
         * right so it's never pushed out of view by a long title -
         * the title label gets ellipsis-truncated and a reserved
         * right margin instead of being centered over the whole row. */
        lv_obj_t *label = lv_label_create(btn);
        lv_label_set_text_fmt(label, LV_SYMBOL_USB "  %s", g_entries[i].title);
        lv_obj_set_style_text_color(label, lv_color_hex(0xe8eef4), 0);
        lv_label_set_long_mode(label, LV_LABEL_LONG_DOT);
        lv_obj_set_width(label, lv_pct(g_entries[i].is_default ? 82 : 100));
        lv_obj_align(label, LV_ALIGN_LEFT_MID, ui_px(16), 0);

        if (g_entries[i].is_default) {
            lv_obj_t *mark = lv_label_create(btn);
            lv_label_set_text(mark, LV_SYMBOL_OK);
            lv_obj_set_style_text_color(mark, lv_color_hex(0x8ec6ff), 0);
            lv_obj_align(mark, LV_ALIGN_RIGHT_MID, -ui_px(16), 0);
        }
        lv_obj_add_event_cb(btn, row_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }

    for (int i = 0; i < g_bootable_n; i++) {
        char row[220];
        snprintf(row, sizeof(row), "%.40s   %.10s   hands off to firmware",
                 g_bootable[i].label[0] ? g_bootable[i].label : g_bootable[i].dev,
                 g_bootable[i].size);
        lv_obj_t *b = make_row(LV_SYMBOL_DRIVE, row, 0);
        lv_obj_add_event_cb(b, boot_external_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }
}

static void show_install_list(void) {
    lv_obj_clean(g_list);
    lv_label_set_text(g_header, LV_SYMBOL_DOWNLOAD "  Install a kernel");
    add_back_row(show_main_menu);

    if (g_tarball_n == 0) {
        lv_obj_t *l = lv_label_create(g_list);
        lv_label_set_text(l, "No kernel tarballs found.\n\n"
                             "Put a *-installer.tar.gz under /home or /root\n"
                             "on the real system and reopen this menu.");
        lv_obj_set_style_text_color(l, lv_color_hex(0x93a0aa), 0);
        return;
    }
    for (int i = 0; i < g_tarball_n; i++) {
        char row[220];
        snprintf(row, sizeof(row), "%.120s   (%.20s)", g_tarballs[i].version, g_tarballs[i].size);
        lv_obj_t *b = make_row(LV_SYMBOL_DOWNLOAD, row, 0);
        lv_obj_add_event_cb(b, install_click_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
    }
}

static void build_ui(struct entry *entries, int n, int timeout_secs, lv_obj_t **countdown_label_out) {
    g_entries = entries;
    g_entry_n = n;

    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x101418), 0);
    lv_obj_set_flex_flow(scr, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_all(scr, ui_px(16), 0);
    lv_obj_set_style_pad_row(scr, ui_px(10), 0);

    g_header = lv_label_create(scr);
    lv_obj_set_style_text_color(g_header, lv_color_hex(0x8ec6ff), 0);

    if (timeout_secs > 0) {
        lv_obj_t *cd = lv_label_create(scr);
        lv_obj_set_style_text_color(cd, lv_color_hex(0x808a94), 0);
        g_countdown = cd;
        *countdown_label_out = cd;
    } else {
        *countdown_label_out = NULL;
    }

    g_list = lv_obj_create(scr);
    lv_obj_set_width(g_list, lv_pct(100));
    lv_obj_set_flex_grow(g_list, 1);
    lv_obj_set_flex_flow(g_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(g_list, ui_px(8), 0);
    lv_obj_set_style_bg_opa(g_list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(g_list, 0, 0);

    show_main_menu();
}

static void lvgl_log_to_stderr(lv_log_level_t level, const char *buf) {
    (void)level;
    fprintf(stderr, "nightfall: lvgl: %s", buf);
}

static void shell_quote(FILE *out, const char *name, const char *value) {
    fprintf(out, "%s='", name);
    for (const char *p = value; *p; p++) {
        if (*p == '\'')
            fputs("'\\''", out);
        else
            fputc(*p, out);
    }
    fputs("'\n", out);
}

/* Retries a device open until it succeeds or NIGHTFALL_WAIT_SECS (default
 * 20, 0 disables) elapses. Exactly one of drm/touch is non-NULL - the
 * point is that the retry re-runs the REAL open, so "usable device"
 * keeps exactly one definition no matter how the criteria evolve.
 *
 * Reports how long it waited, because "touch appeared after 1.4s" and
 * "gave up after 20s" call for completely different next steps, and the
 * boot log is often the only account of a failure anyone gets. */
#define WAIT_POLL_MS 100
/* Seconds since boot, from /proc/uptime. Written to stderr, which init
 * captures into the boot log, so one boot shows where the time between
 * GRUB and the menu - and between the menu and the kernel - really goes. */
static void mark(const char *what) {
    double up = 0;
    FILE *f = fopen("/proc/uptime", "r");
    if (f) { if (fscanf(f, "%lf", &up) != 1) up = 0; fclose(f); }
    fprintf(stderr, "nightfall: [%.2f] %s\n", up, what);
}

/* ---------------- splash: something alive instead of scrolling text ----------------
 *
 * Two gaps used to show nothing but console text. Between GRUB and the
 * menu, Nightfall could not draw anything until touch had appeared,
 * because LVGL was only started after that wait - and touch has been
 * seconds late on real boots. Between a tap and the kernel taking over,
 * Nightfall exited and the kernel restored the text console while init
 * saved the boot log and kexec loaded the kernel.
 *
 * The splash is a full-screen object on lv_layer_top(), so it covers
 * whatever is underneath and is deleted outright rather than having to
 * be un-built. The text lives in SPLASH_TITLE so a future setting can
 * replace it without touching the layout. */
#define SPLASH_TITLE "Nightfall Boot Manager"
/* How long the booting screen may be held with no handoff. kexec normally
 * replaces everything within a second or two; the cap exists so a handoff
 * that never happens cannot leave a frozen spinner covering the reason. */
#define BOOT_SCREEN_MAX_MS 60000
/* The shortest time either screen stays up. The work behind them is
 * usually quick, so without a floor the splash flashed past too fast to
 * see - Bob: "the duration is going to need to be extended a little to be
 * enjoyed". NIGHTFALL_SPLASH_MIN_MS overrides it; 0 turns the floor off. */
#define SPLASH_MIN_MS 1500

/* Drives LVGL outside the main loop - during the touch wait, and in the
 * child that holds the booting screen. Keeps its own clock: the main loop
 * starts timing only just before it runs, so time counted here is never
 * counted twice. */
static struct timespec g_pump_last;
static void lvgl_pump(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (g_pump_last.tv_sec || g_pump_last.tv_nsec) {
        lv_tick_inc((uint32_t)((now.tv_sec - g_pump_last.tv_sec) * 1000 +
                               (now.tv_nsec - g_pump_last.tv_nsec) / 1000000));
    }
    g_pump_last = now;
    /* Auto-rotate here too, so the boot screens follow the tablet the way
     * the menu does. The main loop polls the accelerometer itself, but the
     * splash and the booting screen run outside it - during the touch
     * wait, during their minimum time, and in the child holding the
     * display through the handoff. Without this they stayed in whatever
     * orientation the tablet happened to be in when Nightfall started.
     * accel_poll() rate-limits itself and does nothing at all when there
     * is no accelerometer, so this costs almost nothing. */
    accel_poll();
    lv_timer_handler();
}

/* Both screens - the spinner before the menu and the booting screen - on
 * unless NIGHTFALL_SPLASH is exactly 0 or off. Anything else, including
 * garbage, keeps them on: init has already validated the value from
 * /boot/nightfall-splash, and an unreadable setting should not silently
 * change how the machine looks. */
static int splash_enabled(void) {
    const char *e = getenv("NIGHTFALL_SPLASH");
    return !(e && (!strcmp(e, "0") || !strcmp(e, "off")));
}

static int splash_min_ms(void) {
    const char *e = getenv("NIGHTFALL_SPLASH_MIN_MS");
    if (!e || !*e) return SPLASH_MIN_MS;
    /* Digits only, like every other setting here. strtol quietly skips
     * leading whitespace, so " 5" would otherwise become 5. */
    if (*e < '0' || *e > '9') return SPLASH_MIN_MS;
    char *end;
    long v = strtol(e, &end, 10);
    if (*end || v < 0 || v > 10000) return SPLASH_MIN_MS;   /* garbage: default */
    return (int)v;
}

static long ms_since(const struct timespec *t0) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - t0->tv_sec) * 1000L + (now.tv_nsec - t0->tv_nsec) / 1000000L;
}

/* Keeps the screen animating until at least `min_ms` have passed since
 * `shown`. Nothing else happens meanwhile - this is the point. */
static void pump_until(const struct timespec *shown, int min_ms) {
    while (ms_since(shown) < min_ms) {
        lvgl_pump();
        usleep(30 * 1000);
    }
}

static lv_obj_t *splash_create(const char *line) {
    lv_obj_t *s = lv_obj_create(lv_layer_top());
    lv_obj_remove_style_all(s);
    lv_obj_set_size(s, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_color(s, lv_color_hex(0x101418), 0);
    lv_obj_set_style_bg_opa(s, LV_OPA_COVER, 0);
    lv_obj_set_flex_flow(s, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(s, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(s, ui_px(48), 0);

    lv_obj_t *sp = lv_spinner_create(s);
    lv_obj_set_size(sp, ui_px(260), ui_px(260));
    lv_obj_set_style_arc_width(sp, 18, LV_PART_MAIN);
    lv_obj_set_style_arc_width(sp, 18, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(sp, lv_color_hex(0x3d7ee8), LV_PART_INDICATOR);

    lv_obj_t *t = lv_label_create(s);
    lv_label_set_text(t, SPLASH_TITLE);
    lv_obj_set_style_text_color(t, lv_color_hex(0x8ec6ff), 0);

    if (line && *line) {
        lv_obj_t *l = lv_label_create(s);
        lv_label_set_text(l, line);
        lv_label_set_long_mode(l, LV_LABEL_LONG_DOT);
        lv_obj_set_width(l, lv_pct(90));
        lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_set_style_text_color(l, lv_color_hex(0x93a0aa), 0);
    }
    /* Manually driven display: nothing else decides a repaint is due. */
    lv_obj_invalidate(lv_layer_top());
    lv_refr_now(NULL);
    return s;
}

/* Called only after the selection has been written to stdout. The parent
 * returns at once so init carries on to kexec. The child keeps the DRM
 * file open - DRM master belongs to the open file, not the process, so
 * the parent exiting does not give the display back - and animates the
 * booting screen until kexec replaces the whole system. Any init path
 * that needs the console back kills it first via the pid file.
 *
 * If fork fails, the parent simply exits as before and the console
 * returns: exactly the old behaviour, never worse. */
static void hold_boot_screen(void) {
    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid != 0) return;
    close(STDOUT_FILENO);
    const char *pf = getenv("NIGHTFALL_BOOT_PIDFILE");
    if (!pf) pf = "/run/nightfall/booting.pid";
    FILE *f = fopen(pf, "w");
    if (f) { fprintf(f, "%d\n", (int)getpid()); fclose(f); }
    for (int ms = 0; ms < BOOT_SCREEN_MAX_MS; ms += 30) {
        lvgl_pump();
        usleep(30 * 1000);
    }
    _exit(0);
}

/* ---------------- keyboard and mouse ----------------
 *
 * The Slate is touch-only, so this UI was too - and a desktop or laptop with
 * no touchscreen got no menu at all (Nightfall exited "no touch input
 * device" and init silently booted the default kernel). Keyboards and mice
 * are read as ADDITIONAL input devices alongside touch; the touch path is
 * untouched.
 *
 * Navigation is its own small focus manager rather than LVGL's groups. The
 * reason is modality: dialogs live on lv_layer_top(), and with a group the
 * buttons of the screen BEHIND an open dialog stay reachable with the arrow
 * keys. Here the scope is recomputed on every key: the topmost dialog if
 * there is one, otherwise the active screen. */

enum nav_action { NAV_NONE, NAV_NEXT, NAV_PREV, NAV_UP, NAV_DOWN, NAV_FIRST, NAV_LAST,
                  NAV_PAGE_UP, NAV_PAGE_DOWN, NAV_ACTIVATE, NAV_ESCAPE };

/* The key -> action table, on its own so it can be tested without a
 * keyboard. Left/Right and Up/Down used to share one action (NAV_NEXT/PREV,
 * a flat step through creation order) on the theory that dialogs lay their
 * buttons out in a grid, lists in a column, and one linear order serves
 * both. Real hardware disproved that: found on a genuine 2x2 footer grid
 * (Edit/Set Default over Cancel/Boot) - Right correctly moved Edit->Set
 * Default (next in creation order, which also happens to be next in the
 * row), but Down did the exact same thing instead of reaching Cancel below
 * Edit, because it WAS the exact same action. Up/Down now move by a whole
 * visual row (see nav_row_width) - on any plain vertical list that is still
 * one candidate, so nothing changes there; a real grid is the one case that
 * needed the difference. */
static enum nav_action nav_action_for_key(int code, int shift) {
    switch (code) {
    case KEY_DOWN:                          return NAV_DOWN;
    case KEY_UP:                            return NAV_UP;
    case KEY_RIGHT:                         return NAV_NEXT;
    case KEY_LEFT:                          return NAV_PREV;
    case KEY_TAB:                           return shift ? NAV_PREV : NAV_NEXT;
    case KEY_HOME:                          return NAV_FIRST;
    case KEY_END:                           return NAV_LAST;
    case KEY_PAGEUP:                        return NAV_PAGE_UP;
    case KEY_PAGEDOWN:                      return NAV_PAGE_DOWN;
    case KEY_ENTER: case KEY_KPENTER: case KEY_SPACE: return NAV_ACTIVATE;
    case KEY_ESC:  case KEY_BACKSPACE:      return NAV_ESCAPE;
    default:                                return NAV_NONE;
    }
}

#define NAV_MAX 96
static lv_obj_t *g_nav_focus;

/* The saved border values belong to the object that was focused, so they
 * are dropped with it - restoring them onto whatever is focused NEXT would
 * paint one object's decoration onto an unrelated one. */
static void nav_focus_deleted_cb(lv_event_t *e);

/* Focus is drawn as a border rather than an outline: rows are 100% wide, so
 * an outline outside the box is clipped by the list at both edges.
 *
 * Applied as LOCAL style properties, not via lv_obj_add_style(), and this
 * is the whole point rather than a detail: in LVGL a local property always
 * beats an added style at the same selector, and several dialog buttons set
 * local border properties of their own for decoration - open_confirm_dialog
 * gives Cancel and Boot a 1px top divider that way. With the ring as an
 * added style those two buttons silently kept their 1px TOP border and
 * showed no focus at all, which is exactly what Bob hit on hardware:
 * navigation worked (Down, Down, Enter booted the right thing) but the two
 * buttons he most needed to see - Cancel and Boot - were the two that could
 * never highlight. Measured, not guessed: computed border width came back 8
 * on Edit/Set Default and 1 on Cancel/Boot.
 *
 * The previous appearance is saved and put back when focus leaves, so a
 * button's own decoration survives being focused and unfocused. The saved
 * values are the COMPUTED ones, so restoring them writes locals where there
 * may have been none - visually identical, and these are short-lived menu
 * rows and dialog buttons that nothing else restyles afterwards. */
#define NAV_RING_COLOR 0x8ec6ff
static struct {
    int32_t width;
    lv_border_side_t side;
    lv_color_t color;
    lv_opa_t opa;
    int valid;
} g_nav_saved;

static void nav_focus_deleted_cb(lv_event_t *e) {
    if (lv_event_get_target(e) == g_nav_focus) {
        g_nav_focus = NULL;
        g_nav_saved.valid = 0;
    }
}

static void nav_ring_restore(lv_obj_t *obj) {
    if (!obj || !g_nav_saved.valid) return;
    lv_obj_set_style_border_width(obj, g_nav_saved.width, 0);
    lv_obj_set_style_border_side(obj, g_nav_saved.side, 0);
    lv_obj_set_style_border_color(obj, g_nav_saved.color, 0);
    lv_obj_set_style_border_opa(obj, g_nav_saved.opa, 0);
    g_nav_saved.valid = 0;
}

static void nav_ring_apply(lv_obj_t *obj) {
    g_nav_saved.width = lv_obj_get_style_border_width(obj, LV_PART_MAIN);
    g_nav_saved.side  = lv_obj_get_style_border_side(obj, LV_PART_MAIN);
    g_nav_saved.color = lv_obj_get_style_border_color(obj, LV_PART_MAIN);
    g_nav_saved.opa   = lv_obj_get_style_border_opa(obj, LV_PART_MAIN);
    g_nav_saved.valid = 1;
    lv_obj_set_style_border_width(obj, ui_px(8), 0);
    lv_obj_set_style_border_side(obj, LV_BORDER_SIDE_FULL, 0);
    lv_obj_set_style_border_color(obj, lv_color_hex(NAV_RING_COLOR), 0);
    lv_obj_set_style_border_opa(obj, LV_OPA_COVER, 0);
}

static void nav_set_focus(lv_obj_t *obj) {
    if (g_nav_focus == obj) return;
    if (g_nav_focus) {
        nav_ring_restore(g_nav_focus);
        lv_obj_remove_event_cb(g_nav_focus, nav_focus_deleted_cb);
        lv_obj_invalidate(g_nav_focus);
    }
    g_nav_focus = obj;
    if (obj) {
        nav_ring_apply(obj);
        /* A screen change deletes the focused row; without this the pointer
         * would dangle, and a NEW object allocated at the same address
         * would look focused without the border. */
        lv_obj_add_event_cb(obj, nav_focus_deleted_cb, LV_EVENT_DELETE, NULL);
        lv_obj_scroll_to_view(obj, LV_ANIM_OFF);
        lv_obj_invalidate(obj);
    }
}

static void nav_collect(lv_obj_t *root, lv_obj_t **out, int *n) {
    uint32_t cnt = lv_obj_get_child_count(root);
    for (uint32_t i = 0; i < cnt; i++) {
        lv_obj_t *c = lv_obj_get_child(root, i);
        if (lv_obj_has_flag(c, LV_OBJ_FLAG_HIDDEN)) continue;
        /* Two kinds of button: ordinary lv_buttons (menu rows) and a msgbox's
         * footer buttons, which are a SEPARATE class rooted at lv_obj, not
         * a kind of lv_button - so with only the first check a dialog had no
         * candidates at all and the keyboard did nothing inside one. */
        if (lv_obj_has_class(c, &lv_button_class) ||
            lv_obj_has_class(c, &lv_msgbox_footer_button_class)) {
            if (lv_obj_has_flag(c, LV_OBJ_FLAG_CLICKABLE) &&
                !lv_obj_has_state(c, LV_STATE_DISABLED) && *n < NAV_MAX)
                out[(*n)++] = c;
            continue;                 /* never descend into a button */
        }
        nav_collect(c, out, n);
    }
}

/* Modal scoping: the topmost dialog, else the active screen.
 *
 * The on-screen keyboard is SKIPPED, even though it is deliberately the
 * last child of lv_layer_top() in every text dialog (created after the
 * msgbox so it draws above the backdrop and receives taps - see edit_cb).
 * It is an input surface sitting on top, not the modal scope: it is an
 * lv_buttonmatrix, so it has no button children to collect, and taking it
 * as the scope yields ZERO candidates and kills navigation entirely.
 * Found by a test written for typing, confirmed as exactly what Bob hit on
 * hardware - the Edit dialog opened, the on-screen keyboard appeared, and
 * the real keyboard could neither type NOR reach Use once / Save /
 * Cancel. */
static lv_obj_t *nav_scope(void) {
    lv_obj_t *top = lv_layer_top();
    for (uint32_t i = lv_obj_get_child_count(top); i > 0; i--) {
        lv_obj_t *c = lv_obj_get_child(top, i - 1);
        if (!lv_obj_check_type(c, &lv_keyboard_class)) return c;
    }
    return lv_screen_active();
}

static int nav_candidates(lv_obj_t **out) {
    int n = 0;
    nav_collect(nav_scope(), out, &n);
    return n;
}

static int nav_index_of(lv_obj_t **c, int n, lv_obj_t *o) {
    for (int i = 0; i < n; i++) if (c[i] == o) return i;
    return -1;
}

static const char *nav_button_text(lv_obj_t *btn) {
    lv_obj_t *l = lv_obj_get_child(btn, 0);
    return (l && lv_obj_check_type(l, &lv_label_class)) ? lv_label_get_text(l) : "";
}

/* Escape leaves: a screen's Back row (tagged by add_back_row - its label is
 * NOT reliable, list rows use LVGL's dot-truncation and read "..." until
 * laid out), or a dialog's Cancel / OK. Dialog buttons are matched by label:
 * every dialog builds its own, they are never truncated, and tagging nine call
 * sites would be more code to keep in step than the two words it saves. */
#define NAV_ESCAPE_FLAG LV_OBJ_FLAG_USER_1
static int nav_is_escape(lv_obj_t *btn) {
    if (lv_obj_has_flag(btn, NAV_ESCAPE_FLAG)) return 1;
    const char *t = nav_button_text(btn);
    return !strcmp(t, "Cancel") || !strcmp(t, "OK");
}

/* Where Up/Down actually go: find the closest row strictly above (dir<0)
 * or below (dir>0) c[idx] by ACTUAL laid-out Y - never assumed from which
 * screen this is, so nothing has to be kept in sync with whatever the
 * layout code decides - then, within that row, the candidate whose X is
 * closest to c[idx]'s own X: the column a person would actually aim for.
 *
 * A plain vertical list has one candidate per row, so "the row" always has
 * exactly one member and this reduces to "the next/previous row" - Up/Down
 * end up identical to Left/Right's single-step move there, unchanged from
 * before this existed. The one case this was built for is a real grid, and
 * real hardware found it does not even have to be a SYMMETRIC one: this
 * dialog's actual footer (no Recovery, the common case) is Edit+Set
 * Default sharing a row over Cancel ALONE on its own full-width row over
 * Boot alone on another - nearest-by-X still gets this right (Cancel and
 * Boot each have only one candidate to offer, and Up from either finds
 * Edit over Set Default by X position, not a row-width arithmetic that
 * only works when every row happens to be the same width). A fixed
 * idx +/- row_width was tried first and got exactly this case wrong -
 * "Up from Cancel" landed on Set Default instead of Edit, because Cancel's
 * own row is 1 wide and Edit/Set Default's is 2, and nothing says those
 * line up. */
static int nav_vertical_target(lv_obj_t **c, int n, int idx, int dir) {
    if (idx < 0 || idx >= n) return idx < 0 ? 0 : idx;
    int32_t y0 = lv_obj_get_y(c[idx]), x0 = lv_obj_get_x(c[idx]);
    int32_t row_y = 0; int have_row = 0;
    for (int i = 0; i < n; i++) {
        int32_t yi = lv_obj_get_y(c[i]);
        if (dir < 0 ? (yi < y0) : (yi > y0)) {
            if (!have_row || (dir < 0 ? (yi > row_y) : (yi < row_y))) { row_y = yi; have_row = 1; }
        }
    }
    if (!have_row) return idx;
    int best = -1; int32_t best_dx = 0;
    for (int i = 0; i < n; i++) {
        if (lv_obj_get_y(c[i]) != row_y) continue;
        int32_t dxv = lv_obj_get_x(c[i]) - x0; if (dxv < 0) dxv = -dxv;
        if (best < 0 || dxv < best_dx) { best = i; best_dx = dxv; }
    }
    return best >= 0 ? best : idx;
}

/* Returns 1 if it did something. */
static int nav_do(enum nav_action a) {
    if (a == NAV_NONE) return 0;
    lv_obj_t *c[NAV_MAX];
    int n = nav_candidates(c);
    if (input_dbg()) fprintf(stderr, "nightfall: nav_do action=%d candidates=%d focus=%p\n",
                              (int)a, n, (void *)g_nav_focus);
    if (n == 0) return 0;

    int idx = nav_index_of(c, n, g_nav_focus);
    /* Focus left over from somewhere else (behind a dialog that just
     * opened, say) is dropped so its border does not linger. */
    if (idx < 0 && g_nav_focus) nav_set_focus(NULL);

    switch (a) {
    case NAV_NEXT:
        nav_set_focus(c[idx < 0 ? 0 : (idx + 1) % n]); return 1;
    case NAV_PREV:
        nav_set_focus(c[idx < 0 ? n - 1 : (idx + n - 1) % n]); return 1;
    case NAV_UP:
        /* Clamped, not wrapped - unlike Left/Right/Tab. Wrapping a grid
         * row-to-row would jump between columns that were never lined up
         * to begin with, and wrapping a long list top-to-bottom on Up/Down
         * reads as a bug where the same wrap on Left/Right (a single step)
         * does not. Nothing focused yet starts at the top, same as every
         * other action here - nav_vertical_target's own idx<0 passthrough
         * is never reached because idx is normalised to 0 first. */
        nav_set_focus(c[idx < 0 ? 0 : nav_vertical_target(c, n, idx, -1)]);
        return 1;
    case NAV_DOWN:
        nav_set_focus(c[idx < 0 ? 0 : nav_vertical_target(c, n, idx, 1)]);
        return 1;
    case NAV_FIRST:
        nav_set_focus(c[0]); return 1;
    case NAV_LAST:
        nav_set_focus(c[n - 1]); return 1;
    case NAV_PAGE_UP:
        nav_set_focus(c[idx < 0 ? 0 : (idx >= 4 ? idx - 4 : 0)]); return 1;
    case NAV_PAGE_DOWN:
        nav_set_focus(c[idx < 0 ? 0 : (idx + 4 < n ? idx + 4 : n - 1)]); return 1;
    case NAV_ACTIVATE:
        /* Nothing focused yet: show where focus is instead of firing a
         * button the person has not seen selected. */
        if (idx < 0) { nav_set_focus(c[0]); return 1; }
        lv_obj_send_event(c[idx], LV_EVENT_CLICKED, NULL);
        return 1;
    case NAV_ESCAPE:
        for (int i = 0; i < n; i++)
            if (nav_is_escape(c[i])) { lv_obj_send_event(c[i], LV_EVENT_CLICKED, NULL); return 1; }
        return 0;
    default: return 0;
    }
}

/* ---- keyboards and mice as input sources ---- */

enum { IN_KEYBOARD = 1, IN_MOUSE = 2, IN_TRACKPAD = 4 };
#define MAX_INPUTS 16
/* code_x/code_y/abs_x/abs_y/last_x/last_y are IN_TRACKPAD-only: which ABS
 * axes carry finger position, their reported range (to scale a physical
 * sweep of the pad to a sensible sweep of the screen), and the last sample
 * seen (-1 = none yet - a finger just went down, so the NEXT sample must
 * not be diffed against a stale position from three fingers ago and turn
 * into a random jump). */
struct input_src {
    int fd; int kind; char name[32];
    int code_x, code_y;
    struct input_absinfo abs_x, abs_y;
    int last_x, last_y;
};
static struct input_src g_inputs[MAX_INPUTS];
static int g_input_n;
/* Every node already probed, kept or not, so the hot-plug rescan only opens
 * what is NEW instead of re-probing a dozen event nodes every second. */
static char g_input_seen[64][32];
static int g_input_seen_n;
static int g_kb_shift;

static int input_has(int fd, int type, int code) {
    unsigned long bits[(KEY_MAX / (sizeof(long) * 8)) + 1] = {0};
    if (ioctl(fd, EVIOCGBIT(type, sizeof(bits)), bits) < 0) return 0;
    return bit_set(bits, code);
}

/* A keyboard has to be able to navigate: Enter and both vertical arrows.
 * That excludes power buttons, lid switches and media-key nodes, which is
 * what keeps this from adopting devices the Slate already has. A mouse needs
 * relative X/Y and a left button.
 *
 * A touchpad reports absolute axes, like a touchscreen's digitizer does -
 * the ONE bit that tells them apart is the same INPUT_PROP_DIRECT touch_open()
 * itself now requires: a touchscreen's coordinates ARE the screen's, a
 * touchpad's aren't related to it at all. Confirmed on real hardware: an
 * Elan touchpad enumerating INPUT_PROP_DIRECT=no, multitouch=yes, which
 * used to win touch_open()'s own selection with nothing genuinely direct
 * competing for it - driven as if finger position mapped 1:1 onto the
 * screen, which produced exactly what it looked like: a cursor jumping to
 * an unrelated point on every stroke, with nothing shown to say where it
 * would land. The SAME hardware's OWN separate "Mouse" companion node
 * (there mainly for legacy PS/2-emulation userspace, not for a bare
 * initramfs with no libinput) turned out to never actually emit a single
 * real event on this kernel - confirmed on hardware: it satisfies every
 * capability bit IN_MOUSE checks and NIGHTFALL_DEBUG_INPUT's own poll
 * trace still shows zero activity on it for a whole boot of real trackpad
 * use. So there is no working relative interface to fall back to here -
 * the touchpad's own absolute reports are read directly instead, and
 * turned into relative motion here rather than mapped onto the screen,
 * which is the only way its coordinates make sense: a touchpad's origin
 * is the corner of a small plastic pad on the case, not the corner of the
 * display. code_x/code_y are returned via out-params because inputs_rescan()
 * has to remember which axes to read from every later event - a plain kind
 * bitmask has nowhere to carry that. */
static int classify_input(int fd, int *code_x, int *code_y) {
    int kind = 0;
    if (input_has(fd, EV_KEY, KEY_ENTER) && input_has(fd, EV_KEY, KEY_UP) &&
        input_has(fd, EV_KEY, KEY_DOWN)) kind |= IN_KEYBOARD;
    if (input_has(fd, EV_REL, REL_X) && input_has(fd, EV_REL, REL_Y) &&
        input_has(fd, EV_KEY, BTN_LEFT)) kind |= IN_MOUSE;
    if (!device_is_direct(fd) && input_has(fd, EV_KEY, BTN_LEFT)) {
        int cx = -1, cy = -1;
        if (input_has(fd, EV_ABS, ABS_MT_POSITION_X) && input_has(fd, EV_ABS, ABS_MT_POSITION_Y)) {
            cx = ABS_MT_POSITION_X; cy = ABS_MT_POSITION_Y;
        } else if (input_has(fd, EV_ABS, ABS_X) && input_has(fd, EV_ABS, ABS_Y)) {
            cx = ABS_X; cy = ABS_Y;
        }
        if (cx >= 0) { kind |= IN_TRACKPAD; *code_x = cx; *code_y = cy; }
    }
    return kind;
}

/* Whether a real keyboard has been found - the one thing the text dialogs
 * need to know, to decide whether an on-screen keyboard is worth half the
 * screen. Declared up near those dialogs; defined here, beside the list it
 * reads. Deliberately "is there one NOW" rather than a value latched at
 * startup: a USB keyboard plugged in later is picked up by the same
 * once-a-second rescan everything else uses. */
static int have_physical_keyboard(void) {
    for (int i = 0; i < g_input_n; i++)
        if (g_inputs[i].kind & IN_KEYBOARD) return 1;
    return 0;
}

static int input_seen(const char *name) {
    for (int i = 0; i < g_input_seen_n; i++) if (!strcmp(g_input_seen[i], name)) return 1;
    return 0;
}

/* Opens any keyboard/mouse not seen before. Returns how many it added. */
static int inputs_rescan(void) {
    DIR *dir = opendir("/dev/input");
    if (!dir) return 0;
    int added = 0;
    struct dirent *de;
    while ((de = readdir(dir))) {
        if (strncmp(de->d_name, "event", 5) != 0) continue;
        if (input_seen(de->d_name)) continue;
        if (g_input_seen_n < 64) snprintf(g_input_seen[g_input_seen_n++], 32, "%.31s", de->d_name);
        if (g_input_n >= MAX_INPUTS) continue;
        char path[300];
        snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        int code_x = -1, code_y = -1;
        int kind = classify_input(fd, &code_x, &code_y);
        if (!kind) { close(fd); continue; }
        char name[128] = "?";
        ioctl(fd, EVIOCGNAME(sizeof(name)), name);
        fprintf(stderr, "nightfall: %s%s%s%s%s: %s (\"%s\")\n",
                (kind & IN_KEYBOARD) ? "keyboard" : "", ((kind & IN_KEYBOARD) && (kind & (IN_MOUSE | IN_TRACKPAD))) ? "+" : "",
                (kind & IN_MOUSE) ? "mouse" : "", ((kind & IN_MOUSE) && (kind & IN_TRACKPAD)) ? "+" : "",
                (kind & IN_TRACKPAD) ? "trackpad" : "", path, name);
        g_inputs[g_input_n].fd = fd;
        g_inputs[g_input_n].kind = kind;
        snprintf(g_inputs[g_input_n].name, sizeof(g_inputs[g_input_n].name), "%.31s", de->d_name);
        if (kind & IN_TRACKPAD) {
            g_inputs[g_input_n].code_x = code_x;
            g_inputs[g_input_n].code_y = code_y;
            /* Best-effort: a trackpad missing these still works, just at
             * whatever raw-unit scale trackpad_handle_event()'s fallback
             * uses instead of one tuned to this device's real range. */
            struct input_absinfo ax = {0}, ay = {0};
            ioctl(fd, EVIOCGABS(code_x), &ax);
            ioctl(fd, EVIOCGABS(code_y), &ay);
            g_inputs[g_input_n].abs_x = ax;
            g_inputs[g_input_n].abs_y = ay;
            g_inputs[g_input_n].last_x = -1;
            g_inputs[g_input_n].last_y = -1;
        }
        g_input_n++;
        added++;
    }
    closedir(dir);
    return added;
}

/* An unplugged device stops answering; forgetting it (and its "seen" entry)
 * lets a re-plug be picked up again. */
static void input_drop(int i) {
    close(g_inputs[i].fd);
    for (int k = 0; k < g_input_seen_n; k++)
        if (!strcmp(g_input_seen[k], g_inputs[i].name)) {
            memmove(g_input_seen[k], g_input_seen[k + 1], (size_t)(g_input_seen_n - k - 1) * 32);
            g_input_seen_n--;
            break;
        }
    g_inputs[i] = g_inputs[--g_input_n];
}

/* ---- typing into a textarea with a REAL keyboard ----
 *
 * The text dialogs (the cmdline editor, backup rename, backup name) were
 * built for the Slate, where the only way to type is tapping an on-screen
 * keyboard. On a laptop that left the real keyboard doing nothing at all -
 * Bob, on hardware: "that dosen't accept opens an on screen keyboard and
 * ignores the real one". Every printable key resolves to NAV_NONE in
 * nav_action_for_key(), and nothing else ever looked at them.
 *
 * text_input_begin() records the open textarea (and now skips the
 * on-screen keyboard entirely when there is a real one), so this is just
 * "the textarea currently being edited, if any". */
static lv_obj_t *active_textarea(void) {
    return g_text_input;
}

/* evdev keycode -> what a textarea should receive: a printable character as
 * its ASCII value, or one of LVGL's own LV_KEY_* editing codes, which
 * lv_textarea already understands. 0 means "not a typing key" - the caller
 * then treats it as navigation as before.
 *
 * US layout, deliberately: it is what the machines this runs on have, and a
 * kernel command line is ASCII anyway. Getting this wrong for a different
 * layout mistypes a character - it cannot break anything structurally, and
 * a machine with no keyboard to be wrong about still gets the on-screen
 * one, which is laid out by LVGL rather than by this table. */
static uint32_t key_to_char(int code, int shift) {
    switch (code) {
    case KEY_BACKSPACE: return LV_KEY_BACKSPACE;
    case KEY_DELETE:    return LV_KEY_DEL;
    case KEY_LEFT:      return LV_KEY_LEFT;
    case KEY_RIGHT:     return LV_KEY_RIGHT;
    case KEY_HOME:      return LV_KEY_HOME;
    case KEY_END:       return LV_KEY_END;
    case KEY_SPACE:     return ' ';
    default: break;
    }
    static const char row_q[]  = "qwertyuiop";
    static const char row_qs[] = "QWERTYUIOP";
    static const char row_a[]  = "asdfghjkl";
    static const char row_as[] = "ASDFGHJKL";
    static const char row_z[]  = "zxcvbnm";
    static const char row_zs[] = "ZXCVBNM";
    static const char digits[]  = "1234567890";
    static const char digits_s[] = "!@#$%^&*()";
    if (code >= KEY_Q && code <= KEY_P) return (uint32_t)(shift ? row_qs : row_q)[code - KEY_Q];
    if (code >= KEY_A && code <= KEY_L) return (uint32_t)(shift ? row_as : row_a)[code - KEY_A];
    if (code >= KEY_Z && code <= KEY_M) return (uint32_t)(shift ? row_zs : row_z)[code - KEY_Z];
    if (code >= KEY_1 && code <= KEY_9) return (uint32_t)(shift ? digits_s : digits)[code - KEY_1];
    if (code == KEY_0)                  return (uint32_t)(shift ? digits_s : digits)[9];
    switch (code) {
    case KEY_MINUS:      return shift ? '_' : '-';
    case KEY_EQUAL:      return shift ? '+' : '=';
    case KEY_DOT:        return shift ? '>' : '.';
    case KEY_COMMA:      return shift ? '<' : ',';
    case KEY_SLASH:      return shift ? '?' : '/';
    case KEY_BACKSLASH:  return shift ? '|' : '\\';
    case KEY_SEMICOLON:  return shift ? ':' : ';';
    case KEY_APOSTROPHE: return shift ? '"' : '\'';
    case KEY_LEFTBRACE:  return shift ? '{' : '[';
    case KEY_RIGHTBRACE: return shift ? '}' : ']';
    case KEY_GRAVE:      return shift ? '~' : '`';
    default:             return 0;
    }
}

/* One keyboard event. Returns 1 if it counts as the person being present
 * (any key press), which is what cancels the auto-boot countdown. */
static int kb_handle_event(const struct input_event *ev) {
    if (ev->type != EV_KEY) return 0;
    if (ev->code == KEY_LEFTSHIFT || ev->code == KEY_RIGHTSHIFT) { g_kb_shift = ev->value != 0; return 0; }
    if (ev->value == 0) return 0;                       /* release */
    enum nav_action a = nav_action_for_key(ev->code, g_kb_shift);
    if (input_dbg()) fprintf(stderr, "nightfall: key code=%d value=%d shift=%d -> action=%d\n",
                              ev->code, ev->value, g_kb_shift, (int)a);

    /* With a textarea open, keys that produce or edit TEXT go to it and
     * nowhere else - including three that otherwise mean something quite
     * different: Space activates a button, Backspace is Escape, and
     * Left/Right step between buttons. While typing, all of those have to
     * be the text meaning instead, or the command line editor cannot type
     * a space, delete a character, or move the cursor.
     *
     * Up/Down, Tab, Enter and Escape deliberately stay NAVIGATION even
     * with a textarea open: they are how you leave the text and reach the
     * dialog's own buttons (Use once / Save / Cancel). Enter in particular
     * submits rather than inserting a newline - a kernel command line is
     * one line by definition, so there is nothing a newline could mean. */
    lv_obj_t *ta = active_textarea();
    if (ta) {
        uint32_t c = key_to_char(ev->code, g_kb_shift);
        if (c) {
            lv_obj_send_event(ta, LV_EVENT_KEY, &c);
            /* Same reason splash_create() ends with one: this display is
             * driven manually, so nothing else decides a repaint is due.
             * lv_textarea invalidates itself on edit, which is enough when
             * something is already pumping redraws - belt and braces here
             * because a typed character that lands in the buffer but never
             * reaches the panel is indistinguishable, from the keyboard,
             * from a key that did nothing at all. */
            lv_obj_invalidate(ta);
            if (input_dbg())
                fprintf(stderr, "nightfall: typed 0x%x into textarea, now '%.60s'\n",
                        c, lv_textarea_get_text(ta));
            return 1;
        }
    } else if (input_dbg()) {
        fprintf(stderr, "nightfall: no active textarea - key goes to navigation\n");
    }

    /* Held arrows repeat and should keep moving; a held Enter or Escape must
     * not fire the same button again and again. */
    if (ev->value == 2 && (a == NAV_ACTIVATE || a == NAV_ESCAPE)) return 1;
    nav_do(a);
    return 1;
}

/* Mouse: relative motion moves the shared pointer position, in LOGICAL
 * space and with NO rotation applied. Touch has to be rotated because the
 * digitizer is fixed to the panel; a mouse moves in the room, and what the
 * person sees is already the logical orientation. */
static lv_obj_t *g_cursor;

static void mouse_cursor_show(struct nightfall_ctx *ctx) {
    if (!g_cursor) {
        g_cursor = lv_obj_create(lv_layer_sys());
        lv_obj_remove_style_all(g_cursor);
        lv_obj_set_size(g_cursor, ui_px(26), ui_px(26));
        lv_obj_set_style_radius(g_cursor, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(g_cursor, lv_color_hex(0xffffff), 0);
        lv_obj_set_style_bg_opa(g_cursor, LV_OPA_COVER, 0);
        lv_obj_set_style_border_color(g_cursor, lv_color_hex(0x1c2530), 0);
        lv_obj_set_style_border_width(g_cursor, ui_px(4), 0);
        lv_obj_remove_flag(g_cursor, LV_OBJ_FLAG_CLICKABLE);
        if (ctx->indev) lv_indev_set_cursor(ctx->indev, g_cursor);
    }
    lv_obj_remove_flag(g_cursor, LV_OBJ_FLAG_HIDDEN);
}

static void mouse_cursor_hide(void) {
    if (g_cursor) lv_obj_add_flag(g_cursor, LV_OBJ_FLAG_HIDDEN);
}

static int g_mouse_seen;

static void mouse_move(struct nightfall_ctx *ctx, int dx, int dy) {
    if (!g_mouse_seen) {            /* first motion: start in the middle */
        g_mouse_seen = 1;
        ctx->touch_x = ctx->cw / 2;
        ctx->touch_y = ctx->ch / 2;
    }
    int x = ctx->touch_x + dx, y = ctx->touch_y + dy;
    ctx->touch_x = x < 0 ? 0 : (x >= ctx->cw ? ctx->cw - 1 : x);
    ctx->touch_y = y < 0 ? 0 : (y >= ctx->ch ? ctx->ch - 1 : y);
    mouse_cursor_show(ctx);
}

/* The wheel scrolls the list under the pointer's screen (never a dialog). */
static void mouse_wheel(int notches) {
    if (lv_obj_get_child_count(lv_layer_top()) || !g_list) return;
    lv_obj_scroll_by_bounded(g_list, 0, notches * (ROW_H / 2), LV_ANIM_OFF);
}

/* One mouse event. Returns 1 if it counts as the person being present. */
static int mouse_handle_event(struct nightfall_ctx *ctx, const struct input_event *ev, int *dx, int *dy) {
    if (ev->type == EV_REL) {
        if (ev->code == REL_X) { *dx += ev->value; return 1; }
        if (ev->code == REL_Y) { *dy += ev->value; return 1; }
        if (ev->code == REL_WHEEL) { mouse_wheel(ev->value); return 1; }
        return 0;
    }
    if (ev->type == EV_KEY && ev->code == BTN_LEFT) {
        ctx->touch_down = ev->value != 0;
        if (ev->value) mouse_cursor_show(ctx);
        return ev->value != 0;
    }
    return 0;
}

/* A touchpad's absolute finger position, converted to relative motion and
 * fed into the SAME dx/dy accumulator a real mouse uses - see
 * classify_input()'s comment for why this exists instead of an
 * absolute/touch mapping, or a relative device to defer to.
 *
 * Scaled by the device's own reported axis range against the screen's
 * shorter side, so a full physical sweep of the pad crosses the screen a
 * fixed, moderate number of times regardless of how big the pad or the
 * panel are - there is no OS pointer-speed setting anywhere in this
 * initramfs to read instead, so this is a plain documented constant. A
 * device that reported no usable range (EVIOCGABS is best-effort; see
 * inputs_rescan()) falls back to a fixed divisor rather than dividing by
 * zero or producing a meaninglessly huge or tiny motion.
 *
 * last_x/last_y are reset on finger-up (ABS_MT_TRACKING_ID going to -1 for
 * a multitouch pad, BTN_TOUCH release for a single-touch one) so the FIRST
 * sample of the next touch is never diffed against a stale position left
 * over from wherever the last finger happened to lift - that reads as a
 * single large, unwanted jump exactly once per touch-down otherwise. */
#define TRACKPAD_SWEEPS_PER_SCREEN 2
static int trackpad_handle_event(struct nightfall_ctx *ctx, struct input_src *src,
                                  const struct input_event *ev, int *dx, int *dy) {
    if (ev->type == EV_ABS) {
        if (ev->code == ABS_MT_TRACKING_ID) {
            if (ev->value == -1) { src->last_x = -1; src->last_y = -1; }
            return 0;
        }
        int is_x = (ev->code == src->code_x);
        int is_y = !is_x && (ev->code == src->code_y);
        if (!is_x && !is_y) return 0;
        int range_x = src->abs_x.maximum - src->abs_x.minimum;
        int range_y = src->abs_y.maximum - src->abs_y.minimum;
        int pad_short = (range_x > 0 && range_y > 0) ? (range_x < range_y ? range_x : range_y) : 0;
        int screen_short = ctx->cw < ctx->ch ? ctx->cw : ctx->ch;
        int scale_den = pad_short > 0 ? pad_short * TRACKPAD_SWEEPS_PER_SCREEN : 8;
        if (is_x) {
            if (src->last_x >= 0) *dx += (ev->value - src->last_x) * screen_short / scale_den;
            src->last_x = ev->value;
        } else {
            if (src->last_y >= 0) *dy += (ev->value - src->last_y) * screen_short / scale_den;
            src->last_y = ev->value;
        }
        return 1;
    }
    if (ev->type == EV_KEY && ev->code == BTN_TOUCH && ev->value == 0) {
        src->last_x = -1;
        src->last_y = -1;
        return 0;
    }
    if (ev->type == EV_KEY && ev->code == BTN_LEFT) {
        ctx->touch_down = ev->value != 0;
        if (ev->value) mouse_cursor_show(ctx);
        return ev->value != 0;
    }
    return 0;
}

/* While a device is being waited for, this keeps the splash animating. */
static void (*g_wait_pump)(void);

static int wait_for_device(const char *what, struct drm_dev *drm, struct touch_dev *touch) {
    const char *s = getenv("NIGHTFALL_WAIT_SECS");
    int limit_ms = (s ? atoi(s) : 20) * 1000;
    if (limit_ms < 0) limit_ms = 0;

    int waited = 0;
    for (;;) {
        if ((drm ? drm_open_first_connected(drm) : touch_open(touch)) == 0) {
            if (waited)
                fprintf(stderr, "nightfall: %s appeared after %d.%03ds\n",
                        what, waited / 1000, waited % 1000);
            return 0;
        }
        if (waited >= limit_ms) {
            if (limit_ms)
                fprintf(stderr, "nightfall: gave up waiting for %s after %ds\n",
                        what, limit_ms / 1000);
            return -1;
        }
        if (g_wait_pump) g_wait_pump();
        usleep(WAIT_POLL_MS * 1000);
        waited += WAIT_POLL_MS;
    }
}

/* The auto-boot countdown, cancelled by the first sign the person is there -
 * a touch, a key press or a mouse click. Shared state rather than main()
 * locals so every input path cancels it the same way. */
static int g_cd_timer_fd = -1, g_cd_cancelled;
static lv_obj_t *g_cd_label;
static void countdown_cancel(void) {
    if (g_cd_timer_fd < 0 || g_cd_cancelled) return;
    g_cd_cancelled = 1;
    /* "Booting default in 30s - tap to choose" is false the moment someone
     * has acted, and it follows you into every submenu. */
    countdown_silence(g_cd_label);
    struct itimerspec off = {0};
    timerfd_settime(g_cd_timer_fd, 0, &off, NULL);
}

/* Waits for SOMETHING to steer with. Touch is still preferred and still
 * waited for exactly as before; a keyboard or mouse only shortens the wait -
 * once one is found, touch gets NIGHTFALL_INPUT_GRACE_SECS (default 4) to
 * appear and then we go on without it. The grace exists because touch
 * controllers really do arrive late (measured 1.4s on the Slate, behind i915
 * and I2C-HID) and a keyboard that is already up must not make us skip one.
 * With no input device at all it waits the full NIGHTFALL_WAIT_SECS and
 * fails, as it always did. Returns 0 with touch->fd < 0 when only a keyboard
 * or mouse was found. */
static int wait_for_input(struct touch_dev *touch) {
    const char *s = getenv("NIGHTFALL_WAIT_SECS");
    int limit_ms = (s ? atoi(s) : 20) * 1000;
    if (limit_ms < 0) limit_ms = 0;
    const char *g = getenv("NIGHTFALL_INPUT_GRACE_SECS");
    int grace_ms = (g ? atoi(g) : 4) * 1000;
    if (grace_ms < 0) grace_ms = 0;

    touch->fd = -1;
    int waited = 0, first_other = -1;
    for (;;) {
        if (touch_open(touch) == 0) {
            inputs_rescan();
            if (waited)
                fprintf(stderr, "nightfall: touch input device appeared after %d.%03ds\n",
                        waited / 1000, waited % 1000);
            return 0;
        }
        inputs_rescan();
        if (g_input_n > 0 && first_other < 0) first_other = waited;
        if (g_input_n > 0 && waited - first_other >= grace_ms) {
            fprintf(stderr, "nightfall: no touch device; going on with %d keyboard/mouse device(s)\n", g_input_n);
            return 0;
        }
        if (waited >= limit_ms) {
            if (limit_ms)
                fprintf(stderr, "nightfall: gave up waiting for an input device after %ds\n", limit_ms / 1000);
            return -1;
        }
        if (g_wait_pump) g_wait_pump();
        usleep(WAIT_POLL_MS * 1000);
        waited += WAIT_POLL_MS;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <menu.tsv> [tarballs.tsv] [saved-cmdline.tsv] [targets.tsv] [backups.tsv] [bootable.tsv]\n", argv[0]);
        return 2;
    }

    int timeout_secs = DEFAULT_TIMEOUT_SECS;
    const char *timeout_env = getenv("NIGHTFALL_TIMEOUT_SECS");
    if (timeout_env) timeout_secs = atoi(timeout_env);
    /* An auto-boot that cannot work would only march into a rescue shell
     * (see init) while someone is still reading why - stay on the menu,
     * where booting a drive, restarting and backups still work. */
    if (kexec_blocked_reason() && timeout_secs > 0) {
        fprintf(stderr, "nightfall: kexec is blocked (%s) - auto-boot disabled\n", kexec_blocked_reason());
        timeout_secs = 0;
    }

    struct entry entries[MAX_ENTRIES];
    int n = load_entries(argv[1], entries, MAX_ENTRIES);
    if (n <= 0) {
        fprintf(stderr, "nightfall: no kernel entries found in %s\n", argv[1]);
        return 1;
    }
    g_entries = entries;

    /* Optional second argument. Absent or unreadable just means the
     * Install menu comes up empty - never a reason to refuse to boot. */
    static struct tarball tarballs[64];
    if (argc > 2) {
        g_tarball_n = load_tarballs(argv[2], tarballs, 64);
        g_tarballs = tarballs;
    }
    /* Optional. Absent just means "Forget saved" is never offered,
     * which is correct when nothing is saved. */
    if (argc > 3) load_saved_cmdlines(argv[3]);
    static struct target targets[16];
    static struct backup backups[64];
    if (argc > 4) {
        snprintf(g_targets_path, sizeof(g_targets_path), "%.255s", argv[4]);
        g_target_n = load_targets(argv[4], targets, 16);
        g_targets = g_target_n ? targets : NULL;
    }
    if (argc > 5) {
        snprintf(g_backups_path, sizeof(g_backups_path), "%.255s", argv[5]);
        g_backup_n = load_backups(argv[5], backups, 64);
        g_backups = g_backup_n ? backups : NULL;
    }
    static struct bootable_drive bootables[16];
    if (argc > 6) {
        snprintf(g_bootable_path, sizeof(g_bootable_path), "%.255s", argv[6]);
        g_bootable_n = load_bootable_drives(argv[6], bootables, 16);
        g_bootable = g_bootable_n ? bootables : NULL;
    }

    /* Booted from the initramfs we are in a footrace with driver probe:
     * init reaches this point within ~0.85s of the kernel starting
     * (measured from a real boot log), while i915 and the I2C-HID touch
     * controller are still enumerating. Run by hand on a booted system
     * everything settled minutes ago, which is why this never showed up
     * in testing - the first two real boot attempts both died here with
     * "no touch input device found" while the panel was merely late.
     *
     * The retry lives HERE, not in init, on purpose. What counts as a
     * usable touch device is decided by touch_open()'s scoring
     * (INPUT_PROP_DIRECT + multitouch, after five Wacom sub-interfaces
     * once made a capability-bit match pick the wrong node). init can
     * only approximate that from shell, and its approximation - "does
     * any /dev/input/event* exist" - was satisfied instantly by the
     * unrelated event0-2 that are present from the start, so it waited
     * for nothing and picker still found no touch. A proxy for a check
     * is a second definition that can disagree with the real one; the
     * component that owns the criteria should own the waiting. */
    struct drm_dev drm;
    if (wait_for_device("connected DRM output", &drm, NULL) != 0) {
        fprintf(stderr, "nightfall: no connected DRM output found\n");
        return 1;
    }
    mark("display ready");

    /* TEMPORARY diagnostic, NIGHTFALL_DEBUG_FILL only: a real hardware boot
     * showed the splash freeze on its first frame and never update again,
     * while a later, unrelated redraw (the main menu's header) DID reach
     * the panel - a few dozen pixels near the top, nothing below it. That
     * shape - SOME writes reach the screen, most don't, no crash, no DRM
     * error anywhere in a full drm.debug=0x1e capture - doesn't distinguish
     * "the kernel only scans out the top of this buffer" from "something
     * in Nightfall's own redraw path stops after the first frame". This
     * settles it with one boot: paint the ENTIRE dumb buffer solid red,
     * outside LVGL entirely, and hold it. Whole screen red -> the bug is
     * below this, in Nightfall/LVGL. Only a sliver red -> it's DRM/kernel
     * scanout for this panel/mode, not anything in this codebase. Remove
     * once that's answered - this is not meant to survive as a feature. */
    if (getenv("NIGHTFALL_DEBUG_FILL")) {
        for (uint32_t row = 0; row < drm.height; row++)
            memset(drm.map + (size_t)row * drm.stride, 0, (size_t)drm.width * 4);
        for (uint32_t row = 0; row < drm.height; row++) {
            uint32_t *p = (uint32_t *)(drm.map + (size_t)row * drm.stride);
            for (uint32_t col = 0; col < drm.width; col++) p[col] = 0x00FF0000; /* XRGB8888 red */
        }
        fprintf(stderr, "nightfall: NIGHTFALL_DEBUG_FILL - whole buffer painted solid red, "
                        "holding 8s before continuing normally\n");
        struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
        while (ms_since(&t0) < 8000) usleep(50 * 1000);
    }

    /* Named initial_rot deliberately. It is only correct until the first
     * auto-rotate, and the live value lives in ctx.rot - so anything
     * reaching for a bare "rot" later now fails to compile instead of
     * silently using a stale one. That is the bug this had. */
    int initial_rot = parse_rotation();
    struct nightfall_ctx ctx = {
        .drm = &drm,
        .rot = initial_rot,
        .cw = (initial_rot == ROT_90 || initial_rot == ROT_270) ? (int)drm.height : (int)drm.width,
        .ch = (initial_rot == ROT_90 || initial_rot == ROT_270) ? (int)drm.width : (int)drm.height,
    };

    g_ctx = &ctx;

    /* Auto-rotate is opt-out rather than opt-in, but silently inert when
     * the kernel has no accelerometer - which is every picker kernel
     * built before the cros-ec IIO chain landed, and Nightfall has to
     * stay exactly as usable on those. */
    g_autorotate = 1;
    {
        const char *ar = getenv("NIGHTFALL_AUTOROTATE");
        if (ar && (!strcmp(ar, "0") || !strcmp(ar, "off"))) g_autorotate = 0;
    }
    if (g_autorotate) {
        accel_find();
        if (g_accel_dir[0])
            fprintf(stderr, "nightfall: auto-rotate using %s\n", g_accel_dir);
        else
            fprintf(stderr, "nightfall: no display accelerometer - rotation stays at %d\n", initial_rot);
    }
    /* Directory must already exist - picker does not create it, so a
     * typo'd path fails loudly at the first dump rather than silently
     * scattering files somewhere unexpected. */
    g_shot_dir = getenv("NIGHTFALL_SCREENSHOT_DIR");

    lv_init();
    /* Route LVGL's own warnings to stderr - never stdout, which
     * carries the SELECTED_* contract that initramfs/init sources.
     * Worth having on: an exhausted allocator inside LVGL surfaces
     * here as a plain "No memory" line instead of an unexplained
     * freeze (see the LV_STDLIB_CLIB note in lv_conf.h). */
    lv_log_register_print_cb(lvgl_log_to_stderr);
    lv_display_t *disp = lv_display_create(ctx.cw, ctx.ch);
    ui_scale_init(ctx.cw, ctx.ch);
    fprintf(stderr, "nightfall: display %dx%d, UI scale %d%%\n", ctx.cw, ctx.ch, g_scale_pct);
    /* Must be set before lv_theme_default_init(), which samples it once. The
     * DPI scales with the UI so the theme's own padding follows the rows. */
    lv_display_set_dpi(disp, PANEL_DPI * g_scale_pct / 100);
    lv_display_set_user_data(disp, &ctx);
    lv_display_set_flush_cb(disp, flush_cb);
    /* Sized for the LARGER dimension, not the current one. A 90-degree
     * turn swaps the logical width between drm.width and drm.height, and
     * a buffer cut to the narrower of the two is then too small for the
     * wider orientation. Allocating for the max once means rotation
     * never has to reallocate mid-flight - the one thing that would turn
     * a rotation into a crash. LVGL derives rows-per-chunk from
     * buf_size/width, so a roomier buffer on the narrow orientation just
     * means fewer, larger chunks. */
    int maxdim = (int)(drm.width > drm.height ? drm.width : drm.height);
    size_t buf_size = (size_t)maxdim * 64 * 4; /* partial buffer, >=64 logical rows */
    void *lvgl_buf = malloc(buf_size);
    if (!lvgl_buf) {
        fprintf(stderr, "nightfall: out of memory allocating LVGL draw buffer\n");
        drm_close(&drm);
        return 1;
    }
    lv_display_set_buffers(disp, lvgl_buf, NULL, buf_size, LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_theme_t *theme = lv_theme_default_init(disp, lv_color_hex(0x3d7ee8), lv_color_hex(0x8ec6ff), true, ui_font_for_pct(g_scale_pct));
    lv_display_set_theme(disp, theme);

    /* Something alive on screen from the moment the display is ours. The
     * touch wait below used to run BEFORE LVGL was started, so a late
     * touch controller meant a blank or text-filled screen for its whole
     * duration. Moving that wait after this is the entire change. */
    int show_splash = splash_enabled();
    lv_obj_t *splash = show_splash ? splash_create(NULL) : NULL;
    struct timespec splash_shown;
    clock_gettime(CLOCK_MONOTONIC, &splash_shown);
    mark(show_splash ? "splash drawn" : "splash disabled");

    struct touch_dev touch = { .fd = -1 };   /* fd < 0: keyboard/mouse only */
    g_wait_pump = show_splash ? lvgl_pump : NULL;
    int touch_rc = wait_for_input(&touch);
    g_wait_pump = NULL;
    if (touch_rc != 0) {
        fprintf(stderr, "nightfall: no touch, keyboard or mouse input device found\n");
        drm_close(&drm);
        return 1;
    }
    mark(touch.fd >= 0 ? "touch ready" : "keyboard/mouse ready (no touch)");

    lv_indev_t *indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, indev_read_cb);
    lv_indev_set_user_data(indev, &ctx);
    ctx.indev = indev;

    /* Touch usually appears almost at once, which is exactly why the
     * splash used to be gone before anyone saw it. */
    if (splash) {
        pump_until(&splash_shown, splash_min_ms());
        lv_obj_delete(splash);
    }
    lv_obj_t *countdown_label = NULL;
    build_ui(entries, n, timeout_secs, &countdown_label);

    int vt_fd = vt_setup();
    int sig_fd = signalfd_setup();
    int timer_fd = -1;
    int seconds_left = timeout_secs;
    /* Distinguishes the timeout's auto-boot from a real tap. Without
     * this both look identical downstream, and a boot where the panel
     * stayed dark and the timeout fired reported itself as "booted user
     * selection" - which reads as though someone chose it. */
    int g_selected_by_timeout = 0;
    if (timeout_secs > 0) {
        timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
        struct itimerspec its = {.it_value = {.tv_sec = 1}, .it_interval = {.tv_sec = 1}};
        if (timer_fd >= 0) timerfd_settime(timer_fd, 0, &its, NULL);
        if (countdown_label) {
            lv_label_set_text_fmt(countdown_label, "Booting default in %ds - tap or press a key to choose", seconds_left);
        }
    }
    g_cd_timer_fd = timer_fd;
    g_cd_label = countdown_label;

    int have_master = 1;
    struct timespec last_tick;
    clock_gettime(CLOCK_MONOTONIC, &last_tick);

    lv_timer_handler();
    mark("menu drawn");
    dump_interrupts("menu just appeared");

    struct pollfd fds[4 + MAX_INPUTS];
    long last_rescan_ms = 0;
    char inst_buf[512];
    size_t inst_len = 0;
    while (g_selected < 0) {
        int nfds = 0;
        int touch_idx = -1, sig_idx = -1, timer_idx = -1, inst_idx = -1;
        if (touch.fd >= 0) { fds[nfds].fd = touch.fd; fds[nfds].events = POLLIN; touch_idx = nfds++; }
        /* Keyboards and mice, fixed for THIS pass: the rescan and the drop of
         * an unplugged one both happen after the events are read. */
        int in_base = nfds, nin = g_input_n;
        for (int i = 0; i < nin; i++) { fds[nfds].fd = g_inputs[i].fd; fds[nfds].events = POLLIN; nfds++; }
        if (input_dbg()) {
            static int last_nin = -1;
            if (nin != last_nin) {
                last_nin = nin;
                fprintf(stderr, "nightfall: poll set now has %d keyboard/mouse fd(s):", nin);
                for (int i = 0; i < nin; i++)
                    fprintf(stderr, " fd=%d(%s)", g_inputs[i].fd, g_inputs[i].name);
                fprintf(stderr, "\n");
            }
        }
        if (sig_fd >= 0) { fds[nfds].fd = sig_fd; fds[nfds].events = POLLIN; sig_idx = nfds++; }
        if (timer_fd >= 0) { fds[nfds].fd = timer_fd; fds[nfds].events = POLLIN; timer_idx = nfds++; }
        if (g_install_fd >= 0) { fds[nfds].fd = g_install_fd; fds[nfds].events = POLLIN; inst_idx = nfds++; }

        int pr = poll(fds, nfds, POLL_PERIOD_MS);
        if (pr < 0 && errno != EINTR) break;

        /* Auto-rotate. Polled here rather than given its own fd: the
         * loop already wakes every POLL_PERIOD_MS for touch, and
         * accel_poll() rate-limits itself to a quarter second, so this
         * costs two small sysfs reads a few times a second. IIO can do
         * triggered capture with a ring buffer, which would be the right
         * answer for motion tracking and is wildly disproportionate for
         * noticing that someone turned the tablet over. */
        accel_poll();

        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        uint32_t elapsed_ms = (uint32_t)((now.tv_sec - last_tick.tv_sec) * 1000 +
                                          (now.tv_nsec - last_tick.tv_nsec) / 1000000);
        if (elapsed_ms > 0) {
            lv_tick_inc(elapsed_ms);
            last_tick = now;
        }

        if (sig_idx >= 0 && (fds[sig_idx].revents & POLLIN)) {
            struct signalfd_siginfo si;
            if (read(sig_fd, &si, sizeof(si)) == (ssize_t)sizeof(si)) {
                if (si.ssi_signo == VT_RELEASE_SIG) {
                    drmDropMaster(drm.fd);
                    have_master = 0;
                    if (vt_fd >= 0) ioctl(vt_fd, VT_RELDISP, 1);
                } else if (si.ssi_signo == VT_ACQUIRE_SIG) {
                    if (drmSetMaster(drm.fd) == 0) {
                        have_master = 1;
                        drmModeSetCrtc(drm.fd, drm.crtc_id, drm.fb_id, 0, 0, &drm.conn_id, 1, &drm.mode);
                        /* Both layers: dialogs and the on-screen
                         * keyboard live on lv_layer_top() (msgbox puts
                         * its backdrop there), so invalidating only the
                         * active screen would leave an open dialog
                         * unpainted after a VT switch back. */
                        lv_obj_invalidate(lv_screen_active());
                        lv_obj_invalidate(lv_layer_top());
                    }
                    if (vt_fd >= 0) ioctl(vt_fd, VT_RELDISP, VT_ACKACQ);
                }
            }
        }

        if (timer_idx >= 0 && (fds[timer_idx].revents & POLLIN)) {
            uint64_t ticks;
            if (read(timer_fd, &ticks, sizeof(ticks)) == (ssize_t)sizeof(ticks)) {
                seconds_left -= (int)ticks;
                if (g_installing) {
                    /* see g_installing: never auto-boot mid-install */
                } else if (seconds_left <= 0) {
                    g_selected = 0;
                    g_selected_by_timeout = 1;
                } else if (countdown_label) {
                    lv_label_set_text_fmt(countdown_label, "Booting default in %ds - tap or press a key to choose", seconds_left);
                }
            }
        }
        /* Output from the running child, line by line onto the
         * progress screen - see install_pump(). */
        if (inst_idx >= 0 && (fds[inst_idx].revents & (POLLIN | POLLHUP))) {
            install_pump(inst_buf, sizeof(inst_buf), &inst_len);
        }

        if (g_selected >= 0 || g_install >= 0 || g_reload || g_power_action || g_live_boot || g_boot_external) break;

        if (touch_idx >= 0 && (fds[touch_idx].revents & POLLIN)) {
            struct input_event ev;
            static int last_raw_x = -1, last_raw_y = -1;
            while (read(touch.fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                int new_down = -1; /* -1 = this event doesn't carry a down/up state */
                if (ev.type == EV_ABS) {
                    if (ev.code == touch.code_x) {
                        last_raw_x = ev.value;
                    } else if (ev.code == touch.code_y) {
                        last_raw_y = ev.value;
                    } else if (ev.code == ABS_MT_TRACKING_ID) {
                        /* Type B multitouch (hid_multitouch, which is
                         * what this hardware's touch stack actually
                         * uses) signals finger down/up via tracking ID
                         * rather than BTN_TOUCH - confirmed on real
                         * hardware that this device sends no BTN_TOUCH
                         * at all, which is why touch still didn't
                         * register even after selecting the right
                         * INPUT_PROP_DIRECT device. -1 means lifted. */
                        new_down = (ev.value != -1);
                    }
                    if (last_raw_x >= 0 && last_raw_y >= 0) {
                        int lx, ly;
                        /* ctx.rot, NOT the startup value: auto-rotate
                         * changes it, and this passed the stale local
                         * while passing ctx's UPDATED cw/ch - so after a
                         * turn, touch was transformed with the old
                         * rotation and the new dimensions. Display was
                         * perfect and touch was wrong, which is exactly
                         * how it presented. */
                        touch_to_logical(&touch, ctx.rot, ctx.cw, ctx.ch, drm.width, drm.height,
                                          last_raw_x, last_raw_y, &lx, &ly);
                        ctx.touch_x = lx;
                        ctx.touch_y = ly;
                    }
                } else if (ev.type == EV_KEY && ev.code == BTN_TOUCH) {
                    new_down = ev.value;
                }

                if (new_down >= 0 && new_down != ctx.touch_down) {
                    ctx.touch_down = new_down;
                    if (new_down) {
                        mouse_cursor_hide();     /* touch takes over from a mouse pointer */
                        countdown_cancel();      /* first touch cancels the auto-boot */
                    }
                }
            }
        }

        /* Keyboards and mice. */
        {
            int dx = 0, dy = 0, present = 0, dead[MAX_INPUTS], nd = 0;
            for (int i = 0; i < nin; i++) {
                if (!(fds[in_base + i].revents & (POLLIN | POLLERR | POLLHUP))) continue;
                if (input_dbg())
                    fprintf(stderr, "nightfall: poll fired fd=%d name=%s kind=%d revents=%d\n",
                            g_inputs[i].fd, g_inputs[i].name, g_inputs[i].kind, fds[in_base + i].revents);
                struct input_event ev;
                ssize_t r;
                while ((r = read(g_inputs[i].fd, &ev, sizeof(ev))) == (ssize_t)sizeof(ev)) {
                    if (input_dbg())
                        fprintf(stderr, "nightfall: raw event type=%d code=%d value=%d (sizeof=%zu)\n",
                                ev.type, ev.code, ev.value, sizeof(ev));
                    if (g_inputs[i].kind & IN_KEYBOARD)  present |= kb_handle_event(&ev);
                    if (g_inputs[i].kind & IN_MOUSE)     present |= mouse_handle_event(&ctx, &ev, &dx, &dy);
                    if (g_inputs[i].kind & IN_TRACKPAD)  present |= trackpad_handle_event(&ctx, &g_inputs[i], &ev, &dx, &dy);
                }
                if (input_dbg() && r != (ssize_t)sizeof(ev))
                    fprintf(stderr, "nightfall: read() returned %zd (errno=%d %s)\n",
                            r, errno, strerror(errno));
                if (r < 0 && errno != EAGAIN && errno != EINTR) dead[nd++] = i;
            }
            if (dx || dy) mouse_move(&ctx, dx, dy);
            for (int k = nd - 1; k >= 0; k--) input_drop(dead[k]);
            if (present) countdown_cancel();

            /* Hot-plug: a USB keyboard often enumerates a few seconds after
             * Nightfall is already up. */
            long now_ms = (long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
            if (now_ms - last_rescan_ms >= 1000) {
                last_rescan_ms = now_ms;
                inputs_rescan();
            }
        }

        if (have_master) lv_timer_handler();

        /* After the render, so the dialog that asked for this is
         * actually on screen. The first one is the menu itself. */
        if (g_shot_dir && have_master) {
            if (g_shot_pending) {
                screenshot(g_shot_pending);
                g_shot_pending = NULL;
            } else if (g_shot_n == 0) {
                screenshot("menu");
            }
        }
    }
    dump_interrupts("countdown expired / selection made");

    /* Booting a kernel: put up a booting screen and keep it through the
     * handoff, instead of exiting and letting the text console back while
     * init saves the log and kexec loads the kernel. Only for a real boot -
     * a reload, install or power action relaunches Nightfall or prints to
     * the console, and must get the display back normally.
     * NIGHTFALL_SPLASH=0 turns this and the startup spinner off together. */
    int handoff = (g_selected >= 0 && !g_reload && !g_power_action && g_install < 0
                   && have_master && splash_enabled());
    if (handoff) {
        char line[200];
        snprintf(line, sizeof line, "Booting %.170s", entries[g_selected].title);
        splash_create(line);
        struct timespec boot_shown;
        clock_gettime(CLOCK_MONOTONIC, &boot_shown);
        mark("booting screen drawn");
        /* Held BEFORE the selection is written: init only moves on to kexec
         * once Nightfall exits, so this is the one place the booting screen
         * can be given time on its own. After the fork the child keeps it up
         * for however long the handoff itself takes. */
        pump_until(&boot_shown, splash_min_ms());
    }

    if (touch.fd >= 0) close(touch.fd);
    for (int i = 0; i < g_input_n; i++) close(g_inputs[i].fd);
    if (sig_fd >= 0) close(sig_fd);
    if (timer_fd >= 0) close(timer_fd);
    if (vt_fd >= 0) close(vt_fd);
    /* drm_close would restore the console's own display configuration -
     * the exact thing the booting screen exists to avoid. The child in
     * hold_boot_screen() needs the display and the draw buffer. */
    if (!handoff) {
        drm_close(&drm);
        free(lvgl_buf);
    }

    if (g_reload) {
        /* The install already ran here, in front of the user. init only
         * needs to re-read grub.cfg and show the menu again - it must
         * NOT install anything a second time, which is why this is a
         * different key from INSTALL_TARBALL. */
        shell_quote(stdout, "RELOAD", "1");
        fprintf(stderr, "nightfall: install finished, asking for a menu reload\n");
        return 0;
    }

    if (g_power_action) {
        shell_quote(stdout, "POWER_ACTION", g_power_action);
        fprintf(stderr, "nightfall: %s requested\n", g_power_action);
        return 0;
    }

    if (g_live_boot) {
        /* Its own contract, not SELECTED_LINUX: the vmlinuz/initrd live
         * inside a loop-mounted ISO on an external drive, not at a
         * real-root-relative /boot path the way every other selection
         * here does, so init needs a different script and different
         * arguments to act on this - see initramfs/init and
         * boot-live-iso.sh. */
        shell_quote(stdout, "LIVE_BOOT_TARGET", g_live_target_dev);
        shell_quote(stdout, "LIVE_BOOT_ISO", g_live_iso_path);
        fprintf(stderr, "nightfall: live-USB boot requested: %s on %s\n",
                g_live_iso_path, g_live_target_dev);
        return 0;
    }

    if (g_boot_external) {
        /* Also its own contract: this names a whole drive plus the
         * loader firmware should run on it, not a kernel/initrd path -
         * and unlike every case above, success here does not end at
         * kexec. init runs boot-external-drive.sh to arm BootNext and
         * then has to reboot for it to take effect - see initramfs/init. */
        shell_quote(stdout, "BOOT_EXTERNAL_PART", g_boot_external_part);
        shell_quote(stdout, "BOOT_EXTERNAL_LOADER", g_boot_external_loader);
        fprintf(stderr, "nightfall: external-drive boot requested: %s (%s)\n",
                g_boot_external_part, g_boot_external_loader);
        return 0;
    }

    if (g_install >= 0) {
        /* Distinct from the SELECTED_* contract on purpose: init has to
         * do something completely different with this, and a caller
         * that only knows about SELECTED_LINUX will find nothing to
         * source rather than silently booting the wrong thing. */
        shell_quote(stdout, "INSTALL_TARBALL", g_tarballs[g_install].path);
        fprintf(stderr, "nightfall: install requested: %s\n", g_tarballs[g_install].path);
        return 0;
    }

    if (g_selected < 0) {
        fprintf(stderr, "nightfall: touch input ended with no selection\n");
        return 1;
    }

    shell_quote(stdout, "SELECTED_LINUX", entries[g_selected].linux_path);
    shell_quote(stdout, "SELECTED_INITRD", entries[g_selected].initrd_path);
    shell_quote(stdout, "SELECTED_CMDLINE", entries[g_selected].cmdline);
    if (g_set_default) shell_quote(stdout, "SET_DEFAULT", "1");
    if (g_setcl_set) shell_quote(stdout, "SET_CMDLINE", g_setcl);
    shell_quote(stdout, "SELECTED_BY", g_selected_by_timeout ? "timeout" : "user");
    fprintf(stderr, "nightfall: selection made by %s\n",
            g_selected_by_timeout ? "TIMEOUT (nothing was tapped)" : "user tap");
    if (handoff) hold_boot_screen();
    return 0;
}

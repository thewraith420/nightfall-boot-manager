/* Proves the optimised flush_cb is pixel-identical to the per-pixel
 * version it replaced, for every rotation.
 *
 * The reference below IS the old implementation, kept deliberately as
 * an oracle: it is obviously correct (it calls logical_to_physical for
 * each pixel, the same transform the header documents as verified
 * bijective) and slow, which is exactly what you want to check a fast
 * version against. Rotation bugs are expensive here - they cost a
 * reboot cycle to see - so the fast path should not ship on reasoning
 * alone. */
#define main picker_real_main
#include "nightfall.c"
#undef main

static void flush_reference(struct nightfall_ctx *ctx, const lv_area_t *area, uint8_t *px_map) {
    int w = area->x2 - area->x1 + 1;
    uint32_t *src = (uint32_t *)px_map;
    for (int ly = area->y1; ly <= area->y2; ly++) {
        for (int lx = area->x1; lx <= area->x2; lx++) {
            int px, py;
            logical_to_physical(ctx->rot, ctx->cw, ctx->ch, lx, ly, &px, &py);
            if (px < 0 || py < 0 || (uint32_t)px >= ctx->drm->width || (uint32_t)py >= ctx->drm->height) continue;
            uint32_t color = src[(ly - area->y1) * w + (lx - area->x1)];
            uint32_t *dst_row = (uint32_t *)(ctx->drm->map + (size_t)py * ctx->drm->stride);
            dst_row[px] = color;
        }
    }
}

#define PW 800
#define PH 600
static int fails, passes;
static void ck(int c, const char *m) {
    printf(c ? "  [ok] %s\n" : "  [FAIL] %s\n", m);
    c ? passes++ : fails++;
}

int main(void) {
    lv_init();
    size_t fbsz = (size_t)PW * PH * 4;
    struct drm_dev da = {0}, db = {0};
    da.width = db.width = PW; da.height = db.height = PH;
    da.stride = db.stride = PW * 4;
    da.map = malloc(fbsz); db.map = malloc(fbsz);

    struct nightfall_ctx ca = { .drm = &da }, cb = { .drm = &db };
    lv_display_t *disp = lv_display_create(PW, PH);   /* only for flush_ready */
    lv_display_set_user_data(disp, &cb);

    srand(12345);
    const int rots[4] = { ROT_0, ROT_90, ROT_180, ROT_270 };
    const char *names[4] = { "0", "90", "180", "270" };

    for (int r = 0; r < 4; r++) {
        int rot = rots[r];
        int cw = (rot == ROT_90 || rot == ROT_270) ? PH : PW;
        int ch = (rot == ROT_90 || rot == ROT_270) ? PW : PH;
        ca.rot = cb.rot = rot; ca.cw = cb.cw = cw; ca.ch = cb.ch = ch;

        int mismatches = 0;
        for (int trial = 0; trial < 60; trial++) {
            memset(da.map, 0xAA, fbsz);
            memset(db.map, 0xAA, fbsz);
            lv_area_t a;
            /* full-screen, single rows, single pixels, and random
             * sub-rectangles - partial refreshes produce all of these */
            if (trial == 0)      { a.x1 = 0; a.y1 = 0; a.x2 = cw - 1; a.y2 = ch - 1; }
            else if (trial == 1) { a.x1 = 0; a.y1 = ch / 2; a.x2 = cw - 1; a.y2 = ch / 2; }
            else if (trial == 2) { a.x1 = cw - 1; a.y1 = ch - 1; a.x2 = cw - 1; a.y2 = ch - 1; }
            else {
                a.x1 = rand() % cw; a.y1 = rand() % ch;
                a.x2 = a.x1 + rand() % (cw - a.x1);
                a.y2 = a.y1 + rand() % (ch - a.y1);
            }
            int w = a.x2 - a.x1 + 1, h = a.y2 - a.y1 + 1;
            uint32_t *src = malloc((size_t)w * h * 4);
            for (int i = 0; i < w * h; i++) src[i] = (uint32_t)rand();

            flush_reference(&ca, &a, (uint8_t *)src);
            flush_cb(disp, &a, (uint8_t *)src);
            if (memcmp(da.map, db.map, fbsz) != 0) mismatches++;
            free(src);
        }
        if (mismatches == 0) { printf("  [ok] rot %-4s pixel-identical to the reference over 60 areas\n", names[r]); passes++; }
        else { printf("  [FAIL] rot %-4s differs from reference in %d/60 areas\n", names[r], mismatches); fails++; }
    }
    /* ---- auto-rotate: orientation from a raw accelerometer reading ---- */
    /* Pure function, so the whole mapping is testable years before the
     * kernel can produce a reading. The four ACCEL_ROT entries are the
     * calibration; these assertions pin the LOGIC around them, not the
     * values, so recalibrating on real hardware does not invalidate the
     * suite. */
    {
        const int keep = ROT_90;   /* stand-in for "current orientation" */

        /* Counts, not g. Measured on the Slate: 1g is about 7800 here,
         * from a real reading of x=-7363 y=459 z=2537 held upright
         * portrait. Values below are that scale, so they mean something
         * physical rather than being round numbers. */
        const long G = 7800;

        /* Lying flat: neither axis means anything, so nothing changes.
         * Without this a tablet on a desk flickers between orientations
         * on sensor noise alone. */
        ck(accel_orientation(0, 0, keep) == keep, "flat on a table keeps the current rotation");
        ck(accel_orientation(G/6, -G/6, keep) == keep, "a 10 degree tilt is still too flat to act on");

        /* The dominant axis decides. */
        ck(accel_orientation(0, G, keep) == ACCEL_ROT[0], "+Y down picks entry 0");
        ck(accel_orientation(0, -G, keep) == ACCEL_ROT[1], "-Y down picks entry 1");
        ck(accel_orientation(G, 0, keep) == ACCEL_ROT[2], "+X down picks entry 2");
        ck(accel_orientation(-G, 0, keep) == ACCEL_ROT[3], "-X down picks entry 3");

        /* The real measurement, as recorded: held upright portrait. */
        ck(accel_orientation(-7363, 459, keep) == ROT_270,
           "the measured upright-portrait reading resolves to ROT_270");

        /* Mixed tilt goes with the larger component, and the boundary is
         * decided rather than left to chance. */
        ck(accel_orientation(G/3, G, keep) == ACCEL_ROT[0], "mostly +Y wins over some +X");
        ck(accel_orientation(G, G/3, keep) == ACCEL_ROT[2], "mostly +X wins over some +Y");
        ck(accel_orientation(G, G, keep) == ACCEL_ROT[0], "an exact 45 degrees resolves to Y, not undefined");

        /* Every orientation must be reachable, or one edge of the tablet
         * silently never works. */
        int seen[4] = {0,0,0,0};
        seen[accel_orientation(0, G, keep)]++;
        seen[accel_orientation(0, -G, keep)]++;
        seen[accel_orientation(G, 0, keep)]++;
        seen[accel_orientation(-G, 0, keep)]++;
        int all = 1;
        for (int i2 = 0; i2 < 4; i2++) if (seen[i2] != 1) all = 0;
        ck(all, "the four cases map onto the four rotations, one each");
    }

    /* ---- touch must follow a rotation, not just the display ---- */
    /* The bug this exists for: the touch call site passed the STARTUP
     * rotation while passing ctx's UPDATED cw/ch, so after an auto-rotate
     * touch was transformed with the old rotation and the new dimensions.
     * The display looked perfect, which is what made it confusing.
     *
     * Asserts the invariant rather than specific coordinates: a touch at
     * a known physical point must land on the SAME logical point that
     * the flush transform maps back to that physical point. If the two
     * transforms ever disagree about the current rotation, this fails. */
    {
        struct drm_dev dd = {0};
        dd.width = 3000; dd.height = 2000; dd.stride = 3000 * 4;
        struct nightfall_ctx tc = { .drm = &dd, .rot = ROT_270, .cw = 2000, .ch = 3000 };

        const int rots[4] = { ROT_0, ROT_90, ROT_180, ROT_270 };
        const char *rn[4] = { "0", "90", "180", "270" };
        int roundtrip_ok = 1, which = -1;
        for (int r = 0; r < 4; r++) {
            /* Exactly what apply_rotation() does to the context. */
            int sw = (rots[r] == ROT_90 || rots[r] == ROT_270);
            tc.rot = rots[r];
            tc.cw = sw ? (int)dd.height : (int)dd.width;
            tc.ch = sw ? (int)dd.width  : (int)dd.height;

            for (int ly0 = 0; ly0 < tc.ch; ly0 += 137) {
                for (int lx0 = 0; lx0 < tc.cw; lx0 += 149) {
                    int px, py, lx1, ly1;
                    logical_to_physical(tc.rot, tc.cw, tc.ch, lx0, ly0, &px, &py);
                    physical_to_logical(tc.rot, tc.cw, tc.ch, px, py, &lx1, &ly1);
                    if (lx1 != lx0 || ly1 != ly0) { roundtrip_ok = 0; which = r; }
                }
            }
        }
        if (roundtrip_ok) ck(1, "touch and display transforms agree at every rotation");
        else { char m[80]; snprintf(m, sizeof m, "transforms disagree at rot %s", rn[which]); ck(0, m); }

        /* And the specific regression: a transform given a STALE rotation
         * but current dimensions does not round-trip. This is what the
         * bug looked like, so assert it really is detectable. */
        tc.rot = ROT_0; tc.cw = 3000; tc.ch = 2000;
        int px, py, lx1, ly1;
        logical_to_physical(ROT_0, 3000, 2000, 100, 200, &px, &py);
        physical_to_logical(ROT_270, 3000, 2000, px, py, &lx1, &ly1);  /* stale rot */
        ck(!(lx1 == 100 && ly1 == 200),
           "a stale rotation with current dimensions really does land somewhere else");
    }

    /* ---- auto-rotate: reading the sensor out of sysfs ---- */
    {
        /* A fake IIO device, so the read path is exercised without a
         * kernel that has the cros-ec chain - which is what every
         * machine except the Slate looks like. */
        char dir[] = "/tmp/nf-accel-XXXXXX";
        if (mkdtemp(dir)) {
            char p1[256]; FILE *f;
            snprintf(p1, sizeof p1, "%s/in_accel_x_raw", dir);
            f = fopen(p1, "w"); if (f) { fprintf(f, "-7363\n"); fclose(f); }
            snprintf(p1, sizeof p1, "%s/in_accel_y_raw", dir);
            f = fopen(p1, "w"); if (f) { fprintf(f, "459\n"); fclose(f); }

            setenv("NIGHTFALL_ACCEL", dir, 1);
            g_accel_dir[0] = '\0';
            accel_find();
            ck(!strcmp(g_accel_dir, dir), "NIGHTFALL_ACCEL overrides device discovery");

            long ax = 0, ay = 0;
            ck(accel_read_raw("x", &ax) == 0 && ax == -7363, "reads in_accel_x_raw");
            ck(accel_read_raw("y", &ay) == 0 && ay == 459, "reads in_accel_y_raw");
            /* End to end: the real recorded reading through the real
             * read path lands on the orientation Bob confirmed. */
            ck(accel_orientation(ax, ay, ROT_0) == ROT_270,
               "the recorded portrait reading maps to ROT_270 end to end");

            long miss = 0;
            ck(accel_read_raw("z", &miss) != 0, "a missing channel fails rather than returning junk");

            snprintf(p1, sizeof p1, "%s/in_accel_x_raw", dir); unlink(p1);
            snprintf(p1, sizeof p1, "%s/in_accel_y_raw", dir); unlink(p1);
            rmdir(dir);
            unsetenv("NIGHTFALL_ACCEL");
            g_accel_dir[0] = '\0';
        }
    }

    /* ---- auto-rotate: the debounce ---- */
    {
        struct accel_debounce d = {0, 0};
        const int cur = ROT_90;
        /* A transient must not rotate the UI. Turning a tablet passes
         * through orientations you did not mean. */
        ck(!accel_settled(&d, ROT_0, cur, 3), "one sample of a new orientation is not enough");
        ck(!accel_settled(&d, ROT_0, cur, 3), "two is not enough either");
        ck(accel_settled(&d, ROT_0, cur, 3), "three in a row settles");

        /* An interrupted run starts over rather than accumulating. */
        struct accel_debounce d2 = {0, 0};
        accel_settled(&d2, ROT_0, cur, 3);
        accel_settled(&d2, ROT_180, cur, 3);
        ck(!accel_settled(&d2, ROT_0, cur, 3), "a different reading resets the count");

        /* Already there: nothing to settle, and the counter clears so a
         * later change starts from zero. */
        struct accel_debounce d3 = {0, 0};
        ck(!accel_settled(&d3, cur, cur, 3), "the current orientation never fires a change");
        ck(!accel_settled(&d3, ROT_0, cur, 3), "and the count restarts after it");
    }

    printf("\npassed: %d  failed: %d\n", passes, fails);
    return fails ? 1 : 0;
}

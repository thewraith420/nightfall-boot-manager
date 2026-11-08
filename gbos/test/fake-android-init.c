// TEST ONLY: stands in for Android's /system/bin/init. Reports what it was
// handed, in lines the test greps for, then powers off.
#define _GNU_SOURCE
#include <dirent.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>
static void cat1(const char *tag, const char *p) {
	char b[300]; FILE *f = fopen(p, "r");
	if (!f) { printf("FAKE: %s unreadable\n", tag); return; }
	if (fgets(b, sizeof b, f)) { b[strcspn(b, "\n")] = 0; printf("FAKE: %s = %s\n", tag, b); }
	fclose(f);
}
int main(int argc, char **argv) {
	printf("FAKE: pid=%d argv:", getpid()); for (int i = 0; i < argc; i++) printf(" [%s]", argv[i]); printf("\n");
	DIR *d = opendir("/proc/self/fd"); struct dirent *e; int extra = 0;
	while (d && (e = readdir(d))) { if (e->d_name[0] == '.') continue; int n = atoi(e->d_name); char t[256] = "", l[64];
		snprintf(l, sizeof l, "/proc/self/fd/%d", n); ssize_t k = readlink(l, t, sizeof t - 1); if (k > 0) t[k] = 0;
		if (n > 2 && strstr(t, "/proc/") == NULL) { printf("FAKE: stray fd %d -> %s\n", n, t); extra++; } }
	if (d) closedir(d);
	printf("FAKE: stray fds %d\n", extra);
	cat1("product marker", "/product/MARKER"); cat1("system_ext marker", "/system_ext/MARKER"); cat1("vendor marker", "/vendor/MARKER");
	cat1("firmware_class.path", "/sys/module/firmware_class/parameters/path");
	cat1("firmware via bind", "/debug_ramdisk/gbos-fw/gbos-test.fw");
	FILE *f = fopen("/proc/mounts", "r"); char l[400];
	while (f && fgets(l, sizeof l, f)) if (strstr(l, " / ") || strstr(l, " /proc ") || strstr(l, " /data ") || strstr(l, " /vendor ") || strstr(l, "/sys/fs/selinux") || strstr(l, " /dev/pts ") || strstr(l, "gbos-fw")) printf("FAKE: mount %s", l);
	if (f) fclose(f);
	f = fopen("/proc/modules", "r");
	while (f && fgets(l, sizeof l, f)) { char m[64]; sscanf(l, "%63s", m); if (!strcmp(m, "usbhid") || !strcmp(m, "virtio_rng") || !strcmp(m, "hid_multitouch")) printf("FAKE: module %s loaded\n", m); }
	if (f) fclose(f);
	FILE *w = fopen("/data/WRITE-TEST", "w"); if (w) { fputs("written by android\n", w); fclose(w); printf("FAKE: /data writable\n"); }
	printf("FAKE: /system %s\n", fopen("/system/x", "w") ? "WRITABLE (bad)" : "read-only");
	struct stat st; printf("FAKE: /dev/socket %s, /dev/dm-user %s\n", stat("/dev/socket", &st) ? "missing" : "ok", stat("/dev/dm-user", &st) ? "missing" : "ok");
	fflush(stdout); sync(); sleep(3); sync(); reboot(RB_POWER_OFF); return 0;
}

// TEST ONLY: a stand-in for the distro initramfs (initramfs-tools' init +
// run-init), reduced to the contract gbos-init relies on: the root
// filesystem mounted read-write, /dev /run /sys /proc moved into it, then
// the init= program exec'd as PID 1 on it, with the console on fds 0-2.
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>
static char cmd[4096];
static const char *arg(const char *k) {
	static char v[512]; char pat[64], *p; size_t n;
	snprintf(pat, sizeof pat, "%s=", k);
	for (p = cmd; (p = strstr(p, pat)); p++) {
		if (p != cmd && p[-1] != ' ') continue;
		p += strlen(pat); n = strcspn(p, " \n");
		if (n >= sizeof v) n = sizeof v - 1;
		memcpy(v, p, n); v[n] = 0; return v;
	}
	return NULL;
}
int main(void) {
	int fd; const char *init;
	mkdir("/dev", 0755); mkdir("/proc", 0755); mkdir("/sys", 0755); mkdir("/run", 0755); mkdir("/root", 0755);
	mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("tmpfs", "/run", "tmpfs", 0, "mode=0755");
	fd = open("/proc/cmdline", O_RDONLY); if (fd >= 0) { (void)!read(fd, cmd, sizeof cmd - 1); close(fd); }
	init = arg("init"); if (!init) init = "/sbin/init";
	for (int i = 0; i < 50 && mount("/dev/vda", "/root", "ext4", 0, NULL) != 0; i++) usleep(100000);
	printf("stand-in initramfs: root mounted, exec %s\n", init); fflush(stdout);
	mount("/dev", "/root/dev", NULL, MS_MOVE, NULL);
	mount("/run", "/root/run", NULL, MS_MOVE, NULL);
	mount("/sys", "/root/sys", NULL, MS_MOVE, NULL);
	mount("/proc", "/root/proc", NULL, MS_MOVE, NULL);
	chdir("/root"); mount(".", "/", NULL, MS_MOVE, NULL); chroot("."); chdir("/");
	fd = open("/dev/console", O_RDWR); if (fd >= 0) { dup2(fd, 0); dup2(fd, 1); dup2(fd, 2); if (fd > 2) close(fd); }
	execl(init, init, (char *)NULL);
	perror("stand-in initramfs: exec init"); return 1;
}

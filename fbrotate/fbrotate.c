// SPDX-License-Identifier: GPL-2.0
/*
 * fbrotate - mirror a framebuffer into another one, rotated by 90 degrees.
 *
 * Used to give the Venus OS GUI (gui-v2) a native landscape screen on a panel
 * that scans out in portrait (Waveshare 7" DSI, 720x1280): the GUI draws into a
 * 1280x720 virtual framebuffer (vfb, /dev/fb1) and this program copies changed
 * parts into the panel framebuffer (/dev/fb0) rotated by 90 degrees. gui-v2 then
 * does not rotate itself, so its dialogs (which break on rotated displays) work.
 *
 * The source is compared with a shadow copy in bands of rows; only changed
 * bands are rotated. Polling is fast while the screen changes, slower after a
 * second without changes, and paused while the backlight is off.
 *
 * usage: fbrotate [--ccw] [--interval ms] [--idle-interval ms] [--blank file]
 *                 [--dpms file] [--dpms-delay s] <src-fb> <dst-fb>
 *   --ccw            rotate counter-clockwise; the default is clockwise: the top
 *                    of the source ends up at the right-hand edge of the
 *                    destination (as gui-v1 and gui-v2 rotate themselves)
 *   --interval       poll interval while the screen changes (default 33 ms)
 *   --idle-interval  poll interval after 1 s without changes (default 100 ms)
 *   --blank          file that reads "0" while the display is on, e.g.
 *                    /sys/class/backlight/<dev>/bl_power; polling pauses otherwise
 *   --dpms           the destination's sysfs "blank" file, e.g.
 *                    /sys/class/graphics/fb0/blank. Needs --blank. When the display
 *                    has been blanked for --dpms-delay seconds (default 5), the
 *                    whole display pipeline is powered down through it (DSI link,
 *                    scanout and the panel's own supplies, not only its
 *                    backlight); it is powered up again when the display is on,
 *                    and when fbrotate exits (with the backlight left off if the
 *                    display was blanked). A power-up after which the panel driver
 *                    logs a failed initialisation (read from /dev/kmsg) is retried.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BAND 16	/* source rows compared/rotated at a time */

struct fb {
	const char *path;
	int fd;
	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;
	uint8_t *mem;
	size_t len;
};

static volatile sig_atomic_t stop;
static void on_signal(int sig) { (void)sig; stop = 1; }

static int fb_open(struct fb *fb, const char *path, int writable)
{
	fb->path = path;
	fb->fd = open(path, writable ? O_RDWR : O_RDONLY);
	if (fb->fd < 0 ||
	    ioctl(fb->fd, FBIOGET_VSCREENINFO, &fb->var) < 0 ||
	    ioctl(fb->fd, FBIOGET_FSCREENINFO, &fb->fix) < 0) {
		fprintf(stderr, "fbrotate: %s: %s\n", path, strerror(errno));
		return -1;
	}
	fb->len = (size_t)fb->fix.line_length * fb->var.yres_virtual;
	fb->mem = mmap(NULL, fb->len, writable ? PROT_READ | PROT_WRITE : PROT_READ,
		       MAP_SHARED, fb->fd, 0);
	if (fb->mem == MAP_FAILED) {
		fprintf(stderr, "fbrotate: mmap %s: %s\n", path, strerror(errno));
		return -1;
	}
	return 0;
}

/* rotate source rows [y0, y1) into the destination */
static void rotate_band(const struct fb *s, const struct fb *d, unsigned y0, unsigned y1, int ccw)
{
	const unsigned w = s->var.xres, h = s->var.yres;
	const unsigned bpp = s->var.bits_per_pixel / 8;
	const size_t ss = s->fix.line_length, ds = d->fix.line_length;

	for (unsigned x = 0; x < w; x++) {
		/* clockwise: (x, y) -> (h-1-y, x); counter-clockwise: (x, y) -> (y, w-1-x) */
		uint8_t *drow = d->mem + (size_t)(ccw ? w - 1 - x : x) * ds;
		for (unsigned y = y0; y < y1; y++) {
			const uint8_t *sp = s->mem + (size_t)y * ss + (size_t)x * bpp;
			uint8_t *dp = drow + (size_t)(ccw ? y : h - 1 - y) * bpp;
			if (bpp == 2)
				*(uint16_t *)dp = *(const uint16_t *)sp;
			else
				*(uint32_t *)dp = *(const uint32_t *)sp;
		}
	}
}

static void sleep_ms(int ms)
{
	const struct timespec t = { ms / 1000, (long)(ms % 1000) * 1000000L };
	nanosleep(&t, NULL);
}

/* display blanked? (blank file reads something other than "0") */
static int blanked(int fd)
{
	char c;
	return fd >= 0 && pread(fd, &c, 1, 0) == 1 && c != '0';
}

/*
 * Powering the pipeline up occasionally fails to initialise the panel: the first DCS
 * command of its init sequence times out ("vc4_dsi ...: transfer interrupt wait
 * timeout", then the panel driver's "failed to init panel: -110"). The backlight then
 * comes on over a panel that shows nothing, and stays so until the GUI blanks again
 * (5.10 ignores the panel's prepare() result, so nothing else notices). Powering the
 * pipeline down and up once more recovers it, so the kernel log is checked after each
 * power-up. The power-up write is synchronous: the panel driver has logged a failure
 * by the time it returns.
 */
#define PANEL_INIT_FAILED "failed to init panel"
#define DPMS_UP_TRIES 6		/* attempts per power-up (~10-25 % fail; ~1.9 s each) */
#define DPMS_RETRY_GAP_MS 500	/* powered down between attempts */

static int kmsg_fd = -1;	/* /dev/kmsg, non-blocking; -1 = no check */

/* start reading the kernel log from its current end */
static void kmsg_skip(void)
{
	if (kmsg_fd >= 0)
		lseek(kmsg_fd, 0, SEEK_END);
}

/* has the panel driver logged a failed initialisation since kmsg_skip()? */
static int kmsg_panel_failed(void)
{
	char rec[8192];
	int found = 0;

	if (kmsg_fd < 0)
		return 0;
	for (;;) {
		const ssize_t n = read(kmsg_fd, rec, sizeof(rec) - 1);

		if (n < 0 && errno == EPIPE)
			continue;	/* records overwritten while reading: go on */
		if (n <= 0)
			break;		/* EAGAIN: end of the log */
		rec[n] = '\0';
		if (strstr(rec, PANEL_INIT_FAILED))
			found = 1;
	}
	return found;
}

/*
 * Power the display pipeline down (FB_BLANK_POWERDOWN) or up (FB_BLANK_UNBLANK)
 * through the framebuffer's sysfs "blank" file. Returns the new state: 1 = down.
 * Note that the kernel also writes the backlight's bl_power while doing this
 * (non-zero when powering down, 0 when powering up).
 */
static int dpms_set(int fd, int down, int cur)
{
	if (fd < 0 || down == cur)
		return cur;
	for (int attempt = 1;; attempt++) {
		if (!down)
			kmsg_skip();
		if (pwrite(fd, down ? "4" : "0", 1, 0) != 1) {
			fprintf(stderr, "fbrotate: blank: %s\n", strerror(errno));
			return cur;
		}
		if (down || !kmsg_panel_failed()) {
			if (attempt > 1)
				fprintf(stderr, "fbrotate: panel initialised on attempt %d\n", attempt);
			return down;
		}
		if (attempt >= DPMS_UP_TRIES) {
			/* left up: the next blank -> on cycle tries again */
			fprintf(stderr, "fbrotate: panel initialisation failed %d times, giving up for now\n",
				attempt);
			return down;
		}
		fprintf(stderr, "fbrotate: panel initialisation failed, powering the display pipeline down and up again\n");
		if (pwrite(fd, "4", 1, 0) != 1)
			fprintf(stderr, "fbrotate: blank: %s\n", strerror(errno));
		sleep_ms(DPMS_RETRY_GAP_MS);
	}
}

int main(int argc, char **argv)
{
	struct fb src, dst;
	int ccw = 0, interval_ms = 33, idle_interval_ms = 100, blank_fd = -1, dpms_fd = -1;
	int dpms_delay_ms = 5000, i = 1;

	for (; i < argc && argv[i][0] == '-'; i++) {
		if (!strcmp(argv[i], "--ccw"))
			ccw = 1;
		else if (!strcmp(argv[i], "--interval") && i + 1 < argc)
			interval_ms = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--idle-interval") && i + 1 < argc)
			idle_interval_ms = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--blank") && i + 1 < argc) {
			/* writable if possible: see the exit path */
			blank_fd = open(argv[i + 1], O_RDWR);
			if (blank_fd < 0)
				blank_fd = open(argv[i + 1], O_RDONLY);
			i++;
		}
		else if (!strcmp(argv[i], "--dpms") && i + 1 < argc) {
			dpms_fd = open(argv[++i], O_WRONLY);
			/* see kmsg_panel_failed(); without it, no retries */
			kmsg_fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		}
		else if (!strcmp(argv[i], "--dpms-delay") && i + 1 < argc)
			dpms_delay_ms = atoi(argv[++i]) * 1000;
		else
			break;
	}
	if (argc - i != 2 || interval_ms <= 0 || idle_interval_ms <= 0 || dpms_delay_ms < 0) {
		fprintf(stderr, "usage: %s [--ccw] [--interval ms] [--idle-interval ms] [--blank file] "
			"[--dpms file] [--dpms-delay s] <src-fb> <dst-fb>\n", argv[0]);
		return 2;
	}
	if (dpms_fd >= 0 && blank_fd < 0) {
		fprintf(stderr, "fbrotate: --dpms needs --blank\n");
		return 2;
	}
	if (fb_open(&src, argv[i], 0) || fb_open(&dst, argv[i + 1], 1))
		return 1;

	const unsigned bpp = src.var.bits_per_pixel;
	if (bpp != dst.var.bits_per_pixel || (bpp != 16 && bpp != 32) ||
	    src.var.xres != dst.var.yres || src.var.yres != dst.var.xres) {
		fprintf(stderr, "fbrotate: need equal 16/32 bpp and swapped sizes: %s %ux%u-%u, %s %ux%u-%u\n",
			src.path, src.var.xres, src.var.yres, src.var.bits_per_pixel,
			dst.path, dst.var.xres, dst.var.yres, dst.var.bits_per_pixel);
		return 1;
	}

	const size_t row = (size_t)src.var.xres * (bpp / 8);
	const unsigned h = src.var.yres;
	uint8_t *shadow = malloc(row * h);
	if (!shadow)
		return 1;

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	printf("fbrotate: %s %ux%u -> %s %ux%u, %u bpp, %s, every %d ms (idle %d ms)%s\n",
	       src.path, src.var.xres, h, dst.path, dst.var.xres, dst.var.yres, bpp,
	       ccw ? "counter-clockwise" : "clockwise", interval_ms, idle_interval_ms,
	       blank_fd >= 0 ? ", pauses while blanked" : "");
	if (dpms_fd >= 0)
		printf("fbrotate: powers the display pipeline down after %d s of blanking%s\n",
		       dpms_delay_ms / 1000,
		       kmsg_fd >= 0 ? ", retries failed panel initialisations" : "");
	fflush(stdout);

	/* first frame: copy everything */
	for (unsigned y = 0; y < h; y++)
		memcpy(shadow + y * row, src.mem + (size_t)y * src.fix.line_length, row);
	rotate_band(&src, &dst, 0, h, ccw);

	int idle_ms = 0, blank_ms = 0, was_blank = 0, dpms_down = 0;

	/*
	 * The display should be on when bl_power reads 0. A previous instance may have died
	 * between the GUI's wake-up write and its own unblank, which would leave the panel
	 * powered down for a GUI that believes it is on: make sure the pipeline is up.
	 */
	if (dpms_fd >= 0 && !blanked(blank_fd))
		dpms_set(dpms_fd, 0, 1);

	while (!stop) {
		if (blanked(blank_fd)) {
			const int nap = dpms_down ? 100 : 250;	/* quick wake-up once powered down */
			if (dpms_fd >= 0 && !dpms_down && blank_ms >= dpms_delay_ms)
				dpms_down = dpms_set(dpms_fd, 1, dpms_down);
			sleep_ms(nap);
			blank_ms += nap;
			was_blank = 1;
			idle_ms = 0;	/* catch up quickly once the display is back on */
			continue;
		}
		if (was_blank) {
			/* Unblank on every blank -> on transition, not only when this instance powered the
			 * pipeline down: a previous instance may have died while it was down. */
			dpms_down = dpms_set(dpms_fd, 0, 1);
			was_blank = 0;
		}
		blank_ms = 0;
		const int wait = idle_ms >= 1000 ? idle_interval_ms : interval_ms;
		sleep_ms(wait);
		int any = 0;
		for (unsigned y0 = 0; y0 < h; y0 += BAND) {
			unsigned y1 = y0 + BAND < h ? y0 + BAND : h;
			int changed = 0;
			for (unsigned y = y0; y < y1; y++) {
				const uint8_t *s = src.mem + (size_t)y * src.fix.line_length;
				if (memcmp(shadow + y * row, s, row)) {
					memcpy(shadow + y * row, s, row);
					changed = 1;
				}
			}
			if (changed) {
				rotate_band(&src, &dst, y0, y1, ccw);
				any = 1;
			}
		}
		idle_ms = any ? 0 : (idle_ms < 1000 ? idle_ms + wait : idle_ms);
	}
	if (dpms_down) {
		/*
		 * Never leave the panel powered down behind us. Powering it up makes the kernel
		 * switch the backlight on as well (bl_power -> 0). If the GUI still wants the
		 * display blanked (it only writes bl_power when its timer fires or a touch
		 * wakes it), give that back, or the display would stay lit with a GUI that
		 * believes it is off.
		 */
		const int still_blank = blanked(blank_fd);

		dpms_set(dpms_fd, 0, 1);
		if (still_blank && pwrite(blank_fd, "1", 1, 0) != 1)
			fprintf(stderr, "fbrotate: bl_power: %s\n", strerror(errno));
	}
	return 0;
}

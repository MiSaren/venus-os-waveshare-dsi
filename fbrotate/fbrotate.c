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
 *                 <src-fb> <dst-fb>
 *   --ccw            rotate counter-clockwise; the default is clockwise: the top
 *                    of the source ends up at the right-hand edge of the
 *                    destination (as gui-v1 and gui-v2 rotate themselves)
 *   --interval       poll interval while the screen changes (default 33 ms)
 *   --idle-interval  poll interval after 1 s without changes (default 100 ms)
 *   --blank          file that reads "0" while the display is on, e.g.
 *                    /sys/class/backlight/<dev>/bl_power; polling pauses otherwise
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

int main(int argc, char **argv)
{
	struct fb src, dst;
	int ccw = 0, interval_ms = 33, idle_interval_ms = 100, blank_fd = -1, i = 1;

	for (; i < argc && argv[i][0] == '-'; i++) {
		if (!strcmp(argv[i], "--ccw"))
			ccw = 1;
		else if (!strcmp(argv[i], "--interval") && i + 1 < argc)
			interval_ms = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--idle-interval") && i + 1 < argc)
			idle_interval_ms = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--blank") && i + 1 < argc)
			blank_fd = open(argv[++i], O_RDONLY);
		else
			break;
	}
	if (argc - i != 2 || interval_ms <= 0 || idle_interval_ms <= 0) {
		fprintf(stderr, "usage: %s [--ccw] [--interval ms] [--idle-interval ms] [--blank file] <src-fb> <dst-fb>\n",
			argv[0]);
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
	fflush(stdout);

	/* first frame: copy everything */
	for (unsigned y = 0; y < h; y++)
		memcpy(shadow + y * row, src.mem + (size_t)y * src.fix.line_length, row);
	rotate_band(&src, &dst, 0, h, ccw);

	int idle_ms = 0;
	while (!stop) {
		if (blanked(blank_fd)) {
			sleep_ms(250);
			idle_ms = 0;	/* catch up quickly once the display is back on */
			continue;
		}
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
	return 0;
}

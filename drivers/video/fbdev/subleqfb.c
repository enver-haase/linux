// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq Virtual Machine Framebuffer Driver
 *
 * Simple fbdev driver that maps a fixed memory region as the display buffer.
 * The framebuffer is located at the top of the 1GB address space.
 *
 * Resolution: 800x512, XRGB8888 (32-bit for word-aligned access)
 *
 * Uses hand-optimized Subleq assembly for font blitting performance.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/errno.h>
#include <linux/string.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/delay.h>
#include <linux/fb.h>
#include <linux/init.h>
#include <linux/platform_device.h>

/* Subleq runtime functions */
extern void *__subleq_memmove_aligned(void *dest, const void *src, size_t n);
extern void *__subleq_memset32(void *s, unsigned int v, size_t n);

/* Assembly-optimized row blitter (subleq_blit_row.S) */
extern void subleq_blit_row8(u32 *dst, u32 byte, u32 fg, u32 bg);

/* Framebuffer configuration - shared with arch/subleq/kernel/setup.c */
#include <asm/subleq_fb.h>

/* Convenience aliases matching the SUBLEQFB_ prefix convention */
#define SUBLEQFB_WIDTH       SUBLEQ_FB_WIDTH
#define SUBLEQFB_HEIGHT      SUBLEQ_FB_HEIGHT
#define SUBLEQFB_BPP         SUBLEQ_FB_BPP
#define SUBLEQFB_FB_SIZE     SUBLEQ_FB_SIZE
#define SUBLEQFB_FB_ADDR     SUBLEQ_FB_ADDR

static struct fb_var_screeninfo subleqfb_var = {
	.xres           = SUBLEQFB_WIDTH,
	.yres           = SUBLEQFB_HEIGHT,
	.xres_virtual   = SUBLEQFB_WIDTH,
	.yres_virtual   = SUBLEQFB_HEIGHT,
	.bits_per_pixel = SUBLEQFB_BPP,
	/* XRGB8888: X in bits 24-31 (unused), R in 16-23, G in 8-15, B in 0-7 */
	.red            = { .offset = 16, .length = 8 },
	.green          = { .offset = 8,  .length = 8 },
	.blue           = { .offset = 0,  .length = 8 },
	.transp         = { .offset = 24, .length = 0 },  /* No alpha, just padding */
	.activate       = FB_ACTIVATE_NOW,
	.vmode          = FB_VMODE_NONINTERLACED,
};

static struct fb_fix_screeninfo subleqfb_fix = {
	.id             = "SubleqFB",
	.type           = FB_TYPE_PACKED_PIXELS,
	.visual         = FB_VISUAL_TRUECOLOR,
	.xpanstep       = 0,
	.ypanstep       = 0,
	.ywrapstep      = 0,
	.line_length    = SUBLEQFB_WIDTH * 4,
	.accel          = FB_ACCEL_NONE,
	.smem_start     = SUBLEQFB_FB_ADDR,
	.smem_len       = SUBLEQFB_FB_SIZE,
};

/* Pseudo palette for 24/32bpp modes */
static u32 pseudo_palette[16];

/*
 * Set a single color register (for truecolor modes, this populates the
 * pseudo palette used by higher-level fbcon code).
 */
static int subleqfb_setcolreg(u_int regno, u_int red, u_int green, u_int blue,
			      u_int transp, struct fb_info *info)
{
	if (regno >= 16)
		return 1;

	/* Convert 16-bit color values to 8-bit */
	red   >>= 8;
	green >>= 8;
	blue  >>= 8;

	/* XRGB8888: store in pseudo palette */
	pseudo_palette[regno] = (red << info->var.red.offset) |
				(green << info->var.green.offset) |
				(blue << info->var.blue.offset);
	return 0;
}

/*
 * Custom framebuffer operations using optimized memory functions
 */

/* Fill rectangle with solid color */
static void subleqfb_fillrect(struct fb_info *info, const struct fb_fillrect *rect)
{
	u32 color;
	u32 x, y, width, height;
	u32 line_bytes = info->fix.line_length;

	/* Get color from pseudo palette or use raw color */
	if (info->fix.visual == FB_VISUAL_TRUECOLOR && rect->color < 16)
		color = ((u32 *)info->pseudo_palette)[rect->color];
	else
		color = rect->color;

	/* Clamp to screen bounds */
	x = rect->dx;
	y = rect->dy;
	width = rect->width;
	height = rect->height;

	if (x >= info->var.xres || y >= info->var.yres)
		return;
	if (x + width > info->var.xres)
		width = info->var.xres - x;
	if (y + height > info->var.yres)
		height = info->var.yres - y;

	/*
	 * Fast path: full-width fill — contiguous rows, single memset32 call.
	 */
	if (width == info->var.xres) {
		u32 *p = (u32 *)((u8 *)info->screen_buffer + y * line_bytes);
		__subleq_memset32(p, color, (u32)height * width);
		return;
	}

	/*
	 * Generic path: per-row memset32.
	 */
	{
		u32 *dst = (u32 *)((u8 *)info->screen_buffer + y * line_bytes) + x;
		u32 h;
		for (h = 0; h < height; h++) {
			__subleq_memset32(dst, color, width);
			dst += SUBLEQFB_WIDTH;
		}
	}
}

/* Copy rectangle using memmove for each scanline */
static void subleqfb_copyarea(struct fb_info *info, const struct fb_copyarea *area)
{
	u8 *base = info->screen_buffer;
	u32 line_bytes = info->fix.line_length;
	u32 sx, sy, dx, dy, width, height;
	u32 row_bytes;

	sx = area->sx;
	sy = area->sy;
	dx = area->dx;
	dy = area->dy;
	width = area->width;
	height = area->height;
	row_bytes = width * 4;  /* 4 bytes per pixel */

	/*
	 * Fast path: full-width vertical scroll.
	 * When sx==dx and row_bytes==line_length, all scanlines are
	 * contiguous — collapse into a single memmove instead of
	 * per-scanline loop (~496 calls → 1 call during scroll).
	 */
	if (sx == dx && width == SUBLEQFB_WIDTH) {
		u8 *src = base + sy * line_bytes;
		u8 *dst = base + dy * line_bytes;
		__subleq_memmove_aligned(dst, src, (u32)height * line_bytes);
		return;
	}

	/* Generic path: per-scanline copy */
	if (dy <= sy) {
		/* Copy top-to-bottom */
		u32 h;
		for (h = 0; h < height; h++) {
			u8 *src_row = base + (sy + h) * line_bytes + sx * 4;
			u8 *dst_row = base + (dy + h) * line_bytes + dx * 4;
			__subleq_memmove_aligned(dst_row, src_row, row_bytes);
		}
	} else {
		/* Copy bottom-to-top for overlapping regions */
		u32 h;
		for (h = height; h > 0; h--) {
			u8 *src_row = base + (sy + h - 1) * line_bytes + sx * 4;
			u8 *dst_row = base + (dy + h - 1) * line_bytes + dx * 4;
			__subleq_memmove_aligned(dst_row, src_row, row_bytes);
		}
	}
}

/* Draw image (for fonts/cursors) - optimized for 8-pixel batches */
static void subleqfb_imageblit(struct fb_info *info, const struct fb_image *image)
{
	u32 *dst;
	const u8 *src;
	u32 fg, bg;
	u32 x, y, width, height;
	u32 line_words = info->fix.line_length / 4;

	/* Only support 1bpp images (monochrome fonts) with our optimized path.
	 * For other depths (like the boot logo), fall back to generic code. */
	if (image->depth != 1) {
		cfb_imageblit(info, image);
		return;
	}

	/* Get foreground and background colors */
	if (info->fix.visual == FB_VISUAL_TRUECOLOR) {
		fg = image->fg_color < 16 ? ((u32 *)info->pseudo_palette)[image->fg_color] : image->fg_color;
		bg = image->bg_color < 16 ? ((u32 *)info->pseudo_palette)[image->bg_color] : image->bg_color;
	} else {
		fg = image->fg_color;
		bg = image->bg_color;
	}

	x = image->dx;
	y = image->dy;
	width = image->width;
	height = image->height;

	src = image->data;
	dst = (u32 *)info->screen_buffer + y * line_words + x;

	/* Draw each scanline */
	for (; height > 0; height--) {
		u32 *p = dst;
		u32 w = 0;

		/* Process full bytes (8 pixels at a time) using assembly blitter */
		while (w + 8 <= width) {
			u8 byte = *src++;
			/* Call optimized assembly function */
			subleq_blit_row8(p, (u32)byte, fg, bg);
			p += 8;
			w += 8;
		}

		/* Handle remaining pixels (width not multiple of 8) */
		if (w < width) {
			u8 byte = *src++;
			u8 mask = 0x80;
			while (w < width) {
				*p++ = (byte & mask) ? fg : bg;
				mask >>= 1;
				w++;
			}
		}

		dst += line_words;
	}
}

/*
 * mmap support.
 *
 * NOMMU: get_fb_unmapped_area() (CONFIG_FB_PROVIDE_GET_FB_UNMAPPED_AREA) points the
 * NOMMU mmap code at screen_base directly; the callback just needs to succeed.
 *
 * MMU: the framebuffer is a fixed physical region (SUBLEQFB_FB_ADDR); map its pages
 * into the user vma with remap_pfn_range so userspace (e.g. fbdoom) can write pixels
 * directly. The VM's page-table walk resolves the resulting PTEs to the fb words.
 */
static int subleqfb_mmap(struct fb_info *info, struct vm_area_struct *vma)
{
#ifdef CONFIG_MMU
	unsigned long size = vma->vm_end - vma->vm_start;
	unsigned long offset = vma->vm_pgoff << PAGE_SHIFT;

	if (offset >= SUBLEQFB_FB_SIZE || size > SUBLEQFB_FB_SIZE - offset)
		return -EINVAL;

	vm_flags_set(vma, VM_IO);
	return remap_pfn_range(vma, vma->vm_start,
			       (SUBLEQFB_FB_ADDR + offset) >> PAGE_SHIFT,
			       size, vma->vm_page_prot);
#else
	return 0;
#endif
}

static const struct fb_ops subleqfb_ops = {
	.owner          = THIS_MODULE,
	__FB_DEFAULT_SYSMEM_OPS_RDWR,
	.fb_setcolreg   = subleqfb_setcolreg,
	.fb_mmap        = subleqfb_mmap,
	/* Custom word-only drawing operations */
	.fb_fillrect    = subleqfb_fillrect,
	.fb_copyarea    = subleqfb_copyarea,
	.fb_imageblit   = subleqfb_imageblit,
};

static int subleqfb_probe(struct platform_device *pdev)
{
	struct fb_info *info;
	int ret;

	pr_info("subleq_fb: probing device\n");

	info = framebuffer_alloc(0, &pdev->dev);
	if (!info)
		return -ENOMEM;

	info->var = subleqfb_var;
	info->fix = subleqfb_fix;
	info->fbops = &subleqfb_ops;
	info->flags = FBINFO_VIRTFB | FBINFO_READS_FAST;
	info->pseudo_palette = pseudo_palette;

	/*
	 * On NOMMU Subleq, physical == virtual, so we can directly
	 * point screen_buffer to the framebuffer address.
	 */
	info->screen_buffer = (void __iomem *)SUBLEQFB_FB_ADDR;
	info->screen_size = SUBLEQFB_FB_SIZE;


	ret = fb_alloc_cmap(&info->cmap, 256, 0);
	if (ret < 0) {
		framebuffer_release(info);
		return ret;
	}

	ret = register_framebuffer(info);
	if (ret < 0) {
		fb_dealloc_cmap(&info->cmap);
		framebuffer_release(info);
		return ret;
	}

	platform_set_drvdata(pdev, info);

	fb_info(info, "registered framebuffer at 0x%08lx, %dx%d %dbpp\n",
		SUBLEQFB_FB_ADDR, SUBLEQFB_WIDTH, SUBLEQFB_HEIGHT, SUBLEQFB_BPP);

	return 0;
}

static void subleqfb_remove(struct platform_device *pdev)
{
	struct fb_info *info = platform_get_drvdata(pdev);

	if (info) {
		unregister_framebuffer(info);
		fb_dealloc_cmap(&info->cmap);
		framebuffer_release(info);
	}
}

static struct platform_driver subleqfb_driver = {
	.probe  = subleqfb_probe,
	.remove = subleqfb_remove,
	.driver = {
		.name = "subleqfb",
	},
};

static struct platform_device *subleqfb_device;

static int __init subleqfb_init(void)
{
	int ret;

	pr_info("subleq_fb: initializing\n");

	ret = platform_driver_register(&subleqfb_driver);
	if (ret)
		return ret;

	subleqfb_device = platform_device_alloc("subleqfb", 0);
	if (!subleqfb_device) {
		platform_driver_unregister(&subleqfb_driver);
		return -ENOMEM;
	}

	ret = platform_device_add(subleqfb_device);
	if (ret) {
		platform_device_put(subleqfb_device);
		platform_driver_unregister(&subleqfb_driver);
		return ret;
	}

	return 0;
}

static void __exit subleqfb_exit(void)
{
	platform_device_unregister(subleqfb_device);
	platform_driver_unregister(&subleqfb_driver);
}

/* Use device_initcall for earlier initialization, before fbcon */
device_initcall(subleqfb_init);
module_exit(subleqfb_exit);

MODULE_DESCRIPTION("Subleq Virtual Machine Framebuffer Driver");
MODULE_LICENSE("GPL");


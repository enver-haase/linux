/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Subleq framebuffer constants - shared between setup.c and subleqfb.c
 *
 * These must be kept in sync: setup.c reserves the memory region, and
 * subleqfb.c maps it as the display framebuffer.
 */

#ifndef _ASM_SUBLEQ_SUBLEQ_FB_H
#define _ASM_SUBLEQ_SUBLEQ_FB_H

/* The framebuffer is exactly DOOM s native resolution, which is also the machine s: the guest
 * renders one pixel per pixel and the HOST scales the result to the window (see WIN_W/WIN_H in
 * lunatix src/vm.h). It used to be 800x512, which forced the DOOM backend to 2x-double its
 * 320x200 frame and centre it in a black border -- 256000 pixel writes per frame of pure
 * presentation work, on a CPU that spends four instructions on a word copy. Scaling is the
 * host s job; it has a GPU for it. */
#define SUBLEQ_FB_WIDTH       320
#define SUBLEQ_FB_HEIGHT      200
#define SUBLEQ_FB_BPP         32      /* XRGB8888: 32-bit per pixel */
#define SUBLEQ_FB_PIXELS      (SUBLEQ_FB_WIDTH * SUBLEQ_FB_HEIGHT * (SUBLEQ_FB_BPP / 8))
/* The reservation is rounded up to a whole page, which is what makes SUBLEQ_FB_ADDR land on a
 * page boundary. It has to: the region is memblock-reserved and then mmapped into userspace by
 * the fb driver, so a base halfway into a page both breaks the mapping and leaves the other
 * half of that page inside the reservation while the allocator still considers it free.
 * 800x512x4 was page-aligned by luck; 320x200x4 is 256000 bytes and is not, and the result was
 * a guest that died in a different place on every boot. */
#define SUBLEQ_FB_SIZE        ((SUBLEQ_FB_PIXELS + 4095) & ~4095UL)
#define SUBLEQ_FB_ADDR        (0x60000000UL - SUBLEQ_FB_SIZE)

#endif /* _ASM_SUBLEQ_SUBLEQ_FB_H */

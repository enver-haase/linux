/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Host-file (WAD) MMIO access helpers callable from C (lunatix / Vaadoom VM).
 *
 * The VM can hold a file supplied by its host — in Vaadoom the IWAD the browser
 * fetched — and copy slices of it straight into guest RAM. That is what lets a
 * SUBLEQ machine "load" a 4 MB WAD at all: the host does the copying at native
 * speed, the guest only programs four registers and reads two back.
 *
 * The registers are ordinary zero-page words (asm/subleq-regs.h, MMIO_HF_*), in
 * the free gap above the sound card. Like the sound card they are WRITTEN with
 * the raw-.word idiom, because the VM intercepts the destination operand and
 * takes the instruction's SOURCE operand as the payload — something a C store
 * cannot express (the compiler would emit a zero-then-subtract pair, and the
 * device would see both halves).
 *
 * The two READ registers need no such trick in principle (the VM refreshes the
 * cell before the load), but they are done here too so that exactly one subleq
 * instruction names the register — no reload, no reordering, no surprises from
 * the code generator.
 *
 * ESI ABI: arg1 = R21, return value = R20, return address = RA. Modelled on
 * subleq-sound.S / subleq-cr.S.
 */

#include <asm/subleq-regs.h>

	.text

/*
 * void subleq_hf_set_sel(unsigned long sel)
 *
 * Select the stream the following registers act on: 0 = the file's bytes,
 * 1 = the file name the host suggests (which tells fbdoom's IdentifyVersion
 * which game this WAD is).
 */
	.globl subleq_hf_set_sel
	.type subleq_hf_set_sel, @function
subleq_hf_set_sel:
	.word	REG_R21, MMIO_HF_SEL, .+4	/* HF_SEL := mem[R21] (arg1)            */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA       */
	.size	subleq_hf_set_sel, . - subleq_hf_set_sel

/*
 * void subleq_hf_set_dest(unsigned long phys_word_index)
 *
 * Where the next transfer lands: a physical WORD index (__pa(buf) >> 2).
 */
	.globl subleq_hf_set_dest
	.type subleq_hf_set_dest, @function
subleq_hf_set_dest:
	.word	REG_R21, MMIO_HF_DEST, .+4	/* HF_DEST := mem[R21] (arg1)           */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA       */
	.size	subleq_hf_set_dest, . - subleq_hf_set_dest

/*
 * void subleq_hf_set_off(unsigned long byte_offset)
 *
 * Byte offset within the selected stream for the next transfer.
 */
	.globl subleq_hf_set_off
	.type subleq_hf_set_off, @function
subleq_hf_set_off:
	.word	REG_R21, MMIO_HF_OFF, .+4	/* HF_OFF := mem[R21] (arg1)            */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA       */
	.size	subleq_hf_set_off, . - subleq_hf_set_off

/*
 * void subleq_hf_transfer(unsigned long bytes)
 *
 * The doorbell: writing the length performs the copy [off, off+bytes) -> dest.
 * The host clamps it to the stream and to guest RAM; read subleq_hf_get_done()
 * for the number of bytes actually written (-1 on a rejected request).
 */
	.globl subleq_hf_transfer
	.type subleq_hf_transfer, @function
subleq_hf_transfer:
	.word	REG_R21, MMIO_HF_LEN, .+4	/* HF_LEN := mem[R21] -> transfer runs  */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA       */
	.size	subleq_hf_transfer, . - subleq_hf_transfer

/*
 * unsigned long subleq_hf_get_size(void)
 *
 * Size of the selected stream in bytes; 0 when the host supplied no file (in
 * which case the guest keeps using the WAD baked into the boot image).
 */
	.globl subleq_hf_get_size
	.type subleq_hf_get_size, @function
subleq_hf_get_size:
	.word	REG_T0, REG_T0, .+4		/* T0 = 0                               */
	.word	MMIO_HF_SIZE, REG_T0, .+4	/* T0 -= HF_SIZE  (sourcing it refreshes
						 * the cell, like the RTC at word 64)   */
	.word	REG_R20, REG_R20, .+4		/* R20 = 0                              */
	.word	REG_T0, REG_R20, .+4		/* R20 -= T0  =>  R20 = size            */
	.word	REG_T1, REG_T1, REG_RA | INDIRECT /* return: T1=0 (branch) -> *RA       */
	.size	subleq_hf_get_size, . - subleq_hf_get_size

/*
 * long subleq_hf_get_done(void)
 *
 * Bytes copied by the last subleq_hf_transfer(), or -1 if the request was out
 * of range.
 */
	.globl subleq_hf_get_done
	.type subleq_hf_get_done, @function
subleq_hf_get_done:
	.word	REG_T0, REG_T0, .+4		/* T0 = 0                               */
	.word	MMIO_HF_DONE, REG_T0, .+4	/* T0 -= HF_DONE (refreshed on source)  */
	.word	REG_R20, REG_R20, .+4		/* R20 = 0                              */
	.word	REG_T0, REG_R20, .+4		/* R20 -= T0  =>  R20 = done            */
	.word	REG_T1, REG_T1, REG_RA | INDIRECT /* return: T1=0 (branch) -> *RA       */
	.size	subleq_hf_get_done, . - subleq_hf_get_done

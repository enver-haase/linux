/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Sound-card MMIO access helpers callable from C (lunatix VM).
 *
 * The lunatix VM exposes a host-side OPL3 + PCM sound card through five MMIO
 * registers at negative effective WORD indices (src/vm.c is_audio_reg /
 * audio_reg_write). Like the control registers, such a register cannot be
 * reached by a C store: the VM intercepts an operand naming a negative index
 * before the normal subtract and takes the instruction's SOURCE operand as the
 * write payload. So each access is one raw .word subleq instruction.
 *
 * Register-write idiom (arg1 arrives in R21 per the ESI calling convention):
 *   .word REG_R21, <MMIO_reg>, .+4   -> device_reg := mem[R21]
 * followed by the standard return: self-zero a scratch temp so the subleq
 * branches, targeting *RA.
 *
 * These are supervisor-only, which is satisfied because all kernel code runs in
 * supervisor mode. Modelled on subleq-cr.S; built for both NOMMU and MMU
 * (obj-y) because the sound card is present in either configuration.
 *
 * See docs/sound-handoff-linux.md (Layer 2) and asm/subleq-regs.h.
 */

#include <asm/subleq-regs.h>

	.text

/*
 * void subleq_opl_write(unsigned long packed)
 *
 * Write one OPL3 register: packed = (reg << 8) | val, reg = 9-bit address
 * (bit 8 selects the 2nd bank), val = data byte. The VM forwards it to the
 * Nuked-OPL3 core. Used by the music (FM) path.
 */
	.globl subleq_opl_write
	.type subleq_opl_write, @function
subleq_opl_write:
	.word	REG_R21, MMIO_OPL, .+4		/* OPL := mem[R21] (arg1)               */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA        */
	.size	subleq_opl_write, . - subleq_opl_write

/*
 * void subleq_pcm_set_rate(unsigned long hz)
 *
 * Set the PCM stream sample rate in Hz. Program this BEFORE arming the ring
 * with subleq_pcm_set_base().
 */
	.globl subleq_pcm_set_rate
	.type subleq_pcm_set_rate, @function
subleq_pcm_set_rate:
	.word	REG_R21, MMIO_PCM_RATE, .+4	/* PCM_RATE := mem[R21] (arg1)          */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA        */
	.size	subleq_pcm_set_rate, . - subleq_pcm_set_rate

/*
 * void subleq_pcm_set_frames(unsigned long frames)
 *
 * Set the PCM ring capacity in stereo frames. Program BEFORE arming the base.
 */
	.globl subleq_pcm_set_frames
	.type subleq_pcm_set_frames, @function
subleq_pcm_set_frames:
	.word	REG_R21, MMIO_PCM_FRAMES, .+4	/* PCM_FRAMES := mem[R21] (arg1)        */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA        */
	.size	subleq_pcm_set_frames, . - subleq_pcm_set_frames

/*
 * void subleq_pcm_set_base(unsigned long phys_word_index)
 *
 * Arm (or disarm, if 0) the PCM ring by telling the VM its physical WORD index
 * (__pa(ring) >> 2). Program rate and frames FIRST; set the base LAST so the
 * host never drains a half-configured ring.
 */
	.globl subleq_pcm_set_base
	.type subleq_pcm_set_base, @function
subleq_pcm_set_base:
	.word	REG_R21, MMIO_PCM_BASE, .+4	/* PCM_BASE := mem[R21] (arg1)          */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA        */
	.size	subleq_pcm_set_base, . - subleq_pcm_set_base

/*
 * void subleq_pcm_set_write(unsigned long total_frames)
 *
 * Publish the producer counter: the total number of stereo frames the driver
 * has enqueued into the ring so far. The host drains [pcm_read, pcm_write).
 */
	.globl subleq_pcm_set_write
	.type subleq_pcm_set_write, @function
subleq_pcm_set_write:
	.word	REG_R21, MMIO_PCM_WRITE, .+4	/* PCM_WRITE := mem[R21] (arg1)         */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA        */
	.size	subleq_pcm_set_write, . - subleq_pcm_set_write

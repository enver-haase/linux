/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Subleq register and architecture constants for assembly code
 *
 * Shared definitions used by all .S files. Include with:
 *   #include <asm/subleq-regs.h>
 */

#ifndef _ASM_SUBLEQ_REGS_H
#define _ASM_SUBLEQ_REGS_H

/* Interrupt control addresses (VM contract - NOT part of the register file,
 * never relocated). */
.set INT_HANDLER, 0
.set INT_SAVED_PC, 4
.set INT_SAVED_HANDLER, 8

/*
 * ESI register-file base, in BYTES. MUST match the toolchain's SUBLEQ_REG_BASE
 * (words) -> REG_BASE = SUBLEQ_REG_BASE * 4, and tools/make_boot_image.py.
 *   0    = cable's stock ABI (register file in page 0).
 *   4096 = register file relocated to page 1 so page 0 stays reserved for the
 *          VM I/O / interrupt vectors / kernel scratch (MMU: NULL guard + vector
 *          protection). The kernel scratch cells (INT_Z..SYSCALL_SCRATCH, words
 *          56-63, in entry.S) and the clock stay in page 0 and are NOT relocated.
 */
.set REG_BASE, 4096

/* Core registers */
.set REG_Z, REG_BASE + 12
.set REG_SP, REG_BASE + 16
.set REG_RA, REG_BASE + 20

/* General purpose registers R3-R31 */
.set REG_R3, REG_BASE + 28
.set REG_R4, REG_BASE + 32
.set REG_R5, REG_BASE + 36
.set REG_R6, REG_BASE + 40
.set REG_R7, REG_BASE + 44
.set REG_R8, REG_BASE + 48
.set REG_R9, REG_BASE + 52
.set REG_R10, REG_BASE + 56
.set REG_R11, REG_BASE + 60
.set REG_R12, REG_BASE + 64
.set REG_R13, REG_BASE + 68
.set REG_R14, REG_BASE + 72
.set REG_R15, REG_BASE + 76
.set REG_R16, REG_BASE + 80
.set REG_R17, REG_BASE + 84
.set REG_R18, REG_BASE + 88
.set REG_R19, REG_BASE + 92
.set REG_R20, REG_BASE + 96
.set REG_R21, REG_BASE + 100
.set REG_R22, REG_BASE + 104
.set REG_R23, REG_BASE + 108
.set REG_R24, REG_BASE + 112
.set REG_R25, REG_BASE + 116
.set REG_R26, REG_BASE + 120
.set REG_R27, REG_BASE + 124
.set REG_R28, REG_BASE + 128
.set REG_R29, REG_BASE + 132
.set REG_R30, REG_BASE + 136
.set REG_R31, REG_BASE + 140

/*
 * THE ABI INVARIANT THAT IS EASIEST TO BREAK: Z IS ZERO ON ENTRY TO A FUNCTION.
 *
 * Not a convention anyone has to remember to follow -- a call IS the instruction that establishes
 * it: "subleq Z, Z, target" zeroes Z and jumps, and a return does the same through RA. The
 * compiler depends on it (SubleqAsmPrinter: "Z is guaranteed clear at function entry") and elides
 * Z-clears accordingly, because Z is the cell every generated store goes through:
 *
 *      Z   -= src      ; Z = -value
 *      dst -= dst      ; dst = 0
 *      dst -= Z        ; dst = value
 *
 * An explicit "Z -= Z" appears only where the compiler knows Z is dirty from an earlier sequence
 * in the same function. So ANY entry into user code that does not go through a call instruction --
 * and this kernel synthesises several -- must establish Z = 0 itself:
 *
 *   setup_rt_frame()   a signal handler is a call we invent, from wherever the task happened to
 *                      be, which is usually mid-sequence with a partial value in Z. Sets Z = 0.
 *                      Before it did: a task spinning on a volatile flag received counter + signum
 *                      in that flag, because the loop had left -counter in Z.
 *   start_thread()     memsets pt_regs, so Z = 0 comes for free. Keep it that way.
 *   ret_from_fork      resumes mid-function with the parent's context: inheriting Z is CORRECT
 *                      here, and zeroing it would be the bug.
 *   rt_sigreturn       restores Z from the sigcontext so the interrupted sequence can finish.
 *
 * The same applies to the other cells below: ZERO must contain zero, and under MMU the register
 * file is a user-accessible page, so nothing faults if a guest writes to it -- it just breaks.
 */

/* Read-only zero constant */
.set ZERO, REG_BASE + 144

/* Frame pointer */
.set REG_FP, REG_BASE + 148

/* Temporary registers T0-T15 */
.set REG_T0, REG_BASE + 160
.set REG_T1, REG_BASE + 164
.set REG_T2, REG_BASE + 168
.set REG_T3, REG_BASE + 172
.set REG_T4, REG_BASE + 176
.set REG_T5, REG_BASE + 180
.set REG_T6, REG_BASE + 184
.set REG_T7, REG_BASE + 188
.set REG_T8, REG_BASE + 192
.set REG_T9, REG_BASE + 196
.set REG_T10, REG_BASE + 200
.set REG_T11, REG_BASE + 204
.set REG_T12, REG_BASE + 208
.set REG_T13, REG_BASE + 212
.set REG_T14, REG_BASE + 216
.set REG_T15, REG_BASE + 220

/* Indirect addressing flag (OR'd with register address) */
.set INDIRECT, 1

/* Thread size = 16KB. Decoupled from PAGE_SIZE by THREAD_SIZE_ORDER 2 (asm/page.h is
 * now PAGE_SHIFT=12); must match asm/thread_info.h THREAD_SIZE. */
.set THREAD_SIZE, 16384

/*
 * Privileged control registers (lunatix VM). Named by an operand whose effective WORD
 * index is negative (src/vm.c is_cr, CR_BASE..CR_FAULT_ACC = -16..-24); as .word
 * operands they are BYTE addresses = word_index * 4. Supervisor-only.
 *   write CR:  .word <src>, <CR>, <next>    -> CR := mem[src]
 *   read  CR:  .word <CR>, <dst>, <next>    -> mem[dst] -= CR
 *   RTE:       .word <any>, CR_RTE, <next>  -> return-from-trap (enter user @ CR_SAVED_PC)
 */
.set CR_BASE,       -64   /* word -16 */
.set CR_LIMIT,      -68   /* word -17 */
.set CR_VECTOR,     -72   /* word -18 : trap handler (physical word index)         */
.set CR_SAVED_PC,   -76   /* word -19 : restart PC saved on trap                   */
.set CR_CAUSE,      -80   /* word -20 : FAULT_BOUNDS=1 / FAULT_PAGE=2 / TIMER=0     */
.set CR_FAULT_ADDR, -84   /* word -21 : faulting vaddr (word index)                */
.set CR_RTE,        -88   /* word -22 : write = return-from-trap                   */
.set CR_PTB,        -92   /* word -23 : page-table base (physical word idx); 0=off */
.set CR_FAULT_ACC,  -96   /* word -24 : access type of last fault (R/W/X)          */
.set CR_KPTB,      -100   /* word -25 : kernel page-table base (vmalloc window)    */
.set CR_SYSGATE,   -104   /* word -26 : user syscall-gate vaddr (word idx); 0=off  */
.set CR_QUANTUM,   -108   /* word -27 : user-mode timeslice in MICROSECONDS; 0=off *
                           * The cable timer (m[0]/m[1]) is delivered in supervisor *
                           * mode only, so a user task that neither syscalls nor    *
                           * faults could never be preempted. Programming this makes*
                           * the VM deliver CAUSE_TIMER through CR_VECTOR once a    *
                           * task has run this long without trapping.               */

/*
 * Sound-card MMIO registers (lunatix VM) — RELOCATED (toolchain-cleanup §8 Phase 2) from
 * the old negative sentinels (words -27..-31) to POSITIVE zero-page words 67-71 (bytes
 * 268-284): the free gap just ABOVE the clock (words 64-66) and below the register file /
 * kernel text. This makes the soundcard an OPTIONAL device — a VM WITHOUT it (stock
 * CableVM, no bounds checking) treats a write as a harmless in-array store to a reserved
 * cell nobody reads, so ONE cable-NOMMU image runs silently there and with sound on lunavm.
 * As .word operands these are BYTE addresses = word_index * 4. Supervisor-only, WRITE-only
 * (the VM takes the instruction's SOURCE operand as the payload and ignores the device dest):
 *   write reg: .word <src>, <MMIO_*>, <next>   -> device_reg := mem[src]
 * These words are NOT relocated by REG_BASE (identical in NOMMU and MMU); they are chosen to
 * clear the register file (NOMMU words 3-55), kernel scratch (56-63) and clock (64-66).
 * See arch/subleq/kernel/subleq-sound.S and docs/sound-handoff-linux.md.
 */
.set MMIO_OPL,        268  /* word 67 : packed (reg<<8)|val -> OPL3 chip            */
.set MMIO_PCM_BASE,   272  /* word 68 : PCM ring physical WORD index (0 = off)      */
.set MMIO_PCM_FRAMES, 276  /* word 69 : PCM ring capacity in stereo frames          */
.set MMIO_PCM_WRITE,  280  /* word 70 : PCM producer counter (frames enqueued)      */
.set MMIO_PCM_RATE,   284  /* word 71 : PCM sample rate in Hz                       */

#endif /* _ASM_SUBLEQ_REGS_H */

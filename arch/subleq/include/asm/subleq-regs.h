/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Subleq register and architecture constants for assembly code
 *
 * Shared definitions used by all .S files. Include with:
 *   #include <asm/subleq-regs.h>
 */

#ifndef _ASM_SUBLEQ_REGS_H
#define _ASM_SUBLEQ_REGS_H

/* Interrupt control addresses */
.set INT_HANDLER, 0
.set INT_SAVED_PC, 4
.set INT_SAVED_HANDLER, 8

/* Core registers */
.set REG_Z, 12
.set REG_SP, 16
.set REG_RA, 20

/* General purpose registers R3-R31 */
.set REG_R3, 28
.set REG_R4, 32
.set REG_R5, 36
.set REG_R6, 40
.set REG_R7, 44
.set REG_R8, 48
.set REG_R9, 52
.set REG_R10, 56
.set REG_R11, 60
.set REG_R12, 64
.set REG_R13, 68
.set REG_R14, 72
.set REG_R15, 76
.set REG_R16, 80
.set REG_R17, 84
.set REG_R18, 88
.set REG_R19, 92
.set REG_R20, 96
.set REG_R21, 100
.set REG_R22, 104
.set REG_R23, 108
.set REG_R24, 112
.set REG_R25, 116
.set REG_R26, 120
.set REG_R27, 124
.set REG_R28, 128
.set REG_R29, 132
.set REG_R30, 136
.set REG_R31, 140

/* Read-only zero constant */
.set ZERO, 144

/* Frame pointer */
.set REG_FP, 148

/* Temporary registers T0-T15 */
.set REG_T0, 160
.set REG_T1, 164
.set REG_T2, 168
.set REG_T3, 172
.set REG_T4, 176
.set REG_T5, 180
.set REG_T6, 184
.set REG_T7, 188
.set REG_T8, 192
.set REG_T9, 196
.set REG_T10, 200
.set REG_T11, 204
.set REG_T12, 208
.set REG_T13, 212
.set REG_T14, 216
.set REG_T15, 220

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

#endif /* _ASM_SUBLEQ_REGS_H */

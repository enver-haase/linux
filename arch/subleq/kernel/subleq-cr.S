/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Control-register access helpers callable from C (lunatix VM).
 *
 * The subleq machine has no hardware registers; the ESI ABI designates fixed low
 * memory words as a register file (asm/subleq-regs.h): arg1 = R21, return value = R20,
 * return address = RA. A control register is named by an operand whose effective WORD
 * index is negative, and the VM's CR-write path (src/vm.c is_cr) intercepts before the
 * normal subtract — so this cannot be expressed as a C store and must be raw .word asm.
 *
 * Unconditional-jump idiom: `subleq Tn, Tn, target` — Tn -= Tn = 0 <= 0 always branches,
 * and Tn is caller-saved scratch, so self-zeroing it is harmless.
 *
 * See docs/mmu-port-plan.md step 5.
 */

#include <asm/subleq-regs.h>

	.text

/*
 * void subleq_load_ptb(unsigned long ptb_word_index)
 *
 * Set CR_PTB (the user page-table base, a physical word index; 0 = paging off).
 * Called from switch_mm(). Runs in supervisor mode (all kernel code does), which is
 * required for the CR write to be honored.
 */
	.globl subleq_load_ptb
	.type subleq_load_ptb, @function
subleq_load_ptb:
	.word	REG_R21, CR_PTB, .+4		/* CR_PTB := mem[R21] (arg1)            */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA        */
	.size	subleq_load_ptb, . - subleq_load_ptb

/*
 * void subleq_set_vector(unsigned long vector_word_index)
 *
 * Set CR_VECTOR (the trap/fault handler entry, a physical word index). Called once
 * during MMU bring-up with __pa(subleq_fault_entry) >> 2.
 */
	.globl subleq_set_vector
	.type subleq_set_vector, @function
subleq_set_vector:
	.word	REG_R21, CR_VECTOR, .+4		/* CR_VECTOR := mem[R21] (arg1)         */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA        */
	.size	subleq_set_vector, . - subleq_set_vector

/*
 * void subleq_set_sysgate(unsigned long gate_word_index)
 *
 * Set CR_SYSGATE (the user syscall-gate vaddr, a word index; 0 = disabled). When a user
 * program's pc reaches this vaddr the VM raises CAUSE_SYSCALL. Installed once userspace
 * uses the trap-based syscall ABI.
 */
	.globl subleq_set_sysgate
	.type subleq_set_sysgate, @function
subleq_set_sysgate:
	.word	REG_R21, CR_SYSGATE, .+4	/* CR_SYSGATE := mem[R21] (arg1)        */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA        */
	.size	subleq_set_sysgate, . - subleq_set_sysgate

/*
 * void subleq_set_kptb(unsigned long kptb_word_index)
 *
 * Set CR_KPTB (the kernel page-table base for the vmalloc window, a physical word
 * index; 0 = supervisor stays fully identity). Called once during MMU bring-up with
 * __pa(swapper_pg_dir) >> 2.
 */
	.globl subleq_set_kptb
	.type subleq_set_kptb, @function
subleq_set_kptb:
	.word	REG_R21, CR_KPTB, .+4		/* CR_KPTB := mem[R21] (arg1)           */
	.word	REG_T0, REG_T0, REG_RA | INDIRECT /* return: T0=0 (branch) -> *RA        */
	.size	subleq_set_kptb, . - subleq_set_kptb

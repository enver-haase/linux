/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _ASM_SUBLEQ_TRAPS_H
#define _ASM_SUBLEQ_TRAPS_H

#include <linux/linkage.h>

struct pt_regs;

/*
 * Called from kernel/entry.S's fault vector (step 7) with the VM's fault info:
 *   addr   = faulting virtual BYTE address (CR_FAULT_ADDR word index * 4)
 *   cause  = FAULT_BOUNDS(1) / FAULT_PAGE(2)
 *   access = 0 read / 1 write / 2 exec (CR_FAULT_ACC)
 */
asmlinkage void do_page_fault(struct pt_regs *regs, unsigned long addr,
			      unsigned long cause, unsigned long access);

/* Single CR_VECTOR entry from entry.S; dispatches syscall vs page fault. */
asmlinkage void subleq_trap(struct pt_regs *regs, unsigned long addr,
			    unsigned long cause, unsigned long access);

struct mm_struct;
/* Identity-map user page 0 -> physical page 0 (register file) for the syscall ABI. */
void subleq_map_page0(struct mm_struct *mm);

#endif /* _ASM_SUBLEQ_TRAPS_H */

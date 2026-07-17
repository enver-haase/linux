/* SPDX-License-Identifier: GPL-2.0 */
/*
 * MMU context for Subleq
 *
 * NOMMU - context switch is trivial.
 */

#ifndef _ASM_SUBLEQ_MMU_CONTEXT_H
#define _ASM_SUBLEQ_MMU_CONTEXT_H

#include <asm/mmu.h>
#include <asm-generic/mm_hooks.h>
#ifdef CONFIG_MMU
#include <asm/page.h>
#include <asm/subleq-cr.h>
#endif

static inline int init_new_context(struct task_struct *tsk,
				   struct mm_struct *mm)
{
	return 0;
}

static inline void destroy_context(struct mm_struct *mm)
{
}

static inline void switch_mm(struct mm_struct *prev, struct mm_struct *next,
			     struct task_struct *tsk)
{
#ifdef CONFIG_MMU
	/*
	 * Load the next mm's page-table base into CR_PTB (physical word index).
	 * Kernel code runs in supervisor mode, which is identity-mapped and ignores
	 * CR_PTB, so this only takes effect once we drop to user mode. There is no
	 * TLB, so no flush is needed (the VM re-walks every access).
	 */
	if (prev != next && next->pgd)
		subleq_load_ptb(__pa(next->pgd) >> 2);
#endif
}

#define activate_mm(prev, next) switch_mm((prev), (next), NULL)
#define deactivate_mm(tsk, mm) \
	do {                   \
	} while (0)
#define enter_lazy_tlb(mm, tsk) \
	do {                    \
	} while (0)

#endif /* _ASM_SUBLEQ_MMU_CONTEXT_H */

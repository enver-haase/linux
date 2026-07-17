/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Page table allocation for Subleq.
 *
 * CONFIG_MMU=n : no page tables (unchanged).
 * CONFIG_MMU=y : 2-level allocation. The L1 (pmd, folded onto pgd) entry stores the
 *                L2 table's physical WORD index (__pa(pte) >> 2, no flag bits) to match
 *                the VM walk (src/vm.c). See docs/mmu-port-plan.md.
 */

#ifndef _ASM_SUBLEQ_PGALLOC_H
#define _ASM_SUBLEQ_PGALLOC_H

#ifdef CONFIG_MMU

#include <linux/mm.h>
#include <asm-generic/pgalloc.h>

static inline void pmd_populate_kernel(struct mm_struct *mm, pmd_t *pmd,
				       pte_t *pte)
{
	set_pmd(pmd, __pmd(__pa(pte) >> 2));
}

static inline void pmd_populate(struct mm_struct *mm, pmd_t *pmd,
				pgtable_t pte)
{
	set_pmd(pmd, __pmd(__pa(page_address(pte)) >> 2));
}

static inline pgd_t *pgd_alloc(struct mm_struct *mm)
{
	/* Kernel is identity-mapped (super mode ignores CR_PTB), so a user pgd needs
	 * no kernel entries pre-populated — a zeroed page suffices. */
	return __pgd_alloc(mm, 0);
}

#define __pte_free_tlb(tlb, pte, addr) \
	tlb_remove_ptdesc((tlb), page_ptdesc(pte))

#endif /* CONFIG_MMU */

#endif /* _ASM_SUBLEQ_PGALLOC_H */

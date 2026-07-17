/* SPDX-License-Identifier: GPL-2.0 */
/*
 * TLB flushing for Subleq.
 *
 * The lunatix VM has no software TLB: translate() (src/vm.c) re-walks the page
 * table on every user access, so a PTE or CR_PTB change is visible immediately and
 * every TLB-flush operation is a no-op. Kept as typed inlines for the generic mm
 * callers. See docs/mmu-port-plan.md.
 */

#ifndef _ASM_SUBLEQ_TLBFLUSH_H
#define _ASM_SUBLEQ_TLBFLUSH_H

#include <linux/mm_types.h>

static inline void flush_tlb_all(void) { }
static inline void flush_tlb_mm(struct mm_struct *mm) { }
static inline void flush_tlb_range(struct vm_area_struct *vma,
				   unsigned long start, unsigned long end) { }
static inline void flush_tlb_page(struct vm_area_struct *vma,
				  unsigned long addr) { }
static inline void flush_tlb_kernel_range(unsigned long start,
					  unsigned long end) { }

#endif /* _ASM_SUBLEQ_TLBFLUSH_H */

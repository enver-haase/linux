/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Page definitions for Subleq architecture
 *
 * Subleq has no MMU, so physical == virtual addresses.
 */

#ifndef _ASM_SUBLEQ_PAGE_H
#define _ASM_SUBLEQ_PAGE_H

#include <linux/const.h>

/*
 * 4KB pages: matches the lunatix VM MMU (4KB / 1024-word, 2-level sv32-shaped page
 * tables; src/vm.c PAGE_SHIFT_W 10). cable's stock NOMMU used 16KB (PAGE_SHIFT 14) to
 * reduce struct-page count / speed contiguous ELF loads; the MMU port needs 12. This is
 * the riskiest NOMMU-visible change (docs/mmu-port-plan.md step 1) — validated by a
 * NOMMU regression boot in isolation before any other MMU change.
 */
#define PAGE_SHIFT 12
#define PAGE_SIZE (_AC(1, UL) << PAGE_SHIFT)
#define PAGE_MASK (~(PAGE_SIZE - 1))

#ifndef __ASSEMBLY__

#include <linux/pfn.h>
#include <linux/string.h>

/*
 * NOMMU: Physical addresses == Virtual addresses
 * No translation needed.
 */
#define __pa(x) ((unsigned long)(x))
#define __va(x) ((void *)((unsigned long)(x)))

#define virt_to_pfn(x) (((unsigned long)(x)) >> PAGE_SHIFT)
#define pfn_to_virt(pfn) ((void *)((pfn) << PAGE_SHIFT))

#define virt_to_page(addr) pfn_to_page(virt_to_pfn(addr))
#define page_to_virt(page) pfn_to_virt(page_to_pfn(page))

#define pfn_valid(pfn) ((pfn) < max_mapnr)

#define virt_addr_valid(addr) pfn_valid(virt_to_pfn(addr))

/* Page clearing and copying - use memset/memcpy */
#define clear_page(page) memset((page), 0, PAGE_SIZE)
#define copy_page(to, from) memcpy((to), (from), PAGE_SIZE)

#define clear_user_page(page, vaddr, pg) clear_page(page)
#define copy_user_page(to, from, vaddr, pg) copy_page(to, from)

/* VM data default flags */
#define VM_DATA_DEFAULT_FLAGS VM_DATA_FLAGS_NON_EXEC

/*
 * Page table entry types for NOMMU - minimal definitions
 * These are effectively unused but needed for kernel compilation
 */
typedef struct {
	unsigned long pte;
} pte_t;
typedef struct {
	unsigned long pgd;
} pgd_t;
typedef struct {
	unsigned long pgprot;
} pgprot_t;

#define pte_val(x) ((x).pte)
#define pgd_val(x) ((x).pgd)
#define pgprot_val(x) ((x).pgprot)

#define __pte(x) ((pte_t){ (x) })
#define __pgd(x) ((pgd_t){ (x) })
#define __pgprot(x) ((pgprot_t){ (x) })

/* Page table pointer type */
typedef pte_t *pgtable_t;

#endif /* !__ASSEMBLY__ */

/* Memory layout - no MMU, flat addressing */
#define PAGE_OFFSET 0UL
#define PHYS_OFFSET 0UL

#include <asm-generic/memory_model.h>
#include <asm-generic/getorder.h>

#endif /* _ASM_SUBLEQ_PAGE_H */

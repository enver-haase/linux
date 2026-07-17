/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Page table definitions for Subleq.
 *
 * Two regimes selected by CONFIG_MMU:
 *  - CONFIG_MMU=n : cable's stock flat NOMMU (no page tables) — unchanged.
 *  - CONFIG_MMU=y : real 2-level (sv32-shaped) tables matching the lunatix VM MMU
 *                   (src/vm.c translate()): 4KB / 1024-word pages, 10+10+12 split.
 *                   See lunatix docs/mmu-port-plan.md.
 */

#ifndef _ASM_SUBLEQ_PGTABLE_H
#define _ASM_SUBLEQ_PGTABLE_H

#include <asm-generic/pgtable-nopud.h>
#include <asm-generic/pgtable-nopmd.h>

#ifdef CONFIG_MMU

/*
 * Geometry. wi = virtual WORD index; the VM does vpn = wi>>10, L1 = (vpn>>10)&0x3FF,
 * L2 = vpn&0x3FF. In byte terms that is PAGE_SHIFT=12, two 10-bit index levels.
 */
#define PGDIR_SHIFT	22
#define PGDIR_SIZE	(_AC(1, UL) << PGDIR_SHIFT)
#define PGDIR_MASK	(~(PGDIR_SIZE - 1))

#define PTRS_PER_PTE	1024
#define PTRS_PER_PGD	1024
#define USER_PTRS_PER_PGD	(TASK_SIZE / PGDIR_SIZE)

/*
 * Leaf PTE bits, matching the VM exactly (vm.c:146-149):
 *   bit0 = present, bit1 = writable, frame (pfn) = pte >> 4.
 * The VM ignores bits 2-3, so we use them as software ACCESSED/DIRTY. There is no
 * hardware user/exec bit: super mode is identity-mapped and only user pages are
 * translated, and any present page is readable+executable.
 */
#define _PAGE_PRESENT	(1UL << 0)
#define _PAGE_WRITE	(1UL << 1)
#define _PAGE_ACCESSED	(1UL << 2)	/* software */
#define _PAGE_DIRTY	(1UL << 3)	/* software */
#define _PAGE_PFN_SHIFT	4
#define PFN_PTE_SHIFT	_PAGE_PFN_SHIFT	/* generic set_ptes() increments pfn by this */

/* Bits preserved across pte_modify() (pfn + software state). */
#define _PAGE_CHG_MASK	(~((1UL << _PAGE_PFN_SHIFT) - 1) | _PAGE_ACCESSED | _PAGE_DIRTY)

#define _PAGE_BASE	(_PAGE_PRESENT | _PAGE_ACCESSED)

/* Protection map. No exec/user bits in HW, so read implies exec; write is the only knob. */
#define PAGE_NONE	__pgprot(0)
#define PAGE_READONLY	__pgprot(_PAGE_BASE)
#define PAGE_COPY	__pgprot(_PAGE_BASE)			/* COW: writes fault */
#define PAGE_SHARED	__pgprot(_PAGE_BASE | _PAGE_WRITE)
#define PAGE_KERNEL	__pgprot(_PAGE_BASE | _PAGE_WRITE | _PAGE_DIRTY)

/* Legacy protection arrays (this tree still references them). r=1,w=2,x=4 in the index. */
#define __P000	PAGE_NONE
#define __P001	PAGE_READONLY
#define __P010	PAGE_COPY
#define __P011	PAGE_COPY
#define __P100	PAGE_READONLY
#define __P101	PAGE_READONLY
#define __P110	PAGE_COPY
#define __P111	PAGE_COPY
#define __S000	PAGE_NONE
#define __S001	PAGE_READONLY
#define __S010	PAGE_SHARED
#define __S011	PAGE_SHARED
#define __S100	PAGE_READONLY
#define __S101	PAGE_READONLY
#define __S110	PAGE_SHARED
#define __S111	PAGE_SHARED

#ifndef __ASSEMBLY__

/* ---- PTE (leaf) helpers ------------------------------------------------- */
static inline int pte_present(pte_t pte)  { return pte_val(pte) & _PAGE_PRESENT; }
static inline int pte_none(pte_t pte)     { return pte_val(pte) == 0; }
static inline int pte_write(pte_t pte)    { return pte_val(pte) & _PAGE_WRITE; }
static inline int pte_dirty(pte_t pte)    { return pte_val(pte) & _PAGE_DIRTY; }
static inline int pte_young(pte_t pte)    { return pte_val(pte) & _PAGE_ACCESSED; }

static inline pte_t pte_wrprotect(pte_t pte) { return __pte(pte_val(pte) & ~_PAGE_WRITE); }
static inline pte_t pte_mkwrite_novma(pte_t pte) { return __pte(pte_val(pte) | _PAGE_WRITE); }
static inline pte_t pte_mkclean(pte_t pte)   { return __pte(pte_val(pte) & ~_PAGE_DIRTY); }
static inline pte_t pte_mkdirty(pte_t pte)   { return __pte(pte_val(pte) | _PAGE_DIRTY); }
static inline pte_t pte_mkold(pte_t pte)     { return __pte(pte_val(pte) & ~_PAGE_ACCESSED); }
static inline pte_t pte_mkyoung(pte_t pte)   { return __pte(pte_val(pte) | _PAGE_ACCESSED); }

#define pte_pfn(pte)		(pte_val(pte) >> _PAGE_PFN_SHIFT)
#define pfn_pte(pfn, prot)	__pte(((pfn) << _PAGE_PFN_SHIFT) | pgprot_val(prot))
/* mk_pte() is provided generically by linux/mm.h under CONFIG_MMU. */
#define pte_page(pte)		pfn_to_page(pte_pfn(pte))

static inline pte_t pte_modify(pte_t pte, pgprot_t prot)
{
	return __pte((pte_val(pte) & _PAGE_CHG_MASK) | pgprot_val(prot));
}

static inline void set_pte(pte_t *ptep, pte_t pte) { *ptep = pte; }
static inline void set_pte_at(struct mm_struct *mm, unsigned long addr,
			      pte_t *ptep, pte_t pte) { set_pte(ptep, pte); }
#define pte_clear(mm, addr, ptep)	set_pte((ptep), __pte(0))

/* ---- PMD (folded onto the L1/PGD slot) ---------------------------------- *
 * The L1 entry is a BARE physical word index of the L2 table (no flag bits),
 * 0 = absent. pmd_val() reads that word through the nopud/nopmd folding.
 */
/* nopmd folds pmd onto the pud/pgd slot but leaves set_pmd to the arch. */
static inline void set_pmd(pmd_t *pmdp, pmd_t pmd) { *pmdp = pmd; }

static inline int pmd_none(pmd_t pmd)    { return pmd_val(pmd) == 0; }
static inline int pmd_present(pmd_t pmd) { return pmd_val(pmd) != 0; }
static inline int pmd_bad(pmd_t pmd)     { return 0; }
static inline void pmd_clear(pmd_t *pmdp) { set_pmd(pmdp, __pmd(0)); }

/* L2 table phys byte addr = (word index) << 2; its pfn = word index >> (PAGE_SHIFT-2). */
static inline unsigned long pmd_page_vaddr(pmd_t pmd)
{
	return (unsigned long)__va(pmd_val(pmd) << 2);
}
#define pmd_pfn(pmd)	(pmd_val(pmd) >> (PAGE_SHIFT - 2))
#define pmd_page(pmd)	pfn_to_page(pmd_pfn(pmd))

/* ---- swap entries (bit0 clear = !present) ------------------------------- *
 * Layout of a swap PTE: bit0=0 (absent), bit1 = SWP_EXCLUSIVE, type bits 2-6,
 * offset bits 7+.
 */
#define _PAGE_SWP_EXCLUSIVE	(1UL << 1)
#define __swp_type(x)		(((x).val >> 2) & 0x1f)
#define __swp_offset(x)		((x).val >> 7)
#define __swp_entry(type, offset) \
	((swp_entry_t){ ((type) << 2) | ((offset) << 7) })
#define __pte_to_swp_entry(pte)	((swp_entry_t){ pte_val(pte) })
#define __swp_entry_to_pte(x)	((pte_t){ (x).val })

static inline int pte_swp_exclusive(pte_t pte)
{ return pte_val(pte) & _PAGE_SWP_EXCLUSIVE; }
static inline pte_t pte_swp_mkexclusive(pte_t pte)
{ return __pte(pte_val(pte) | _PAGE_SWP_EXCLUSIVE); }
static inline pte_t pte_swp_clear_exclusive(pte_t pte)
{ return __pte(pte_val(pte) & ~_PAGE_SWP_EXCLUSIVE); }

/* VM re-walks tables every access — no software TLB to prime. */
#define update_mmu_cache(vma, addr, ptep)			do { } while (0)
#define update_mmu_cache_range(vmf, vma, addr, ptep, nr)	do { } while (0)

extern pgd_t swapper_pg_dir[PTRS_PER_PGD];

/* Kernel is identity-mapped (super mode ignores CR_PTB); no vmalloc arena. */
#define VMALLOC_START	0UL
#define VMALLOC_END	0UL

#endif /* !__ASSEMBLY__ */

#else /* !CONFIG_MMU ---- cable's stock flat NOMMU (unchanged) ------------- */

/* No page tables */
#define pgd_none(pgd) (1)
#define pgd_bad(pgd) (0)
#define pgd_present(pgd) (0)
#define pgd_clear(pgdp) \
	do {            \
	} while (0)

#define pte_none(pte) (1)
#define pte_present(pte) (0)
#define pte_clear(mm, addr, ptep) \
	do {                      \
	} while (0)

#define kern_addr_valid(addr) (1)
#define pte_pfn(pte) (0)

/* Protection values - unused but needed for compilation */
#define PAGE_NONE __pgprot(0)
#define PAGE_SHARED __pgprot(0)
#define PAGE_COPY __pgprot(0)
#define PAGE_READONLY __pgprot(0)
#define PAGE_KERNEL __pgprot(0)

#define __P000 PAGE_NONE
#define __P001 PAGE_READONLY
#define __P010 PAGE_COPY
#define __P011 PAGE_COPY
#define __P100 PAGE_READONLY
#define __P101 PAGE_READONLY
#define __P110 PAGE_COPY
#define __P111 PAGE_COPY

#define __S000 PAGE_NONE
#define __S001 PAGE_READONLY
#define __S010 PAGE_SHARED
#define __S011 PAGE_SHARED
#define __S100 PAGE_READONLY
#define __S101 PAGE_READONLY
#define __S110 PAGE_SHARED
#define __S111 PAGE_SHARED

/* Stubs for NOMMU */
#define swapper_pg_dir ((pgd_t *)0)

#endif /* CONFIG_MMU */

/*
 * ZERO_PAGE - a global shared page that is always zero
 */
extern void *empty_zero_page;
#define ZERO_PAGE(vaddr) (virt_to_page(empty_zero_page))

#endif /* _ASM_SUBLEQ_PGTABLE_H */

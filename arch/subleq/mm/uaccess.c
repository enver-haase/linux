// SPDX-License-Identifier: GPL-2.0
/*
 * Software user-access for Subleq (CONFIG_MMU).
 *
 * Supervisor mode is identity-mapped and ignores CR_PTB (see docs/architecture.md),
 * so the kernel cannot dereference a user virtual address directly and cannot rely on
 * a hardware fault + __ex_table fixup. Instead we software-walk current->mm's page
 * table (mirroring src/vm.c translate()), faulting absent pages in via handle_mm_fault,
 * and copy through the physical (== kernel identity) mapping.
 *
 * See lunatix docs/mmu-port-plan.md step 8. First-cut implementation for the MMU
 * bring-up boot-debug loop.
 */

#include <linux/mm.h>
#include <linux/uaccess.h>
#include <linux/sched.h>
#include <linux/pagemap.h>
#include <linux/highmem.h>

/* Fault a single user page in. Returns 0 on success, -EFAULT otherwise. */
static int subleq_fault_in_page(unsigned long uaddr, int write)
{
	struct mm_struct *mm = current->mm;
	struct vm_area_struct *vma;
	vm_fault_t fault;
	unsigned int flags = FAULT_FLAG_USER | (write ? FAULT_FLAG_WRITE : 0);

	if (!mm)
		return -EFAULT;

	mmap_read_lock(mm);
	vma = find_vma(mm, uaddr);
	if (!vma || vma->vm_start > uaddr) {
		mmap_read_unlock(mm);
		return -EFAULT;
	}
	fault = handle_mm_fault(vma, uaddr, flags, NULL);
	mmap_read_unlock(mm);

	if (fault & (VM_FAULT_ERROR | VM_FAULT_RETRY))
		return -EFAULT;
	return 0;
}

/*
 * Translate a user byte address to a kernel (identity == physical) pointer for one
 * access, faulting the page in if necessary. Returns NULL on failure.
 */
static void *subleq_translate(unsigned long uaddr, int write)
{
	struct mm_struct *mm = current->mm;
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *ptep, pte;
	spinlock_t *ptl;
	int tried = 0;

	if (!mm || uaddr >= TASK_SIZE)
		return NULL;

retry:
	pgd = pgd_offset(mm, uaddr);
	p4d = p4d_offset(pgd, uaddr);
	pud = pud_offset(p4d, uaddr);
	pmd = pmd_offset(pud, uaddr);
	if (pmd_none(*pmd) || pmd_bad(*pmd))
		goto fault;

	ptep = pte_offset_map_lock(mm, pmd, uaddr, &ptl);
	if (!ptep)
		goto fault;
	pte = *ptep;
	pte_unmap_unlock(ptep, ptl);

	if (!pte_present(pte) || (write && !pte_write(pte)))
		goto fault;

	return __va((pte_pfn(pte) << PAGE_SHIFT) | (uaddr & ~PAGE_MASK));

fault:
	if (!tried++ && subleq_fault_in_page(uaddr, write) == 0)
		goto retry;
	return NULL;
}

/* Copy n bytes across (possibly non-contiguous) user pages. Returns # not copied. */
static unsigned long subleq_copy(void *k_to, const void *k_from,
				 unsigned long u_addr, unsigned long n, int write)
{
	while (n) {
		unsigned long off = u_addr & ~PAGE_MASK;
		unsigned long chunk = min(n, PAGE_SIZE - off);
		void *upage = subleq_translate(u_addr, write);

		if (!upage)
			return n;	/* remaining bytes not copied -> -EFAULT */

		if (write)
			memcpy(upage, k_from, chunk);
		else
			memcpy(k_to, upage, chunk);

		u_addr  += chunk;
		k_to     = (char *)k_to + chunk;
		k_from   = (const char *)k_from + chunk;
		n       -= chunk;
	}
	return 0;
}

unsigned long subleq_copy_from_user(void *to, const void __user *from, unsigned long n)
{
	return subleq_copy(to, NULL, (unsigned long)from, n, 0);
}

unsigned long subleq_copy_to_user(void __user *to, const void *from, unsigned long n)
{
	return subleq_copy(NULL, from, (unsigned long)to, n, 1);
}

unsigned long subleq_clear_user(void __user *to, unsigned long n)
{
	unsigned long u_addr = (unsigned long)to;

	while (n) {
		unsigned long off = u_addr & ~PAGE_MASK;
		unsigned long chunk = min(n, PAGE_SIZE - off);
		void *upage = subleq_translate(u_addr, 1);

		if (!upage)
			return n;
		memset(upage, 0, chunk);
		u_addr += chunk;
		n -= chunk;
	}
	return 0;
}

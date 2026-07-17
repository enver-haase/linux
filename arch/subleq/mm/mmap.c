// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq MMU: page-protection map and a few arch hooks the generic MMU/ELF code
 * requires under CONFIG_MMU. See docs/mmu-port-plan.md step 8.
 */

#include <linux/mm.h>
#include <linux/export.h>
#include <linux/elfcore.h>

/*
 * protection_map — indexed by vm_flags & (VM_SHARED|VM_EXEC|VM_WRITE|VM_READ),
 * i.e. bit0=READ, bit1=WRITE, bit2=EXEC, bit3=SHARED. The subleq VM has no
 * exec/read hardware bit (any present page is readable+executable; only write is
 * gated), so read/exec rows collapse to PAGE_READONLY. Private writable pages are
 * COW (PAGE_COPY, write-faults); shared writable pages are PAGE_SHARED.
 */
static pgprot_t protection_map[16] __ro_after_init = {
	PAGE_NONE,     PAGE_READONLY, PAGE_COPY,   PAGE_COPY,	/* private --,r,w,rw   */
	PAGE_READONLY, PAGE_READONLY, PAGE_COPY,   PAGE_COPY,	/* private x,rx,wx,rwx */
	PAGE_NONE,     PAGE_READONLY, PAGE_SHARED, PAGE_SHARED,	/* shared  --,r,w,rw   */
	PAGE_READONLY, PAGE_READONLY, PAGE_SHARED, PAGE_SHARED	/* shared  x,rx,wx,rwx */
};

pgprot_t vm_get_page_prot(vm_flags_t vm_flags)
{
	return protection_map[vm_flags &
			      (VM_READ | VM_WRITE | VM_EXEC | VM_SHARED)];
}
EXPORT_SYMBOL(vm_get_page_prot);

/* No FPU on the subleq machine — nothing to copy into an ELF core dump. */
int elf_core_copy_task_fpregs(struct task_struct *t, elf_fpregset_t *fpu)
{
	return 0;
}

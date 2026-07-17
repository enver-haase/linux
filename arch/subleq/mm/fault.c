// SPDX-License-Identifier: GPL-2.0
/*
 * Page-fault handling for Subleq (CONFIG_MMU).
 *
 * The lunatix VM delivers a precise, restartable fault: it rewinds PC to the faulting
 * instruction (CR_SAVED_PC) before vectoring to the supervisor, so a successful
 * return-from-trap (RTE) simply re-runs the instruction — this handler never adjusts a
 * return PC. Supervisor mode is identity-mapped and never faults, so every fault here
 * originates in user mode (the !user_mode paths are defensive only).
 *
 * kernel/entry.S's fault vector (step 7) reads the VM control registers and calls:
 *   do_page_fault(regs, addr, cause, access)
 *     addr   = faulting virtual BYTE address (CR_FAULT_ADDR word index * 4)
 *     cause  = FAULT_BOUNDS(1) / FAULT_PAGE(2)   (src/vm.c)
 *     access = 0 read / 1 write / 2 exec         (CR_FAULT_ACC)
 * See lunatix docs/mmu-port-plan.md.
 */

#include <linux/mm.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/interrupt.h>
#include <linux/extable.h>
#include <linux/uaccess.h>
#include <linux/perf_event.h>
#include <linux/kernel.h>
#include <asm/traps.h>

/* CR_FAULT_ACC access types (src/vm.c access_t). */
#define SUBLEQ_ACCESS_READ	0
#define SUBLEQ_ACCESS_WRITE	1
#define SUBLEQ_ACCESS_EXEC	2

asmlinkage void do_page_fault(struct pt_regs *regs, unsigned long addr,
			      unsigned long cause, unsigned long access)
{
	struct mm_struct *mm = current->mm;
	struct vm_area_struct *vma;
	unsigned int flags = FAULT_FLAG_DEFAULT;
	vm_fault_t fault;
	int code = SEGV_MAPERR;

	/* In an atomic region or no user context: can't take the fault. */
	if (faulthandler_disabled() || !mm)
		goto no_context;

	if (unlikely(!user_mode(regs)))
		goto no_context;		/* supervisor never faults here */

	if (unlikely(addr >= TASK_SIZE))
		goto bad_area_nosem;

	flags |= FAULT_FLAG_USER;
	if (access == SUBLEQ_ACCESS_WRITE)
		flags |= FAULT_FLAG_WRITE;

	perf_sw_event(PERF_COUNT_SW_PAGE_FAULTS, 1, regs, addr);

retry:
	vma = lock_mm_and_find_vma(mm, addr, regs);
	if (!vma)
		goto bad_area_nosem;

	/* Good VMA — check it permits this access. */
	code = SEGV_ACCERR;
	switch (access) {
	case SUBLEQ_ACCESS_WRITE:
		if (!(vma->vm_flags & VM_WRITE))
			goto bad_area;
		break;
	case SUBLEQ_ACCESS_EXEC:
		if (!(vma->vm_flags & VM_EXEC))
			goto bad_area;
		break;
	default: /* read */
		if (!(vma->vm_flags & (VM_READ | VM_WRITE | VM_EXEC)))
			goto bad_area;
		break;
	}

	fault = handle_mm_fault(vma, addr, flags, regs);

	if (fault_signal_pending(fault, regs)) {
		if (!user_mode(regs))
			goto no_context;
		return;
	}

	/* Fully handled (mmap lock already released). */
	if (fault & VM_FAULT_COMPLETED)
		return;

	if (unlikely(fault & VM_FAULT_ERROR)) {
		if (fault & VM_FAULT_OOM)
			goto out_of_memory;
		if (fault & VM_FAULT_SIGBUS)
			goto do_sigbus;
		if (fault & VM_FAULT_SIGSEGV)
			goto bad_area;
		BUG();
	}

	if (fault & VM_FAULT_RETRY) {
		flags |= FAULT_FLAG_TRIED;
		goto retry;	/* mmap lock already dropped by the retry path */
	}

	mmap_read_unlock(mm);
	return;

bad_area:
	mmap_read_unlock(mm);
bad_area_nosem:
	if (user_mode(regs)) {
		force_sig_fault(SIGSEGV, code, (void __user *)addr);
		return;
	}
	goto no_context;

out_of_memory:
	mmap_read_unlock(mm);
	if (!user_mode(regs))
		goto no_context;
	pagefault_out_of_memory();
	return;

do_sigbus:
	mmap_read_unlock(mm);
	if (!user_mode(regs))
		goto no_context;
	force_sig_fault(SIGBUS, BUS_ADRERR, (void __user *)addr);
	return;

no_context:
	/* Kernel fault. Supervisor is identity-mapped and never translates, so it cannot
	 * fault on a user address; reaching here is a genuine kernel bug. (uaccess will
	 * software-walk the user page table rather than fault + __ex_table fixup, so there
	 * are no fixups to try.) */
	pr_alert("subleq: unhandled kernel page fault at 0x%08lx (cause %lu, access %lu)\n",
		 addr, cause, access);
	panic("Oops: kernel page fault");
}

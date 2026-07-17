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
#include <linux/vmalloc.h>
#include <linux/linkage.h>
#include <asm/ptrace.h>
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
	pr_alert("subleq: swapper_pg_dir=%px (pa 0x%lx, kptb word 0x%lx) init_mm.pgd=%px vmalloc 0x%lx..0x%lx\n",
		 swapper_pg_dir, __pa(swapper_pg_dir), __pa(swapper_pg_dir) >> 2,
		 init_mm.pgd, (unsigned long)VMALLOC_START, (unsigned long)VMALLOC_END);
	panic("Oops: kernel page fault");
}

/*
 * subleq_trap — the single C entry from kernel/entry.S's CR_VECTOR handler.
 * Dispatches on the VM trap cause: a user syscall-gate trap (CAUSE_SYSCALL) vs a page
 * fault. Keeping the dispatch in C keeps the hand-written asm entry minimal.
 *
 * Syscall ABI (ESI): nr = R21, args a1..a6 = R22..R27. __subleq_syscall_c does the
 * sys_call_table dispatch + signal/restart and writes the result to pt_regs->r20.
 * We then resume the user after the gate call, at its return address (RA), by
 * overwriting the RTE target subleq_fault_saved_pc (word index).
 */
#define SUBLEQ_CAUSE_SYSCALL 3	/* must match src/vm.c CAUSE_SYSCALL */

extern asmlinkage long __subleq_syscall_c(long nr, long a1, long a2, long a3,
					  long a4, long a5, long a6);
extern unsigned long subleq_fault_saved_pc;	/* kernel/entry.S */

asmlinkage void subleq_trap(struct pt_regs *regs, unsigned long addr,
			    unsigned long cause, unsigned long access)
{
	if (cause == SUBLEQ_CAUSE_SYSCALL) {
		__subleq_syscall_c(PT_REG_GET(regs, r21), PT_REG_GET(regs, r22),
				   PT_REG_GET(regs, r23), PT_REG_GET(regs, r24),
				   PT_REG_GET(regs, r25), PT_REG_GET(regs, r26),
				   PT_REG_GET(regs, r27));
		/* Resume in user mode at the instruction after the gate call. */
		subleq_fault_saved_pc = PT_REG_GET(regs, ra) >> 2;
		return;
	}
	do_page_fault(regs, addr, cause, access);
}

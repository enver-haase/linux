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
#include <linux/irqflags.h>
#include <asm/irqflags.h>
#include <asm/unistd.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/interrupt.h>
#include <linux/extable.h>
#include <linux/uaccess.h>
#include <linux/perf_event.h>
#include <linux/kernel.h>
#include <linux/vmalloc.h>
#include <linux/linkage.h>
#include <linux/resume_user_mode.h>
#include <asm/ptrace.h>
#include <asm/irq.h>			/* subleq_do_IRQ(): the timer tick */
#include <asm/pgalloc.h>
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
		/* Say where it died. Other architectures print this and it is how a userspace
		 * crash is diagnosed at all: without it a task that faults at its first
		 * instruction is indistinguishable from one that never started. */
		pr_info("%s[%d]: segfault at %lx pc %lx sp %lx access %lu cause %lu\n",
			current->comm, task_pid_nr(current), addr,
			(unsigned long)PT_REG_GET(regs, pc),
			(unsigned long)PT_REG_GET(regs, sp), access, cause);
		/* Where the resume target came from matters more than the address itself when the
		 * fault is an instruction fetch: pc == addr means the task was RESUMED there. */
		pr_info("  ra %lx  rte_pc %lx (x4 = %lx)  fp %lx  syscall_nr %ld\n",
			(unsigned long)PT_REG_GET(regs, ra),
			(unsigned long)PT_REG_GET(regs, rte_pc),
			(unsigned long)PT_REG_GET(regs, rte_pc) << 2,
			(unsigned long)PT_REG_GET(regs, fp), (long)regs->syscall_nr);
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
#define SUBLEQ_CAUSE_TIMER   0	/* must match src/vm.c CAUSE_TIMER   */

extern asmlinkage long __subleq_syscall_c(long nr, long a1, long a2, long a3,
					  long a4, long a5, long a6);
extern unsigned long subleq_fault_saved_pc;	/* kernel/entry.S */
extern bool do_signal(struct pt_regs *regs);	/* kernel/signal.c */

/*
 * Return-to-user work, shared by every trap cause: run the scheduler if this trap made
 * something else runnable, then deliver pending signals and task work before we RTE.
 * Only adopt pt_regs->pc as the RTE target when do_signal() actually installed a handler
 * (setup_rt_frame() rewrote pt_regs->pc); otherwise leave the target stashed at trap entry,
 * because pt_regs->pc cannot be trusted for a demand fault and blindly resuming from it
 * sends the task to a wild pc.
 */
static void subleq_trap_return_work(struct pt_regs *regs)
{
	bool handled_sig = false;

	if (need_resched())
		schedule();
	if (test_thread_flag(TIF_SIGPENDING) ||
	    test_thread_flag(TIF_NOTIFY_SIGNAL))
		handled_sig = do_signal(regs);
	if (test_thread_flag(TIF_NOTIFY_RESUME))
		resume_user_mode_work(regs);

	if (handled_sig)
		PT_REG_SET(regs, rte_pc, PT_REG_GET(regs, pc) >> 2);
}


/*
 * A resume target has to be somewhere this task can actually execute. Anything else means a trap
 * path handed back a value that is not this task's PC, and returning to it produces a bare
 * "segfault at <some address>" one instruction later, with nothing to say where it came from.
 *
 * Range tests are useless here: the kernel is identity-mapped at low physical addresses, so
 * kernel text and low user addresses are the same numbers. Ask the address space instead. This
 * caught the signal trampoline running from kernel text, which killed the shell after every
 * command that produced a SIGCHLD.
 */
#define SUBLEQ_USER_GATE_ADDR	0x8000UL	/* mm/init.c: subleq_set_sysgate(0x2000) words */
static void subleq_check_rte(struct pt_regs *regs, const char *where,
			     unsigned long cause, unsigned long access)
{
	unsigned long target = PT_REG_GET(regs, rte_pc) << 2;
	struct mm_struct *mm = current->mm;
	struct vm_area_struct *vma;

	if (!mm)
		return;
	/*
	 * The syscall gate is a trapping address, not memory: resuming there is how a restarted
	 * syscall re-enters the kernel, so it is never a mistake.
	 */
	if (target == SUBLEQ_USER_GATE_ADDR)
		return;
	if (!mmap_read_trylock(mm))
		return;                 /* cannot tell without blocking; say nothing */
	vma = find_vma(mm, target);
	if (vma && vma->vm_start > target)
		vma = NULL;             /* find_vma returns the NEXT vma when there is no hit */
	mmap_read_unlock(mm);
	/*
	 * Executability is deliberately not checked: this machine has no NX bit, anything mapped
	 * can be fetched from, and the signal trampoline really does run from the user stack.
	 */
	if (likely(vma))
		return;

	pr_err("subleq: BAD RTE TARGET in %s: %s[%d] would resume at %lx, which is not mapped\n",
	       where, current->comm, task_pid_nr(current), target);
	pr_err("subleq:   cause %lu access %lu  pc %lx ra %lx sp %lx fp %lx\n",
	       cause, access,
	       (unsigned long)PT_REG_GET(regs, pc), (unsigned long)PT_REG_GET(regs, ra),
	       (unsigned long)PT_REG_GET(regs, sp), (unsigned long)PT_REG_GET(regs, fp));
	pr_err("subleq:   syscall_nr %ld  global fault_saved_pc %lx (x4 = %lx)  regs at %px\n",
	       (long)regs->syscall_nr, subleq_fault_saved_pc, subleq_fault_saved_pc << 2, regs);
}

asmlinkage void subleq_trap(struct pt_regs *regs, unsigned long addr,
			    unsigned long cause, unsigned long access)
{
	/*
	 * Timer preemption of a USER task. The cable timer (m[0]/m[1]) is delivered in
	 * supervisor mode only, so it can never take the CPU away from a user task that
	 * neither syscalls nor faults: such a task would own the machine forever. The VM
	 * therefore counts user-mode steps too and delivers CAUSE_TIMER through this trap
	 * vector when the quantum expires (src/cpu.c, run(): user_quantum). Run the tick
	 * exactly as subleq_irq_entry's C half does, then take the normal return-to-user
	 * path -- which is where a reschedule actually happens. The RTE target is left at
	 * the stashed PC, so an un-rescheduled task resumes exactly where it was preempted.
	 *
	 * LIMITATION (single user task only): this path builds pt_regs at a fixed offset
	 * from the global subleq_kernel_sp and stashes the resume PC in the global
	 * subleq_fault_saved_pc, so two user tasks preempted in turn would overwrite each
	 * other's frame. Making the MMU trap path use the current task's kernel stack and
	 * carry the resume PC in pt_regs is the prerequisite for real multitasking here;
	 * until then this gives one user task a preemptible, tick-driven kernel.
	 */
	/*
	 * Take the entry snapshot of the resume PC into this task's frame immediately, before
	 * anything below can schedule. From here on the RTE target is per task, so preempting
	 * one user task while another is mid-trap cannot mix the two up.
	 */
	PT_REG_SET(regs, rte_pc, subleq_fault_saved_pc);

	if (cause == SUBLEQ_CAUSE_TIMER) {
		subleq_do_IRQ(regs);            /* jiffies, timer wheel, softirqs */
		subleq_trap_return_work(regs);
		subleq_check_rte(regs, "timer", cause, access);
		return;
	}

	if (cause == SUBLEQ_CAUSE_SYSCALL) {
		unsigned long nr = PT_REG_GET(regs, r21);

		/*
		 * A syscall runs with interrupts ENABLED, as on every other architecture. Two things
		 * depend on it: a long call must not block the timer tick, and the return-to-user work
		 * below (reschedule, deliver signals) may sleep, which is not allowed with interrupts
		 * off. Running that work with them off is exactly what froze the machine the first time
		 * this was tried -- the idle task inherited the disabled state and no timer ever came
		 * (a profile of the hang showed do_idle with "traps: timer=0").
		 *
		 * Safe here: the gate's globals (subleq_syscall_saved_sp/fp/ra, subleq_fault_saved_pc)
		 * have already been consumed into this task's pt_regs, and subleq_irq_entry copes with
		 * landing inside the kernel -- it only switches to the kernel stack when it was not
		 * already on one.
		 */
		/*
		 * Interrupts stay OFF for the duration of the call, and signals are delivered by the
		 * timer path rather than here. Both are wrong in principle and both are load-bearing
		 * today; the order to fix them in, learned the hard way:
		 *
		 * 1. subleq_irq_entry saves the interrupt handler in INT_Z -- ONE GLOBAL CELL (entry.S,
		 *    around line 134) -- zeroes m[0], and restores from that same cell on the way out.
		 *    With interrupts enabled during a syscall, a timer landing inside another entry
		 *    overwrites it, the outer restore writes the wrong value, and interrupts never come
		 *    back: the machine sits in do_idle with no ticks. Make that save per-nesting-level.
		 * 2. Then interrupts can be enabled here.
		 * 3. Then subleq_trap_return_work() can run at syscall exit, which is what delivers a
		 *    signal to a task sitting in a blocking call -- and that is what linuxthreads
		 *    condition variables wait for. pthread_cond_wait hangs without it.
		 *
		 * One detail already proven and worth keeping when step 2 happens: the resume target has
		 * to be set BEFORE interrupts go on, or a signal delivered mid-syscall saves the syscall
		 * gate as its resume point and the handler returns straight into the same syscall for
		 * ever (traced: "deliver 10 ... rte_pc 8000 ra 40b7b0", repeating). Setting it early on
		 * its own, without the rest, breaks forks -- so all of this moves together.
		 */

		__subleq_syscall_c(PT_REG_GET(regs, r21), PT_REG_GET(regs, r22),
				   PT_REG_GET(regs, r23), PT_REG_GET(regs, r24),
				   PT_REG_GET(regs, r25), PT_REG_GET(regs, r26),
				   PT_REG_GET(regs, r27));
		/*
		 * Resume in user mode at the instruction after the gate call -- except for
		 * rt_sigreturn, which restores the interrupted context itself, including the resume
		 * target it saved in its signal frame.
		 */
		if (nr != __NR_rt_sigreturn)
			PT_REG_SET(regs, rte_pc, PT_REG_GET(regs, ra) >> 2);
		/*
		 * Then the same return-to-user work the timer path does: reschedule if asked, and
		 * deliver pending signals. Without this a signal aimed at a task sitting in a blocking
		 * syscall waited for the next timer tick, and linuxthreads' cond_wait -- suspend in
		 * sigsuspend, wake with a restart signal -- hung outright.
		 */
		subleq_check_rte(regs, "syscall", cause, access);
		return;
	}
	do_page_fault(regs, addr, cause, access);
	subleq_check_rte(regs, "fault-entry", cause, access);

	/*
	 * Then the shared return-to-user work. Previously omitted entirely: a fault that
	 * raised a signal (e.g. force_sig_fault(SIGSEGV) from bad_area on an illegal access)
	 * would RTE straight back to the faulting instruction and re-fault forever, because
	 * the pending signal was never delivered -- an unrecoverable user fault hung the whole
	 * machine instead of killing the task. For an unhandled fatal SIGSEGV, get_signal()
	 * takes the default path (do_exit / panic("kill init") for PID 1) and never returns.
	 */
	subleq_trap_return_work(regs);
}

/*
 * Map user virtual PAGE 1 -> physical page 1 in a freshly exec'd mm. After the Phase 3/5
 * register-file relocation the ESI register file lives in page 1 (REG_BASE, words 1024..),
 * and the kernel's own register file is physical page 1 (identity in supervisor mode). So
 * mapping user vpn1 -> pfn1 gives userspace its registers as the shared, context-switched
 * register bank the trap entry reads/writes — without exposing page 0.
 *
 * Page 0 (the VM interrupt vectors + kernel scratch) is deliberately LEFT UNMAPPED for
 * userspace: NULL derefs fault (guard restored) and the timer vector can't be hijacked.
 * (Name kept for callers; despite "page0" it now maps page 1.) Called from start_thread()
 * and copy_thread().
 */
/*
 * The register file page needs to be described by a vma, not merely mapped.
 *
 * Everything the kernel does to an address space is vma-driven: free_pgtables() walks vma ranges
 * to free page tables, unmap walks them to tear mappings down. A PTE with no vma behind it is
 * invisible to all of it -- the page table leaked on every exit (`non-zero pgtables_bytes on
 * freeing mm: 4096`, exactly one page), and a mapping the kernel cannot see is a mapping it
 * cannot unmap.
 *
 * So the mapping is wrapped in a special-mapping vma, which is what other architectures use for
 * the same kind of kernel-provided page (vDSO, gate pages). VM_PFNMAP says the page is a raw pfn
 * with no struct page accounting, which is correct here: physical page 1 is reserved memory
 * holding the relocated ESI register file, shared with the VM.
 */
static const struct vm_special_mapping subleq_regfile_mapping = {
	.name = "[regfile]",
};

void subleq_map_page0(struct mm_struct *mm)
{
	unsigned long addr = PAGE_SIZE;            /* page 1 = the relocated register file */
	const unsigned long regfile_pfn = 1;       /* physical page 1 = shared register bank */
	struct vm_area_struct *vma;
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;

	mmap_write_lock(mm);

	/* Only once per mm: start_thread() can run more than once against the same address space,
	 * and a second install fails with ENOMEM because the range is already taken -- a warning
	 * about a mapping that is present is worse than no warning at all. */
	if (find_vma_intersection(mm, addr, addr + PAGE_SIZE)) {
		mmap_write_unlock(mm);
		return;
	}

	vma = _install_special_mapping(mm, addr, PAGE_SIZE,
				       VM_READ | VM_WRITE | VM_SHARED | VM_PFNMAP | VM_IO |
				       VM_DONTEXPAND | VM_DONTDUMP,
				       &subleq_regfile_mapping);
	if (IS_ERR(vma))
		pr_warn("subleq: no vma for the register file page (%ld)\n", PTR_ERR(vma));

	/* The PTE is installed by hand rather than faulted in: the special mapping carries no
	 * pages of its own, and this pfn must be there before the first user instruction runs. */
	pgd = pgd_offset(mm, addr);
	p4d = p4d_alloc(mm, pgd, addr);
	pud = p4d ? pud_alloc(mm, p4d, addr) : NULL;
	pmd = pud ? pmd_alloc(mm, pud, addr) : NULL;
	if (pmd && !pte_alloc(mm, pmd)) {
		pte = pte_offset_map(pmd, addr);
		if (pte) {
			set_pte_at(mm, addr, pte, pfn_pte(regfile_pfn, PAGE_SHARED));
			pte_unmap(pte);
		}
	}
	mmap_write_unlock(mm);
}

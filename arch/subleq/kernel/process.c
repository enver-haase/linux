// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq process management
 *
 * NOTE: pt_regs values are stored NEGATED. All access uses PT_REG_GET/SET macros.
 */

#include <asm/traps.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/sched/task_stack.h>
#include <linux/ptrace.h>
#include <linux/cpu.h>
#include <linux/resume_user_mode.h>

#include <asm/processor.h>
#include <asm/ptrace.h>
#include <asm/current.h>
#include <asm/switch_context.h>

/* Signal handling - for ret_to_user_prep work checks */
extern bool do_signal(struct pt_regs *regs);

/*
 * The idle thread - just spin
 */

void __cpuidle arch_cpu_idle(void)
{
	raw_local_irq_enable();
	/* Busy wait - Subleq has no halt instruction */
}

/*
 * __switch_to is now implemented in entry.S
 * It's declared in switch_to.h
 */

/* Assembly entry point for new threads */
extern char ret_from_fork[];

/*
 * Entry point for new kernel threads. Called with:
 *   r4 = fn pointer, r5 = arg
 * Finishes the context switch, then calls fn(arg).
 */
extern asmlinkage void schedule_tail(struct task_struct *prev);

void kernel_thread_helper(struct task_struct *prev)
{
	struct pt_regs *regs = task_pt_regs(current);
	int (*fn)(void *) = (int (*)(void *))PT_REG_GET(regs, r3);
	void *arg = (void *)PT_REG_GET(regs, r21);

	/* Finish context switch bookkeeping before running the thread */
	schedule_tail(prev);

	/* Call the kernel thread function */
	fn(arg);

	/*
	 * If fn() returns, check if kernel_execve() transformed this into
	 * a user thread (r3 == 0). If so, jump to userspace; otherwise exit.
	 */
	regs = task_pt_regs(current); /* Re-read in case it changed */

	if (PT_REG_GET(regs, r3) == 0) {
		/*
		 * This thread called kernel_execve() and is now a user thread.
		 * Jump to userspace using an assembly helper that does a RAW jump
		 * without pushing a return address (which would corrupt the user stack).
		 */

		/*
		 * Call the assembly helper which will:
		 * 1. Set SP to regs->sp
		 * 2. Jump to regs->pc WITHOUT pushing a return address
		 *
		 * We pass pc in R21 (first arg) and sp in R22 (second arg).
		 */
		extern void __noreturn jump_to_userspace(unsigned long pc,
							 unsigned long sp);
#ifdef CONFIG_MMU
		/* MMU: jump_to_userspace enters MODE_USER via CR_RTE, which needs the
		 * entry as a WORD index (CR_SAVED_PC is a word index). */
		jump_to_userspace(PT_REG_GET(regs, pc) >> 2, PT_REG_GET(regs, sp));
#else
		jump_to_userspace(PT_REG_GET(regs, pc), PT_REG_GET(regs, sp));
#endif
	}

	/* Normal kernel thread completion - call do_exit */
	do_exit(0);
}

/*
 * Prepare for userspace return after fork/clone.
 * Finishes the context switch and processes pending work.
 * Returns a pointer to pt_regs for the assembly caller.
 */
struct pt_regs *ret_to_user_prep(struct task_struct *prev)
{
	struct pt_regs *regs;

	schedule_tail(prev);

	/* Return pointer to pt_regs for assembly to use */
	regs = task_pt_regs(current);

	/* Process pending work before returning to userspace */
	if (need_resched())
		schedule();

	if (test_thread_flag(TIF_SIGPENDING) ||
	    test_thread_flag(TIF_NOTIFY_SIGNAL))
		do_signal(regs);

	if (test_thread_flag(TIF_NOTIFY_RESUME))
		resume_user_mode_work(regs);

	return regs;
}

/*
 * Initialize registers for a freshly exec'd thread.
 * r3 = 0 marks this as a user thread (kernel threads have r3 = fn ptr).
 * memset(0) is safe for negated storage since -0 = 0.
 */
void start_thread(struct pt_regs *regs, unsigned long pc, unsigned long sp)
{
	/* Clear all registers to start with a clean slate */
	/* NOTE: memset(0) is correct even for negated storage since -0 = 0 */
	memset(regs, 0, sizeof(*regs));

	PT_REG_SET(regs, pc, pc);
	PT_REG_SET(regs, sp, sp);
	/* r3 = 0 is already set by memset, marking this as a user thread */

#ifdef CONFIG_MMU
	/* Make the ESI register file (user page 0) reachable for the syscall ABI. */
	if (current->mm)
		subleq_map_page0(current->mm);
#endif
	
	/*
	 * CRITICAL: Mark that we're NOT in a syscall.
	 * memset sets syscall_nr=0, which makes in_syscall()
	 * return true (syscall 0 = read). do_signal() would then incorrectly
	 * try to handle syscall restart, corrupting the return context.
	 */
	syscall_wont_restart(regs);
}

/*
 * Copy thread state for fork/clone
 *
 * For kernel threads, we set up the stack so that when __switch_to
 * switches to this thread for the first time:
 *   1. It restores registers from switch_stack (initially zeroed)
 *   2. It pops the "return address" (retpc) which is ret_from_fork
 *      (RA-Direct: __switch_to pushes RA at entry, so pop works the same)
 *   3. ret_from_fork checks r3: if non-zero, it's a kernel thread
 *   4. For kernel threads: ret_from_fork calls kernel_thread_helper
 *      which reads pt_regs.r3 (the fn) and pt_regs.r21 (the arg)
 *   5. For user threads: ret_from_fork restores regs and jumps to pc
 *
 * r3 serves as the kernel/user thread flag:
 *   - r3 != 0: kernel thread (r3 = thread function pointer)
 *   - r3 == 0: user thread (should return to userspace via pc)
 *
 * Stack layout (growing down):
 *   [high addr]  pt_regs structure
 *   [mid addr]   switch_stack structure  <-- thread.sp points here
 *   [low addr]   ... (more stack space)
 *
 * NOTE: Since pt_regs stores values NEGATED, we use PT_REG_SET for all writes.
 */
int copy_thread(struct task_struct *p, const struct kernel_clone_args *args)
{
	unsigned long usp = args->stack;
	struct pt_regs *childregs;
	struct switch_stack *childstack;
	unsigned long *retpc_slot;

	childregs = task_pt_regs(p);

	/*
	 * Set up stack for __switch_to:
	 *
	 * Stack layout (growing down):
	 *   [high addr]  pt_regs structure
	 *   [mid]        ret_from_fork (return address, 4 bytes)
	 *   [low]        switch_stack (96 bytes)  <-- thread.sp points here
	 *
	 * When __switch_to restores this task:
	 *   1. Restores registers from switch_stack
	 *   2. SP += 96 (now points to retpc slot)
	 *   3. Pops retpc, jumps to ret_from_fork
	 */

	/* Store negated ret_from_fork (RA-Direct: pop does RA = -[SP]) */
	retpc_slot = (unsigned long *)childregs - 1;
	*retpc_slot = -(unsigned long)ret_from_fork;

	/* Then allocate switch_stack below the return address */
	childstack = (struct switch_stack *)retpc_slot - 1;
	memset(childstack, 0, sizeof(struct switch_stack));

	/* thread.sp points to switch_stack */
	p->thread.sp = (unsigned long)childstack;

	if (unlikely(args->fn)) {
		/* Kernel thread */
		/* NOTE: memset(0) works for negated storage since -0 = 0 */
		memset(childregs, 0, sizeof(struct pt_regs));

		/*
		 * Store thread function in r3 (kernel thread marker)
		 * and arg in r21 for kernel_thread_helper.
		 * pc is set to 0 (unused for kernel threads since we call fn directly).
		 */
		PT_REG_SET(childregs, r3, (unsigned long)args->fn);
		PT_REG_SET(childregs, r21, (unsigned long)args->fn_arg);
		PT_REG_SET(childregs, pc, 0);
		/* Mark not in syscall (memset leaves syscall_nr=0) */
		syscall_wont_restart(childregs);

		return 0;
	}

	/* User thread (fork) - copy parent's regs */
	*childregs = *task_pt_regs(current);
	if (usp)
		PT_REG_SET(childregs, sp, usp);
	PT_REG_SET(childregs, r20, 0); /* Return 0 in child */
	/* Note: r3 is NOT cleared - we use pc==0 to detect kernel threads */
	/*
	 * Mark not in syscall for the child.
	 * Even though the parent is in clone/fork syscall, the child is
	 * starting fresh and should not inherit the syscall restart state.
	 * Without this, in_syscall() returns true and
	 * do_signal() corrupts the return context.
	 */
	syscall_wont_restart(childregs);

	return 0;
}


/*
 * Get wait channel for sleeping task
 */
unsigned long __get_wchan(struct task_struct *p)
{
	return 0;
}

/*
 * Flush thread state
 */
void flush_thread(void)
{
}

/*
 * Machine power management - required by kernel/reboot.c
 */
void machine_halt(void)
{
	/* Use Subleq HALT instruction: subleq(-4, 0, -4) */
	while (1)
		;
}

void machine_power_off(void)
{
	machine_halt();
}

void machine_restart(char *cmd)
{
	machine_halt();
}

/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Register save structure for Subleq
 *
 * IMPORTANT: pt_regs values are stored NEGATED for efficient SUBLEQ assembly.
 * SUBLEQ's natural store pattern is: dest -= src (which stores -src).
 * By storing values negated, we eliminate the double-negation overhead
 * in the interrupt entry/exit paths (~100 instructions saved per interrupt).
 *
 * All C code MUST use the PT_REG_GET/PT_REG_SET macros to access pt_regs
 * fields. Direct field access will give wrong (negated) values!
 */

#ifndef _ASM_SUBLEQ_PTRACE_H
#define _ASM_SUBLEQ_PTRACE_H

#ifndef __ASSEMBLY__

/*
 * Subleq register save structure
 *
 * This represents the saved state when entering the kernel.
 * Subleq doesn't have hardware registers - these are memory locations.
 *
 * NOTE: All values are stored NEGATED. Use PT_REG_GET/PT_REG_SET macros!
 */
struct pt_regs {
	unsigned long r3; /* General purpose / return value high */
	unsigned long r4; /* General purpose / return value low */
	unsigned long r5;
	unsigned long r6;
	unsigned long r7;
	unsigned long r8;
	unsigned long r9;
	unsigned long r10;
	unsigned long r11;
	unsigned long r12;
	unsigned long r13;
	unsigned long r14;
	unsigned long r15;
	unsigned long r16;
	unsigned long r17;
	unsigned long r18;
	unsigned long r19;
	unsigned long r20; /* Return value */
	unsigned long r21; /* Arg 1 / syscall number */
	unsigned long r22; /* Arg 2 */
	unsigned long r23; /* Arg 3 */
	unsigned long r24; /* Arg 4 */
	unsigned long r25; /* General purpose */
	unsigned long r26;
	unsigned long r27;
	unsigned long r28;
	unsigned long r29;
	unsigned long r30;
	unsigned long r31;
	unsigned long fp;  /* Frame pointer - CRITICAL for fork! */
	unsigned long sp;  /* Stack pointer */
	unsigned long ra;  /* Return address (link register) */
	unsigned long pc;  /* Program counter */
	unsigned long rte_pc;   /* RTE resume target, a WORD index, PER TASK. The MMU trap
				 * path used to keep this in the global subleq_fault_saved_pc,
				 * which is only correct while at most one user task is ever
				 * inside a trap: preemption schedules another task out of
				 * subleq_trap(), and its own exit would then RTE to whatever
				 * PC the last trap stored. Living in pt_regs, it is saved and
				 * restored with the task like every other register. (Was the
				 * unused orig_r20; same offset, so no frame layout changes.) */
	long syscall_nr;        /* Syscall number, -1 if not in syscall */
	unsigned long orig_r21; /* Original R21 (syscall nr) for restart */
	unsigned long orig_a1;  /* Original arg1 for syscall restart */
	unsigned long orig_a2;  /* Original arg2 for syscall restart */
	unsigned long orig_a3;  /* Original arg3 for syscall restart */
	unsigned long orig_a4;  /* Original arg4 for syscall restart */
	/* T-registers and Z - saved by assembly at interrupt entry for signal handling */
	unsigned long t0;
	unsigned long t1;
	unsigned long t2;
	unsigned long t3;
	unsigned long t4;
	unsigned long t5;
	unsigned long t6;
	unsigned long t7;
	unsigned long t8;
	unsigned long t9;
	unsigned long t10;
	unsigned long t11;
	unsigned long t12;
	unsigned long t13;
	unsigned long t14;
	unsigned long t15;
	unsigned long z;
	/* Placed after T-regs/Z to avoid shifting assembly offsets */
	unsigned long orig_a5;  /* Original arg5 for syscall restart */
	unsigned long orig_a6;  /* Original arg6 for syscall restart */
};

/*
 * pt_regs accessor macros
 *
 * Values are stored NEGATED in pt_regs. These macros handle the conversion:
 * - PT_REG_GET: reads a field and negates to get the logical value
 * - PT_REG_SET: negates the value before storing
 *
 * For signed values (like syscall_nr or error codes), negation preserves sign.
 * For addresses (like pc, sp), negation is just bit manipulation that reverses.
 */
#define PT_REG_GET(regs, field)       ((unsigned long)(-(long)(regs)->field))
#define PT_REG_SET(regs, field, val)  ((regs)->field = (unsigned long)(-(long)(val)))

/* Signed version for fields that can be negative (like syscall_nr, r20 errors) */
#define PT_REG_GET_SIGNED(regs, field)       (-(long)(regs)->field)
#define PT_REG_SET_SIGNED(regs, field, val)  ((regs)->field = (unsigned long)(-(long)(val)))

/* Check if we're returning from a syscall (vs interrupt/exception) */
#define in_syscall(regs)	(PT_REG_GET_SIGNED(regs, syscall_nr) >= 0)

/* Mark that syscall restart should NOT happen (e.g., after sigreturn) */
#define syscall_wont_restart(regs)	PT_REG_SET_SIGNED(regs, syscall_nr, -1)

/*
 * user_mode - Check if interrupted context was in user mode
 *
 * For NOMMU Subleq, we detect user mode by checking if the saved SP
 * is within the kernel stack range for the current task.
 *
 * CRITICAL: We CANNOT use PC for this check! The Subleq runtime library
 * (e.g., __subleq_mul, __subleq_and) is linked into the kernel image and
 * resides in [_stext, _end). When userspace code calls these runtime
 * functions, PC is in "kernel" text even though we're logically executing
 * on behalf of userspace. Using PC would incorrectly report kernel mode
 * and prevent preemption/signal delivery.
 *
 * The SP check works because:
 * - User code uses userspace stack (regardless of PC location)
 * - Kernel code (syscalls) switches to the task's kernel stack
 * - If interrupted SP is NOT on kernel stack, we were in user mode
 */

/*
 * Hardcoded offset of task_struct::stack, for use by user_mode().
 * We can't #include <linux/sched.h> here due to circular dependencies.
 * With CONFIG_THREAD_INFO_IN_TASK:
 *   thread_info (8 bytes) + __state (4) + saved_state (4) = 16
 *
 * NOTE: 'stack' is within randomized_struct_fields. If CONFIG_RANDSTRUCT
 * were enabled, this offset could change. The BUILD_BUG_ON in asm-offsets.c
 * will catch any mismatch at build time.
 */
#define SUBLEQ_TASK_STACK_OFFSET 16

/*
 * Hardcoded THREAD_SIZE for user_mode() — same rationale as above.
 * Verified at build time by BUILD_BUG_ON in asm-offsets.c.
 */
#define SUBLEQ_THREAD_SIZE 16384

/* Symbols for syscall handler range check */
extern char __subleq_syscall[];
extern char __subleq_syscall_end[];
/* Symbols for IRQ handler range check */
extern char subleq_irq_entry[];
extern char subleq_irq_entry_end[];
/* Symbols for ret_from_fork / jump_to_userspace range check */
extern char ret_from_fork[];

static inline int __subleq_user_mode(struct pt_regs *regs)
{
	unsigned long pc = PT_REG_GET(regs, pc);
	unsigned long sp = PT_REG_GET(regs, sp);
	
	/*
	 * CRITICAL: If PC is within syscall, IRQ handler, or new-thread
	 * setup code, we're definitely in kernel mode even if SP looks
	 * like userspace.
	 * 
	 * This handles the race condition where SP has been restored to
	 * userspace value but we haven't jumped yet. The PC is still in
	 * kernel code, so we should NOT treat this as user mode.
	 *
	 * Note: This is different from runtime helpers (__subleq_mul, etc.)
	 * which ARE in kernel text but are called from userspace. The syscall
	 * and IRQ handlers are never called from userspace as functions.
	 */
	if (pc >= (unsigned long)__subleq_syscall && 
	    pc < (unsigned long)__subleq_syscall_end)
		return 0;  /* kernel mode */
	if (pc >= (unsigned long)subleq_irq_entry && 
	    pc < (unsigned long)subleq_irq_entry_end)
		return 0;  /* kernel mode */
	/*
	 * ret_from_fork and jump_to_userspace are sequential in entry.S,
	 * between subleq_irq_entry_end and __subleq_syscall.  Both restore
	 * SP to userspace before the final jump; without this check an
	 * interrupt in that window would be misclassified as user mode.
	 */
	if (pc >= (unsigned long)ret_from_fork &&
	    pc < (unsigned long)__subleq_syscall)
		return 0;  /* kernel mode - new thread setup */

	/*
	 * Get kernel stack base from current task's stack pointer.
	 *
	 * With CONFIG_THREAD_INFO_IN_TASK and __current_task available,
	 * we can directly read current->stack to find the kernel stack.
	 *
	 * NOTE: We cannot #include <linux/sched.h> from ptrace.h due to
	 * circular header dependencies, so we access the stack field
	 * via a hardcoded offset. The offset is verified by a static_assert
	 * in asm-offsets.c.
	 *
	 * CRITICAL: The old SP-masking approach (sp & ~(THREAD_SIZE-1)) was
	 * tautologically broken: it always found SP within its own aligned
	 * range, so user_mode() always returned 0 (kernel mode), breaking
	 * signal delivery entirely.
	 */
	{
		extern struct task_struct *volatile __current_task;
		unsigned long kstack_base = *(unsigned long *)((char *)__current_task + SUBLEQ_TASK_STACK_OFFSET);
		unsigned long kstack_top = kstack_base + SUBLEQ_THREAD_SIZE;

		/* If SP is outside kernel stack range, we were in user mode */
		return (sp < kstack_base || sp >= kstack_top);
	}
}

#define user_mode(regs) __subleq_user_mode(regs)
#define kernel_mode(regs) (!user_mode(regs))

#define instruction_pointer(regs) PT_REG_GET(regs, pc)
#define user_stack_pointer(regs) PT_REG_GET(regs, sp)
#define profile_pc(regs) instruction_pointer(regs)

#define MAX_REG_OFFSET (offsetof(struct pt_regs, orig_a6) + sizeof(unsigned long))

#endif /* !__ASSEMBLY__ */

#endif /* _ASM_SUBLEQ_PTRACE_H */

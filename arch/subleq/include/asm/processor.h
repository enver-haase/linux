/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Processor definitions for Subleq architecture
 */

#ifndef _ASM_SUBLEQ_PROCESSOR_H
#define _ASM_SUBLEQ_PROCESSOR_H

#ifndef __ASSEMBLY__

#include <asm/ptrace.h>
#include <linux/linkage.h>

/* Task size - 1GB total address space, kernel takes some */
#define TASK_SIZE (0x30000000UL) /* 768MB for user */
#define TASK_SIZE_MAX TASK_SIZE

/* Where to search for free VM space during mmap */
#define TASK_UNMAPPED_BASE (TASK_SIZE / 3)

/* Top of the user stack region (== user address ceiling). */
#ifndef STACK_TOP
#define STACK_TOP	TASK_SIZE
#define STACK_TOP_MAX	STACK_TOP
#endif

/*
 * Thread state structure - minimal for Subleq
 * Need to save both stack pointer and frame pointer for context switch.
 * Frame pointer is now always enabled by the LLVM backend.
 */
struct thread_struct {
	unsigned long sp; /* Saved stack pointer */
	unsigned long fp; /* Saved frame pointer */
};

#define INIT_THREAD      \
	{                \
		.sp = 0, \
		.fp = 0, \
	}

/*
 * cpu_relax - hint to the processor that we're spinning
 * Subleq has no yield instruction, so this is a no-op
 */
#define cpu_relax() barrier()

/*
 * Get saved registers from a stopped task.
 *
 * The syscall/fault entry (entry.S) saves 8 bytes of syscall globals
 * (SYSCALL_SCRATCH + SYSCALL_JMPTGT) ABOVE pt_regs on the kernel stack, so
 * pt_regs must sit 8 bytes below the stack top to leave room for them (see
 * KERNEL_SP_OFFSET in asm-offsets.c). Without the "- 8" the asm frame's top
 * two words overflowed into the next page. Keep this in lockstep with
 * KERNEL_SP_OFFSET: asm pt_regs = kernel_sp + 1024 = stack + THREAD_SIZE - 8
 * - sizeof(pt_regs), which is exactly what this macro computes.
 */
#ifdef CONFIG_MMU
#define task_pt_regs(task) \
	((struct pt_regs *)(task_stack_page(task) + THREAD_SIZE - 8) - 1)
#else
#define task_pt_regs(task) \
	((struct pt_regs *)(task_stack_page(task) + THREAD_SIZE) - 1)
#endif

/*
 * Saved instruction pointer and stack pointer.
 * pt_regs stores values negated, so use PT_REG_GET to get logical values.
 */
#define KSTK_EIP(tsk) PT_REG_GET(task_pt_regs(tsk), pc)
#define KSTK_ESP(tsk) PT_REG_GET(task_pt_regs(tsk), sp)

/*
 * Get wait channel for sleeping task
 */
extern unsigned long __get_wchan(struct task_struct *p);

/*
 * Start a new thread at given entry point with given stack
 */
extern void start_thread(struct pt_regs *regs, unsigned long pc,
			 unsigned long sp);

/* Default I/O bitmap */
#define INIT_THREAD_FLAGS 0

/* Process management functions */
extern void kernel_thread_helper(struct task_struct *prev);
extern struct pt_regs *ret_to_user_prep(struct task_struct *prev);

/* Signal handling */
asmlinkage void do_notify_resume(struct pt_regs *regs);

/* Machine power management */
extern void machine_halt(void);
extern void machine_power_off(void);
extern void machine_restart(char *cmd);

#endif /* !__ASSEMBLY__ */

#endif /* _ASM_SUBLEQ_PROCESSOR_H */

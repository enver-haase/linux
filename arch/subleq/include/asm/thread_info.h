/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Thread info for Subleq architecture
 *
 * With CONFIG_THREAD_INFO_IN_TASK, thread_info is embedded as the first
 * member of task_struct. The generic kernel provides current_thread_info()
 * as ((struct thread_info *)current).
 *
 * We keep preempt_count here because asm-generic/preempt.h accesses it
 * via current_thread_info()->preempt_count.
 */

#ifndef _ASM_SUBLEQ_THREAD_INFO_H
#define _ASM_SUBLEQ_THREAD_INFO_H

#ifdef __KERNEL__

#include <asm/page.h>

/*
 * Thread stack size - 16KB. Kept decoupled from PAGE_SIZE: cable's stock NOMMU used a
 * 16KB page so THREAD_SIZE_ORDER 0 gave a 16KB stack. With the MMU port's 4KB page
 * (docs/mmu-port-plan.md step 1) we hold the stack at 16KB via ORDER 2 so THREAD_SIZE
 * stays == SUBLEQ_THREAD_SIZE (ptrace.h) and entry.S's SP masking is unchanged.
 */
#define THREAD_SIZE_ORDER 2
#define THREAD_SHIFT (PAGE_SHIFT + THREAD_SIZE_ORDER)
#define THREAD_SIZE (_AC(1, UL) << THREAD_SHIFT)

#ifndef __ASSEMBLY__

#include <linux/types.h>

/*
 * Low level thread information structure
 *
 * With THREAD_INFO_IN_TASK, this is embedded at offset 0 of task_struct.
 * Only flags and preempt_count remain; the old .task and .cpu fields
 * are no longer needed.
 */
struct thread_info {
	unsigned long flags; /* thread flags */
	int preempt_count; /* preemption counter */
};

#define INIT_THREAD_INFO(tsk)                        \
	{                                            \
		.flags = 0,                          \
		.preempt_count = INIT_PREEMPT_COUNT, \
	}

#endif /* !__ASSEMBLY__ */

/*
 * Thread information flags
 */
#define TIF_SYSCALL_TRACE 0 /* syscall trace active */
#define TIF_NOTIFY_RESUME 1 /* callback before returning to user */
#define TIF_SIGPENDING 2 /* signal pending */
#define TIF_NEED_RESCHED 3 /* rescheduling necessary */
#define TIF_SINGLESTEP 4 /* single stepping */
#define TIF_NOTIFY_SIGNAL 5 /* signal notifications exist */
#define TIF_MEMDIE 17 /* OOM killer killed process */

#define _TIF_SYSCALL_TRACE (1 << TIF_SYSCALL_TRACE)
#define _TIF_NOTIFY_RESUME (1 << TIF_NOTIFY_RESUME)
#define _TIF_SIGPENDING (1 << TIF_SIGPENDING)
#define _TIF_NEED_RESCHED (1 << TIF_NEED_RESCHED)
#define _TIF_SINGLESTEP (1 << TIF_SINGLESTEP)
#define _TIF_NOTIFY_SIGNAL (1 << TIF_NOTIFY_SIGNAL)

/* Work to do on return from interrupt/exception */
#define _TIF_WORK_MASK (0x0000FFFF & ~_TIF_SYSCALL_TRACE)
#define _TIF_ALLWORK_MASK 0x0000FFFF

#endif /* __KERNEL__ */

#endif /* _ASM_SUBLEQ_THREAD_INFO_H */

// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq asm-offsets - Generate constants for assembly code
 */

#define COMPILE_OFFSETS

#include <linux/kbuild.h>
#include <linux/sched.h>
#include <asm/ptrace.h>
#include <asm/processor.h>
#include <asm/thread_info.h>
#include <asm/irqflags.h>

int main(void)
{
	COMMENT("Subleq pt_regs offsets");
	OFFSET(PT_R3, pt_regs, r3);
	OFFSET(PT_R4, pt_regs, r4);
	OFFSET(PT_R5, pt_regs, r5);
	OFFSET(PT_R6, pt_regs, r6);
	OFFSET(PT_R7, pt_regs, r7);
	OFFSET(PT_R8, pt_regs, r8);
	OFFSET(PT_R9, pt_regs, r9);
	OFFSET(PT_R10, pt_regs, r10);
	OFFSET(PT_R11, pt_regs, r11);
	OFFSET(PT_R12, pt_regs, r12);
	OFFSET(PT_R13, pt_regs, r13);
	OFFSET(PT_R14, pt_regs, r14);
	OFFSET(PT_R15, pt_regs, r15);
	OFFSET(PT_R16, pt_regs, r16);
	OFFSET(PT_R17, pt_regs, r17);
	OFFSET(PT_R18, pt_regs, r18);
	OFFSET(PT_R19, pt_regs, r19);
	OFFSET(PT_R20, pt_regs, r20);
	OFFSET(PT_R21, pt_regs, r21);
	OFFSET(PT_R22, pt_regs, r22);
	OFFSET(PT_R23, pt_regs, r23);
	OFFSET(PT_R24, pt_regs, r24);
	OFFSET(PT_R25, pt_regs, r25);
	OFFSET(PT_R26, pt_regs, r26);
	OFFSET(PT_R27, pt_regs, r27);
	OFFSET(PT_R28, pt_regs, r28);
	OFFSET(PT_R29, pt_regs, r29);
	OFFSET(PT_R30, pt_regs, r30);
	OFFSET(PT_R31, pt_regs, r31);
	OFFSET(PT_FP, pt_regs, fp);
	OFFSET(PT_SP, pt_regs, sp);
	OFFSET(PT_RA, pt_regs, ra);
	OFFSET(PT_PC, pt_regs, pc);
	OFFSET(PT_RTE_PC, pt_regs, rte_pc);
	OFFSET(PT_SYSCALL_NR, pt_regs, syscall_nr);
	OFFSET(PT_ORIG_R21, pt_regs, orig_r21);
	OFFSET(PT_ORIG_A1, pt_regs, orig_a1);
	OFFSET(PT_ORIG_A2, pt_regs, orig_a2);
	OFFSET(PT_ORIG_A3, pt_regs, orig_a3);
	OFFSET(PT_ORIG_A4, pt_regs, orig_a4);
	OFFSET(PT_ORIG_A5, pt_regs, orig_a5);
	OFFSET(PT_ORIG_A6, pt_regs, orig_a6);
	DEFINE(PT_SIZE, sizeof(struct pt_regs));
	BLANK();

	COMMENT("Subleq thread_info offsets");
	OFFSET(TI_FLAGS, thread_info, flags);
	DEFINE(THREAD_SIZE_ASM, THREAD_SIZE);
	BLANK();

	COMMENT("Subleq task_struct offsets");
	OFFSET(TASK_THREAD, task_struct, thread);
	OFFSET(THREAD_SP, thread_struct, sp);
	OFFSET(THREAD_FP, thread_struct, fp);
	/* Combined offsets for direct access from task_struct pointer */
	DEFINE(TASK_THREAD_SP, offsetof(struct task_struct, thread.sp));
	DEFINE(TASK_THREAD_FP, offsetof(struct task_struct, thread.fp));
	/* task->stack offset for kernel stack pointer computation */
	DEFINE(TASK_STACK, offsetof(struct task_struct, stack));
	/* Offset from stack page base to get subleq_kernel_sp value:
	 * kernel_sp = task->stack + THREAD_SIZE - sizeof(pt_regs) - 1024 - 8
	 * This constant = THREAD_SIZE - sizeof(pt_regs) - 1024 - 8
	 *
	 * The syscall/fault entry (entry.S) resets SP to kernel_sp + 1268 and
	 * builds the frame downward as [SYSCALL_SCRATCH | SYSCALL_JMPTGT | pt_regs]:
	 * pt_regs occupies [kernel_sp+1024, kernel_sp+1260) and the two saved
	 * globals occupy [kernel_sp+1260, kernel_sp+1268) = 8 bytes ABOVE pt_regs.
	 * The original offset (without -8) placed pt_regs' top exactly at the stack
	 * top (stack + THREAD_SIZE), so those 8 bytes of saved globals overflowed
	 * one page past the stack — silently clobbering the neighbouring allocation
	 * on every trap (deterministically PID1's own sighand->signalfd_wqh, whose
	 * zeroed list head then crashed __wake_up on the next signal). The -8
	 * reserves that headroom so the whole 244-byte frame ends at the stack top.
	 * task_pt_regs (processor.h) is shifted down by the same 8 to match.
	 */
#ifdef CONFIG_MMU
	/* MMU-only: the fault/syscall entry saves 8 bytes of globals above pt_regs
	 * (see the comment above). NOMMU uses the frameless __subleq_syscall path
	 * with pt_regs at the stack top, so keep its offset unchanged/byte-identical. */
	DEFINE(KERNEL_SP_OFFSET, THREAD_SIZE - sizeof(struct pt_regs) - 1024 - 8);
#else
	DEFINE(KERNEL_SP_OFFSET, THREAD_SIZE - sizeof(struct pt_regs) - 1024);
#endif
	BLANK();

	/*
	 * Verify that SUBLEQ_TASK_STACK_OFFSET in ptrace.h matches reality.
	 * ptrace.h can't include sched.h, so it hardcodes this offset.
	 */
	BUILD_BUG_ON(SUBLEQ_TASK_STACK_OFFSET != offsetof(struct task_struct, stack));
	BUILD_BUG_ON(SUBLEQ_TI_PREEMPT_OFFSET != offsetof(struct thread_info, preempt_count));
	BUILD_BUG_ON(SUBLEQ_THREAD_SIZE != THREAD_SIZE);
	BUILD_BUG_ON(sizeof(struct pt_regs) != 236);

	return 0;
}

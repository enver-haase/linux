// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq signal handling
 *
 * This file implements signal delivery and return for the Subleq architecture.
 * Following the m68k NOMMU pattern as reference.
 */

#include <linux/signal.h>
#include <linux/errno.h>
#include <linux/sched/signal.h>
#include <linux/sched/task_stack.h>
#include <linux/uaccess.h>
#include <linux/resume_user_mode.h>
#include <linux/syscalls.h>

#include <asm/ptrace.h>
#include <asm/ucontext.h>
#include <asm/unistd.h>

#include <asm/sigcontext.h>

/* Forward declarations */
bool do_signal(struct pt_regs *regs);
asmlinkage long sys_rt_sigreturn(void);

/* Syscall table and types - needed for restart handling in sigreturn */
extern void *sys_call_table[];
typedef long (*syscall_fn_t)(long, long, long, long, long, long);
extern long sys_ni_syscall(void);



/* Signal return trampoline (entry.S) — invokes sys_rt_sigreturn */
extern void ret_from_user_rt_signal(void);

/*
 * Signal frame placed on user stack when delivering a signal.
 * pretcode points to the return trampoline; sys_rt_sigreturn
 * restores the original context from uc when the handler returns.
 */
struct rt_sigframe {
	void *pretcode;              /* Return trampoline address */
	int sig;                     /* Signal number */
	struct siginfo __user *pinfo; /* Pointer to info below */
	void __user *puc;            /* Pointer to uc below */
	struct siginfo info;         /* Signal info */
	struct ucontext uc;          /* User context with saved regs/mask */
	/*
	 * Kernel-private tail. Userspace only ever looks at the four fields above, so adding
	 * here changes nothing it can see.
	 */
	unsigned long retcode[10];   /* the rt_sigreturn trampoline (see setup_rt_frame) */
	unsigned long rte_pc;        /* resume target at delivery: not part of sigcontext */
};

/*
 * The trampoline, as subleq words. Three instructions and a constant:
 *
 *   R21 = 0                       ; the syscall number register
 *   R21 -= (-__NR_rt_sigreturn)   ; = __NR_rt_sigreturn
 *   Z   -= Z                      ; = 0, so the branch is always taken -> the syscall gate
 *
 * Operands are absolute byte addresses, which is why this is built per frame rather than kept as
 * a constant blob: the two branch targets and the constant's address depend on where the frame
 * landed on the user stack. The register file is mapped into every user address space at
 * SUBLEQ_REG_BASE (that is how user code reaches its own registers), so those addresses are the
 * same numbers the kernel uses.
 */
#define SUBLEQ_REG_BASE_BYTES	4096UL		/* asm/subleq-regs.h: .set REG_BASE, 4096 */
#define SUBLEQ_REG_Z		(SUBLEQ_REG_BASE_BYTES + 12)	/* .set REG_Z,   REG_BASE + 12  */
#define SUBLEQ_REG_R21		(SUBLEQ_REG_BASE_BYTES + 100)	/* .set REG_R21, REG_BASE + 100 */
#define SUBLEQ_USER_GATE	0x8000UL	/* mm/init.c: subleq_set_sysgate(0x2000) words */

static int subleq_put_sigtramp(struct rt_sigframe __user *frame)
{
	unsigned long t = (unsigned long)frame->retcode;
	unsigned long code[10] = {
		SUBLEQ_REG_R21, SUBLEQ_REG_R21, t + 12,		/* R21 = 0                    */
		t + 36,         SUBLEQ_REG_R21, t + 24,		/* R21 -= -__NR_rt_sigreturn  */
		SUBLEQ_REG_Z,   SUBLEQ_REG_Z,   SUBLEQ_USER_GATE, /* Z = 0 -> jump to the gate */
		(unsigned long)-(long)__NR_rt_sigreturn,	/* the constant, at t + 36    */
	};

	return copy_to_user(frame->retcode, code, sizeof(code)) ? -EFAULT : 0;
}

/*
 * Save registers to sigcontext. PT_REG_GET converts from negated
 * internal storage to positive values for userspace.
 */
static int save_sigcontext(struct sigcontext __user *sc, struct pt_regs *regs)
{
	int err = 0;



	/* Save all general purpose registers (convert from negated storage) */
	err |= __put_user(PT_REG_GET(regs, r3), &sc->sc_regs[0]);
	err |= __put_user(PT_REG_GET(regs, r4), &sc->sc_regs[1]);
	err |= __put_user(PT_REG_GET(regs, r5), &sc->sc_regs[2]);
	err |= __put_user(PT_REG_GET(regs, r6), &sc->sc_regs[3]);
	err |= __put_user(PT_REG_GET(regs, r7), &sc->sc_regs[4]);
	err |= __put_user(PT_REG_GET(regs, r8), &sc->sc_regs[5]);
	err |= __put_user(PT_REG_GET(regs, r9), &sc->sc_regs[6]);
	err |= __put_user(PT_REG_GET(regs, r10), &sc->sc_regs[7]);
	err |= __put_user(PT_REG_GET(regs, r11), &sc->sc_regs[8]);
	err |= __put_user(PT_REG_GET(regs, r12), &sc->sc_regs[9]);
	err |= __put_user(PT_REG_GET(regs, r13), &sc->sc_regs[10]);
	err |= __put_user(PT_REG_GET(regs, r14), &sc->sc_regs[11]);
	err |= __put_user(PT_REG_GET(regs, r15), &sc->sc_regs[12]);
	err |= __put_user(PT_REG_GET(regs, r16), &sc->sc_regs[13]);
	err |= __put_user(PT_REG_GET(regs, r17), &sc->sc_regs[14]);
	err |= __put_user(PT_REG_GET(regs, r18), &sc->sc_regs[15]);
	err |= __put_user(PT_REG_GET(regs, r19), &sc->sc_regs[16]);
	err |= __put_user(PT_REG_GET(regs, r20), &sc->sc_regs[17]);
	err |= __put_user(PT_REG_GET(regs, r21), &sc->sc_regs[18]);
	err |= __put_user(PT_REG_GET(regs, r22), &sc->sc_regs[19]);
	err |= __put_user(PT_REG_GET(regs, r23), &sc->sc_regs[20]);
	err |= __put_user(PT_REG_GET(regs, r24), &sc->sc_regs[21]);
	err |= __put_user(PT_REG_GET(regs, r25), &sc->sc_regs[22]);
	err |= __put_user(PT_REG_GET(regs, r26), &sc->sc_regs[23]);
	err |= __put_user(PT_REG_GET(regs, r27), &sc->sc_regs[24]);
	err |= __put_user(PT_REG_GET(regs, r28), &sc->sc_regs[25]);
	err |= __put_user(PT_REG_GET(regs, r29), &sc->sc_regs[26]);
	err |= __put_user(PT_REG_GET(regs, r30), &sc->sc_regs[27]);
	err |= __put_user(PT_REG_GET(regs, r31), &sc->sc_regs[28]);
	err |= __put_user(PT_REG_GET(regs, fp), &sc->sc_regs[29]);
	err |= __put_user(PT_REG_GET(regs, sp), &sc->sc_regs[30]);
	err |= __put_user(PT_REG_GET(regs, ra), &sc->sc_regs[31]);
	err |= __put_user(PT_REG_GET(regs, pc), &sc->sc_pc);

	/* Save T-registers from pt_regs (populated by interrupt entry assembly) */
	err |= __put_user(PT_REG_GET(regs, t0), &sc->sc_tregs[0]);
	err |= __put_user(PT_REG_GET(regs, t1), &sc->sc_tregs[1]);
	err |= __put_user(PT_REG_GET(regs, t2), &sc->sc_tregs[2]);
	err |= __put_user(PT_REG_GET(regs, t3), &sc->sc_tregs[3]);
	err |= __put_user(PT_REG_GET(regs, t4), &sc->sc_tregs[4]);
	err |= __put_user(PT_REG_GET(regs, t5), &sc->sc_tregs[5]);
	err |= __put_user(PT_REG_GET(regs, t6), &sc->sc_tregs[6]);
	err |= __put_user(PT_REG_GET(regs, t7), &sc->sc_tregs[7]);
	err |= __put_user(PT_REG_GET(regs, t8), &sc->sc_tregs[8]);
	err |= __put_user(PT_REG_GET(regs, t9), &sc->sc_tregs[9]);
	err |= __put_user(PT_REG_GET(regs, t10), &sc->sc_tregs[10]);
	err |= __put_user(PT_REG_GET(regs, t11), &sc->sc_tregs[11]);
	err |= __put_user(PT_REG_GET(regs, t12), &sc->sc_tregs[12]);
	err |= __put_user(PT_REG_GET(regs, t13), &sc->sc_tregs[13]);
	err |= __put_user(PT_REG_GET(regs, t14), &sc->sc_tregs[14]);
	err |= __put_user(PT_REG_GET(regs, t15), &sc->sc_tregs[15]);
	err |= __put_user(PT_REG_GET(regs, z), &sc->sc_z);

	/* Save syscall restart information */
	err |= __put_user(PT_REG_GET(regs, orig_r21), &sc->sc_orig_r21);
	err |= __put_user(PT_REG_GET(regs, orig_a1), &sc->sc_orig_a1);
	err |= __put_user(PT_REG_GET(regs, orig_a2), &sc->sc_orig_a2);
	err |= __put_user(PT_REG_GET(regs, orig_a3), &sc->sc_orig_a3);
	err |= __put_user(PT_REG_GET(regs, orig_a4), &sc->sc_orig_a4);
	err |= __put_user(PT_REG_GET(regs, orig_a5), &sc->sc_orig_a5);
	err |= __put_user(PT_REG_GET(regs, orig_a6), &sc->sc_orig_a6);
	err |= __put_user(PT_REG_GET_SIGNED(regs, syscall_nr), &sc->sc_syscall_nr);

	return err;
}

/*
 * Restore registers from sigcontext. PT_REG_SET negates the user's
 * positive values back to internal storage format.
 */
static int restore_sigcontext(struct pt_regs *regs, struct sigcontext __user *sc)
{
	int err = 0;
	unsigned long val;
	long sval;

	/* Restore all general purpose registers (convert to negated storage) */
	err |= __get_user(val, &sc->sc_regs[0]); PT_REG_SET(regs, r3, val);
	err |= __get_user(val, &sc->sc_regs[1]); PT_REG_SET(regs, r4, val);
	err |= __get_user(val, &sc->sc_regs[2]); PT_REG_SET(regs, r5, val);
	err |= __get_user(val, &sc->sc_regs[3]); PT_REG_SET(regs, r6, val);
	err |= __get_user(val, &sc->sc_regs[4]); PT_REG_SET(regs, r7, val);
	err |= __get_user(val, &sc->sc_regs[5]); PT_REG_SET(regs, r8, val);
	err |= __get_user(val, &sc->sc_regs[6]); PT_REG_SET(regs, r9, val);
	err |= __get_user(val, &sc->sc_regs[7]); PT_REG_SET(regs, r10, val);
	err |= __get_user(val, &sc->sc_regs[8]); PT_REG_SET(regs, r11, val);
	err |= __get_user(val, &sc->sc_regs[9]); PT_REG_SET(regs, r12, val);
	err |= __get_user(val, &sc->sc_regs[10]); PT_REG_SET(regs, r13, val);
	err |= __get_user(val, &sc->sc_regs[11]); PT_REG_SET(regs, r14, val);
	err |= __get_user(val, &sc->sc_regs[12]); PT_REG_SET(regs, r15, val);
	err |= __get_user(val, &sc->sc_regs[13]); PT_REG_SET(regs, r16, val);
	err |= __get_user(val, &sc->sc_regs[14]); PT_REG_SET(regs, r17, val);
	err |= __get_user(val, &sc->sc_regs[15]); PT_REG_SET(regs, r18, val);
	err |= __get_user(val, &sc->sc_regs[16]); PT_REG_SET(regs, r19, val);
	err |= __get_user(val, &sc->sc_regs[17]); PT_REG_SET(regs, r20, val);
	err |= __get_user(val, &sc->sc_regs[18]); PT_REG_SET(regs, r21, val);
	err |= __get_user(val, &sc->sc_regs[19]); PT_REG_SET(regs, r22, val);
	err |= __get_user(val, &sc->sc_regs[20]); PT_REG_SET(regs, r23, val);
	err |= __get_user(val, &sc->sc_regs[21]); PT_REG_SET(regs, r24, val);
	err |= __get_user(val, &sc->sc_regs[22]); PT_REG_SET(regs, r25, val);
	err |= __get_user(val, &sc->sc_regs[23]); PT_REG_SET(regs, r26, val);
	err |= __get_user(val, &sc->sc_regs[24]); PT_REG_SET(regs, r27, val);
	err |= __get_user(val, &sc->sc_regs[25]); PT_REG_SET(regs, r28, val);
	err |= __get_user(val, &sc->sc_regs[26]); PT_REG_SET(regs, r29, val);
	err |= __get_user(val, &sc->sc_regs[27]); PT_REG_SET(regs, r30, val);
	err |= __get_user(val, &sc->sc_regs[28]); PT_REG_SET(regs, r31, val);
	err |= __get_user(val, &sc->sc_regs[29]); PT_REG_SET(regs, fp, val);
	err |= __get_user(val, &sc->sc_regs[30]); PT_REG_SET(regs, sp, val);
	err |= __get_user(val, &sc->sc_regs[31]); PT_REG_SET(regs, ra, val);
	err |= __get_user(val, &sc->sc_pc); PT_REG_SET(regs, pc, val);

	/* Restore T-registers to pt_regs (assembly exit will restore to hardware) */
	err |= __get_user(val, &sc->sc_tregs[0]); PT_REG_SET(regs, t0, val);
	err |= __get_user(val, &sc->sc_tregs[1]); PT_REG_SET(regs, t1, val);
	err |= __get_user(val, &sc->sc_tregs[2]); PT_REG_SET(regs, t2, val);
	err |= __get_user(val, &sc->sc_tregs[3]); PT_REG_SET(regs, t3, val);
	err |= __get_user(val, &sc->sc_tregs[4]); PT_REG_SET(regs, t4, val);
	err |= __get_user(val, &sc->sc_tregs[5]); PT_REG_SET(regs, t5, val);
	err |= __get_user(val, &sc->sc_tregs[6]); PT_REG_SET(regs, t6, val);
	err |= __get_user(val, &sc->sc_tregs[7]); PT_REG_SET(regs, t7, val);
	err |= __get_user(val, &sc->sc_tregs[8]); PT_REG_SET(regs, t8, val);
	err |= __get_user(val, &sc->sc_tregs[9]); PT_REG_SET(regs, t9, val);
	err |= __get_user(val, &sc->sc_tregs[10]); PT_REG_SET(regs, t10, val);
	err |= __get_user(val, &sc->sc_tregs[11]); PT_REG_SET(regs, t11, val);
	err |= __get_user(val, &sc->sc_tregs[12]); PT_REG_SET(regs, t12, val);
	err |= __get_user(val, &sc->sc_tregs[13]); PT_REG_SET(regs, t13, val);
	err |= __get_user(val, &sc->sc_tregs[14]); PT_REG_SET(regs, t14, val);
	err |= __get_user(val, &sc->sc_tregs[15]); PT_REG_SET(regs, t15, val);
	err |= __get_user(val, &sc->sc_z); PT_REG_SET(regs, z, val);

	/* Restore syscall restart information */
	err |= __get_user(val, &sc->sc_orig_r21); PT_REG_SET(regs, orig_r21, val);
	err |= __get_user(val, &sc->sc_orig_a1); PT_REG_SET(regs, orig_a1, val);
	err |= __get_user(val, &sc->sc_orig_a2); PT_REG_SET(regs, orig_a2, val);
	err |= __get_user(val, &sc->sc_orig_a3); PT_REG_SET(regs, orig_a3, val);
	err |= __get_user(val, &sc->sc_orig_a4); PT_REG_SET(regs, orig_a4, val);
	err |= __get_user(val, &sc->sc_orig_a5); PT_REG_SET(regs, orig_a5, val);
	err |= __get_user(val, &sc->sc_orig_a6); PT_REG_SET(regs, orig_a6, val);
	err |= __get_user(sval, &sc->sc_syscall_nr); PT_REG_SET_SIGNED(regs, syscall_nr, sval);

	return err;
}

/*
 * get_sigframe - Calculate where to place the signal frame on user stack
 */
static inline void __user *get_sigframe(struct ksignal *ksig,
					struct pt_regs *regs,
					size_t frame_size)
{
	unsigned long sp;

	/* Use alternate signal stack if available and appropriate */
	sp = sigsp(PT_REG_GET(regs, sp), ksig);

	/* Align to 4-byte boundary (Subleq word alignment) */
	sp = (sp - frame_size) & ~3UL;

	return (void __user *)sp;
}

/*
 * Build the signal frame on the user stack and redirect execution
 * to the signal handler. RA is set to the return trampoline.
 */
static int setup_rt_frame(struct ksignal *ksig, sigset_t *set,
			  struct pt_regs *regs)
{
	struct rt_sigframe __user *frame;
	int err = 0;

	frame = get_sigframe(ksig, regs, sizeof(*frame));



	if (!access_ok(frame, sizeof(*frame)))
		return -EFAULT;

	/* Set up the frame header */
	err |= subleq_put_sigtramp(frame);
	err |= __put_user((void *)frame->retcode, &frame->pretcode);
	/* The resume target is per task and not in sigcontext; carry it in the frame. */
	err |= __put_user((unsigned long)PT_REG_GET(regs, rte_pc), &frame->rte_pc);
	err |= __put_user(ksig->sig, &frame->sig);
	err |= __put_user(&frame->info, &frame->pinfo);
	err |= __put_user(&frame->uc, &frame->puc);

	/* Copy siginfo */
	err |= copy_siginfo_to_user(&frame->info, &ksig->info);

	/* Set up ucontext */
	err |= __put_user(0, &frame->uc.uc_flags);
	err |= __put_user(NULL, &frame->uc.uc_link);
	err |= __save_altstack(&frame->uc.uc_stack, PT_REG_GET(regs, sp));
	err |= save_sigcontext(&frame->uc.uc_mcontext, regs);
	err |= __copy_to_user(&frame->uc.uc_sigmask, set, sizeof(*set));

	if (err)
		return -EFAULT;

	/* RA-Direct: SP = frame, RA = trampoline. No stack slot needed. */
	{
		/* RA-Direct: SP = frame directly, no RA slot needed */
		PT_REG_SET(regs, sp, (unsigned long)frame);
	}

	PT_REG_SET(regs, pc, (unsigned long)ksig->ka.sa.sa_handler);
	/*
	 * ... and the RTE target, which is what actually resumes this task. pc and rte_pc are two
	 * different things here: pc is a byte address in pt_regs, rte_pc is the WORD index the trap
	 * exit writes to CR_RTE. The timer path happened to work because subleq_trap_return_work()
	 * copies pc into rte_pc when a handler was installed; the syscall path calls do_signal()
	 * from __subleq_syscall_c(), where nothing did -- so the frame was built, the handler
	 * address was stored in pc, and the task resumed at the instruction after the gate as if no
	 * signal had happened. Setting it here covers every caller, and sigreturn restores the
	 * saved rte_pc from the frame.
	 */
	PT_REG_SET(regs, rte_pc, (unsigned long)ksig->ka.sa.sa_handler >> 2);
	PT_REG_SET(regs, r21, ksig->sig);  /* First argument: signal number */

	/*
	 * For SA_SIGINFO handlers, set up additional arguments:
	 * R22 = pointer to siginfo
	 * R23 = pointer to ucontext
	 */
	if (ksig->ka.sa.sa_flags & SA_SIGINFO) {
		PT_REG_SET(regs, r22, (unsigned long)&frame->info);
		PT_REG_SET(regs, r23, (unsigned long)&frame->uc);
	}

	/*
	 * RA-Direct: Set RA to trampoline address.
	 * The handler will return via JMP RA|I, jumping to the trampoline.
	 */
	PT_REG_SET(regs, ra, (unsigned long)frame->retcode);

	return 0;
}

/*
 * Handle syscall restart based on error code and signal state.
 */
static inline void
handle_restart(struct pt_regs *regs, struct k_sigaction *ka, int has_handler)
{
	long ret = PT_REG_GET_SIGNED(regs, r20);

	switch (ret) {
	case -ERESTARTNOHAND:
		/*
		 * ERESTARTNOHAND: Restart only if there's no handler.
		 * If we have a handler, convert to EINTR.
		 */
		if (!has_handler)
			goto do_restart;
		PT_REG_SET_SIGNED(regs, r20, -EINTR);
		break;

	case -ERESTART_RESTARTBLOCK:
		/*
		 * ERESTART_RESTARTBLOCK: Use the restart_block mechanism.
		 * If there's no handler, call the restart_block function now.
		 * If there IS a handler, preserve the error code so that
		 * sigreturn can call the restart_block after the handler
		 * completes. This allows nanosleep to sleep the remaining
		 * time after the signal handler returns.
		 */
		if (!has_handler) {
			struct restart_block *restart = &current->restart_block;
			PT_REG_SET_SIGNED(regs, r20, restart->fn(restart));
		}
		/* With handler: keep r20 as -ERESTART_RESTARTBLOCK for sigreturn */
		break;

	case -ERESTARTSYS:
		/*
		 * ERESTARTSYS: Restart unless there's a handler without SA_RESTART.
		 */
		if (has_handler && !(ka->sa.sa_flags & SA_RESTART)) {
			PT_REG_SET_SIGNED(regs, r20, -EINTR);
			break;
		}
		fallthrough;

	case -ERESTARTNOINTR:
		/*
		 * ERESTARTNOINTR: Always restart, regardless of signals.
		 * This is used by vfork's wait_for_vfork_done().
		 *
		 * To restart the syscall:
		 * 1. Restore original syscall number to R21 (from orig_r21)
		 * 2. Keep the restart code so syscall_entry.c knows to restart
		 */
	do_restart:
		PT_REG_SET(regs, r21, PT_REG_GET(regs, orig_r21));
		PT_REG_SET_SIGNED(regs, r20, -ERESTARTNOINTR);  /* Keep the restart code */
		break;
	}
}

/*
 * handle_signal - Invoke a signal handler
 */
static void handle_signal(struct ksignal *ksig, struct pt_regs *regs)
{
	sigset_t *oldset = sigmask_to_save();
	int err;



	/* Handle syscall restart if we came from a syscall */
	if (in_syscall(regs))
		handle_restart(regs, &ksig->ka, 1);

	/* Set up the signal frame */
	err = setup_rt_frame(ksig, oldset, regs);



	/* Report signal setup status */
	signal_setup_done(err, ksig, 0);
}

/*
 * Main signal delivery entry point, called from the syscall return path.
 * Returns true if a signal handler was set up (caller must not do
 * restart logic — the handler runs first).
 */
bool do_signal(struct pt_regs *regs)
{
	struct ksignal ksig;



	/*
	 * Check if there's a signal to deliver.
	 * get_signal() returns true if a signal needs to be delivered.
	 * It also handles signal stopping, coredumps, and sets up ksig.
	 */
	if (get_signal(&ksig)) {

		/* Deliver the signal */
		handle_signal(&ksig, regs);

		return true;  /* Signal handler was set up */
	}

	/*
	 * No signal to deliver.
	 *
	 * If we came from a syscall and got a restart code, handle it.
	 * With no signal handler, ERESTARTSYS and ERESTARTNOHAND should
	 * both result in syscall restart.
	 */
	if (in_syscall(regs))
		handle_restart(regs, NULL, 0);

	/*
	 * If there's no signal to deliver, restore the saved sigmask.
	 * This is used by sigsuspend() and related calls.
	 */
	restore_saved_sigmask();
	
	return false;  /* No signal handler was set up */
}

/*
 * Handle pending work (signals, task_work) before returning to user mode.
 */
asmlinkage void do_notify_resume(struct pt_regs *regs)
{
	if (test_thread_flag(TIF_NOTIFY_SIGNAL) ||
	    test_thread_flag(TIF_SIGPENDING)) {
		do_signal(regs);
	}

	if (test_thread_flag(TIF_NOTIFY_RESUME)) {
		resume_user_mode_work(regs);
	}
}

/*
 * Restore context after signal handler returns via the trampoline.
 */
asmlinkage long sys_rt_sigreturn(void)
{
	struct pt_regs *regs = current_pt_regs();
	struct rt_sigframe __user *frame;
	sigset_t set;

	/*
	 * The signal frame is at SP.
	 *
	 * RA-Direct: The handler returned via JMP RA|I to the trampoline.
	 * SP was not modified by the return — it still points to the frame.
	 * The trampoline JUMPs (not CALLs) to __subleq_syscall.
	 * __subleq_syscall reads RA from the register, so SP is unchanged.
	 */
	frame = (struct rt_sigframe __user *)(PT_REG_GET(regs, sp));

	if (!access_ok(frame, sizeof(*frame)))
		goto badframe;

	/* Restore signal mask */
	if (__copy_from_user(&set, &frame->uc.uc_sigmask, sizeof(set)))
		goto badframe;

	set_current_blocked(&set);



	/* Restore registers */
	if (restore_sigcontext(regs, &frame->uc.uc_mcontext))
		goto badframe;



	/* Restore alternate signal stack */
	if (restore_altstack(&frame->uc.uc_stack))
		goto badframe;

	/*
	 * And the resume target saved at delivery. Without this the trap exit would compute it
	 * from ra, which is the right thing after an ordinary syscall and wrong here: this call
	 * restores a context that may have been interrupted anywhere.
	 */
	{
		unsigned long rte;

		if (!__get_user(rte, &frame->rte_pc))
			PT_REG_SET(regs, rte_pc, rte);
	}

	/*
	 * If the restored context was in a syscall with a restart error
	 * code, actually restart it now. We must verify syscall_nr >= 0
	 * to avoid spurious restarts from userspace r20 values.
	 */
	if (PT_REG_GET_SIGNED(regs, syscall_nr) >= 0) {
		long ret = PT_REG_GET_SIGNED(regs, r20);

		switch (ret) {
		case -ERESTARTNOINTR:
		case -ERESTARTSYS:
		case -ERESTARTNOHAND: {
			/*
			 * The original syscall needs to be restarted.
			 * We use the preserved orig_a1-a4 which contain the original
			 * syscall arguments, since r21-r24 were overwritten with signal
			 * handler arguments (signal number, siginfo, etc.)
			 */
			long nr = PT_REG_GET_SIGNED(regs, orig_r21);
			if (nr >= 0 && nr < __NR_syscalls) {
				syscall_fn_t fn = (syscall_fn_t)sys_call_table[nr];
				if (fn && sys_call_table[nr] != (void *)sys_ni_syscall) {
					/*
					 * Mark that we're in a syscall again for proper
					 * signal/restart handling during the restarted call.
					 */
					PT_REG_SET_SIGNED(regs, syscall_nr, nr);

					/*
					 * Restart the original syscall with the ORIGINAL
					 * arguments from when the syscall was first made.
					 */
					ret = fn(PT_REG_GET(regs, orig_a1),
						 PT_REG_GET(regs, orig_a2),
						 PT_REG_GET(regs, orig_a3),
						 PT_REG_GET(regs, orig_a4),
						 PT_REG_GET(regs, orig_a5),
						 PT_REG_GET(regs, orig_a6));
					PT_REG_SET_SIGNED(regs, r20, ret);

					/*
					 * The restarted syscall may have been interrupted again.
					 * Let do_signal handle any pending signals.
					 */

					do_signal(regs);
				}
			}
			break;
		}

		case -ERESTART_RESTARTBLOCK: {
			/*
			 * ERESTART_RESTARTBLOCK requires calling the restart_block
			 * function instead of the original syscall.
			 */
			struct restart_block *restart = &current->restart_block;
			PT_REG_SET_SIGNED(regs, r20, restart->fn(restart));

			do_signal(regs);
			break;
		}
		}
	}

	/*
	 * Now that restart handling is complete, invalidate the restart_block
	 * to prevent stale restart functions from being called if the signal
	 * handler corrupted it. This MUST come after the restart handling above.
	 */
	current->restart_block.fn = do_no_restart_syscall;

	/*
	 * Mark that we're NOT in a syscall.
	 * This prevents syscall_entry.c from attempting further restart
	 * processing on our return value.
	 */
	syscall_wont_restart(regs);

	/*
	 * Return the final R20 value.
	 */

	return PT_REG_GET_SIGNED(regs, r20);

badframe:

	force_sig(SIGSEGV);
	return 0;
}

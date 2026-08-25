// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq system call table
 */

#include <linux/linkage.h>
#include <linux/syscalls.h>
#include <linux/uaccess.h>
#include <linux/preempt.h>
#include <asm-generic/syscalls.h>
#include <asm/syscall.h>

/* Forward declarations for 32-bit syscalls that may not be declared
 * in syscalls.h due to conditional compilation */
asmlinkage long sys_fstat64(unsigned long fd, struct stat64 __user *statbuf);
asmlinkage long sys_fstatat64(int dfd, const char __user *filename,
			       struct stat64 __user *statbuf, int flag);

/* 
 * Build the syscall table by redefining __SYSCALL and including
 * the syscall table header (which has no include guard).
 */
/*
 * Atomic exchange on a user word, on behalf of userspace.
 *
 * There is no atomic read-modify-write instruction on this architecture: subleq has one
 * instruction and it is not atomic against preemption. NOMMU userspace faked it by disabling
 * interrupts through the registers at addresses 0 and 8; under MMU those are not userspace's to
 * touch (address 0 is the NULL guard), so the primitive lives here. linuxthreads' testandset()
 * is exactly xchg(ptr, 1).
 *
 * The guest is single-CPU, so disabling preemption is enough for this to be indivisible from any
 * other thread's point of view. The page is faulted in first, outside the critical section, so
 * nothing inside it can sleep.
 */
SYSCALL_DEFINE2(subleq_atomic_xchg, int __user *, uaddr, int, newval)
{
	int old;

	if (!access_ok(uaddr, sizeof(int)))
		return -EFAULT;
	if (get_user(old, uaddr))		/* fault the page in before going atomic */
		return -EFAULT;

	preempt_disable();
	if (__get_user(old, uaddr) || __put_user(newval, uaddr)) {
		preempt_enable();
		return -EFAULT;
	}
	preempt_enable();

	return old;
}

#undef __SYSCALL
#define __SYSCALL(nr, call) [nr] = (call),

void *sys_call_table[__NR_syscalls] = {
	[0 ... __NR_syscalls - 1] = sys_ni_syscall,
#include <asm/syscall_table.h>
};

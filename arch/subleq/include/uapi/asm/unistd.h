/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
/*
 * System call definitions for Subleq
 */

#ifndef _UAPI_ASM_SUBLEQ_UNISTD_H
#define _UAPI_ASM_SUBLEQ_UNISTD_H

/* Enable new stat syscalls (fstat, fstatat, etc.) */
#define __ARCH_WANT_NEW_STAT
#define __ARCH_WANT_STAT64

/* Enable 32-bit time syscalls (ppoll, pselect6, etc.) */
#define __ARCH_WANT_TIME32_SYSCALLS

/* Enable legacy syscalls that are superseded but still useful */
#define __ARCH_WANT_RENAMEAT

/* Use the generic system call table */
#include <asm-generic/unistd.h>

/*
 * Arch-specific additions, numbered after the generic table.
 *
 * subleq_atomic_xchg exists because this architecture has no atomic read-modify-write instruction
 * -- subleq is one instruction and that instruction is not atomic against preemption. On NOMMU,
 * userspace faked atomicity by disabling interrupts through the registers at addresses 0 and 8;
 * with memory protection that is (rightly) impossible, so the kernel provides the primitive.
 * linuxthreads' testandset() is built on it.
 */
/*
 * The generic table reserves a range for architecture-specific calls
 * (__NR_arch_specific_syscall), which is what riscv and friends use. Taking a slot there keeps
 * __NR_syscalls -- and therefore the table size -- exactly as the generic header set it. Defining
 * the number as __NR_syscalls and then bumping __NR_syscalls does not work: the two macros expand
 * through each other.
 */
#define __NR_subleq_atomic_xchg (__NR_arch_specific_syscall + 0)

#endif /* _UAPI_ASM_SUBLEQ_UNISTD_H */

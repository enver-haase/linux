/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Subleq syscall table header
 *
 * This file is included multiple times with different definitions
 * of __SYSCALL() to build the syscall table. It must NOT have an
 * include guard.
 *
 * NOTE: We define the __ARCH_WANT_* flags directly here instead of
 * including asm/unistd.h because that header includes the generic
 * unistd.h with the default no-op __SYSCALL macro. The syscalls.c
 * file defines __SYSCALL before including this header, so we must
 * not include unistd.h through any other path first.
 */

/* Enable syscall variants for Subleq */
#define __ARCH_WANT_NEW_STAT
#define __ARCH_WANT_STAT64
#define __ARCH_WANT_TIME32_SYSCALLS
#define __ARCH_WANT_RENAMEAT

/* Include the generic syscall table */
#include <uapi/asm-generic/unistd.h>

/* ... and the arch-specific tail (see uapi/asm/unistd.h for why this one exists) */
__SYSCALL(__NR_subleq_atomic_xchg, sys_subleq_atomic_xchg)

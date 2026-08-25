/* SPDX-License-Identifier: GPL-2.0 */
/*
 * ELF definitions for Subleq
 */

#ifndef _ASM_SUBLEQ_ELF_H
#define _ASM_SUBLEQ_ELF_H

#include <asm/ptrace.h>

/*
 * ELF register state for core dumps
 */
typedef unsigned long elf_greg_t;

#define ELF_NGREG (sizeof(struct pt_regs) / sizeof(elf_greg_t))
typedef elf_greg_t elf_gregset_t[ELF_NGREG];

/* No FPU */
typedef unsigned long elf_fpregset_t;

/*
 * ELF class - 32-bit
 */
#define ELF_CLASS ELFCLASS32

/*
 * ELF data encoding - little endian
 */
#define ELF_DATA ELFDATA2LSB

/*
 * ELF machine type
 * 
 * The Subleq LLVM backend uses EM_SUBLEQ.
 */
#define ELF_ARCH EM_SUBLEQ

/*
 * Check if this is a Subleq ELF binary.
 */
/*
 * Accept static ET_EXEC only when there is an MMU.
 *
 * There is no dynamic linker for this architecture. On NOMMU the kernel is the linker
 * (arch/subleq/kernel/binfmt_elf_subleq.c, built only for CONFIG_NOMMU); the MMU build uses the
 * generic loader, which would map an ET_DYN image and jump to its entry point with every
 * relocation still unresolved. That did not merely kill the process -- it halted the machine.
 * Refusing here turns it into a plain ENOEXEC. Porting the dynamic path is worth doing (a
 * dynamically linked launcher is 7 KB where the static one is 1.5 MB, and ScummVM is 57 MB mostly
 * because libc++ is copied into it), and this check is what that work removes.
 */
#define elf_check_arch(x) \
	((x)->e_machine == EM_SUBLEQ && (x)->e_ident[EI_CLASS] == ELFCLASS32 && \
	 (!IS_ENABLED(CONFIG_MMU) || (x)->e_type == ET_EXEC))

/*
 * Memory map for this architecture
 */
#define ELF_PLAT_INIT(_r, load_addr) \
	do {                         \
	} while (0)

#define ELF_EXEC_PAGESIZE PAGE_SIZE

#define ELF_ET_DYN_BASE (TASK_SIZE / 3 * 2)

/* No hardware capability bits or platform string on the subleq machine. */
#define ELF_HWCAP	(0)
#define ELF_PLATFORM	(NULL)

/*
 * Core dump register copy - de-negate pt_regs values for userspace tools.
 *
 * pt_regs stores values NEGATED for efficient Subleq assembly. When writing
 * a core dump, we must negate each word so GDB sees correct values.
 *
 * NOTE: elfcore.h calls this WITHOUT a trailing semicolon, so we use
 * an inline helper called as an expression statement with its own ';'.
 */
static inline void __elf_core_copy_regs(void *dest, const void *regs)
{
	const unsigned long *s = (const unsigned long *)regs;
	unsigned long *d = (unsigned long *)dest;
	int i;
	for (i = 0; i < (int)(sizeof(struct pt_regs)/sizeof(unsigned long)); i++)
		d[i] = (unsigned long)(-(long)s[i]);
}

#define ELF_CORE_COPY_REGS(dest, regs) \
	__elf_core_copy_regs(&(dest), (regs));

#endif /* _ASM_SUBLEQ_ELF_H */

/* SPDX-License-Identifier: GPL-2.0 */
/*
 * vmalloc support for Subleq
 *
 * NOMMU - vmalloc is just regular allocation
 */

#ifndef _ASM_SUBLEQ_VMALLOC_H
#define _ASM_SUBLEQ_VMALLOC_H

#include <asm/pgtable.h>

/*
 * NOMMU: vmalloc space is just the physical address space.
 * MMU: the kernel is identity-mapped (supervisor ignores CR_PTB) with no kernel
 * page table, so there is no vmalloc arena. Use an EMPTY range so is_vmalloc_addr()
 * is always false and allocations route to contiguous kmalloc (as under NOMMU).
 */
#ifdef CONFIG_MMU
/* Real vmalloc window, translated in supervisor mode through CR_KPTB (see the VM's
 * translate(): word idx >= MEM_WORDS = 0x18000000 = byte 0x60000000). Sits just above
 * physical RAM (1.5 GiB) and below 2 GiB — the upper bound matters because the VM's
 * operand word index is signed (v/4), so a >=2 GiB byte address would wrap negative. */
#define VMALLOC_START 0x60000000UL
#define VMALLOC_END   0x78000000UL
#else
#define VMALLOC_START 0UL
#define VMALLOC_END 0xffffffffUL
#endif

/* Align vmalloc area on module boundary */
#define VMALLOC_MODULE_START VMALLOC_START
#define VMALLOC_MODULE_END VMALLOC_END

#endif /* _ASM_SUBLEQ_VMALLOC_H */

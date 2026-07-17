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
 * translate(): word idx >= 0x30000000). Placed above physical RAM so it never overlaps
 * the identity direct map. */
#define VMALLOC_START 0xC0000000UL
#define VMALLOC_END   0xF0000000UL
#else
#define VMALLOC_START 0UL
#define VMALLOC_END 0xffffffffUL
#endif

/* Align vmalloc area on module boundary */
#define VMALLOC_MODULE_START VMALLOC_START
#define VMALLOC_MODULE_END VMALLOC_END

#endif /* _ASM_SUBLEQ_VMALLOC_H */

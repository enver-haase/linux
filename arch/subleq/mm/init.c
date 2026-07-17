// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq memory initialization
 */

#include <linux/init.h>
#include <linux/mm.h>
#include <linux/memblock.h>

#include <asm/page.h>
#include <asm/sections.h>
#include <asm/setup.h>
#ifdef CONFIG_MMU
#include <asm/pgtable.h>
#include <asm/subleq-cr.h>

/* Kernel page directory (init_mm.pgd). The kernel is identity-mapped in supervisor
 * mode, so this needs no entries — it exists only as init_mm's pgd and as the template
 * copied into new user pgds. Page-aligned, one page (PTRS_PER_PGD * 4 = 4096). */
pgd_t swapper_pg_dir[PTRS_PER_PGD] __aligned(PAGE_SIZE);

/* The MMU fault/trap vector, defined in kernel/entry.S. */
extern char subleq_fault_entry[];
#endif

/*
 * Memory initialization for NOMMU kernel
 * 
 * For NOMMU kernels, we need to:
 * 1. Set up high_memory pointer
 * 2. Allocate empty_zero_page
 * 3. Initialize memory zones via free_area_init()
 *
 * empty_zero_page is declared in pgtable.h but allocated here.
 */

/* Allocate the zero page from memblock */
void *empty_zero_page;

/*
 * paging_init - Set up memory zones for NOMMU kernel
 *
 * This must be called from setup_arch() to initialize the zone
 * allocator before mm_core_init() runs. Without this, the kernel
 * will report "Total pages: 0" and SLUB allocation will fail.
 */
void __init paging_init(void)
{
	unsigned long end_mem = subleq_memory_end & PAGE_MASK;
	unsigned long max_zone_pfn[MAX_NR_ZONES] = {
		0,
	};

	/* Set high_memory to end of physical memory */
	high_memory = (void *)end_mem;

	/* Allocate the zero page */
	empty_zero_page = memblock_alloc(PAGE_SIZE, PAGE_SIZE);
	if (!empty_zero_page)
		panic("Failed to allocate empty_zero_page\n");
	memset(empty_zero_page, 0, PAGE_SIZE);

	/* Set up min/max PFNs */
	min_low_pfn = PFN_UP(subleq_memory_start);
	max_low_pfn = PFN_DOWN(end_mem);
	max_mapnr = max_low_pfn;

	/*
	 * For NOMMU, all memory is in ZONE_NORMAL.
	 * This tells the zone allocator about our available memory.
	 */
	max_zone_pfn[ZONE_NORMAL] = max_low_pfn;

	/* Initialize memory zones - this is critical! */
	free_area_init(max_zone_pfn);

#ifdef CONFIG_MMU
	/*
	 * Install the fault/trap handler as CR_VECTOR (physical word index). The
	 * kernel is identity-mapped, so the physical address is the link address.
	 * After this, user-mode faults vector to subleq_fault_entry -> do_page_fault.
	 */
	subleq_set_vector((unsigned long)subleq_fault_entry >> 2);

	/*
	 * Install the kernel page-table base (CR_KPTB) = swapper_pg_dir. Supervisor-mode
	 * accesses to the vmalloc window (>= VMALLOC_START) are then translated through it,
	 * so generic mm/vmalloc.c (which maps into init_mm.pgd == swapper_pg_dir) works.
	 * The physical direct map stays identity (addresses below the window).
	 */
	subleq_set_kptb(__pa(swapper_pg_dir) >> 2);
#endif
}

/*
 * mem_init - Final memory initialization
 *
 * Called after zone setup is complete.
 */
void __init mem_init(void)
{
	/* Memory stats are now printed by generic code */
}

/*
 * Free memory from init sections after boot completes.
 * This includes:
 * - .init.text (init functions)
 * - .init.data (init data, including the built-in initramfs cpio archive)
 * - .init.setup, .initcall.init, etc.
 *
 * The initramfs cpio archive is embedded in .init.ramfs (within .init.data)
 * and is extracted to ramfs during boot. After extraction, this original
 * copy is no longer needed and can be freed to avoid memory duplication.
 */
void free_initmem(void)
{
	free_initmem_default(-1);
}

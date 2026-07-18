/* SPDX-License-Identifier: GPL-2.0 */
/*
 * vmlinux.lds.S - Linker script for Subleq architecture
 *
 * This linker script defines how the kernel binary is laid out in memory.
 * Subleq is a NOMMU architecture with a simple memory model.
 *
 * Modeled after arch/microblaze/kernel/vmlinux.lds.S
 */

/* Exception table alignment - needed by RO_DATA macro */
#define RO_EXCEPTION_TABLE_ALIGN	16

/*
 * Keep .exit.text sections at link time to avoid LLD relocation errors.
 * Built-in drivers reference their exit functions even though they won't
 * be called on NOMMU systems without module unloading.
 */
#define RUNTIME_DISCARD_EXIT

#include <asm/page.h>
#include <asm/cache.h>
#include <asm/thread_info.h>
#include <asm-generic/vmlinux.lds.h>

/*
 * Use i386 output format since Subleq uses 32-bit words and this is
 * what the LLVM backend generates.
 */
OUTPUT_FORMAT("elf32-subleq", "elf32-subleq", "elf32-subleq")
OUTPUT_ARCH(i386)
ENTRY(_start)

jiffies = jiffies_64;

SECTIONS
{
	/* Start at 8KB: page 0 = boot area + VM I/O / interrupt vectors / kernel
	 * scratch; page 1 = the relocated ESI register file (REG_BASE, see
	 * asm/subleq-regs.h). Both are reserved by setup.c (memblock_reserve 0,0x2000)
	 * and pre-initialised by tools/make_boot_image.py, so kernel text starts at
	 * page 2. (Was 0x1000 when the register file lived in page 0.) */
	. = 0x2000;

	_text = .;
	_stext = .;

	/* Text section */
	.text : AT(ADDR(.text) - LOAD_OFFSET) {
		HEAD_TEXT
		TEXT_TEXT
		SCHED_TEXT
		LOCK_TEXT
		KPROBES_TEXT
		IRQENTRY_TEXT
		SOFTIRQENTRY_TEXT
		*(.fixup)
		. = ALIGN(16);
		_etext = .;
	}

	/* Read-only data */
	. = ALIGN(16);
	RO_DATA(PAGE_SIZE)

	/* Read-write data - uses standard RW_DATA macro like microblaze */
	_sdata = .;
	RW_DATA(L1_CACHE_BYTES, PAGE_SIZE, THREAD_SIZE)
	_edata = .;

	/* Per-CPU data (minimal, we're single-CPU) */
	PERCPU_SECTION(L1_CACHE_BYTES)

	/* Init section - can be freed after boot */
	. = ALIGN(PAGE_SIZE);
	__init_begin = .;

	INIT_TEXT_SECTION(PAGE_SIZE)

	.init.data : AT(ADDR(.init.data) - LOAD_OFFSET) {
		INIT_DATA
		INIT_RAM_FS
	}

	.init.setup : AT(ADDR(.init.setup) - LOAD_OFFSET) {
		INIT_SETUP(16)
	}

	.initcall.init : AT(ADDR(.initcall.init) - LOAD_OFFSET) {
		INIT_CALLS
	}

	.con_initcall.init : AT(ADDR(.con_initcall.init) - LOAD_OFFSET) {
		CON_INITCALL
	}

	__init_end = .;

	/*
	 * BSS section - uninitialized data, zeroed at runtime
	 * CRITICAL: Subleq requires ALL addresses to be 4-byte aligned.
	 * Use alignment of 4 for sbss, bss, and stop to ensure proper alignment.
	 */
	. = ALIGN(PAGE_SIZE);
	BSS_SECTION(4, 4, 4)

	_end = .;

	/* Debug sections */
	STABS_DEBUG
	DWARF_DEBUG
	ELF_DETAILS

	/* Sections to discard */
	DISCARDS
}

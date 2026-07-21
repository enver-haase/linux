# SPDX-License-Identifier: GPL-2.0
# Kernel Makefile for Subleq

obj-y += head.o
obj-y += entry.o
obj-y += setup.o
obj-y += irq.o
obj-y += time.o
obj-y += process.o
obj-y += signal.o
obj-y += traps.o
obj-y += ptrace.o
obj-y += syscalls.o
obj-y += syscall_entry.o
obj-y += sys_subleq.o
obj-y += tty.o
obj-y += keyboard.o
# NOMMU uses the bespoke load-time-relocated ELF loader; MMU uses generic binfmt_elf.
obj-$(CONFIG_NOMMU) += binfmt_elf_subleq.o
obj-$(CONFIG_NOMMU) += elf_process_relr_section.o
obj-$(CONFIG_MMU) += subleq-cr.o
# Sound-card MMIO helpers (raw .word); the card exists on both NOMMU and MMU.
obj-$(CONFIG_SUBLEQ_SOUND) += subleq-sound.o
obj-$(CONFIG_FRAMEBUFFER_CONSOLE) += fbcon.o bitblit.o direct_putcs_asm.o


always-$(KBUILD_BUILTIN) := vmlinux.lds

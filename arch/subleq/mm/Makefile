# SPDX-License-Identifier: GPL-2.0
# Memory management for Subleq
#
# nommu.o: Subleq-optimized NOMMU with power-of-2 compound page allocations
# for efficient memory freeing (O(log n) instead of O(n) page frees)

obj-y += init.o
obj-$(CONFIG_MMU) += fault.o
obj-$(CONFIG_MMU) += uaccess.o
obj-$(CONFIG_MMU) += mmap.o
obj-$(CONFIG_NOMMU) += nommu.o

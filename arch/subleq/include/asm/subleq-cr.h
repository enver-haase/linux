/* SPDX-License-Identifier: GPL-2.0 */
/*
 * C-callable lunatix control-register helpers. Implemented in kernel/subleq-cr.S
 * (raw subleq, since a CR access can't be expressed as a C memory op). CR reads and
 * return-from-trap (CR_RTE) are done directly in kernel/entry.S's fault path, not here.
 */
#ifndef _ASM_SUBLEQ_CR_H
#define _ASM_SUBLEQ_CR_H

#ifndef __ASSEMBLY__
#ifdef CONFIG_MMU

/* Load CR_PTB: the user page-table base as a physical WORD index (0 = paging off). */
void subleq_load_ptb(unsigned long ptb_word_index);

#endif /* CONFIG_MMU */
#endif /* __ASSEMBLY__ */

#endif /* _ASM_SUBLEQ_CR_H */

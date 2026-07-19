/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Subleq interrupt entry/exit code
 */

#include <asm/asm-offsets.h>

.text
.globl subleq_irq_entry
.type subleq_irq_entry, @function

/* Interrupt control addresses */
.set INT_HANDLER, 0
.set INT_SAVED_PC, 4
.set INT_SAVED_HANDLER, 8

#include <asm/subleq-regs.h>

.set INT_Z, 224

/*
 * Kernel scratch/save slots (words 57-62, bytes 228-248)
 * Compact layout placing all kernel registers together.
 * Note: Words 64-67 (bytes 256-271) are clock registers (read-only).
 */
.set INT_Z2, 228         /* Scratch for address calculations (word 57) */
.set SAVE_SP, 232        /* Saved interrupted SP for restoration (word 58) */
.set SYSCALL_JMPTGT, 236 /* Syscall return jump target (word 59) - saved/restored by IRQ handler */
.set SAVE_JMPTGT, 240    /* Interrupt return jump target address (word 60) */
.set SW_Z, 244           /* Context switch scratch (word 61) */
.set SW_Z2, 248          /* Context switch second scratch (word 62) */
.set SYSCALL_SCRATCH, 252 /* Syscall return address pointer (word 63) - saved/restored by IRQ handler */
/* Words 64-67 (256-271) = struct timespec for clock (16 bytes on 64-bit host) - DO NOT USE */

/*
 * Interrupt entry point
 *
 * CRITICAL: Disable interrupts FIRST to prevent nested re-entry.
 * Then save the interrupted SP (which may be in an invalid state).
 *
 * Interrupts now run directly on the kernel stack (not a separate IRQ stack).
 * This enables proper preemptive context switching via preempt_schedule_irq().
 */
subleq_irq_entry:
        /*
         * PHASE -1: SELF-INTERRUPT DETECTION
         *
         * Check if we interrupted our own handler code. This happens when
         * Phase 4 re-enables interrupts and the timer fires before the
         * final jump to SAVE_JMPTGT completes.
         *
         * If INT_SAVED_PC (m[1]) is within [subleq_irq_entry, subleq_irq_entry_end),
         * skip this interrupt entirely and return to the interrupted handler code.
         *
         * Safe because:
         *   - INT_Z is IRQ-only scratch, safe to clobber without restore
         *   - Timer counter just reset (~300K instructions of headroom)
         *   - The interrupted handler resumes unaware anything happened
         *   - Lost timer tick is harmless; another fires in ~300K cycles
         */

        /* .Lhazard_scratch = INT_SAVED_PC (using INT_Z as intermediary) */
        .word   .Lhazard_scratch, .Lhazard_scratch, .+4  /* scratch = 0 */
        .word   INT_Z, INT_Z, .+4                         /* INT_Z = 0 */
        .word   INT_SAVED_PC, INT_Z, .+4                  /* INT_Z = -PC */
        .word   INT_Z, .Lhazard_scratch, .+4              /* scratch = PC */

        /* Check lower bound: scratch -= (start - 1); jump if <= 0 → PC < irq_start */
        .word   .Lconst_entry_start_m1, .Lhazard_scratch, .Lchk_fault_hazard

        /* Check upper bound: scratch -= (end - start); jump if <= 0 → PC < irq_end = IN HAZARD */
        .word   .Lconst_entry_size, .Lhazard_scratch, .Lin_hazard

        /* PC >= irq_end → check the MMU fault-entry range too */
        .word   INT_Z, INT_Z, .Lchk_fault_hazard

.Lchk_fault_hazard:
#ifdef CONFIG_MMU
        /*
         * A timer nested into subleq_fault_entry's ASM critical section would
         * clobber the scratch it shares with this path (INT_Z/INT_Z2/SAVE_SP/
         * subleq_fault_saved_pc). Skip such a timer, exactly as for the IRQ entry.
         * Reload scratch = PC (the IRQ check consumed it) and range-check
         * [subleq_fault_entry, subleq_fault_entry_end). While the fault handler is
         * in its C code (do_page_fault), PC is outside this range, so preemption
         * there still works — only the hand-written entry/exit ASM is guarded.
         */
        .word   .Lhazard_scratch, .Lhazard_scratch, .+4  /* scratch = 0 */
        .word   INT_Z, INT_Z, .+4                         /* INT_Z = 0 */
        .word   INT_SAVED_PC, INT_Z, .+4                  /* INT_Z = -PC */
        .word   INT_Z, .Lhazard_scratch, .+4              /* scratch = PC */
        .word   .Lconst_fault_start_m1, .Lhazard_scratch, .Lphase0a_start  /* PC < fault_start → normal */
        .word   .Lconst_fault_size, .Lhazard_scratch, .Lin_hazard          /* PC < fault_end → IN HAZARD */
#endif
        /* Not in either handler → not a self-interrupt, continue normally */
        .word   INT_Z, INT_Z, .Lphase0a_start

.Lin_hazard:
        /*
         * Self-interrupt detected! Return to the interrupted handler code.
         * .Lhazard_scratch is <= 0 here (from the range check that jumped us in)
         * and is dead after this jump, so use it as the branch cell — do NOT touch
         * INT_Z, which the fault entry keeps live across its own instructions.
         */
        .word   ZERO, .Lhazard_scratch, INT_SAVED_PC | INDIRECT

.Lphase0a_start:
        /*
         * PHASE 0a: DISABLE INTERRUPTS IMMEDIATELY
         *
         * Save m[0] to m[8] (INT_SAVED_HANDLER), then clear m[0].
         * Uses only INT_Z as scratch (address 224).
         */
        .word   INT_Z, INT_Z, .+4                   /* INT_Z = 0 */
        .word   INT_HANDLER, INT_Z, .+4              /* INT_Z = -handler */
        .word   INT_SAVED_HANDLER, INT_SAVED_HANDLER, .+4  /* m[8] = 0 */
        .word   INT_Z, INT_SAVED_HANDLER, .+4        /* m[8] = handler */
        .word   INT_HANDLER, INT_HANDLER, .+4         /* m[0] = 0 (disabled!) */

        /*
         * PHASE 0b: CHECK SP VALIDITY
         *
         * CRITICAL: In Subleq, SP updates are non-atomic (SP=0 then SP=new).
         * If we interrupt during this transition, SP is 0 or garbage.
         * We check SP FIRST and return immediately if invalid.
         *
         * Uses only INT_Z and INT_Z2 - the only registers safe to clobber
         * before saving state.
         *
         * Logic: INT_Z2 = 1 - SP
         *   If SP >= 1: 1 - SP <= 0, jump to valid (continue)
         *   If SP <= 0: 1 - SP > 0, fall through to skip
         */
        .word   INT_Z2, INT_Z2, .+4              /* INT_Z2 = 0 */
        .word   REG_SP, INT_Z2, .+4              /* INT_Z2 = -SP */
        .word   .Lconst_neg1, INT_Z2, .+4        /* INT_Z2 = -SP - (-1) = 1 - SP */
        .word   ZERO, INT_Z2, .Lsp_valid         /* jump if 1-SP <= 0 (SP >= 1) */

        /* SP <= 0: Invalid stack! Re-enable interrupts and return immediately */
.Lsp_invalid:
        .word   INT_Z, INT_Z, .+4
        .word   INT_SAVED_HANDLER, INT_Z, .+4
        .word   INT_HANDLER, INT_HANDLER, .+4
        .word   INT_Z, INT_HANDLER, .+4          /* m[0] = handler (re-enable) */
        .word   INT_Z, INT_Z, INT_SAVED_PC | INDIRECT  /* return to saved PC */

.Lsp_valid:
        /*
         * PHASE 0c: SAVE INTERRUPTED SP
         *
         * SP is valid (>= 1). Save it for later restoration.
         * SAVE_SP = -SP (negated for easy restore pattern)
         */
        .word   SAVE_SP, SAVE_SP, .+4            /* SAVE_SP = 0 */
        .word   REG_SP, SAVE_SP, .+4             /* SAVE_SP = -SP */

        /*
         * PHASE 1: DETERMINE KERNEL VS USER MODE AND SET UP STACK
         *
         * CRITICAL: If we're already on the kernel stack (kernel mode interrupt),
         * we must NOT reset SP to subleq_kernel_sp! That would overwrite the
         * existing kernel stack data. We must continue using the current SP.
         *
         * Check if SP is within kernel stack range:
         *   kstack_base <= SP < kstack_top
         * where kstack_top = subleq_kernel_sp, kstack_base = kstack_top - THREAD_SIZE
         *
         * We need TWO checks:
         * 1. SP < kstack_top (SP < subleq_kernel_sp)
         * 2. SP >= kstack_base (SP >= subleq_kernel_sp - 16384)
         *
         * If BOTH are true -> kernel mode, use current SP
         * Otherwise -> user mode, switch to subleq_kernel_sp
         */

        /*
         * Check 1: SP < kstack_top (SP < subleq_kernel_sp)
         * INT_Z2 = SP - kernel_sp
         * If INT_Z2 < 0 (SP < kernel_sp): passes check 1
         * If INT_Z2 >= 0 (SP >= kernel_sp): user mode (fail)
         *
         * OPT-9: SAVE_SP = -SP (from Phase 0c), reuse it.
         */
        .word   INT_Z2, INT_Z2, .+4              /* INT_Z2 = 0 */
        .word   SAVE_SP, INT_Z2, .+4             /* INT_Z2 = SP */
        .word   subleq_kernel_sp, INT_Z2, .+4    /* INT_Z2 = SP - kernel_sp */
        /*
         * Upper bound is kernel_sp + 1268, NOT kernel_sp: the syscall/fault entry
         * builds the interrupted task's user pt_regs at kernel_sp + 1024, and its
         * entry ASM and early C frame (subleq_trap/do_page_fault prologue) run with
         * SP in (kernel_sp, kernel_sp + 1268] — ABOVE kernel_sp. If a timer there is
         * mis-classified as a user-mode interrupt, .Lswitch_to_kernel rebuilds a
         * nested pt_regs at kernel_sp + 1024, overwriting that user pt_regs with
         * kernel-context registers; the syscall then restores a KERNEL sp into the
         * user task (the ~0x6067xxx wild-SP crash). Treat SP <= kernel_sp + 1268 as
         * kernel mode. (A user SP can never land in this tiny kernel-local window.)
         */
        .word   .Lconst_pos1268, INT_Z2, .+4     /* INT_Z2 = SP - kernel_sp - 1268 */
        .word   ZERO, INT_Z2, .Lkstack_upper_ok  /* if SP <= kernel_sp + 1268, in range */
        /* SP > kernel_sp + 1268: genuine user mode */
        .word   INT_Z, INT_Z, .Lswitch_to_kernel
.Lkstack_upper_ok:
        .word   .Lconst_neg1268, INT_Z2, .+4     /* INT_Z2 += 1268 = SP - kernel_sp (restore for check 2) */

.Lcheck_kstack_base:
        /*
         * Check 2: SP >= kstack_base (SP >= subleq_kernel_sp - 16384)
         * INT_Z2 = SP - (kernel_sp - 16384) = SP - kernel_sp + 16384
         * If INT_Z2 >= 0: SP >= kstack_base, kernel mode!
         * If INT_Z2 < 0: SP < kstack_base, user mode
         *
         * We already have INT_Z2 = SP - kernel_sp (which is <= 0)
         * Add 16384: INT_Z2 = SP - kernel_sp + 16384
         */
        .word   .Lconst_neg_thread_size, INT_Z2, .+4  /* INT_Z2 += 16384 */
        /* Now INT_Z2 = SP - kernel_sp + 16384 = SP - kstack_base */
        /* If INT_Z2 >= 0 (SP >= kstack_base): kernel mode */
        /* subleq ZERO, INT_Z2, .Lon_kernel: jumps if INT_Z2 <= 0 */
        /* We want kernel mode if INT_Z2 >= 0, i.e., NOT <= -1 */
        /* Add 1 to INT_Z2, then check <= 0 */
        .word   .Lconst_neg1, INT_Z2, .+4        /* INT_Z2 = SP - kstack_base + 1 */
        /* Now jump if INT_Z2 <= 0, i.e., SP - kstack_base + 1 <= 0, i.e., SP < kstack_base */
        .word   ZERO, INT_Z2, .Lswitch_to_kernel /* if SP < kstack_base, user mode */
        /* Fall through: SP >= kstack_base AND SP <= kernel_sp -> kernel mode */
        .word   INT_Z, INT_Z, .Lon_kernel_stack

        /* User mode: Switch to kernel stack */
        /*
         * Set SP so that after SYSCALL_JMPTGT/SCRATCH pushes (-8)
         * and pt_regs allocation (-PT_SIZE=236), pt_regs ends up at kernel_sp + 1024.
         * This matches task_pt_regs(current), ensuring signal delivery and sigreturn
         * use the same pt_regs location.
         *
         * Formula: SP = kernel_sp + 1024 + PT_SIZE + 8 = kernel_sp + 1268
         * After pushes: SP = kernel_sp + 1252
         * After SP -= PT_SIZE: SP = kernel_sp + 1024 = pt_regs = task_pt_regs!
         */
.Lswitch_to_kernel:
        .word   REG_SP, REG_SP, .+4              /* SP = 0 */
        .word   INT_Z, INT_Z, .+4                /* INT_Z = 0 */
        .word   subleq_kernel_sp, INT_Z, .+4     /* INT_Z = -kernel_sp */
        .word   .Lconst_neg1268, INT_Z, .+4      /* INT_Z = -(kernel_sp + 1268) */
        .word   INT_Z, REG_SP, .Lsave_done       /* SP = kernel_sp + 1268, goto save */

.Lon_kernel_stack:
        /* Already on kernel stack: keep using current SP (already in REG_SP) */

.Lsave_done:
        /*
         * Save SYSCALL_JMPTGT to kernel stack.
         * This global is used by syscall return for the final jump target.
         * It must be saved/restored so context switches don't clobber it.
         */
        .word   .Lconst_4, REG_SP, .+4                /* SP -= 4 */
        .word   REG_SP | INDIRECT, REG_SP | INDIRECT, .+4  /* [SP] = 0 */
        .word   SYSCALL_JMPTGT, REG_SP | INDIRECT, .+4    /* [SP] = -SYSCALL_JMPTGT */

        /*
         * Save SYSCALL_SCRATCH to kernel stack.
         * This global is used by syscall return for address arithmetic.
         * It must be saved/restored so context switches don't clobber it.
         */
        .word   .Lconst_4, REG_SP, .+4                /* SP -= 4 */
        .word   REG_SP | INDIRECT, REG_SP | INDIRECT, .+4  /* [SP] = 0 */
        .word   SYSCALL_SCRATCH, REG_SP | INDIRECT, .+4   /* [SP] = -SYSCALL_SCRATCH */

        /*
         * PHASE 2: BUILD pt_regs ON KERNEL STACK
         *
         * We allocate PT_SIZE (236) bytes on the kernel stack and build a
         * pt_regs structure that C code can read and modify.
         * Now includes T-registers and Z for proper signal handling.
         *
         * CRITICAL: C code expects POSITIVE values in pt_regs fields.
         * Subleq's natural store pattern (subleq A, B) stores -A.
         * We use double-negation to store positive values:
         *   TEMP = -value; [dest] = -TEMP = +value
         *
         * The pt_regs is now on the kernel stack (not a separate IRQ stack).
         * This enables proper preemption via preempt_schedule_irq().
         */

        /* Allocate pt_regs: SP -= PT_SIZE (236 bytes) */
        .word   .Lconst_pt_size, REG_SP, .+4
        /* NOTE: SP now points to pt_regs base. C calling convention preserves SP,
         * so after C calls return, SP still points to pt_regs. */


        /*
         * Fill pt_regs fields with POSITIVE values using double-negation.
         *
         * CRITICAL: We must populate ALL registers in pt_regs, not just the
         * signal-affected subset. This is because save_sigcontext() reads
         * ALL registers (r3-r31, fp, sp, ra, pc) when delivering a signal.
         * If we only populate a subset, the signal frame will contain garbage
         * for the unpopulated registers, corrupting the interrupted context.
         *
         * pt_regs layout (236 bytes total):
         *   r3-r19:      offsets 0-64
         *   r20:         offset 68
         *   r21-r24:     offsets 72-84
         *   r25-r31:     offsets 88-112
         *   fp:          offset 116
         *   sp:          offset 120
         *   ra:          offset 124
         *   pc:          offset 128
         *   orig_r20:    offset 132 (not needed for interrupts)
         *   syscall_nr:  offset 136 (set to -1 for interrupts)
         *   orig_r21:    offset 140 (not needed for interrupts)
         *   orig_a1-a4:  offsets 144-156 (not needed for interrupts)
         *   t0-t15:      offsets 160-220
         *   z:           offset 224
         *   orig_a5-a6:  offsets 228-232 (not needed for interrupts)
         *
         * NOTE: After PUSH_IRQ_REG, the hardware registers still contain their
         * original values (subleq reads but doesn't modify the A operand).
         * So we can read directly from REG_Rx to get the interrupted values.
         */

        /*
         * Use running pointer for pt_regs population.
         * Initialize INT_Z2 = SP (pt_regs base), then increment for each field.
         *
         * NEGATED STORAGE: pt_regs values are stored as -value.
         * C code uses PT_REG_GET() which negates to get +value.
         * This eliminates the double-negation overhead (saves ~2 instr/reg).
         *
         * Pattern per register:
         *   INT_Z2 -= -4        (advance pointer)
         *   [INT_Z2] = 0        (clear destination)
         *   [INT_Z2] -= REG     (store -REG)
         */

        /* Initialize running pointer: INT_Z2 = SP (current, post-switch SP) */
        .word   INT_Z2, INT_Z2, .+4              /* INT_Z2 = 0 */
        .word   INT_Z, INT_Z, .+4                /* INT_Z = 0 */
        .word   REG_SP, INT_Z, .+4               /* INT_Z = -SP */
        .word   INT_Z, INT_Z2, .+4               /* INT_Z2 = SP */

        /* Store r3 = -REG_R3 (offset 0) - NEGATED */
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4  /* [ptr] = 0 */
        .word   REG_R3, INT_Z2 | INDIRECT, .+4             /* [ptr] = -r3 */

        /* Store r4 (offset 4) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R4, INT_Z2 | INDIRECT, .+4

        /* Store r5 (offset 8) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R5, INT_Z2 | INDIRECT, .+4

        /* Store r6 (offset 12) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R6, INT_Z2 | INDIRECT, .+4

        /* Store r7 (offset 16) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R7, INT_Z2 | INDIRECT, .+4

        /* Store r8 (offset 20) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R8, INT_Z2 | INDIRECT, .+4

        /* Store r9 (offset 24) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R9, INT_Z2 | INDIRECT, .+4

        /* Store r10 (offset 28) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R10, INT_Z2 | INDIRECT, .+4

        /* Store r11 (offset 32) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R11, INT_Z2 | INDIRECT, .+4

        /* Store r12 (offset 36) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R12, INT_Z2 | INDIRECT, .+4

        /* Store r13 (offset 40) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R13, INT_Z2 | INDIRECT, .+4

        /* Store r14 (offset 44) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R14, INT_Z2 | INDIRECT, .+4

        /* Store r15 (offset 48) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R15, INT_Z2 | INDIRECT, .+4

        /* Store r16 (offset 52) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R16, INT_Z2 | INDIRECT, .+4

        /* Store r17 (offset 56) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R17, INT_Z2 | INDIRECT, .+4

        /* Store r18 (offset 60) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R18, INT_Z2 | INDIRECT, .+4

        /* Store r19 (offset 64) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R19, INT_Z2 | INDIRECT, .+4

        /* Store r20 (offset 68) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R20, INT_Z2 | INDIRECT, .+4

        /* Store r21 (offset 72) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R21, INT_Z2 | INDIRECT, .+4

        /* Store r22 (offset 76) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R22, INT_Z2 | INDIRECT, .+4

        /* Store r23 (offset 80) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R23, INT_Z2 | INDIRECT, .+4

        /* Store r24 (offset 84) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R24, INT_Z2 | INDIRECT, .+4

        /* Store r25 (offset 88) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R25, INT_Z2 | INDIRECT, .+4

        /* Store r26 (offset 92) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R26, INT_Z2 | INDIRECT, .+4

        /* Store r27 (offset 96) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R27, INT_Z2 | INDIRECT, .+4

        /* Store r28 (offset 100) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R28, INT_Z2 | INDIRECT, .+4

        /* Store r29 (offset 104) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R29, INT_Z2 | INDIRECT, .+4

        /* Store r30 (offset 108) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R30, INT_Z2 | INDIRECT, .+4

        /* Store r31 (offset 112) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R31, INT_Z2 | INDIRECT, .+4

        /* Store fp (offset 116) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_FP, INT_Z2 | INDIRECT, .+4

        /* Store sp = -original SP (offset 120) - NEGATED
         * SAVE_SP already contains -original_sp.
         * We want to store -sp for negated storage.
         *
         * Problem: [ptr] = 0; [ptr] -= SAVE_SP gives +sp (wrong!)
         * Solution: First negate SAVE_SP, then use the standard pattern:
         *   INT_Z = -SAVE_SP = -(-sp) = +sp
         *   [ptr] = 0
         *   [ptr] -= INT_Z = -sp  <-- correct!
         *
         * This takes 4 instructions instead of 2, but SP is special.
         */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z, INT_Z, .+4                          /* INT_Z = 0 */
        .word   SAVE_SP, INT_Z, .+4                        /* INT_Z = -SAVE_SP = +sp */
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4  /* [ptr] = 0 */
        .word   INT_Z, INT_Z2 | INDIRECT, .+4              /* [ptr] = -INT_Z = -sp */

        /* Store ra (offset 124) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_RA, INT_Z2 | INDIRECT, .+4

        /* Store pc = -INT_SAVED_PC (offset 128) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   INT_SAVED_PC, INT_Z2 | INDIRECT, .+4

        /* Skip orig_r20 (offset 132) - not used for interrupts */

        /* Store syscall_nr = -1 (offset 136) to mark as NOT a syscall
         * For negated storage, we store -(-1) = +1 so that PT_REG_GET reads -1 */
        .word   .Lconst_neg8, INT_Z2, .+4        /* Advance by 8: 128 -> 136 */
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   .Lconst_neg1, INT_Z2 | INDIRECT, .+4  /* [addr] = 0 - (-1) = +1 */

        /* Skip orig_r21, orig_a1-4 (offsets 140-156) - not used for interrupts
         * (orig_a5/a6 at offsets 228-232 are also skipped, past Z at 224) */
        /* Advance to T0 at offset 160: 136 -> 160 = +24 */
        .word   .Lconst_neg24, INT_Z2, .+4

        /* Store T0 (offset 160) - NEGATED */
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T0, INT_Z2 | INDIRECT, .+4

        /* Store T1 (offset 164) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T1, INT_Z2 | INDIRECT, .+4

        /* Store T2 (offset 168) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T2, INT_Z2 | INDIRECT, .+4

        /* Store T3 (offset 172) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T3, INT_Z2 | INDIRECT, .+4

        /* Store T4 (offset 176) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T4, INT_Z2 | INDIRECT, .+4

        /* Store T5 (offset 180) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T5, INT_Z2 | INDIRECT, .+4

        /* Store T6 (offset 184) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T6, INT_Z2 | INDIRECT, .+4

        /* Store T7 (offset 188) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T7, INT_Z2 | INDIRECT, .+4

        /* Store T8 (offset 192) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T8, INT_Z2 | INDIRECT, .+4

        /* Store T9 (offset 196) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T9, INT_Z2 | INDIRECT, .+4

        /* Store T10 (offset 200) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T10, INT_Z2 | INDIRECT, .+4

        /* Store T11 (offset 204) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T11, INT_Z2 | INDIRECT, .+4

        /* Store T12 (offset 208) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T12, INT_Z2 | INDIRECT, .+4

        /* Store T13 (offset 212) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T13, INT_Z2 | INDIRECT, .+4

        /* Store T14 (offset 216) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T14, INT_Z2 | INDIRECT, .+4

        /* Store T15 (offset 220) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T15, INT_Z2 | INDIRECT, .+4

        /* Store Z (offset 224) - NEGATED */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_Z, INT_Z2 | INDIRECT, .+4

        /*
         * Set R21 = pt_regs pointer (= SP) for the function call.
         * C calling convention preserves SP, so it will still point to pt_regs
         * after the C functions return.
         */
        .word   REG_R21, REG_R21, .+4
        .word   INT_Z, INT_Z, .+4
        .word   REG_SP, INT_Z, .+4
        .word   INT_Z, REG_R21, .+4


        /* RA-Direct call to subleq_do_IRQ */
        .word   REG_RA, REG_RA, .+4                          /* RA = 0 */
        .word   .Lirq_return_neg, REG_RA, .+4                /* RA = .Lirq_returned */
        .word   REG_Z, REG_Z, subleq_do_IRQ

        /*
         * PHASE 2b: WORK LOOP (ColdFire pattern)
         *
         * We're already on the kernel stack, so subleq_do_work() can safely
         * call preempt_schedule_irq() if needed - context switches work correctly.
         *
         * subleq_do_work returns:
         *   0 = no work done, safe to return
         *   non-zero = work was done, loop back to check for more
         */
.Lirq_returned:

        /* Set R21 = pt_regs pointer (= current SP) */
        .word   REG_R21, REG_R21, .+4
        .word   INT_Z, INT_Z, .+4
        .word   REG_SP, INT_Z, .+4
        .word   INT_Z, REG_R21, .+4              /* R21 = SP = pt_regs */

.Lwork_loop:
        /* RA-Direct call to subleq_do_work(regs) */
        .word   REG_RA, REG_RA, .+4                          /* RA = 0 */
        .word   .Lwork_return_neg, REG_RA, .+4                /* RA = .Lwork_returned */
        .word   REG_Z, REG_Z, subleq_do_work

.Lwork_returned:
        /* Check R20: if <= 0, done. Otherwise reload R21 and loop.
         * CRITICAL: Must use ZERO (constant 0 at address 144), NOT REG_Z
         * (scratch at address 12). REG_Z is clobbered by C functions.
         * If REG_Z happened to be negative, R20 -= Z would make R20
         * positive even when subleq_do_work() returned 0, causing an
         * infinite work loop (system hang).
         */
        .word   ZERO, REG_R20, .Lno_more_work    /* If R20 <= 0, done */

        /* R20 > 0: more work. Reload R21 from SP (C calling convention preserves SP) */
        .word   REG_R21, REG_R21, .+4
        .word   INT_Z, INT_Z, .+4
        .word   REG_SP, INT_Z, .+4
        .word   INT_Z, REG_R21, .+4              /* R21 = SP = pt_regs */
        .word   INT_Z, INT_Z, .Lwork_loop

.Lno_more_work:
        /*
         * NOTE: We rely on C calling convention to preserve SP.
         * SP should still point to pt_regs after the C functions return.
         */

        /*
         * OPTIMIZED: Use running pointer for PC/SP reading.
         * Initialize INT_Z2 = SP + 120, read sp, advance +8, read pc.
         */

        /* Initialize running pointer: INT_Z2 = SP + 120 */
        .word   INT_Z2, INT_Z2, .+4
        .word   INT_Z, INT_Z, .+4
        .word   REG_SP, INT_Z, .+4
        .word   INT_Z, INT_Z2, .+4
        .word   .Lconst_neg120, INT_Z2, .+4

        /* Read pt_regs->sp (offset 120) into SAVE_SP for SP restore
         * With negated storage, pt_regs->sp contains -sp.
         * The restore does: REG_SP = 0; REG_SP -= SAVE_SP = -SAVE_SP
         * So we need SAVE_SP = -sp to get REG_SP = sp
         *
         * Since pt_regs->sp = -sp, we need to copy it without double-negation.
         * Pattern: INT_Z = -[ptr] = -(-sp) = +sp; SAVE_SP = -INT_Z = -sp */
        .word   INT_Z, INT_Z, .+4
        .word   INT_Z2 | INDIRECT, INT_Z, .+4    /* INT_Z = -(-sp) = +sp */
        .word   SAVE_SP, SAVE_SP, .+4            /* SAVE_SP = 0 */
        .word   INT_Z, SAVE_SP, .+4              /* SAVE_SP = -sp */

        /* Advance pointer by 8: INT_Z2 += 8 (120 -> 128) */
        .word   .Lconst_neg8, INT_Z2, .+4

        /* Read pt_regs->pc (offset 128) into SAVE_JMPTGT for return jump
         * With negated storage, pt_regs->pc contains -pc.
         * We need +pc in SAVE_JMPTGT. Use simplified pattern:
         * SAVE_JMPTGT = 0; SAVE_JMPTGT -= [ptr] = -(-pc) = +pc */
        .word   SAVE_JMPTGT, SAVE_JMPTGT, .+4            /* SAVE_JMPTGT = 0 */
        .word   INT_Z2 | INDIRECT, SAVE_JMPTGT, .+4      /* SAVE_JMPTGT = +pc */


        /*
         * PHASE 3a: RESTORE ALL GPRs FROM pt_regs
         *
         * This MUST happen BEFORE we pop pt_regs from the stack!
         * Load r3-r31, fp, ra from pt_regs. These may have been modified
         * by signal delivery (particularly r21-r23, ra for signal handler).
         *
         * NEGATED STORAGE: pt_regs values are stored as -value.
         * To restore: reg = 0; reg -= [ptr] = -(-value) = value
         *
         * OPT-1: INT_Z2 is currently at SP+128 (after reading PC).
         * Rewind to SP+0 by subtracting 128 (1 insn vs 4).
         */
        .word   .Lconst_128, INT_Z2, .+4         /* INT_Z2 = SP+128 - 128 = SP */

        /* Load R3 from pt_regs->r3 (offset 0) - from NEGATED storage */
        .word   REG_R3, REG_R3, .+4                /* reg = 0 */
        .word   INT_Z2 | INDIRECT, REG_R3, .+4     /* reg = -(-value) = value */

        /* Load R4 (offset 4) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R4, REG_R4, .+4
        .word   INT_Z2 | INDIRECT, REG_R4, .+4

        /* Load R5 (offset 8) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R5, REG_R5, .+4
        .word   INT_Z2 | INDIRECT, REG_R5, .+4

        /* Load R6 (offset 12) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R6, REG_R6, .+4
        .word   INT_Z2 | INDIRECT, REG_R6, .+4

        /* Load R7 (offset 16) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R7, REG_R7, .+4
        .word   INT_Z2 | INDIRECT, REG_R7, .+4

        /* Load R8 (offset 20) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R8, REG_R8, .+4
        .word   INT_Z2 | INDIRECT, REG_R8, .+4

        /* Load R9 (offset 24) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R9, REG_R9, .+4
        .word   INT_Z2 | INDIRECT, REG_R9, .+4

        /* Load R10 (offset 28) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R10, REG_R10, .+4
        .word   INT_Z2 | INDIRECT, REG_R10, .+4

        /* Load R11 (offset 32) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R11, REG_R11, .+4
        .word   INT_Z2 | INDIRECT, REG_R11, .+4

        /* Load R12 (offset 36) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R12, REG_R12, .+4
        .word   INT_Z2 | INDIRECT, REG_R12, .+4

        /* Load R13 (offset 40) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R13, REG_R13, .+4
        .word   INT_Z2 | INDIRECT, REG_R13, .+4

        /* Load R14 (offset 44) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R14, REG_R14, .+4
        .word   INT_Z2 | INDIRECT, REG_R14, .+4

        /* Load R15 (offset 48) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R15, REG_R15, .+4
        .word   INT_Z2 | INDIRECT, REG_R15, .+4

        /* Load R16 (offset 52) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R16, REG_R16, .+4
        .word   INT_Z2 | INDIRECT, REG_R16, .+4

        /* Load R17 (offset 56) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R17, REG_R17, .+4
        .word   INT_Z2 | INDIRECT, REG_R17, .+4

        /* Load R18 (offset 60) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R18, REG_R18, .+4
        .word   INT_Z2 | INDIRECT, REG_R18, .+4

        /* Load R19 (offset 64) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R19, REG_R19, .+4
        .word   INT_Z2 | INDIRECT, REG_R19, .+4

        /* Load R20 (offset 68) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R20, REG_R20, .+4
        .word   INT_Z2 | INDIRECT, REG_R20, .+4

        /* Load R21 (offset 72) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R21, REG_R21, .+4
        .word   INT_Z2 | INDIRECT, REG_R21, .+4

        /* Load R22 (offset 76) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R22, REG_R22, .+4
        .word   INT_Z2 | INDIRECT, REG_R22, .+4

        /* Load R23 (offset 80) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R23, REG_R23, .+4
        .word   INT_Z2 | INDIRECT, REG_R23, .+4

        /* Load R24 (offset 84) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R24, REG_R24, .+4
        .word   INT_Z2 | INDIRECT, REG_R24, .+4

        /* Load R25 (offset 88) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R25, REG_R25, .+4
        .word   INT_Z2 | INDIRECT, REG_R25, .+4

        /* Load R26 (offset 92) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R26, REG_R26, .+4
        .word   INT_Z2 | INDIRECT, REG_R26, .+4

        /* Load R27 (offset 96) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R27, REG_R27, .+4
        .word   INT_Z2 | INDIRECT, REG_R27, .+4

        /* Load R28 (offset 100) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R28, REG_R28, .+4
        .word   INT_Z2 | INDIRECT, REG_R28, .+4

        /* Load R29 (offset 104) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R29, REG_R29, .+4
        .word   INT_Z2 | INDIRECT, REG_R29, .+4

        /* Load R30 (offset 108) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R30, REG_R30, .+4
        .word   INT_Z2 | INDIRECT, REG_R30, .+4

        /* Load R31 (offset 112) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_R31, REG_R31, .+4
        .word   INT_Z2 | INDIRECT, REG_R31, .+4

        /* Load FP (offset 116) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_FP, REG_FP, .+4
        .word   INT_Z2 | INDIRECT, REG_FP, .+4

        /* Skip SP (offset 120) - handled separately via SAVE_SP */

        /* Load RA (offset 124) - from NEGATED storage */
        .word   .Lconst_neg8, INT_Z2, .+4    /* Skip SP: 116 -> 124 */
        .word   REG_RA, REG_RA, .+4
        .word   INT_Z2 | INDIRECT, REG_RA, .+4

        /*
         * PHASE 3b: Load T-registers and Z from pt_regs
         *
         * Continue from RA at offset 124, skip to T0 at offset 160.
         * INT_Z2 is currently at offset 124.
         */

        /* Skip from RA (124) to T0 (160): advance by 36 */
        .word   .Lconst_neg36, INT_Z2, .+4

        /* Load T0 (offset 160) - from NEGATED storage */
        .word   REG_T0, REG_T0, .+4
        .word   INT_Z2 | INDIRECT, REG_T0, .+4

        /* Load T1 (offset 164) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T1, REG_T1, .+4
        .word   INT_Z2 | INDIRECT, REG_T1, .+4

        /* Load T2 (offset 168) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T2, REG_T2, .+4
        .word   INT_Z2 | INDIRECT, REG_T2, .+4

        /* Load T3 (offset 172) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T3, REG_T3, .+4
        .word   INT_Z2 | INDIRECT, REG_T3, .+4

        /* Load T4 (offset 176) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T4, REG_T4, .+4
        .word   INT_Z2 | INDIRECT, REG_T4, .+4

        /* Load T5 (offset 180) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T5, REG_T5, .+4
        .word   INT_Z2 | INDIRECT, REG_T5, .+4

        /* Load T6 (offset 184) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T6, REG_T6, .+4
        .word   INT_Z2 | INDIRECT, REG_T6, .+4

        /* Load T7 (offset 188) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T7, REG_T7, .+4
        .word   INT_Z2 | INDIRECT, REG_T7, .+4

        /* Load T8 (offset 192) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T8, REG_T8, .+4
        .word   INT_Z2 | INDIRECT, REG_T8, .+4

        /* Load T9 (offset 196) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T9, REG_T9, .+4
        .word   INT_Z2 | INDIRECT, REG_T9, .+4

        /* Load T10 (offset 200) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T10, REG_T10, .+4
        .word   INT_Z2 | INDIRECT, REG_T10, .+4

        /* Load T11 (offset 204) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T11, REG_T11, .+4
        .word   INT_Z2 | INDIRECT, REG_T11, .+4

        /* Load T12 (offset 208) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T12, REG_T12, .+4
        .word   INT_Z2 | INDIRECT, REG_T12, .+4

        /* Load T13 (offset 212) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T13, REG_T13, .+4
        .word   INT_Z2 | INDIRECT, REG_T13, .+4

        /* Load T14 (offset 216) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T14, REG_T14, .+4
        .word   INT_Z2 | INDIRECT, REG_T14, .+4

        /* Load T15 (offset 220) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_T15, REG_T15, .+4
        .word   INT_Z2 | INDIRECT, REG_T15, .+4

        /* Load Z (offset 224) - from NEGATED storage */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   REG_Z, REG_Z, .+4
        .word   INT_Z2 | INDIRECT, REG_Z, .+4

        /*
         * PHASE 3c: Deallocate pt_regs from kernel stack
         */

        /* Pop pt_regs: SP += PT_SIZE */
        .word   .Lconst_neg_pt_size, REG_SP, .+4

        /*
         * Restore SYSCALL_SCRATCH from kernel stack (LIFO - pushed last, pop first).
         * This was saved at interrupt entry to preserve syscall scratch space.
         */
        .word   SYSCALL_SCRATCH, SYSCALL_SCRATCH, .+4     /* SYSCALL_SCRATCH = 0 */
        .word   REG_SP | INDIRECT, SYSCALL_SCRATCH, .+4   /* SYSCALL_SCRATCH = -[SP] */
        .word   .Lconst_neg4, REG_SP, .+4                 /* SP += 4 */

        /*
         * Restore SYSCALL_JMPTGT from kernel stack (LIFO - pushed first, pop second).
         * This was saved at interrupt entry to preserve syscall return target.
         */
        .word   SYSCALL_JMPTGT, SYSCALL_JMPTGT, .+4       /* SYSCALL_JMPTGT = 0 */
        .word   REG_SP | INDIRECT, SYSCALL_JMPTGT, .+4    /* SYSCALL_JMPTGT = -[SP] */
        .word   .Lconst_neg4, REG_SP, .+4                 /* SP += 4 */

        /*
         * PHASE 3d: RESTORE INTERRUPTED SP
         *
         * Restore SP from SAVE_SP (which we saved at interrupt entry).
         * SAVE_SP contains -sp (negated).
         * SP = 0; SP -= SAVE_SP = -(-sp) = sp
         */
        .word   REG_SP, REG_SP, .+4
        .word   SAVE_SP, REG_SP, .+4



.Lrestore_done:
        /* PHASE 4: RE-ENABLE INTERRUPTS AND RETURN
         *
         * After re-enabling (m[0] = handler), there is a hazard window until
         * the final jump to SAVE_JMPTGT executes. If a timer interrupt fires
         * during this window, the Phase -1 self-interrupt detection at handler
         * entry will detect it and return immediately.
         */

        /* SAVE_JMPTGT now contains the (potentially modified) return PC */
.Ldo_jump:
.Lenable_irq:
        .word   INT_Z, INT_Z, .+4
        .word   INT_SAVED_HANDLER, INT_Z, .+4
        .word   INT_HANDLER, INT_HANDLER, .+4
        .word   INT_Z, INT_HANDLER, .+4

        .word   INT_Z, INT_Z, SAVE_JMPTGT | INDIRECT

.Ljump_failed:
        .word   .Lconst_char_I, -4, .Lhang
.Lhang:
        .word   INT_Z, INT_Z, .Lhang

.Lirq_return_neg:
        .word   -.Lirq_returned

.Lwork_return_neg:
        .word   -.Lwork_returned

.Lconst_char_W:
        .word   87              /* 'W' for Work loop debug */


.globl subleq_irq_entry_end
subleq_irq_entry_end:
.size subleq_irq_entry, .-subleq_irq_entry



/*
 * ===========================================================================
 * Context Switch Implementation (RE-ENTRANT VERSION)
 * ===========================================================================
 *
 * __switch_to(prev, next) - Switch from prev task to next task
 *
 * Arguments:
 *   R21 = prev (struct task_struct *)
 *   R22 = next (struct task_struct *)
 *
 * Returns:
 *   R20 = prev
 *
 * This function uses Subleq+ indirect addressing to avoid self-modifying code,
 * making it fully re-entrant and safe for use when interrupts are enabled.
 *
 * The key technique is using the indirect flag (|1) on operands:
 *   - A|1 means: use m[A] as the actual A address (dereference)
 *   - B|1 means: use m[B] as the actual B address (dereference)
 *   - C|1 means: jump to m[C] instead of C
 *
 * This function:
 *   1. Pushes RA to prev's stack
 *   2. Saves SP to prev->thread.sp
 *   3. Loads SP from next->thread.sp
 *   4. Pops RA from next's stack
 *   5. Returns (to the return address saved by next's previous switch)
 */

/*
 * TASK_THREAD_SP and TASK_THREAD_FP are now generated in asm-offsets.h
 * and included via #include <asm/asm-offsets.h> at the top of this file.
 * This ensures the offsets are always correct regardless of kernel config
 * (e.g., CONFIG_PREEMPT=y adds fields to task_struct, shifting thread).
 */


.globl __switch_to
.type __switch_to, @function
__switch_to:
        /*
         * __switch_to(prev, next) - Context switch with full register save
         *
         * Arguments: R21 = prev, R22 = next
         * Returns: R20 = prev
         *
         * RA-Direct: RA register holds the return address on entry.
         * We push RA to the stack first, so the rest of the function sees
         * the same layout as the old convention: [SP] = -RA.
         *
         * We allocate a switch_stack (96 bytes) BELOW the return address,
         * save all 24 callee-saved registers there, then save SP.
         *
         * On restore, we load SP, restore registers, then pop and jump to
         * the return address.
         *
         * Stack layout after save:
         *   [SP+96] = return address (pushed by our prologue)
         *   [SP+0..96] = switch_stack (25 registers, including R20)
         */

        /*
         * STEP 0: Save RA to stack (RA-Direct prologue)
         */
        .word   .Lconst_4, REG_SP, .+4              /* SP -= 4 */
        .word   REG_SP | INDIRECT, REG_SP | INDIRECT, .+4  /* [SP] = 0 */
        .word   REG_RA, REG_SP | INDIRECT, .+4      /* [SP] = -RA */

        /*
         * STEP 1: Allocate switch_stack: SP -= 100
         */
        .word   .Lconst_100, REG_SP, .Lsw_save_regs_start

        /*
         * STEP 2: Save callee-saved registers to switch_stack
         *
         * We save R3-R19 (17 regs) at offsets 0-64
         * then R20 (1 reg, for vfork) at offset 68
         * and R25-R31 (7 regs) at offsets 72-96
         *
         * For each register, we compute SP + offset into SW_Z2,
         * then store the register value there using indirect addressing.
         */
.Lsw_save_regs_start:
        /*
         * OPTIMIZED: Use running pointer in SW_Z2
         * Initialize SW_Z2 = SP - 4, then each save increments by 4
         * Reduces from 9 to 3 instructions per register
         */
        .word   SW_Z2, SW_Z2, .+4
        .word   SW_Z, SW_Z, .+4
        .word   REG_SP, SW_Z, .+4
        .word   SW_Z, SW_Z2, .+4              /* SW_Z2 = SP */
        .word   .Lconst_4, SW_Z2, .+4       /* SW_Z2 = SP - 4 */

        /* Save R3 at [SP + 0] */
        .word   .Lconst_neg4, SW_Z2, .+4                          /* SW_Z2 += 4 */
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4       /* [SW_Z2] = 0 */
        .word   REG_R3, SW_Z2 | INDIRECT, .+4                  /* [SW_Z2] = -R3 */

        /* Save R4 at [SP + 4] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R4, SW_Z2 | INDIRECT, .+4

        /* Save R5 at [SP + 8] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R5, SW_Z2 | INDIRECT, .+4

        /* Save R6 at [SP + 12] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R6, SW_Z2 | INDIRECT, .+4

        /* Save R7 at [SP + 16] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R7, SW_Z2 | INDIRECT, .+4

        /* Save R8 at [SP + 20] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R8, SW_Z2 | INDIRECT, .+4

        /* Save R9 at [SP + 24] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R9, SW_Z2 | INDIRECT, .+4

        /* Save R10 at [SP + 28] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R10, SW_Z2 | INDIRECT, .+4

        /* Save R11 at [SP + 32] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R11, SW_Z2 | INDIRECT, .+4

        /* Save R12 at [SP + 36] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R12, SW_Z2 | INDIRECT, .+4

        /* Save R13 at [SP + 40] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R13, SW_Z2 | INDIRECT, .+4

        /* Save R14 at [SP + 44] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R14, SW_Z2 | INDIRECT, .+4

        /* Save R15 at [SP + 48] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R15, SW_Z2 | INDIRECT, .+4

        /* Save R16 at [SP + 52] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R16, SW_Z2 | INDIRECT, .+4

        /* Save R17 at [SP + 56] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R17, SW_Z2 | INDIRECT, .+4

        /* Save R18 at [SP + 60] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R18, SW_Z2 | INDIRECT, .+4

        /* Save R19 at [SP + 64] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R19, SW_Z2 | INDIRECT, .+4

        /* Save R20 at [SP + 68] - needed for vfork CLONE_VM fix */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R20, SW_Z2 | INDIRECT, .+4

        /* Save R25 at [SP + 72] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R25, SW_Z2 | INDIRECT, .+4

        /* Save R26 at [SP + 76] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R26, SW_Z2 | INDIRECT, .+4

        /* Save R27 at [SP + 80] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R27, SW_Z2 | INDIRECT, .+4

        /* Save R28 at [SP + 84] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R28, SW_Z2 | INDIRECT, .+4

        /* Save R29 at [SP + 88] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R29, SW_Z2 | INDIRECT, .+4

        /* Save R30 at [SP + 92] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R30, SW_Z2 | INDIRECT, .+4

        /* Save R31 at [SP + 96] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4
        .word   REG_R31, SW_Z2 | INDIRECT, .Lsw_save_sp_fp

        /*
         * STEP 3: Save SP and FP to prev->thread (SW-1: fused)
         *
         * thread.sp and thread.fp are adjacent (offsets 0 and 4 within
         * thread_struct). Compute &prev->thread.sp once, then advance
         * by 4 for fp. Saves 4 instructions vs independent calculations.
         */
.Lsw_save_sp_fp:
        /* Calculate &prev->thread.sp into SW_Z2 */
        .word   SW_Z, SW_Z, .+4
        .word   REG_R21, SW_Z, .+4
        .word   SW_Z2, SW_Z2, .+4
        .word   SW_Z, SW_Z2, .+4              /* SW_Z2 = prev */
        .word   .Lconst_neg_task_thread_sp, SW_Z2, .+4       /* SW_Z2 = &prev->thread.sp */
        /* Store SP */
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4      /* [dest] = 0 */
        .word   SW_Z, SW_Z, .+4
        .word   REG_SP, SW_Z, .+4                            /* SW_Z = -SP */
        .word   SW_Z, SW_Z2 | INDIRECT, .+4                  /* [dest] = SP */
        /* Advance to &prev->thread.fp */
        .word   .Lconst_neg4, SW_Z2, .+4                     /* SW_Z2 += 4 */
        /* Store FP */
        .word   SW_Z2 | INDIRECT, SW_Z2 | INDIRECT, .+4      /* [dest] = 0 */
        .word   SW_Z, SW_Z, .+4
        .word   REG_FP, SW_Z, .+4                            /* SW_Z = -FP */
        .word   SW_Z, SW_Z2 | INDIRECT, .Lsw_update_current  /* [dest] = FP */

        /*
         * STEP 4: Update __current_task = next
         *
         * With CONFIG_THREAD_INFO_IN_TASK, 'current' is a global volatile
         * pointer (__current_task) rather than being derived from SP.
         * We must update it here before loading next's stack.
         *
         * SW_Z = -R22 = -next is also reused by STEP 4b below.
         */
.Lsw_update_current:
        .word   SW_Z, SW_Z, .+4
        .word   REG_R22, SW_Z, .+4                            /* SW_Z = -next */
        .word   __current_task, __current_task, .+4            /* __current_task = 0 */
        .word   SW_Z, __current_task, .Lsw_update_kernel_sp   /* __current_task = next */

        /*
         * STEP 4b: Update subleq_kernel_sp for next task
         *
         * IMPORTANT: Without this, all tasks would use init_task's kernel stack
         * for syscalls, causing corruption when multiple tasks make syscalls.
         *
         * Formula: subleq_kernel_sp = next->stack + KERNEL_SP_OFFSET
         * where KERNEL_SP_OFFSET = THREAD_SIZE - sizeof(pt_regs) - 1024
         *
         * SW_Z still = -R22 = -next from Step 4. Reuse directly.
         */
.Lsw_update_kernel_sp:
        /* Load next->stack into SW_Z2. SW_Z = -next (cached from Step 4) */
        .word   SW_Z2, SW_Z2, .+4
        .word   SW_Z, SW_Z2, .+4                              /* SW_Z2 = next */
        .word   .Lconst_neg_task_stack, SW_Z2, .+4            /* SW_Z2 = &next->stack */
        /* Load [SW_Z2] (the stack page pointer) into SW_Z */
        .word   SW_Z, SW_Z, .+4
        .word   SW_Z2 | INDIRECT, SW_Z, .+4                   /* SW_Z = -next->stack */
        /* Compute kernel_sp = stack + KERNEL_SP_OFFSET */
        .word   SW_Z2, SW_Z2, .+4
        .word   SW_Z, SW_Z2, .+4                              /* SW_Z2 = next->stack */
        .word   .Lconst_neg_kernel_sp_offset, SW_Z2, .+4      /* SW_Z2 = stack + KERNEL_SP_OFFSET */
        /* Store to subleq_kernel_sp */
        .word   SW_Z, SW_Z, .+4
        .word   SW_Z2, SW_Z, .+4                              /* SW_Z = -kernel_sp */
        .word   subleq_kernel_sp, subleq_kernel_sp, .+4       /* clear */
        .word   SW_Z, subleq_kernel_sp, .Lsw_load_sp_fp      /* store */

        /*
         * STEP 5: Load SP and FP from next->thread (SW-2: fused)
         *
         * Like SW-1, thread.sp and thread.fp are adjacent. Compute
         * &next->thread.sp once, load SP, advance by 4, load FP.
         * Saves 5 instructions vs independent calculations.
         */
.Lsw_load_sp_fp:
        .word   SW_Z, SW_Z, .+4
        .word   REG_R22, SW_Z, .+4
        .word   SW_Z2, SW_Z2, .+4
        .word   SW_Z, SW_Z2, .+4
        .word   .Lconst_neg_task_thread_sp, SW_Z2, .+4       /* SW_Z2 = &next->thread.sp */
        /* Load [SW_Z2] into SP */
        .word   SW_Z, SW_Z, .+4
        .word   SW_Z2 | INDIRECT, SW_Z, .+4
        .word   REG_SP, REG_SP, .+4
        .word   SW_Z, REG_SP, .+4                            /* SP = next->thread.sp */
        /* Advance to &next->thread.fp */
        .word   .Lconst_neg4, SW_Z2, .+4                     /* SW_Z2 += 4 */
        /* Load [SW_Z2] into FP */
        .word   SW_Z, SW_Z, .+4
        .word   SW_Z2 | INDIRECT, SW_Z, .+4
        .word   REG_FP, REG_FP, .+4
        .word   SW_Z, REG_FP, .Lsw_restore_regs_start

        /*
         * STEP 6: Restore callee-saved registers from switch_stack
         *
         * Similar to save, but loading from [SP + offset] into registers.
         */
.Lsw_restore_regs_start:
        /*
         * OPTIMIZED: Use running pointer in SW_Z2
         * Initialize SW_Z2 = SP - 4, then each restore increments by 4
         * Reduces from 9 to 3 instructions per register
         */
        .word   SW_Z2, SW_Z2, .+4
        .word   SW_Z, SW_Z, .+4
        .word   REG_SP, SW_Z, .+4
        .word   SW_Z, SW_Z2, .+4              /* SW_Z2 = SP */
        .word   .Lconst_4, SW_Z2, .+4       /* SW_Z2 = SP - 4 */

        /* Restore R3 from [SP + 0] */
        .word   .Lconst_neg4, SW_Z2, .+4                          /* SW_Z2 += 4 */
        .word   REG_R3, REG_R3, .+4                             /* R3 = 0 */
        .word   SW_Z2 | INDIRECT, REG_R3, .+4                  /* R3 = -(-R3) = R3 */

        /* Restore R4 from [SP + 4] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R4, REG_R4, .+4
        .word   SW_Z2 | INDIRECT, REG_R4, .+4

        /* Restore R5 from [SP + 8] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R5, REG_R5, .+4
        .word   SW_Z2 | INDIRECT, REG_R5, .+4

        /* Restore R6 from [SP + 12] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R6, REG_R6, .+4
        .word   SW_Z2 | INDIRECT, REG_R6, .+4

        /* Restore R7 from [SP + 16] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R7, REG_R7, .+4
        .word   SW_Z2 | INDIRECT, REG_R7, .+4

        /* Restore R8 from [SP + 20] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R8, REG_R8, .+4
        .word   SW_Z2 | INDIRECT, REG_R8, .+4

        /* Restore R9 from [SP + 24] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R9, REG_R9, .+4
        .word   SW_Z2 | INDIRECT, REG_R9, .+4

        /* Restore R10 from [SP + 28] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R10, REG_R10, .+4
        .word   SW_Z2 | INDIRECT, REG_R10, .+4

        /* Restore R11 from [SP + 32] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R11, REG_R11, .+4
        .word   SW_Z2 | INDIRECT, REG_R11, .+4

        /* Restore R12 from [SP + 36] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R12, REG_R12, .+4
        .word   SW_Z2 | INDIRECT, REG_R12, .+4

        /* Restore R13 from [SP + 40] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R13, REG_R13, .+4
        .word   SW_Z2 | INDIRECT, REG_R13, .+4

        /* Restore R14 from [SP + 44] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R14, REG_R14, .+4
        .word   SW_Z2 | INDIRECT, REG_R14, .+4

        /* Restore R15 from [SP + 48] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R15, REG_R15, .+4
        .word   SW_Z2 | INDIRECT, REG_R15, .+4

        /* Restore R16 from [SP + 52] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R16, REG_R16, .+4
        .word   SW_Z2 | INDIRECT, REG_R16, .+4

        /* Restore R17 from [SP + 56] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R17, REG_R17, .+4
        .word   SW_Z2 | INDIRECT, REG_R17, .+4

        /* Restore R18 from [SP + 60] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R18, REG_R18, .+4
        .word   SW_Z2 | INDIRECT, REG_R18, .+4

        /* Restore R19 from [SP + 64] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R19, REG_R19, .+4
        .word   SW_Z2 | INDIRECT, REG_R19, .+4

        /* Restore R20 from [SP + 68] - needed for vfork CLONE_VM fix */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R20, REG_R20, .+4
        .word   SW_Z2 | INDIRECT, REG_R20, .+4

        /* Restore R25 from [SP + 72] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R25, REG_R25, .+4
        .word   SW_Z2 | INDIRECT, REG_R25, .+4

        /* Restore R26 from [SP + 76] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R26, REG_R26, .+4
        .word   SW_Z2 | INDIRECT, REG_R26, .+4

        /* Restore R27 from [SP + 80] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R27, REG_R27, .+4
        .word   SW_Z2 | INDIRECT, REG_R27, .+4

        /* Restore R28 from [SP + 84] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R28, REG_R28, .+4
        .word   SW_Z2 | INDIRECT, REG_R28, .+4

        /* Restore R29 from [SP + 88] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R29, REG_R29, .+4
        .word   SW_Z2 | INDIRECT, REG_R29, .+4

        /* Restore R30 from [SP + 92] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R30, REG_R30, .+4
        .word   SW_Z2 | INDIRECT, REG_R30, .+4

        /* Restore R31 from [SP + 96] */
        .word   .Lconst_neg4, SW_Z2, .+4
        .word   REG_R31, REG_R31, .+4
        .word   SW_Z2 | INDIRECT, REG_R31, .+4


        /*
         * STEP 7: Deallocate switch_stack: SP += 100
         */
        .word   .Lconst_neg100, REG_SP, .Lsw_set_retval

        /*
         * STEP 8: Set return value R20 = prev (R21)
         */
.Lsw_set_retval:
        .word   SW_Z, SW_Z, .+4
        .word   REG_R21, SW_Z, .+4
        .word   REG_R20, REG_R20, .+4
        .word   SW_Z, REG_R20, .Lsw_pop_ra

        /*
         * STEP 9: Pop return address and return
         *
         * Now SP points to the return address (at old SP+96 = retpc slot).
         */
.Lsw_pop_ra:
        .word   REG_RA, REG_RA, .+4                        /* RA = 0 */
        .word   REG_SP | INDIRECT, REG_RA, .+4             /* RA = 0 - (-ret_addr) = +ret_addr; > 0 falls through */
        .word   .Lconst_neg4, REG_SP, .Lsw_return          /* SP += 4 */

        /*
         * STEP 10: Jump to return address
         */
.Lsw_return:
        /* Jump directly to [RA] */
        .word   SW_Z, SW_Z, REG_RA | INDIRECT

.Lsw_ra_copy:
        .word   0       /* Temp storage for RA */
.Lsw_syscall_ret_addr:
        .word   .Lsyscall_c_return   /* Address of syscall return point (BAD if parent returns here) */
.Lsw_ret_from_fork_addr:
        .word   ret_from_fork        /* Address of ret_from_fork (RF if parent returns here) */

.size __switch_to, .-__switch_to

/*
 * ret_from_fork - Entry point for new threads (RE-ENTRANT VERSION)
 *
 * When a new thread is scheduled for the first time, __switch_to returns
 * here. R20 contains the prev task pointer (returned by __switch_to).
 *
 * This function checks pt_regs.pc to determine if this is a kernel or user thread:
 *   - pc == 0: Kernel thread - call kernel_thread_helper(prev)
 *   - pc != 0: User thread - call ret_to_user_prep(prev), then jump to userspace
 *
 * copy_thread() sets pc = 0 for kernel threads (fn goes in r3, arg in r21).
 *
 * Uses Subleq+ indirect addressing for all memory operations.
 */
.globl ret_from_fork
.type ret_from_fork, @function
ret_from_fork:
        /*
         * R20 contains prev (from __switch_to's return value)
         * We need to pass it as the first argument (R21).
         * 
         * Check if this is a kernel thread or user thread by reading pc from pt_regs.
         * For kernel threads: pc == 0 (set by copy_thread)
         * For user threads:   pc != 0 (copied from parent's pt_regs)
         *
         * pt_regs is at the top of the kernel stack. After __switch_to pops the return
         * address from the stack, SP points to pt_regs.
         * pt_regs.pc is at offset 128 from pt_regs.
         */

        /* Copy R20 to R21: R21 = R20 (will be used as argument to either function) */
        .word   REG_R21, REG_R21, .+4   /* R21 = 0 */
        .word   SW_Z, SW_Z, .+4
        .word   REG_R20, SW_Z, .+4     /* SW_Z = -R20 */
        .word   SW_Z, REG_R21, .Lrff_check_pc  /* R21 = R20 = prev */

        /*
         * Read pt_regs.pc from [SP + 128] to check kernel/user thread.
         * 
         * NEGATED STORAGE: pt_regs stores -value, so [SP+128] = -pc
         * We need to test if pc == 0 (kernel thread) or pc != 0 (user thread)
         *
         * Compute address: SW_Z2 = SP + 128, then read pc
         */
.Lrff_check_pc:
        .word   SW_Z, SW_Z, .+4
        .word   REG_SP, SW_Z, .+4              /* SW_Z = -SP */
        .word   SW_Z2, SW_Z2, .+4
        .word   SW_Z, SW_Z2, .+4               /* SW_Z2 = SP */
        .word   .Lconst_neg128, SW_Z2, .+4     /* SW_Z2 = SP + 128 (address of pc) */

        /* Read [SW_Z2] = -pc into SW_Z, then negate to get +pc */
        .word   SW_Z, SW_Z, .+4
        .word   SW_Z2 | INDIRECT, SW_Z, .+4    /* SW_Z = -(-pc) = pc */

        /*
         * Test if pc == 0 (kernel thread) using ZERO constant.
         * subleq(ZERO, SW_Z, target): SW_Z -= 0; if SW_Z <= 0, branch
         *   - If pc > 0: no branch (user thread - valid address)
         *   - If pc == 0: branch (kernel thread)  
         * Note: pc is an unsigned address, so pc < 0 is not possible.
         * Addresses > 0x7FFFFFFF appear as "negative" in signed comparison
         * but that's fine - they won't be 0, so user path is correct.
         */
        .word   ZERO, SW_Z, .Lrff_kernel_thread  /* if pc <= 0, kernel thread */
        /* Fall through: pc > 0 => user thread */
        .word   SW_Z, SW_Z, .Lrff_user_thread

.Lrff_kernel_thread:
        /*
         * KERNEL THREAD PATH
         * Call kernel_thread_helper(prev) - R21 already contains prev
         */
        /* RA-Direct call: set RA to loop (kernel threads should never return) */
        .word   REG_RA, REG_RA, .+4                          /* RA = 0 */
        .word   .Lrff_loop_neg, REG_RA, .+4                  /* RA = .Lrff_loop */

        /* Jump to kernel_thread_helper */
        .word   SW_Z, SW_Z, kernel_thread_helper

.Lrff_user_thread:
        /*
         * USER THREAD PATH
         *
         * Call ret_to_user_prep(prev) which will:
         * 1. Call schedule_tail(prev) to finish context switch
         * 2. Return pointer to pt_regs in R20
         *
         * Then we read directly from pt_regs:
         *   pt_regs->r20 at offset  68 = syscall return value (0 for fork child)
         *   pt_regs->fp  at offset 116 = frame pointer
         *   pt_regs->sp  at offset 120 = user stack pointer
         *   pt_regs->ra  at offset 124 = return address
         *   pt_regs->pc  at offset 128 = user PC to return to
         *
         * This ensures no C code can clobber these critical values.
         */
        /* RA-Direct call to ret_to_user_prep */
        .word   REG_RA, REG_RA, .+4                          /* RA = 0 */
        .word   .Lrff_user_ret_neg, REG_RA, .+4              /* RA = .Lrff_user_return */

        /* Jump to ret_to_user_prep */
        .word   SW_Z, SW_Z, ret_to_user_prep

.Lrff_user_return:
        /*
         * ret_to_user_prep has returned with R20 = pointer to pt_regs.
         *
         * pt_regs layout (offsets from base, after adding R25-R31):
         *   r3-r19:  offsets 0-64
         *   r20:     offset 68 (return value, 0 for fork child)
         *   r21-r24: offsets 72-84
         *   r25-r31: offsets 88-112
         *   fp:      offset 116
         *   sp:      offset 120
         *   ra:      offset 124
         *   pc:      offset 128
         *
         * We need to restore ALL GPRs (R3-R19, R21-R31) from pt_regs so the
         * child has the same register values as the parent.
         *
         * NOTE: We do NOT restore T-registers (T0-T15) or Z here.
         * Since fork/clone is entered via syscall, T-regs were not saved at
         * entry and are already considered clobbered per calling convention.
         * The child inherits this expected "clobbered" state naturally.
         *
         * Order of restoration:
         * 1. First restore R3-R19, R21-R31 while we can still use R20 as the base
         * 2. Load PC into SW_Z2 (we'll jump to this)
         * 3. Load SP, FP
         * 4. Load R20 last (since we're using it as pt_regs pointer)
         * 5. Jump to the saved PC
         */

        /*
         * STEP 0: Restore all GPRs from pt_regs (except R20 which is our base)
         *
         * For each register Rn at offset N:
         *   1. RA = R20 + N (calculate address)
         *   2. Rn = [RA] (load value)
         *
         * We use RA as scratch since it will be overwritten anyway.
         * SW_Z is also available.
         */

        /*
         * OPTIMIZED: Use RA as running pointer
         * Initialize RA = R20 - 4, then increment by 4 for each register
         * Skip R20 (offset 68) by adding 8 instead of 4
         * Reduces from 9 to 5 instructions per register
         */
        .word   SW_Z, SW_Z, .+4
        .word   REG_R20, SW_Z, .+4
        .word   REG_RA, REG_RA, .+4
        .word   SW_Z, REG_RA, .+4                /* RA = R20 */
        .word   .Lconst_4, REG_RA, .+4        /* RA = R20 - 4 */

        /*
         * NEGATED STORAGE: pt_regs stores -value.
         * Simplified load pattern: reg = 0; reg -= [ptr] = -(-value) = value
         */

        /* --- Restore R3 (offset 0) - from NEGATED storage --- */
        .word   .Lconst_neg4, REG_RA, .+4           /* RA += 4 -> R20+0 */
        .word   REG_R3, REG_R3, .+4                 /* R3 = 0 */
        .word   REG_RA | INDIRECT, REG_R3, .+4     /* R3 = -(-r3) = r3 */

        /* --- Restore R4 (offset 4) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R4, REG_R4, .+4
        .word   REG_RA | INDIRECT, REG_R4, .+4

        /* --- Restore R5 (offset 8) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R5, REG_R5, .+4
        .word   REG_RA | INDIRECT, REG_R5, .+4

        /* --- Restore R6 (offset 12) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R6, REG_R6, .+4
        .word   REG_RA | INDIRECT, REG_R6, .+4

        /* --- Restore R7 (offset 16) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R7, REG_R7, .+4
        .word   REG_RA | INDIRECT, REG_R7, .+4

        /* --- Restore R8 (offset 20) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R8, REG_R8, .+4
        .word   REG_RA | INDIRECT, REG_R8, .+4

        /* --- Restore R9 (offset 24) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R9, REG_R9, .+4
        .word   REG_RA | INDIRECT, REG_R9, .+4

        /* --- Restore R10 (offset 28) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R10, REG_R10, .+4
        .word   REG_RA | INDIRECT, REG_R10, .+4

        /* --- Restore R11 (offset 32) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R11, REG_R11, .+4
        .word   REG_RA | INDIRECT, REG_R11, .+4

        /* --- Restore R12 (offset 36) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R12, REG_R12, .+4
        .word   REG_RA | INDIRECT, REG_R12, .+4

        /* --- Restore R13 (offset 40) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R13, REG_R13, .+4
        .word   REG_RA | INDIRECT, REG_R13, .+4

        /* --- Restore R14 (offset 44) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R14, REG_R14, .+4
        .word   REG_RA | INDIRECT, REG_R14, .+4

        /* --- Restore R15 (offset 48) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R15, REG_R15, .+4
        .word   REG_RA | INDIRECT, REG_R15, .+4

        /* --- Restore R16 (offset 52) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R16, REG_R16, .+4
        .word   REG_RA | INDIRECT, REG_R16, .+4

        /* --- Restore R17 (offset 56) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R17, REG_R17, .+4
        .word   REG_RA | INDIRECT, REG_R17, .+4

        /* --- Restore R18 (offset 60) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R18, REG_R18, .+4
        .word   REG_RA | INDIRECT, REG_R18, .+4

        /* --- Restore R19 (offset 64) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R19, REG_R19, .+4
        .word   REG_RA | INDIRECT, REG_R19, .+4

        /* --- Skip R20 (offset 68) - add 8 to skip it --- */

        /* --- Restore R21 (offset 72) --- */
        .word   .Lconst_neg8, REG_RA, .+4           /* RA += 8 (skip R20) -> R20+72 */
        .word   REG_R21, REG_R21, .+4
        .word   REG_RA | INDIRECT, REG_R21, .+4

        /* --- Restore R22 (offset 76) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R22, REG_R22, .+4
        .word   REG_RA | INDIRECT, REG_R22, .+4

        /* --- Restore R23 (offset 80) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R23, REG_R23, .+4
        .word   REG_RA | INDIRECT, REG_R23, .+4

        /* --- Restore R24 (offset 84) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R24, REG_R24, .+4
        .word   REG_RA | INDIRECT, REG_R24, .+4

        /* --- Restore R25 (offset 88) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R25, REG_R25, .+4
        .word   REG_RA | INDIRECT, REG_R25, .+4

        /* --- Restore R26 (offset 92) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R26, REG_R26, .+4
        .word   REG_RA | INDIRECT, REG_R26, .+4

        /* --- Restore R27 (offset 96) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R27, REG_R27, .+4
        .word   REG_RA | INDIRECT, REG_R27, .+4

        /* --- Restore R28 (offset 100) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R28, REG_R28, .+4
        .word   REG_RA | INDIRECT, REG_R28, .+4

        /* --- Restore R29 (offset 104) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R29, REG_R29, .+4
        .word   REG_RA | INDIRECT, REG_R29, .+4

        /* --- Restore R30 (offset 108) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R30, REG_R30, .+4
        .word   REG_RA | INDIRECT, REG_R30, .+4

        /* --- Restore R31 (offset 112) --- */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_R31, REG_R31, .+4
        .word   REG_RA | INDIRECT, REG_R31, .+4

        /*
         * --- Restore T-registers (T0-T14) and Z from pt_regs ---
         *
         * CRITICAL under CONFIG_MMU: the ESI register file (page 1) is a single
         * physical page shared between the kernel and the current user task. If we
         * return to user without writing these cells, a freshly exec'd task inherits
         * the KERNEL's leftover T-regs/Z left in page 1 -- garbage that breaks
         * write-before-read assumptions (wild/near-NULL pointers) AND leaks kernel
         * state to userspace. start_thread() zeroes t0-t15/z in pt_regs, so exec'd
         * tasks get a clean slate; fork children get the parent's saved values.
         *
         * T15 is intentionally NOT restored here: the code below loads it with the
         * user PC and uses it as the indirect jump target (a T-reg is required
         * because it survives a context switch mid-return, unlike the SW_* globals).
         * PC is the task's own entry address, not kernel state, so this is benign.
         *
         * pt_regs offsets: T0=160 .. T14=216, Z=224. RA is the running pointer.
         */
        .word   SW_Z, SW_Z, .+4
        .word   REG_R20, SW_Z, .+4               /* SW_Z = -R20 */
        .word   REG_RA, REG_RA, .+4              /* RA = 0 */
        .word   SW_Z, REG_RA, .+4                /* RA = R20 */
        .word   .Lconst_neg160, REG_RA, .+4      /* RA = R20 + 160 = &pt_regs->t0 */

        /* T0 (offset 160) */
        .word   REG_T0, REG_T0, .+4
        .word   REG_RA | INDIRECT, REG_T0, .+4
        /* T1 (164) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T1, REG_T1, .+4
        .word   REG_RA | INDIRECT, REG_T1, .+4
        /* T2 (168) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T2, REG_T2, .+4
        .word   REG_RA | INDIRECT, REG_T2, .+4
        /* T3 (172) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T3, REG_T3, .+4
        .word   REG_RA | INDIRECT, REG_T3, .+4
        /* T4 (176) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T4, REG_T4, .+4
        .word   REG_RA | INDIRECT, REG_T4, .+4
        /* T5 (180) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T5, REG_T5, .+4
        .word   REG_RA | INDIRECT, REG_T5, .+4
        /* T6 (184) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T6, REG_T6, .+4
        .word   REG_RA | INDIRECT, REG_T6, .+4
        /* T7 (188) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T7, REG_T7, .+4
        .word   REG_RA | INDIRECT, REG_T7, .+4
        /* T8 (192) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T8, REG_T8, .+4
        .word   REG_RA | INDIRECT, REG_T8, .+4
        /* T9 (196) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T9, REG_T9, .+4
        .word   REG_RA | INDIRECT, REG_T9, .+4
        /* T10 (200) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T10, REG_T10, .+4
        .word   REG_RA | INDIRECT, REG_T10, .+4
        /* T11 (204) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T11, REG_T11, .+4
        .word   REG_RA | INDIRECT, REG_T11, .+4
        /* T12 (208) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T12, REG_T12, .+4
        .word   REG_RA | INDIRECT, REG_T12, .+4
        /* T13 (212) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T13, REG_T13, .+4
        .word   REG_RA | INDIRECT, REG_T13, .+4
        /* T14 (216) */
        .word   .Lconst_neg4, REG_RA, .+4
        .word   REG_T14, REG_T14, .+4
        .word   REG_RA | INDIRECT, REG_T14, .+4
        /* Z (offset 224): skip T15 (220), advance +8 */
        .word   .Lconst_neg8, REG_RA, .+4
        .word   REG_Z, REG_Z, .+4
        .word   REG_RA | INDIRECT, REG_Z, .+4

        /*
         * Step 1: Calculate &pt_regs->pc (R20 + 128) and load into REG_T15
         *
         * CRITICAL: We use REG_T15 (a T-register) instead of SW_Z2 (a global)
         * because T-registers are preserved across interrupts. If a context
         * switch occurs before the final jump, SW_Z2 would be clobbered.
         *
         * NEGATED STORAGE: pt_regs stores -value.
         * Use RA as address holder, then: T15 = 0; T15 -= [RA] = -(-pc) = pc
         */
        .word   SW_Z, SW_Z, .+4
        .word   REG_R20, SW_Z, .+4        /* SW_Z = -R20 */
        .word   REG_RA, REG_RA, .+4       /* RA = 0 */
        .word   SW_Z, REG_RA, .+4         /* RA = R20 (pt_regs base) */
        .word   .Lconst_neg128, REG_RA, .+4  /* RA = R20 + 128 = &pt_regs->pc */
        /* Load PC - simplified for negated storage */
        .word   REG_T15, REG_T15, .+4     /* T15 = 0 */
        .word   REG_RA | INDIRECT, REG_T15, .Lrff_load_sp  /* T15 = -(-pc) = pc */

        /*
         * Step 2: Load pt_regs->sp (R20 + 120) into hardware SP - from NEGATED storage
         */
.Lrff_load_sp:
        .word   SW_Z, SW_Z, .+4
        .word   REG_R20, SW_Z, .+4        /* SW_Z = -R20 */
        /* Calculate R20 + 120 into RA */
        .word   REG_RA, REG_RA, .+4
        .word   SW_Z, REG_RA, .+4         /* RA = R20 */
        .word   .Lconst_neg120, REG_RA, .+4   /* RA = R20 + 120 = &pt_regs->sp */
        /* Load SP - simplified for negated storage */
        .word   REG_SP, REG_SP, .+4       /* SP = 0 */
        .word   REG_RA | INDIRECT, REG_SP, .Lrff_load_fp  /* SP = -(-sp) = sp */

        /*
         * Step 3: Load pt_regs->fp (R20 + 116) into hardware FP - from NEGATED storage
         * This is CRITICAL - the child needs the parent's frame pointer!
         */
.Lrff_load_fp:
        .word   SW_Z, SW_Z, .+4
        .word   REG_R20, SW_Z, .+4        /* SW_Z = -R20 */
        .word   REG_RA, REG_RA, .+4
        .word   SW_Z, REG_RA, .+4         /* RA = R20 */
        .word   .Lconst_neg116, REG_RA, .+4   /* RA = R20 + 116 = &pt_regs->fp */
        /* Load FP - simplified for negated storage */
        .word   REG_FP, REG_FP, .+4       /* FP = 0 */
        .word   REG_RA | INDIRECT, REG_FP, .Lrff_load_r20  /* FP = -(-fp) = fp */

        /*
         * Step 4: Load pt_regs->r20 (R20 + 68) into hardware R20 - from NEGATED storage
         * This is the fork return value (0 for child)
         */
.Lrff_load_r20:
        /* First save the current R20 (pt_regs pointer) to SW_Z temporarily */
        .word   SW_Z, SW_Z, .+4
        .word   REG_R20, SW_Z, .+4      /* SW_Z = -R20 (save pt_regs ptr) */
        /* Calculate &pt_regs->r20 using RA as scratch */
        .word   REG_RA, REG_RA, .+4
        .word   SW_Z, REG_RA, .+4       /* RA = R20 (pt_regs base) */
        .word   .Lconst_neg68, REG_RA, .+4 /* RA = R20 + 68 = &pt_regs->r20 */
        /* Load R20 - simplified for negated storage */
        .word   REG_R20, REG_R20, .+4   /* R20 = 0 */
        .word   REG_RA | INDIRECT, REG_R20, .Lrff_jump_user  /* R20 = -(-r20) = r20 (0 for child) */

        /*
         * Step 5: Jump to user PC (saved in REG_T15)
         *
         * REG_T15 | INDIRECT = 220 | 2 = 222
         */
.Lrff_jump_user:
#ifdef CONFIG_MMU
        /*
         * MMU: a fork/clone child must ENTER MODE_USER via CR_RTE — a raw
         * indirect jump would stay in supervisor mode (same bug fixed in
         * jump_to_userspace). REG_T15 holds the resume PC as a WORD index
         * (copy_thread stored the fork call's RA >> 2, since pt_regs->pc is the
         * syscall gate address, not the resume point). Writing a CR assigns it.
         */
        .word   REG_T15, CR_SAVED_PC, .+4   /* CR_SAVED_PC := resume PC (word) */
        .word   ZERO, CR_RTE, .+4           /* return-from-trap -> user @ pc   */
.Lrff_mmu_hang:                             /* unreached (now in user mode)    */
        .word   SW_Z, SW_Z, .Lrff_mmu_hang
#else
        /* NOMMU: pt_regs->pc is the resume address; raw indirect jump. */
        .word   SW_Z
        .word   SW_Z
        .word   REG_T15 | INDIRECT
#endif

.Lrff_loop:
        /* Infinite loop - should never reach here for kernel threads */
        .word   SW_Z, SW_Z, .Lrff_loop

.Lrff_loop_neg:
        .word   -.Lrff_loop
.Lrff_user_ret_neg:
        .word   -.Lrff_user_return

.size ret_from_fork, .-ret_from_fork

/*
 * jump_to_userspace - Jump to userspace WITHOUT using the C calling convention
 *
 * This function is called from kernel_thread_helper when a kernel thread
 * has called kernel_execve() and needs to transition to userspace.
 *
 * Unlike a normal C function call, this does NOT push a return address,
 * which would corrupt the user stack that has been set up with argc/argv/envp.
 *
 * Arguments (C calling convention - they were pushed by caller):
 *   R21 = pc (userspace entry point)
 *   R22 = sp (userspace stack pointer)
 *
 * This function never returns.
 */
.globl jump_to_userspace
.type jump_to_userspace, @function
#ifdef CONFIG_MMU
jump_to_userspace:
        /*
         * MMU: enter MODE_USER via CR_RTE (a raw jump would stay in supervisor mode).
         * R21 = user entry PC (WORD index, from process.c pc>>2), R22 = user SP (byte).
         */
        .word   .Lconst_neg4, REG_SP, .+4        /* pop caller return addr: SP += 4 */
        /* SP = R22 (user stack pointer) */
        .word   REG_SP, REG_SP, .+4
        .word   SW_Z, SW_Z, .+4
        .word   REG_R22, SW_Z, .+4               /* SW_Z = -R22 */
        .word   SW_Z, REG_SP, .+4                /* SP = R22 */
        /* CR_SAVED_PC = R21 (user entry, word index) */
        .word   REG_R21, CR_SAVED_PC, .+4
        /*
         * Clear ALL user-visible registers before entering user mode.
         *
         * CRITICAL under CONFIG_MMU: the ESI register file (page 1) is a single
         * physical page shared between the kernel and the current user task. This
         * exec transition (kernel_thread_helper -> here) does NOT go through the
         * pt_regs restore in ret_from_fork, so without clearing them the freshly
         * exec'd task would inherit the KERNEL's leftover R-/T-regs, Z, RA and FP.
         * That garbage breaks compiled code's write-before-read assumptions (wild /
         * near-NULL pointers) AND leaks kernel state to userspace. exec semantics
         * require a zeroed register set regardless.
         *
         * SP (user stack) and CR_SAVED_PC (user entry) are already set above; the
         * constant cells ZERO/ONE/MINUS_ONE are preserved. subleq(X,X,.) => X = 0.
         * R21/R22 (our inputs) are consumed by now and cleared here too.
         */
        .word   REG_R3,  REG_R3,  .+4
        .word   REG_R4,  REG_R4,  .+4
        .word   REG_R5,  REG_R5,  .+4
        .word   REG_R6,  REG_R6,  .+4
        .word   REG_R7,  REG_R7,  .+4
        .word   REG_R8,  REG_R8,  .+4
        .word   REG_R9,  REG_R9,  .+4
        .word   REG_R10, REG_R10, .+4
        .word   REG_R11, REG_R11, .+4
        .word   REG_R12, REG_R12, .+4
        .word   REG_R13, REG_R13, .+4
        .word   REG_R14, REG_R14, .+4
        .word   REG_R15, REG_R15, .+4
        .word   REG_R16, REG_R16, .+4
        .word   REG_R17, REG_R17, .+4
        .word   REG_R18, REG_R18, .+4
        .word   REG_R19, REG_R19, .+4
        .word   REG_R20, REG_R20, .+4
        .word   REG_R21, REG_R21, .+4
        .word   REG_R22, REG_R22, .+4
        .word   REG_R23, REG_R23, .+4
        .word   REG_R24, REG_R24, .+4
        .word   REG_R25, REG_R25, .+4
        .word   REG_R26, REG_R26, .+4
        .word   REG_R27, REG_R27, .+4
        .word   REG_R28, REG_R28, .+4
        .word   REG_R29, REG_R29, .+4
        .word   REG_R30, REG_R30, .+4
        .word   REG_R31, REG_R31, .+4
        .word   REG_RA,  REG_RA,  .+4
        .word   REG_FP,  REG_FP,  .+4
        .word   REG_T0,  REG_T0,  .+4
        .word   REG_T1,  REG_T1,  .+4
        .word   REG_T2,  REG_T2,  .+4
        .word   REG_T3,  REG_T3,  .+4
        .word   REG_T4,  REG_T4,  .+4
        .word   REG_T5,  REG_T5,  .+4
        .word   REG_T6,  REG_T6,  .+4
        .word   REG_T7,  REG_T7,  .+4
        .word   REG_T8,  REG_T8,  .+4
        .word   REG_T9,  REG_T9,  .+4
        .word   REG_T10, REG_T10, .+4
        .word   REG_T11, REG_T11, .+4
        .word   REG_T12, REG_T12, .+4
        .word   REG_T13, REG_T13, .+4
        .word   REG_T14, REG_T14, .+4
        .word   REG_T15, REG_T15, .+4
        .word   REG_Z,   REG_Z,   .+4
        /* return-from-trap: switch to MODE_USER and jump to CR_SAVED_PC */
        .word   ZERO, CR_RTE, .+4
.Ljtu_mmu_hang:                                  /* unreached (now in user mode) */
        .word   SW_Z, SW_Z, .Ljtu_mmu_hang
.size jump_to_userspace, .-jump_to_userspace
#else
jump_to_userspace:
        /*
         * On entry, the caller has pushed a return address to the stack.
         * We don't need it since we're jumping to userspace.
         * First, pop and discard it: SP += 4
         */
        .word   .Lconst_neg4, REG_SP, .Ljtu_set_ra

        /*
         * Set RA to a halt loop as a safety backstop.
         * If the user binary returns (which it shouldn't), it will
         * jump to this loop instead of crashing on RA=0.
         */
.Ljtu_set_ra:
        .word   REG_RA, REG_RA, .+4
        .word   .Ljtu_halt_neg, REG_RA, .Ljtu_set_sp   /* RA = 0 - (-.Ljtu_halt_loop) = halt_loop */

        /*
         * Set SP = R22 (the user stack pointer)
         */
.Ljtu_set_sp:
        /* Clear SP */
        .word   REG_SP, REG_SP, .+4
        /* Get -R22 into SW_Z */
        .word   SW_Z, SW_Z, .+4
        .word   REG_R22, SW_Z, .+4  /* SW_Z = -R22 */
        /* SP -= SW_Z => SP = R22 */
        .word   SW_Z, REG_SP, .Ljtu_jump

        /*
         * Jump to R21 (the user entry point) using indirect addressing.
         * This is a RAW JUMP - no return address is pushed!
         */
.Ljtu_jump:
        /* Indirect jump: subleq(Z, Z, R21|I) jumps to m[R21] */
        .word   SW_Z, SW_Z, REG_R21 | INDIRECT

        /*
         * Halt loop - if user binary returns, it will end up here
         */
.Ljtu_halt_loop:
        .word   SW_Z, SW_Z, .Ljtu_halt_loop

.Ljtu_halt_addr:
        .word   .Ljtu_halt_loop
.Ljtu_halt_neg:
        .word   -.Ljtu_halt_loop

.size jump_to_userspace, .-jump_to_userspace
#endif /* CONFIG_MMU */


/*
 * __subleq_syscall - Frameless syscall entry point
 *
 * This is a FRAMELESS function - it does NOT create a stack frame on the
 * userspace stack. This is critical because vfork children share the parent's
 * userspace stack and would corrupt any frame we create.
 *
 * Instead, we:
 *   1. Immediately save SP, FP, and return address to GLOBAL variables
 *   2. Switch to the kernel stack
 *   3. Call __subleq_syscall_c which runs entirely on kernel stack
 *   4. Restore userspace SP and FP from globals
 *   5. Jump to the saved return address (NOT from stack!)
 *
 * On entry (from userspace caller, RA-Direct convention):
 *   RA = return address (caller loaded RA before jumping)
 *   FP = caller's frame pointer
 *   R21 = syscall number, R22-R24 = args 1-3
 */
.globl __subleq_syscall
.type __subleq_syscall, @function
__subleq_syscall:
        /*
         * STEP 0: DISABLE INTERRUPTS
         *
         * CRITICAL ORDERING: Zero m[0] FIRST (atomic, one instruction), then
         * update .Lsyscall_saved_handler while interrupts are guaranteed off.
         *
         * .Lsyscall_saved_handler is a SHARED GLOBAL. If we cleared and set it
         * with m[0] still nonzero, a timer interrupt between those two writes
         * could context-switch to another task that also calls __subleq_syscall.
         * That task would set the slot to `handler`. When the original task
         * resumed and ran its "set" instruction, it would add handler on top:
         *   slot = handler + handler = 2*handler
         * The subsequent re-enable would then write m[0] = 2*handler — bug!
         *
         * By zeroing m[0] first (one instruction = the disable is atomic), no
         * interrupt can fire between the clear-slot and set-slot steps, so no
         * context switch is possible during those two writes.
         *
         * If an interrupt fires between the read of m[0] (T0 = -m[0]) and the
         * zero of m[0], the interrupt handler saves/restores T0 via pt_regs, so
         * T0 = -handler is preserved correctly when we resume.
         */
        .word   REG_T0, REG_T0, .+4                         /* T0 = 0 */
        .word   INT_HANDLER, REG_T0, .+4                    /* T0 = -m[0] */
        .word   INT_HANDLER, INT_HANDLER, .+4               /* m[0] = 0 (DISABLED FIRST) */
        .word   .Lsyscall_saved_handler, .Lsyscall_saved_handler, .+4  /* clear save slot (safe: m[0]=0) */
        .word   REG_T0, .Lsyscall_saved_handler, .+4        /* save slot = old m[0] (safe: m[0]=0) */

        /*
         * STEP 1: Save SP to global subleq_syscall_saved_sp
         */
        .word   subleq_syscall_saved_sp, subleq_syscall_saved_sp, .+4  /* clear */
        .word   REG_T0, REG_T0, .+4  /* T0 = 0 */
        .word   REG_SP, REG_T0, .+4       /* T0 = -SP */
        .word   REG_T0, subleq_syscall_saved_sp, .+4  /* saved_sp = SP */
        
        /*
         * STEP 2: Save FP to global subleq_syscall_saved_fp
         */
        .word   subleq_syscall_saved_fp, subleq_syscall_saved_fp, .+4  /* clear */
        .word   REG_T0, REG_T0, .+4  /* T0 = 0 */
        .word   REG_FP, REG_T0, .+4       /* T0 = -FP */
        .word   REG_T0, subleq_syscall_saved_fp, .+4  /* saved_fp = FP */

        /*
         * STEP 3: Save return address from RA register to global subleq_syscall_saved_ra
         *
         * RA-Direct: The caller loaded RA before jumping here.
         * RA register contains the return address directly.
         */
        .word   subleq_syscall_saved_ra, subleq_syscall_saved_ra, .+4  /* saved_ra = 0 */
        .word   REG_T0, REG_T0, .+4  /* T0 = 0 */
        .word   REG_RA, REG_T0, .+4  /* T0 = -RA */
        .word   REG_T0, subleq_syscall_saved_ra, .+4  /* saved_ra = +RA */

        /*
         * STEP 4: Switch to kernel stack
         *
         * Load subleq_kernel_sp (set by context switch) into hardware SP.
         */
        .word   REG_SP, REG_SP, .+4       /* SP = 0 */
        .word   REG_T0, REG_T0, .+4
        .word   subleq_kernel_sp, REG_T0, .+4  /* T0 = -kernel_sp */
        .word   REG_T0, REG_SP, .+4   /* SP = kernel_sp */

        /*
         * STEP 4a: Save all GPRs (R3-R31) to pt_regs
         *
         * pt_regs is at subleq_kernel_sp + 1024.
         * We need to save R3-R31 so that fork/vfork can correctly copy the
         * parent's register state to the child.
         *
         * pt_regs layout (after adding R25-R31):
         *   r3:  offset 0
         *   r4:  offset 4
         *   ...
         *   r19: offset 64
         *   r20: offset 68
         *   r21: offset 72
         *   ...
         *   r31: offset 112
         *
         * We use REG_T8 as scratch to compute addresses.
         * REG_T9 holds the pt_regs base address.
         */

        /* Compute pt_regs base = subleq_kernel_sp + 1024 into REG_T9 */
        .word   REG_T0, REG_T0, .+4
        .word   subleq_kernel_sp, REG_T0, .+4        /* T0 = -kernel_sp */
        .word   REG_T9, REG_T9, .+4                      /* T9 = 0 */
        .word   REG_T0, REG_T9, .+4                  /* T9 = kernel_sp */
        .word   .Lconst_neg1024, REG_T9, .+4           /* T9 = kernel_sp + 1024 = pt_regs base */

        /*
         * NEGATED STORAGE: pt_regs values are stored as -value.
         * C code uses PT_REG_GET() which negates to get +value.
         * Pattern: [T9] = 0; [T9] -= REG = -REG
         */

        /* Save R3 at [T9 + 0] - NEGATED */
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4  /* [T9] = 0 */
        .word   REG_R3, REG_T9 | INDIRECT, .+4             /* [T9] = -R3 */

        /* Save R4 at [T9 + 4] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R4, REG_T9 | INDIRECT, .+4

        /* Save R5 at [T9 + 8] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R5, REG_T9 | INDIRECT, .+4

        /* Save R6 at [T9 + 12] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R6, REG_T9 | INDIRECT, .+4

        /* Save R7 at [T9 + 16] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R7, REG_T9 | INDIRECT, .+4

        /* Save R8 at [T9 + 20] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R8, REG_T9 | INDIRECT, .+4

        /* Save R9 at [T9 + 24] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R9, REG_T9 | INDIRECT, .+4

        /* Save R10 at [T9 + 28] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R10, REG_T9 | INDIRECT, .+4

        /* Save R11 at [T9 + 32] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R11, REG_T9 | INDIRECT, .+4

        /* Save R12 at [T9 + 36] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R12, REG_T9 | INDIRECT, .+4

        /* Save R13 at [T9 + 40] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R13, REG_T9 | INDIRECT, .+4

        /* Save R14 at [T9 + 44] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R14, REG_T9 | INDIRECT, .+4

        /* Save R15 at [T9 + 48] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R15, REG_T9 | INDIRECT, .+4

        /* Save R16 at [T9 + 52] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R16, REG_T9 | INDIRECT, .+4

        /* Save R17 at [T9 + 56] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R17, REG_T9 | INDIRECT, .+4

        /* Save R18 at [T9 + 60] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R18, REG_T9 | INDIRECT, .+4

        /* Save R19 at [T9 + 64] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R19, REG_T9 | INDIRECT, .+4

        /* Save R20 at [T9 + 68] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R20, REG_T9 | INDIRECT, .+4

        /* Save R21 at [T9 + 72] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R21, REG_T9 | INDIRECT, .+4

        /* Save R22 at [T9 + 76] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R22, REG_T9 | INDIRECT, .+4

        /* Save R23 at [T9 + 80] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R23, REG_T9 | INDIRECT, .+4

        /* Save R24 at [T9 + 84] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R24, REG_T9 | INDIRECT, .+4

        /* Save R25 at [T9 + 88] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R25, REG_T9 | INDIRECT, .+4

        /* Save R26 at [T9 + 92] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R26, REG_T9 | INDIRECT, .+4

        /* Save R27 at [T9 + 96] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R27, REG_T9 | INDIRECT, .+4

        /* Save R28 at [T9 + 100] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R28, REG_T9 | INDIRECT, .+4

        /* Save R29 at [T9 + 104] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R29, REG_T9 | INDIRECT, .+4

        /* Save R30 at [T9 + 108] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R30, REG_T9 | INDIRECT, .+4

        /* Save R31 at [T9 + 112] - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   REG_R31, REG_T9 | INDIRECT, .+4

        /*
         * STEP 4a-continued: Save FP, SP, RA, PC to pt_regs (NEGATED)
         *
         * CRITICAL: These must be saved HERE in assembly, not later in C code!
         * If we wait for C code to copy from globals, an interrupt between here
         * and the C code can cause a context switch, allowing another task to
         * overwrite the globals with its own values. When we resume, C would
         * copy the wrong values to pt_regs, causing a crash on syscall return.
         *
         * Offsets (continuing from R31 at 112):
         *   FP at offset 116
         *   SP at offset 120 (must be saved_sp + 4 to match post-call state)
         *   RA at offset 124
         *   PC at offset 128 (same as RA - the return address IS the PC)
         */

        /* Save FP at [T9 + 116] from subleq_syscall_saved_fp - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4              /* T9 = pt_regs + 116 */
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   subleq_syscall_saved_fp, REG_T9 | INDIRECT, .+4

        /* Save SP at [T9 + 120] = -(saved_sp) - NEGATED
         * RA-Direct: saved_sp IS the correct userspace SP (no RA slot to skip) */
        .word   .Lconst_neg4, REG_T9, .+4              /* T9 = pt_regs + 120 */
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4  /* [T9] = 0 */
        .word   subleq_syscall_saved_sp, REG_T9 | INDIRECT, .+4  /* [T9] = -saved_sp */

        /* Save RA at [T9 + 124] from subleq_syscall_saved_ra - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4              /* T9 = pt_regs + 124 */
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   subleq_syscall_saved_ra, REG_T9 | INDIRECT, .+4

        /* Save PC at [T9 + 128] - same as RA - NEGATED */
        .word   .Lconst_neg4, REG_T9, .+4              /* T9 = pt_regs + 128 */
        .word   REG_T9 | INDIRECT, REG_T9 | INDIRECT, .+4
        .word   subleq_syscall_saved_ra, REG_T9 | INDIRECT, .+4

        /*
         * NOTE: T-registers (T0-T15) and Z are NOT saved to pt_regs here.
         *
         * These are caller-saved scratch registers. For normal syscalls, userspace
         * doesn't expect them to be preserved. For rt_sigreturn, restore_sigcontext()
         * overwrites these slots with the original values from the signal frame
         * before the syscall return path restores them.
         *
         * The pt_regs T-reg slots will contain stale kernel stack data for normal
         * syscalls. The syscall return path restores these into hardware registers,
         * which is a minor information disclosure risk (kernel stack contents leak
         * to userspace via caller-saved registers). Accepted because:
         *   1. T-regs are caller-saved — userspace treats them as clobbered
         *   2. Zeroing 17 words (68 bytes) on every syscall entry adds ~100
         *      Subleq instructions of overhead
         *   3. No known exploit vector — values are transient and uncontrolled
         */

        /*
         * STEP 4a-final: RE-ENABLE INTERRUPTS
         *
         * All critical state is now safely saved to pt_regs. We can re-enable
         * interrupts. Even if an interrupt causes a context switch now, our
         * pt_regs (on our kernel stack) remains intact, and when we return,
         * __switch_to will restore subleq_kernel_sp to point to our stack.
         *
         * Restore m[0] from .Lsyscall_saved_handler.
         * Using REG_T0 for consistency with STEP 0 (though interrupts are
         * currently disabled, so REG_T0 would also be safe here).
         */
        .word   REG_T0, REG_T0, .+4                         /* T0 = 0 */
        .word   .Lsyscall_saved_handler, REG_T0, .+4        /* T0 = -handler */
        .word   INT_HANDLER, INT_HANDLER, .+4               /* m[0] = 0 */
        .word   REG_T0, INT_HANDLER, .+4                    /* m[0] = handler */

        /*
         * STEP 4b: Push a6, a5, a4 from userspace stack onto kernel stack
         *
         * The userspace stack (saved in subleq_syscall_saved_sp) has:
         *   [saved_sp]     = arg 5 (a4 in C function signature)
         *   [saved_sp+4]   = arg 6 (a5)
         *   [saved_sp+8]   = arg 7 (a6)
         *
         * RA-Direct: no return address on the stack; args start at [saved_sp].
         *
         * We need to push these in reverse order (a6, a5, a4) so that
         * when __subleq_syscall_c is called, the stack has:
         *   [SP]    = return address
         *   [SP+4]  = a4 (arg 5)
         *   [SP+8]  = a5 (arg 6)
         *   [SP+12] = a6 (arg 7)
         *
         * Pattern for loading [saved_sp + offset]:
         *   1. Load saved_sp into scratch (.Lsyscall_ustack_addr)
         *   2. Add offset
         *   3. Use indirect addressing to read [scratch]
         *   4. Push value onto kernel stack
         */
        
        /* ---- Push a6 (from [saved_sp + 8]) ---- */
        /* Compute saved_sp + 8 into REG_T8 for indirect access */
        .word   REG_T8, REG_T8, .+4                                /* T8 = 0 */
        .word   REG_T0, REG_T0, .+4
        .word   subleq_syscall_saved_sp, REG_T0, .+4           /* T0 = -saved_sp */
        .word   REG_T0, REG_T8, .+4                            /* T8 = saved_sp */
        .word   .Lconst_neg8, REG_T8, .+4                        /* T8 = saved_sp + 8 */
        
        /* Load [T8] into REG_T0 using indirect addressing */
        .word   REG_T0, REG_T0, .+4
        .word   REG_T8 | INDIRECT, REG_T0, .+4                 /* T0 = -[T8] = -a6 */
        
        /* Push -T0 onto kernel stack */
        .word   .Lconst_4, REG_SP, .+4                           /* SP -= 4 */
        .word   REG_SP | INDIRECT, REG_SP | INDIRECT, .+4          /* [SP] = 0 */
        .word   REG_T0, REG_SP | INDIRECT, .+4                 /* [SP] = a6 */
        
        /* ---- Push a5 (from [saved_sp + 4]) ---- */
        .word   REG_T8, REG_T8, .+4                                /* T8 = 0 */
        .word   REG_T0, REG_T0, .+4
        .word   subleq_syscall_saved_sp, REG_T0, .+4           /* T0 = -saved_sp */
        .word   REG_T0, REG_T8, .+4                            /* T8 = saved_sp */
        .word   .Lconst_neg4, REG_T8, .+4                        /* T8 = saved_sp + 4 */
        
        .word   REG_T0, REG_T0, .+4
        .word   REG_T8 | INDIRECT, REG_T0, .+4                 /* T0 = -a5 */
        
        .word   .Lconst_4, REG_SP, .+4                           /* SP -= 4 */
        .word   REG_SP | INDIRECT, REG_SP | INDIRECT, .+4          /* [SP] = 0 */
        .word   REG_T0, REG_SP | INDIRECT, .+4                 /* [SP] = a5 */
        
        /* ---- Push a4 (from [saved_sp + 0]) ---- */
        .word   REG_T8, REG_T8, .+4                                /* T8 = 0 */
        .word   REG_T0, REG_T0, .+4
        .word   subleq_syscall_saved_sp, REG_T0, .+4           /* T0 = -saved_sp */
        .word   REG_T0, REG_T8, .+4                            /* T8 = saved_sp */
        
        .word   REG_T0, REG_T0, .+4
        .word   REG_T8 | INDIRECT, REG_T0, .+4                 /* T0 = -a4 */
        
        .word   .Lconst_4, REG_SP, .+4                           /* SP -= 4 */
        .word   REG_SP | INDIRECT, REG_SP | INDIRECT, .+4          /* [SP] = 0 */
        .word   REG_T0, REG_SP | INDIRECT, .+4                 /* [SP] = a4 */

        /*
         * STEP 5: RA-Direct call to __subleq_syscall_c
         */
        .word   REG_RA, REG_RA, .+4                                   /* RA = 0 */
        .word   .Lsyscall_c_ret_neg, REG_RA, .+4                      /* RA = .Lsyscall_c_return */

        /* Jump to C handler */
        .word   REG_Z, REG_Z, __subleq_syscall_c


        /* Return point from C handler */
.Lsyscall_c_return:

        /*
         * Syscall return path.
         *
         * R20 contains the syscall return value (set by C calling convention).
         * With R20 now saved in switch_stack, it's preserved across context
         * switches, so parent's return value survives even when child runs.
         *
         * Read userspace SP/FP/PC from pt_regs (which is per-task).
         */

        .word   REG_T0, REG_T0, .Lsyscall_start_restore

.Lsyscall_r20_check:
        .word   0                                              /* scratch for R20 test */

.Lsyscall_start_restore:

        /*
         * SYSCALL RETURN PATH - FULL REGISTER RESTORE
         *
         * This path now restores ALL registers from pt_regs, not just SP/FP/PC.
         * This is CRITICAL for sys_rt_sigreturn to work correctly:
         *
         * When a signal interrupts user code (e.g., in the middle of __subleq_mul),
         * the interrupt handler saves ALL registers (R3-R31, T0-T15, Z) to pt_regs.
         * Signal delivery then modifies pt_regs->pc to point to the signal handler.
         * When the handler returns, it calls sys_rt_sigreturn which restores the
         * ORIGINAL register values back into pt_regs.
         *
         * All registers are restored, exactly like the IRQ return path.
         * This is required for sys_rt_sigreturn: when a signal interrupts user
         * code (e.g., in __subleq_mul), the handler returns via sigreturn which
         * restores original register values back into pt_regs. The syscall return
         * path must then reload all registers to resume the interrupted code.
         *
         * Stack layout at this point (AFTER C function returned):
         *   - RA-Direct: C function returned via JMP RA|I, SP unchanged
         *   - SP now points to a4 (first stack arg)
         *   - Stack: [a4][a5][a6] = 12 bytes above kernel_sp
         *   - So: kernel_sp = SP + 12
         *   - pt_regs = kernel_sp + 1024 = SP + 12 + 1024 = SP + 1036
         */

        /*
         * STEP 1: Compute pt_regs base address into SYSCALL_SCRATCH
         *
         * Interrupts remain ENABLED during this sequence. Any interrupt
         * will see our PC is within __subleq_syscall and correctly detect
         * kernel mode, even after SP is restored to userspace.
         */
        .word   REG_T0, REG_T0, .+4           /* T0 = 0 */
        .word   REG_SP, REG_T0, .+4           /* T0 = -SP */
        .word   SYSCALL_SCRATCH, SYSCALL_SCRATCH, .+4  /* SYSCALL_SCRATCH = 0 */
        .word   REG_T0, SYSCALL_SCRATCH, .+4  /* SYSCALL_SCRATCH = SP */
        .word   .Lconst_neg1036, SYSCALL_SCRATCH, .+4  /* SYSCALL_SCRATCH = SP + 1036 = pt_regs */

        /*
         * STEP 2: Save PC to SYSCALL_JMPTGT BEFORE restoring registers
         *
         * NOTE: We do NOT cache SP in SAVE_SP because SAVE_SP can be corrupted
         * by an interrupt (the IRQ handler uses SAVE_SP for its own purposes).
         * Instead, we compute pt_regs->sp at the end of the restoration sequence.
         *
         * SYSCALL_JMPTGT is saved/restored by the IRQ handler, so it's safe.
         */

        /* Calculate &pt_regs->pc (offset 128) into T8 */
        .word   REG_T0, REG_T0, .+4
        .word   SYSCALL_SCRATCH, REG_T0, .+4  /* T0 = -pt_regs */
        .word   REG_T8, REG_T8, .+4
        .word   REG_T0, REG_T8, .+4           /* T8 = pt_regs */
        .word   .Lconst_neg128, REG_T8, .+4   /* T8 = pt_regs + 128 = &pc */

        /* Read pt_regs->pc into SYSCALL_JMPTGT
         * pt_regs->pc contains -pc (negated). We need +pc for jumping.
         * Pattern: SYSCALL_JMPTGT = 0; SYSCALL_JMPTGT -= [T8] = -(-pc) = +pc */
        .word   SYSCALL_JMPTGT, SYSCALL_JMPTGT, .+4
        .word   REG_T8 | INDIRECT, SYSCALL_JMPTGT, .+4  /* SYSCALL_JMPTGT = +pc */

        /*
         * STEP 3: RESTORE ALL GPRs FROM pt_regs
         *
         * Use SYSCALL_SCRATCH as the running pointer. It survives T-reg restore.
         * Pattern for each register: advance pointer; reg = 0; reg -= [ptr]
         *
         * pt_regs layout:
         *   r3:  offset 0     r19: offset 64    r25-r31: offsets 88-112
         *   r4:  offset 4     r20: offset 68    fp: offset 116
         *   ...               r21: offset 72    sp: offset 120 (skip - use SAVE_SP)
         *   r18: offset 60    r22-r24: 76-84    ra: offset 124
         */

        /* Load R3 from pt_regs->r3 (offset 0) - from NEGATED storage */
        .word   REG_R3, REG_R3, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R3, .+4

        /* Load R4 (offset 4) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R4, REG_R4, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R4, .+4

        /* Load R5 (offset 8) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R5, REG_R5, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R5, .+4

        /* Load R6 (offset 12) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R6, REG_R6, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R6, .+4

        /* Load R7 (offset 16) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R7, REG_R7, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R7, .+4

        /* Load R8 (offset 20) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R8, REG_R8, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R8, .+4

        /* Load R9 (offset 24) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R9, REG_R9, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R9, .+4

        /* Load R10 (offset 28) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R10, REG_R10, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R10, .+4

        /* Load R11 (offset 32) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R11, REG_R11, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R11, .+4

        /* Load R12 (offset 36) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R12, REG_R12, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R12, .+4

        /* Load R13 (offset 40) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R13, REG_R13, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R13, .+4

        /* Load R14 (offset 44) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R14, REG_R14, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R14, .+4

        /* Load R15 (offset 48) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R15, REG_R15, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R15, .+4

        /* Load R16 (offset 52) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R16, REG_R16, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R16, .+4

        /* Load R17 (offset 56) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R17, REG_R17, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R17, .+4

        /* Load R18 (offset 60) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R18, REG_R18, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R18, .+4

        /* Load R19 (offset 64) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R19, REG_R19, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R19, .+4

        /* Load R20 (offset 68) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R20, REG_R20, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R20, .+4

        /* Load R21 (offset 72) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R21, REG_R21, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R21, .+4

        /* Load R22 (offset 76) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R22, REG_R22, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R22, .+4

        /* Load R23 (offset 80) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R23, REG_R23, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R23, .+4

        /* Load R24 (offset 84) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R24, REG_R24, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R24, .+4

        /* Load R25 (offset 88) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R25, REG_R25, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R25, .+4

        /* Load R26 (offset 92) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R26, REG_R26, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R26, .+4

        /* Load R27 (offset 96) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R27, REG_R27, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R27, .+4

        /* Load R28 (offset 100) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R28, REG_R28, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R28, .+4

        /* Load R29 (offset 104) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R29, REG_R29, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R29, .+4

        /* Load R30 (offset 108) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R30, REG_R30, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R30, .+4

        /* Load R31 (offset 112) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_R31, REG_R31, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_R31, .+4

        /* Load FP (offset 116) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_FP, REG_FP, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_FP, .+4

        /* Skip SP (offset 120) - handled via SAVE_SP at the end */

        /* Load RA (offset 124) - skip 8 from FP */
        .word   .Lconst_neg8, SYSCALL_SCRATCH, .+4
        .word   REG_RA, REG_RA, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_RA, .+4

        /*
         * STEP 4: RESTORE T-REGISTERS AND Z FROM pt_regs
         *
         * Continue from RA at offset 124, skip to T0 at offset 160 (gap of 36).
         * These are critical for sigreturn when returning to interrupted
         * runtime helpers like __subleq_mul that use T-regs for temporaries.
         *
         * For normal syscalls, these will be garbage (syscall entry doesn't
         * save T-regs), but that's fine - T-regs are caller-saved anyway.
         * For sigreturn, restore_sigcontext filled these with original values.
         */

        /* Skip from RA (124) to T0 (160): advance by 36 */
        .word   .Lconst_neg36, SYSCALL_SCRATCH, .+4

        /* Load T0 (offset 160) */
        .word   REG_T0, REG_T0, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T0, .+4

        /* Load T1 (offset 164) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T1, REG_T1, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T1, .+4

        /* Load T2 (offset 168) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T2, REG_T2, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T2, .+4

        /* Load T3 (offset 172) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T3, REG_T3, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T3, .+4

        /* Load T4 (offset 176) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T4, REG_T4, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T4, .+4

        /* Load T5 (offset 180) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T5, REG_T5, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T5, .+4

        /* Load T6 (offset 184) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T6, REG_T6, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T6, .+4

        /* Load T7 (offset 188) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T7, REG_T7, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T7, .+4

        /* Load T8 (offset 192) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T8, REG_T8, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T8, .+4

        /* Load T9 (offset 196) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T9, REG_T9, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T9, .+4

        /* Load T10 (offset 200) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T10, REG_T10, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T10, .+4

        /* Load T11 (offset 204) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T11, REG_T11, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T11, .+4

        /* Load T12 (offset 208) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T12, REG_T12, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T12, .+4

        /* Load T13 (offset 212) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T13, REG_T13, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T13, .+4

        /* Load T14 (offset 216) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T14, REG_T14, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T14, .+4

        /* Load T15 (offset 220) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_T15, REG_T15, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_T15, .+4

        /* Load Z (offset 224) */
        .word   .Lconst_neg4, SYSCALL_SCRATCH, .+4
        .word   REG_Z, REG_Z, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_Z, .+4

        /*
         * STEP 5: RESTORE SP FROM pt_regs
         *
         * CRITICAL: We cannot use SAVE_SP here because it could have been
         * overwritten by an interrupt during the restoration sequence above.
         * The IRQ handler uses SAVE_SP for its own interrupted SP.
         *
         * After loading Z at offset 224, SYSCALL_SCRATCH = pt_regs + 224.
         * We need pt_regs + 120 (sp offset), which is 104 bytes back.
         * (224 - 120 = 104)
         */
        .word   .Lconst_104, SYSCALL_SCRATCH, .+4  /* SYSCALL_SCRATCH = pt_regs + 224 - 104 = pt_regs + 120 */

        /* Load SP from [SYSCALL_SCRATCH] (pt_regs->sp)
         * pt_regs->sp contains -sp (negated). Restore: SP = 0; SP -= [ptr] = sp */
        .word   REG_SP, REG_SP, .+4
        .word   SYSCALL_SCRATCH | INDIRECT, REG_SP, .+4  /* SP = -(-sp) = sp */

        /*
         * STEP 6: JUMP TO USERSPACE
         *
         * Interrupts are enabled (from STEP 4a-final before C call).
         * Any interrupt between here and the jump will see PC is within
         * __subleq_syscall and correctly detect kernel mode.
         */

        /*
         * SYSCALL_JMPTGT contains the return PC. Jump using indirect addressing.
         *
         * Use SYSCALL_SCRATCH as dummy source (we're done with it)
         */
        .word   SYSCALL_SCRATCH, SYSCALL_SCRATCH, SYSCALL_JMPTGT | INDIRECT




/* Local data for __subleq_syscall */
.Lsyscall_c_ret_neg:
        .word   -.Lsyscall_c_return

.Lsyscall_tmp_addr:
        .word   0

/* New constants for pt_regs-based syscall return (vfork fix) */
.Lsyscall_ptregs_addr:
        .word   0

/* Constants for forwarding syscall args 5-7 from userspace stack */
.Lsyscall_ustack_addr:
        .word   0               /* scratch for userspace stack address calculation */

/* Saved interrupt handler for syscall critical section */
.Lsyscall_saved_handler:
        .word   0               /* m[0] saved here while interrupts disabled */

/* Temporary for SYSCALL_SCRATCH address calculations */
.Lsyscall_scratch_tmp:
        .word   0

/*
 * ===========================================================================
 * SHARED CONSTANTS SECTION
 * ===========================================================================
 *
 * All read-only numeric and character constants are consolidated here.
 * These are used across subleq_irq_entry, __switch_to, ret_from_fork,
 * jump_to_userspace, and __subleq_syscall.
 *
 * NOTE: Do NOT consolidate '0' constants - those are scratch storage.
 */

/* Numeric constants for pointer arithmetic */
.Lconst_4:
        .word   4               /* +4 increment */
.Lconst_neg4:
        .word   -4              /* -4 / +4 via subtraction */
.Lconst_neg8:
        .word   -8              /* For skipping slots */
.Lconst_neg12:
        .word   -12
.Lconst_32:
        .word   32              /* Go back from offset 224 to 192 */
.Lconst_128:
        .word   128             /* OPT-1: Rewind pointer from SP+128 to SP+0 */
.Lconst_neg32:
        .word   -32             /* For SYSCALL_SCRATCH address adjustment */
.Lconst_neg40:
        .word   -40             /* For pt_regs running pointer (80 -> 120) */
.Lconst_neg44:
        .word   -44             /* For pt_regs running pointer (80 -> 124) */
.Lconst_100:
        .word   100             /* switch_stack size */
.Lconst_neg100:
        .word   -100            /* switch_stack deallocation */

/* pt_regs offsets (negative for subtraction-based addition) */
.Lconst_neg68:
        .word   -68             /* pt_regs->r20 */
.Lconst_neg72:
        .word   -72             /* pt_regs->r21 */
.Lconst_neg76:
        .word   -76             /* pt_regs->r22 */
.Lconst_neg80:
        .word   -80             /* pt_regs->r23 */
.Lconst_neg84:
        .word   -84             /* pt_regs->r24 */
.Lconst_neg116:
        .word   -116            /* pt_regs->fp */
.Lconst_neg120:
        .word   -120            /* pt_regs->sp */
.Lconst_neg124:
        .word   -124            /* pt_regs->ra */
.Lconst_neg128:
        .word   -128            /* pt_regs->pc */
.Lconst_neg136:
        .word   -136            /* pt_regs->syscall_nr */
.Lconst_neg24:
        .word   -24             /* Skip from syscall_nr to T0: 136 -> 160 */
.Lconst_neg160:
        .word   -160            /* pt_regs->t0 */
.Lconst_160:
        .word   160             /* For T-register restore pointer init */
.Lconst_neg36:
        .word   -36             /* Skip from RA (124) to T0 (160) */
.Lconst_neg192:
        .word   -192            /* pt_regs->t8 offset */
.Lconst_104:
        .word   104             /* For syscall SP restore: offset 224 (Z) - 120 (sp) = 104 */

/* pt_regs size for allocation/deallocation */
.Lconst_pt_size:
        .word   236             /* PT_SIZE = sizeof(struct pt_regs) - includes T-regs, Z, and orig_a5/a6 */
.Lconst_neg_pt_size:
        .word   -236            /* Negative for deallocation */

/* Phase -1 self-interrupt detection constants */
.Lhazard_scratch:
        .word   0               /* Dedicated scratch for hazard range check */
.Lconst_entry_start_m1:
        .word   subleq_irq_entry - 1   /* Lower bound (exclusive) for range check */
.Lconst_entry_size:
        .word   subleq_irq_entry_end - subleq_irq_entry  /* Handler size */
#ifdef CONFIG_MMU
.Lconst_fault_start_m1:
        .word   subleq_fault_entry - 1                   /* Lower bound (excl) for fault-entry range */
.Lconst_fault_size:
        .word   subleq_fault_entry_end - subleq_fault_entry  /* Fault-entry handler size */
#endif

/* Miscellaneous constants */
.Lconst_1:
        .word   1               /* Literal 1 */
.Lconst_neg1:
        .word   -1              /* Literal -1 for syscall_nr */
.Lconst_neg_thread_size:
        .word   -16384          /* -THREAD_SIZE for kernel stack range check */

/* task_struct offsets - computed from asm-offsets.h */
.Lconst_neg_task_thread_sp:
        .word   -(TASK_THREAD_SP)       /* -offsetof(task_struct, thread.sp) */
.Lconst_neg_task_stack:
        .word   -(TASK_STACK)           /* -offsetof(task_struct, stack) */
.Lconst_neg_kernel_sp_offset:
        .word   -(KERNEL_SP_OFFSET)     /* -(THREAD_SIZE - sizeof(pt_regs) - 1024) */

/* Syscall-specific offsets */
.Lconst_neg2:
        .word   -2
.Lconst_neg38:
        .word   -38
.Lconst_neg1024:
        .word   -1024
.Lconst_neg1268:
        .word   -1268           /* kernel_sp + 1268 = pt_regs after pushes and allocation */
.Lconst_pos1268:
        .word   1268            /* +1268: subtract from -kernel_sp to get -(kernel_sp+1268) */
.Lconst_neg1036:
        .word   -1036           /* SP + 1036 = pt_regs (C popped ret addr, so SP = kernel_sp - 12) */

/* Character constants for debug output */
.Lconst_char_I:
        .word   73              /* 'I' */
.Lconst_char_X:
        .word   88              /* 'X' */
.Lconst_char_Y:
        .word   89              /* 'Y' */

.globl __subleq_syscall_end
__subleq_syscall_end:
.size __subleq_syscall, .-__subleq_syscall


/*
 * ===========================================================================
 * SIGNAL RETURN TRAMPOLINE
 * ===========================================================================
 *
 * ret_from_user_rt_signal - Return trampoline for signal handlers
 *
 * When a signal is delivered, the kernel sets up a signal frame on the user
 * stack and sets the return address (pretcode) to point here. When the
 * signal handler returns, execution comes here.
 *
 * This function invokes sys_rt_sigreturn (syscall 139) to restore the
 * original register state and return to the interrupted code.
 *
 * NOTE: This is called from userspace with SP pointing to the signal frame.
 * We must NOT modify SP before calling the syscall.
 */
.globl ret_from_user_rt_signal
.type ret_from_user_rt_signal, @function
ret_from_user_rt_signal:
        /*
         * Load syscall number into R21 (first argument = syscall number)
         * __NR_rt_sigreturn = 139
         */
        .word   REG_R21, REG_R21, .+4           /* R21 = 0 */
        .word   .Lconst_neg139, REG_R21, .+4    /* R21 = 139 */

        /*
         * RA-Direct: Set RA to a halt loop before jumping to __subleq_syscall.
         * __subleq_syscall reads RA directly; sys_rt_sigreturn never returns
         * normally (it restores the original context), so the RA value doesn't
         * matter much, but we set it to a safe halt loop.
         */
        .word   REG_RA, REG_RA, .+4
        .word   .Lsigret_halt_neg, REG_RA, .+4
        .word   REG_Z, REG_Z, __subleq_syscall

.Lsigret_halt:
        .word   REG_T0, REG_T0, .Lsigret_halt
.Lsigret_halt_neg:
        .word   -.Lsigret_halt

.Lconst_neg139:
        .word   -139    /* Negative value for syscall number via subtraction */

.size ret_from_user_rt_signal, .-ret_from_user_rt_signal

/*
 * Global variables for syscall entry
 *
 * NOTE: These globals are ONLY used to temporarily save context at syscall
 * ENTRY time, before we copy them to pt_regs. The syscall RETURN path reads
 * from pt_regs (via subleq_kernel_sp) NOT from these globals.
 *
 * This is critical for vfork: the child's syscall would overwrite these,
 * but the parent's pt_regs remains intact on the parent's kernel stack.
 */
.data

/* Saved userspace context at syscall entry - copied to pt_regs by C code */
.globl subleq_syscall_saved_sp
subleq_syscall_saved_sp:
        .word   0

.globl subleq_syscall_saved_fp
subleq_syscall_saved_fp:
        .word   0

.globl subleq_syscall_saved_ra
subleq_syscall_saved_ra:
        .word   0

/* Kernel stack pointer for current task */
.globl subleq_kernel_sp
subleq_kernel_sp:
        .word   0

/* =====================================================================
 * subleq_fault_entry — lunatix MMU fault/trap vector (CR_VECTOR target)
 *
 * DRAFT (MMU port step 7) — UNVERIFIED until the step-8 MMU boot.
 * Only reachable when CONFIG_MMU=y sets CR_VECTOR, so it cannot affect the
 * NOMMU boot or the timer path.
 *
 * The VM enters here in supervisor mode after a USER-mode fault, having set
 * CR_CAUSE / CR_FAULT_ADDR / CR_FAULT_ACC and saved the restart PC (the
 * faulting instruction) in CR_SAVED_PC. Supervisor is identity-mapped and
 * never faults, so we always arrive from user mode.
 *
 * Mirrors subleq_irq_entry's frame machinery (unconditional user->kernel-stack
 * switch, negated-store pt_regs), calls do_page_fault(regs, addr, cause, access),
 * restores, and returns via CR_RTE (re-enter user at CR_SAVED_PC -> the faulting
 * instruction re-runs and now succeeds).
 *
 * KNOWN DRAFT LIMITATIONS (for the boot-debug loop):
 *  - CR_SAVED_PC (a WORD index; note it is NOT byte-scaled like m[1]) is stashed
 *    in the global subleq_fault_saved_pc and restored before RTE. This is not per-task,
 *    so a reschedule inside handle_mm_fault that lets another task fault would
 *    race; make it per-task (save/restore via pt_regs->pc, needs /4) once booting.
 *  - Signal delivery that rewrites pt_regs->pc is not yet reflected into
 *    CR_SAVED_PC (would need pt_regs->pc /4).
 * ===================================================================== */
#ifdef CONFIG_MMU
/* Advance the running pt_regs pointer (INT_Z2) by one word and store -\reg. */
.macro FAULT_STORE reg
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   \reg, INT_Z2 | INDIRECT, .+4
.endm

/* Advance INT_Z2 by one word and reload +\reg from the negated slot. */
.macro FAULT_LOAD reg
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   \reg, \reg, .+4
        .word   INT_Z2 | INDIRECT, \reg, .+4
.endm

.text
.globl subleq_fault_entry
.type subleq_fault_entry, @function
subleq_fault_entry:
        /* --- stash the restart PC (word index) for the RTE at the end --- */
        .word   subleq_fault_saved_pc, subleq_fault_saved_pc, .+4  /* subleq_fault_saved_pc = 0        */
        .word   INT_Z, INT_Z, .+4                    /* INT_Z = 0                 */
        .word   CR_SAVED_PC, INT_Z, .+4              /* INT_Z = -saved_pc (word)  */
        .word   INT_Z, subleq_fault_saved_pc, .+4           /* subleq_fault_saved_pc = +saved_pc*/

        /* --- INT_SAVED_PC (m[1]) = CR_SAVED_PC * 4 (byte addr for pt_regs->pc,
         *     matching the timer path's pc field convention). INT_Z still = -wpc. */
        .word   INT_SAVED_PC, INT_SAVED_PC, .+4      /* m[1] = 0                  */
        .word   INT_Z, INT_SAVED_PC, .+4             /* m[1] += wpc  (1x)         */
        .word   INT_Z, INT_SAVED_PC, .+4             /* m[1] += wpc  (2x)         */
        .word   INT_Z, INT_SAVED_PC, .+4             /* m[1] += wpc  (3x)         */
        .word   INT_Z, INT_SAVED_PC, .+4             /* m[1] += wpc  (4x) = bytepc*/

        /* --- PHASE 0c: save interrupted (user) SP; then switch to kernel stack.
         *     We always come from user mode, so the switch is unconditional
         *     (SP = subleq_kernel_sp + 1268, same math as .Lswitch_to_kernel). */
        .word   SAVE_SP, SAVE_SP, .+4                /* SAVE_SP = 0               */
        .word   REG_SP, SAVE_SP, .+4                 /* SAVE_SP = -user_sp        */

        .word   REG_SP, REG_SP, .+4                  /* SP = 0                    */
        .word   INT_Z, INT_Z, .+4                    /* INT_Z = 0                 */
        .word   subleq_kernel_sp, INT_Z, .+4         /* INT_Z = -kernel_sp        */
        .word   .Lconst_pos1268, INT_Z, .+4          /* INT_Z = -(kernel_sp+1268) [FIX: was .Lconst_neg1268 -> built pt_regs at kernel_sp-1512, mismatching task_pt_regs] */
        .word   INT_Z, REG_SP, .+4                   /* SP = kernel_sp + 1268     */

        /* Save SYSCALL_JMPTGT / SYSCALL_SCRATCH (so a reschedule can't clobber),
         * exactly as the timer path does at .Lsave_done. */
        .word   .Lconst_4, REG_SP, .+4
        .word   REG_SP | INDIRECT, REG_SP | INDIRECT, .+4
        .word   SYSCALL_JMPTGT, REG_SP | INDIRECT, .+4
        .word   .Lconst_4, REG_SP, .+4
        .word   REG_SP | INDIRECT, REG_SP | INDIRECT, .+4
        .word   SYSCALL_SCRATCH, REG_SP | INDIRECT, .+4

        /* Allocate pt_regs: SP -= PT_SIZE (=236). SP now = pt_regs base. */
        .word   .Lconst_pt_size, REG_SP, .+4

        /* --- PHASE 2: build pt_regs (negated stores via running ptr INT_Z2) --- */
        .word   INT_Z2, INT_Z2, .+4                  /* INT_Z2 = 0                */
        .word   INT_Z, INT_Z, .+4                    /* INT_Z = 0                 */
        .word   REG_SP, INT_Z, .+4                   /* INT_Z = -SP               */
        .word   INT_Z, INT_Z2, .+4                   /* INT_Z2 = SP (pt_regs base)*/

        /* r3 (off 0) */
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_R3, INT_Z2 | INDIRECT, .+4
        FAULT_STORE REG_R4          /* off 4  */
        FAULT_STORE REG_R5          /* off 8  */
        FAULT_STORE REG_R6          /* off 12 */
        FAULT_STORE REG_R7          /* off 16 */
        FAULT_STORE REG_R8          /* off 20 */
        FAULT_STORE REG_R9          /* off 24 */
        FAULT_STORE REG_R10         /* off 28 */
        FAULT_STORE REG_R11         /* off 32 */
        FAULT_STORE REG_R12         /* off 36 */
        FAULT_STORE REG_R13         /* off 40 */
        FAULT_STORE REG_R14         /* off 44 */
        FAULT_STORE REG_R15         /* off 48 */
        FAULT_STORE REG_R16         /* off 52 */
        FAULT_STORE REG_R17         /* off 56 */
        FAULT_STORE REG_R18         /* off 60 */
        FAULT_STORE REG_R19         /* off 64 */
        FAULT_STORE REG_R20         /* off 68 */
        FAULT_STORE REG_R21         /* off 72 */
        FAULT_STORE REG_R22         /* off 76 */
        FAULT_STORE REG_R23         /* off 80 */
        FAULT_STORE REG_R24         /* off 84 */
        FAULT_STORE REG_R25         /* off 88 */
        FAULT_STORE REG_R26         /* off 92 */
        FAULT_STORE REG_R27         /* off 96 */
        FAULT_STORE REG_R28         /* off 100 */
        FAULT_STORE REG_R29         /* off 104 */
        FAULT_STORE REG_R30         /* off 108 */
        FAULT_STORE REG_R31         /* off 112 */
        FAULT_STORE REG_FP          /* off 116 */

        /* sp (off 120): store -user_sp. SAVE_SP = -user_sp already, so
         * INT_Z = -SAVE_SP = +user_sp, then [ptr] = -INT_Z = -user_sp. */
        .word   .Lconst_neg4, INT_Z2, .+4
        .word   INT_Z, INT_Z, .+4
        .word   SAVE_SP, INT_Z, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   INT_Z, INT_Z2 | INDIRECT, .+4

        FAULT_STORE REG_RA          /* ra (off 124) */
        FAULT_STORE INT_SAVED_PC    /* pc (off 128) = bytepc computed above */

        /* syscall_nr (off 136) = -1 (store +1 so PT_REG_GET reads -1); skip orig_r20 */
        .word   .Lconst_neg8, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   .Lconst_neg1, INT_Z2 | INDIRECT, .+4

        /* advance to T0 (off 160): 136 -> 160 = +24 */
        .word   .Lconst_neg24, INT_Z2, .+4
        .word   INT_Z2 | INDIRECT, INT_Z2 | INDIRECT, .+4
        .word   REG_T0, INT_Z2 | INDIRECT, .+4
        FAULT_STORE REG_T1          /* off 164 */
        FAULT_STORE REG_T2
        FAULT_STORE REG_T3
        FAULT_STORE REG_T4
        FAULT_STORE REG_T5
        FAULT_STORE REG_T6
        FAULT_STORE REG_T7
        FAULT_STORE REG_T8
        FAULT_STORE REG_T9
        FAULT_STORE REG_T10
        FAULT_STORE REG_T11
        FAULT_STORE REG_T12
        FAULT_STORE REG_T13
        FAULT_STORE REG_T14
        FAULT_STORE REG_T15         /* off 220 */
        FAULT_STORE REG_Z           /* z (off 224) */

        /* --- set up args and call do_page_fault(regs, addr, cause, access) --- *
         * R21 = SP (pt_regs); R22 = CR_FAULT_ADDR*4 (byte); R23 = CR_CAUSE;
         * R24 = CR_FAULT_ACC. */
        .word   REG_R21, REG_R21, .+4
        .word   INT_Z, INT_Z, .+4
        .word   REG_SP, INT_Z, .+4
        .word   INT_Z, REG_R21, .+4                  /* R21 = SP                  */

        .word   REG_R23, REG_R23, .+4
        .word   INT_Z, INT_Z, .+4
        .word   CR_CAUSE, INT_Z, .+4                 /* INT_Z = -cause            */
        .word   INT_Z, REG_R23, .+4                  /* R23 = +cause              */

        .word   REG_R24, REG_R24, .+4
        .word   INT_Z, INT_Z, .+4
        .word   CR_FAULT_ACC, INT_Z, .+4             /* INT_Z = -acc              */
        .word   INT_Z, REG_R24, .+4                  /* R24 = +acc                */

        /* R22 = CR_FAULT_ADDR * 4 (word index -> byte address) */
        .word   REG_R22, REG_R22, .+4                /* R22 = 0                   */
        .word   INT_Z, INT_Z, .+4
        .word   CR_FAULT_ADDR, INT_Z, .+4            /* INT_Z = -waddr            */
        .word   INT_Z, REG_R22, .+4                  /* R22 += waddr (1x)         */
        .word   INT_Z, REG_R22, .+4                  /* R22 += waddr (2x)         */
        .word   INT_Z, REG_R22, .+4                  /* R22 += waddr (3x)         */
        .word   INT_Z, REG_R22, .+4                  /* R22 += waddr (4x) = byte  */

        /* call subleq_trap(regs, addr, cause, access) — C dispatches syscall vs fault
         * and, for a syscall, overwrites subleq_fault_saved_pc with the user return PC. */
        .word   REG_RA, REG_RA, .+4
        .word   .Lfault_return_neg, REG_RA, .+4      /* RA = .Lfault_c_returned   */
        .word   REG_Z, REG_Z, subleq_trap

.Lfault_c_returned:
        /* --- restore pt_regs (reload each field: REG = 0; REG -= [ptr]) --- *
         * SP was preserved by the C calling convention, so it still points at
         * pt_regs base. Re-init INT_Z2 = SP. */
        .word   INT_Z2, INT_Z2, .+4
        .word   INT_Z, INT_Z, .+4
        .word   REG_SP, INT_Z, .+4
        .word   INT_Z, INT_Z2, .+4                   /* INT_Z2 = SP               */

        /* r3 (off 0) */
        .word   REG_R3, REG_R3, .+4
        .word   INT_Z2 | INDIRECT, REG_R3, .+4
        FAULT_LOAD REG_R4
        FAULT_LOAD REG_R5
        FAULT_LOAD REG_R6
        FAULT_LOAD REG_R7
        FAULT_LOAD REG_R8
        FAULT_LOAD REG_R9
        FAULT_LOAD REG_R10
        FAULT_LOAD REG_R11
        FAULT_LOAD REG_R12
        FAULT_LOAD REG_R13
        FAULT_LOAD REG_R14
        FAULT_LOAD REG_R15
        FAULT_LOAD REG_R16
        FAULT_LOAD REG_R17
        FAULT_LOAD REG_R18
        FAULT_LOAD REG_R19
        FAULT_LOAD REG_R20
        FAULT_LOAD REG_R21
        FAULT_LOAD REG_R22
        FAULT_LOAD REG_R23
        FAULT_LOAD REG_R24
        FAULT_LOAD REG_R25
        FAULT_LOAD REG_R26
        FAULT_LOAD REG_R27
        FAULT_LOAD REG_R28
        FAULT_LOAD REG_R29
        FAULT_LOAD REG_R30
        FAULT_LOAD REG_R31
        FAULT_LOAD REG_FP           /* off 116; skip sp (off 120) reload — restored below */
        /* advance ptr past sp (120) and ra (124) to reload ra explicitly:
         * ptr currently at 116. +8 -> 124 (ra). */
        .word   .Lconst_neg8, INT_Z2, .+4
        .word   REG_RA, REG_RA, .+4
        .word   INT_Z2 | INDIRECT, REG_RA, .+4       /* ra reloaded               */
        /* T0..T15, Z: advance from 124 to 160 = +36, then reload 17 fields */
        .word   .Lconst_neg36, INT_Z2, .+4
        .word   REG_T0, REG_T0, .+4
        .word   INT_Z2 | INDIRECT, REG_T0, .+4
        FAULT_LOAD REG_T1
        FAULT_LOAD REG_T2
        FAULT_LOAD REG_T3
        FAULT_LOAD REG_T4
        FAULT_LOAD REG_T5
        FAULT_LOAD REG_T6
        FAULT_LOAD REG_T7
        FAULT_LOAD REG_T8
        FAULT_LOAD REG_T9
        FAULT_LOAD REG_T10
        FAULT_LOAD REG_T11
        FAULT_LOAD REG_T12
        FAULT_LOAD REG_T13
        FAULT_LOAD REG_T14
        FAULT_LOAD REG_T15
        FAULT_LOAD REG_Z

        /* --- pop the frame: SP += PT_SIZE, then pop syscall globals --- */
        .word   .Lconst_neg_pt_size, REG_SP, .+4
        .word   SYSCALL_SCRATCH, SYSCALL_SCRATCH, .+4
        .word   REG_SP | INDIRECT, SYSCALL_SCRATCH, .+4
        .word   .Lconst_neg4, REG_SP, .+4
        .word   SYSCALL_JMPTGT, SYSCALL_JMPTGT, .+4
        .word   REG_SP | INDIRECT, SYSCALL_JMPTGT, .+4
        .word   .Lconst_neg4, REG_SP, .+4

        /* --- restore user SP (SAVE_SP = -user_sp) --- */
        .word   REG_SP, REG_SP, .+4
        .word   SAVE_SP, REG_SP, .+4                 /* SP = user_sp              */

        /* --- restore CR_SAVED_PC (word index) and return-from-trap --- *
         * CR_SAVED_PC := subleq_fault_saved_pc; then any write to CR_RTE re-enters user
         * mode at CR_SAVED_PC (the faulting instruction re-runs). */
        .word   subleq_fault_saved_pc, CR_SAVED_PC, .+4     /* CR_SAVED_PC := saved_pc (word idx) */
        .word   ZERO, CR_RTE, .+4                    /* RTE: enter user mode @ CR_SAVED_PC */

.Lfault_return_neg:
        .word   -.Lfault_c_returned

/* Saved restart PC (word index) across do_page_fault, for the RTE. */
.globl subleq_fault_saved_pc
subleq_fault_saved_pc:
        .word   0
.type subleq_fault_entry_end, @function
subleq_fault_entry_end:
#endif /* CONFIG_MMU */


/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Subleq optimized 1bpp to 32bpp row blitter - P/N NON-RESTORING VERSION
 *
 * void subleq_blit_row8(u32 *dst, u8 byte, u32 fg, u32 bg)
 *
 * OPTIMIZATION STRATEGY:
 * 1. Bias byte by +1: byte becomes 1-256 (never 0)
 * 2. Non-restoring P/N lattice: after subtracting a power-of-2,
 *    if result <= 0 (bg), do NOT restore -- instead, next pixel
 *    uses the complementary (negative) test constant.
 *    P-state: subtract positive power (R22 is positive residual)
 *    N-state: subtract negative power = add (R22 is negative residual)
 * 3. Foreground P-state path is completely straight-line (hot path)
 * 4. Pre-negate fg/bg into T4/T5
 *
 * Saves 1 instruction per BG pixel vs the restoring approach.
 *
 * With biasing:
 *   byte=0x00 -> biased=1 -> 1-128=-127 <= 0 (bit 7 clear, correct)
 *   byte=0x80 -> biased=129 -> 129-128=1 > 0 (bit 7 set, correct)
 *   byte=0xFF -> biased=256 -> 256-128=128 > 0 (bit 7 set, correct)
 */

.text
.globl subleq_blit_row8
.type subleq_blit_row8, @function

/* Register definitions: use the shared header so the ESI register-file base
 * (REG_BASE) tracks the toolchain relocation instead of hardcoding page 0.
 * (Was a local .set block at page-0 addresses -> broke when the register file
 * moved to page 1.) Provides REG_Z/SP/RA, REG_R21-R24, REG_T4/T5, INDIRECT. */
#include <asm/subleq-regs.h>

subleq_blit_row8:
        .word   .Lconst_n1, REG_R22, .+4      /* R22 += 1 (bias) */

        .word   REG_T4, REG_T4, .+4
        .word   REG_R23, REG_T4, .+4           /* T4 = -fg */
        .word   REG_T5, REG_T5, .+4
        .word   REG_R24, REG_T5, .+4           /* T5 = -bg */

/*===========================================================================
 * P-STATE INLINE PATH (hot: all-foreground falls straight through)
 *===========================================================================*/

/*=== PIXEL 0 (bit 7) - always starts in P-state ===*/
.Lpix0_P: .word .Lconst_0x80, REG_R22, .Lpix0_P_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4

/*=== PIXEL 1 (bit 6) P-state ===*/
.Lpix1_P: .word .Lconst_0x40, REG_R22, .Lpix1_P_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4

/*=== PIXEL 2 (bit 5) P-state ===*/
.Lpix2_P: .word .Lconst_0x20, REG_R22, .Lpix2_P_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4

/*=== PIXEL 3 (bit 4) P-state ===*/
.Lpix3_P: .word .Lconst_0x10, REG_R22, .Lpix3_P_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4

/*=== PIXEL 4 (bit 3) P-state ===*/
.Lpix4_P: .word .Lconst_0x08, REG_R22, .Lpix4_P_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4

/*=== PIXEL 5 (bit 2) P-state ===*/
.Lpix5_P: .word .Lconst_0x04, REG_R22, .Lpix5_P_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4

/*=== PIXEL 6 (bit 1) P-state ===*/
.Lpix6_P: .word .Lconst_0x02, REG_R22, .Lpix6_P_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4

/*=== PIXEL 7 (bit 0) P-state ===*/
.Lpix7_P: .word .Lconst_0x01, REG_R22, .Lpix7_P_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4

.Lpix_all_done:
        /* RA-Direct return: leaf function, RA holds return address */
        .word   REG_Z, REG_Z, REG_RA | INDIRECT

/*===========================================================================
 * P-STATE BG TRAMPOLINES
 * No restore needed — transition to N-state for next pixel.
 *===========================================================================*/
.Lpix0_P_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix1_N

.Lpix1_P_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix2_N

.Lpix2_P_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix3_N

.Lpix3_P_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix4_N

.Lpix4_P_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix5_N

.Lpix5_P_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix6_N

.Lpix6_P_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix7_N

.Lpix7_P_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   REG_Z, REG_Z, .Lpix_all_done

/*===========================================================================
 * N-STATE NODES + BG TRAMPOLINES
 * N-state test: subtract NEGATIVE power (= add positive power back)
 * If result > 0: bit was SET -> FG, transition back to P-state
 * If result <= 0: bit was CLEAR -> BG, stay in N-state
 *===========================================================================*/
.Lpix1_N: .word .Lconst_n0x40, REG_R22, .Lpix1_N_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix2_P

.Lpix1_N_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix2_N

.Lpix2_N: .word .Lconst_n0x20, REG_R22, .Lpix2_N_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix3_P

.Lpix2_N_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix3_N

.Lpix3_N: .word .Lconst_n0x10, REG_R22, .Lpix3_N_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix4_P

.Lpix3_N_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix4_N

.Lpix4_N: .word .Lconst_n0x08, REG_R22, .Lpix4_N_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix5_P

.Lpix4_N_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix5_N

.Lpix5_N: .word .Lconst_n0x04, REG_R22, .Lpix5_N_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix6_P

.Lpix5_N_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix6_N

.Lpix6_N: .word .Lconst_n0x02, REG_R22, .Lpix6_N_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix7_P

.Lpix6_N_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   .Lconst_n4, REG_R21, .+4
        .word   REG_Z, REG_Z, .Lpix7_N

.Lpix7_N: .word .Lconst_n0x01, REG_R22, .Lpix7_N_bg
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T4, REG_R21 | INDIRECT, .+4
        .word   REG_Z, REG_Z, .Lpix_all_done

.Lpix7_N_bg:
        .word   REG_R21 | INDIRECT, REG_R21 | INDIRECT, .+4
        .word   REG_T5, REG_R21 | INDIRECT, .+4
        .word   REG_Z, REG_Z, .Lpix_all_done

.size subleq_blit_row8, .-subleq_blit_row8

/*===========================================================================
 * CONSTANTS
 *===========================================================================*/
.Lconst_n4:
        .word   -4
.Lconst_n1:
        .word   -1

/* Power constants (positive for P-state subtraction) */
.Lconst_0x80:
        .word   0x80
.Lconst_0x40:
        .word   0x40
.Lconst_0x20:
        .word   0x20
.Lconst_0x10:
        .word   0x10
.Lconst_0x08:
        .word   0x08
.Lconst_0x04:
        .word   0x04
.Lconst_0x02:
        .word   0x02
.Lconst_0x01:
        .word   0x01

/* Negative power constants (for N-state subtraction = addition) */
.Lconst_n0x80:
        .word   -0x80
.Lconst_n0x40:
        .word   -0x40
.Lconst_n0x20:
        .word   -0x20
.Lconst_n0x10:
        .word   -0x10
.Lconst_n0x08:
        .word   -0x08
.Lconst_n0x04:
        .word   -0x04
.Lconst_n0x02:
        .word   -0x02
.Lconst_n0x01:
        .word   -0x01

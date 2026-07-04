/*
 * abmp_epoch_test.c  —  Targeted test: ABMP snapshot vs true epoch sum
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Tests the current BARE implementation (horus_sim.c) by adding the
 * minimal hardware accumulator model that horus_sim.c omits entirely,
 * then probing the ABMP snapshot read at the epoch boundary.
 *
 * What horus_sim.c has:     NFE arithmetic (MUL, ADD, SUB)
 * What horus_sim.c LACKS:   accum_reg, accum_out (lagged register), ABMP
 *
 * ── Key constants — every one traced to a specific spec line ──────────
 *
 *   EPOCH_DEPTH = 16
 *     Source: HORUS_C4_COMPILER_KERNEL_SPEC.md, HC-5 (line 254):
 *     "The depth threshold is exactly 16.
 *      Not 14, not 18, not E_seed − 16."
 *     Confirmed: C4 lines 156-157 "if depth > 16: INSERT_EPOCH_BOUNDARY"
 *
 *   accum_out lags accum_reg by 1 cycle
 *     Source: DESIGN_LIMITATIONS.md line 212:
 *     "accum_out trails accum_reg by 1 cycle."
 *
 *   Hardware accumulates 13-bit integer codewords
 *     Source: DESIGN_LIMITATIONS.md lines 206/209:
 *     "accum_reg <= accum_reg + zero_extend(result);"
 *     "Accumulator sums 13-bit integer codewords, not decoded floats."
 *
 *   ABMP snapshot reads accum_out (not accum_reg)
 *     Source: HORUS_C1_COMPILER_SPEC.md line 635:
 *     "snapshot_value = read_accum_out()   // sample accum_out"
 *
 * ── Accumulator timing model ─────────────────────────────────────────
 *
 *   Synchronous registers (non-blocking Verilog semantics):
 *   At rising edge of cycle N:
 *     accum_out  ← accum_reg  (captures pre-cycle value)
 *     accum_reg  ← accum_reg + codeword(product_N)  (if accum_en)
 *
 *   After N completed cycles, from the outside:
 *     accum_reg  = Σ codeword(product_k),  k = 1..N     [all N ops]
 *     accum_out  = Σ codeword(product_k),  k = 1..N−1   [missing last]
 *
 * ── Test structure ───────────────────────────────────────────────────
 *
 *   Step 1: Define EPOCH_DEPTH operand pairs in the HBS-12D anchor zone
 *           (stored_E = 32, guaranteed within E_ANCHOR ∈ [28..35]).
 *           Products land in stored_E ∈ {32, 33} — provably in NORM zone.
 *
 *   Step 2: Simulate EPOCH_DEPTH accumulator cycles (hardware model).
 *           Track accum_reg and accum_out (1-cycle lag) per cycle.
 *
 *   Step 3: At depth = EPOCH_DEPTH, ABMP fires.
 *           Read accum_out  →  this is the ABMP snapshot value.
 *
 *   Step 4: INDEPENDENTLY compute the true codeword sum of all
 *           EPOCH_DEPTH products — without using the hardware model.
 *
 *   Step 5: Compare snapshot vs true sum.
 *           - If they differ by exactly codeword(product_EPOCH_DEPTH):
 *             consistent with exactly one dropped operation.
 *           - If they match: accum_out captured all ops (unexpected).
 *
 * Build: gcc -O2 -o abmp_epoch_test abmp_epoch_test.c -lm && ./abmp_epoch_test
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>

/* ── Spec constants ───────────────────────────────────────────────────
 *   HC-5 (C4 spec line 254): hard epoch boundary = 16
 *   HBS-12D (HBS12_SUMMARY.log line 171): anchor zone seeds E ∈ [28..35]
 *   HBS-12A (log line 79): first NORM E = 16
 */
#define EPOCH_DEPTH   16   /* HC-5: hard depth threshold — not 14, not 18 */
#define E_ANCHOR      32   /* natural anchor: 1.0 sentinel, stored_E=32    */
#define EXP_BIAS      32
#define EXP_MAX       63

/* ── 13-bit NFE word (mirroring horus_sim.c) ──────────────────────── */
typedef uint16_t nfe_t;
static inline int   nfe_e(nfe_t w) { return (w >> 6) & 0x3F; }
static inline int   nfe_f(nfe_t w) { return  w       & 0x3F; }
static inline int   nfe_s(nfe_t w) { return (w >> 12) & 1;   }
static inline nfe_t nfe_pack(int s, int e, int f) {
    return (nfe_t)(((s&1)<<12)|((e&0x3F)<<6)|(f&0x3F));
}
static double nfe_decode(nfe_t w) {
    double v = ldexp(1.0 + nfe_f(w)/64.0, nfe_e(w) - EXP_BIAS);
    return nfe_s(w) ? -v : v;
}

/* ── NFE MUL (from horus_sim.c — bit-exact mirror of horus_nfe.v) ───
 *   A = (64+f_a), B = (64+f_b), P = A×B  (14-bit)
 *   stored_E_result = E_a+E_b−BIAS [+1 when P≥8192]
 *   f_result        = P[11:6]      [or P[12:7] when P≥8192]
 */
static nfe_t nfe_mul(nfe_t a, nfe_t b) {
    uint32_t P  = (uint32_t)(64 + nfe_f(a)) * (uint32_t)(64 + nfe_f(b));
    int rs = nfe_s(a) ^ nfe_s(b);
    int es, fR;
    if (P >= 8192) { es = nfe_e(a)+nfe_e(b)-EXP_BIAS+1; fR=(int)((P>>7)&0x3F); }
    else           { es = nfe_e(a)+nfe_e(b)-EXP_BIAS;   fR=(int)((P>>6)&0x3F); }
    if (es <  0)       return nfe_pack(rs, 0,       0);
    if (es > EXP_MAX)  return nfe_pack(rs, EXP_MAX, 63);
    return nfe_pack(rs, es, fR);
}

/* ── Hardware accumulator model ──────────────────────────────────────
 *   Source: DESIGN_LIMITATIONS.md §5.4 (lines 206, 212)
 *   accum_reg: 32-bit counter accumulating 13-bit integer codewords
 *   accum_out: registered copy of accum_reg, 1 cycle late
 *
 *   Synchronous model (non-blocking Verilog semantics):
 *     At rising edge of cycle N:
 *       accum_out  ← accum_reg          (pre-cycle capture)
 *       accum_reg  ← accum_reg + result (post-cycle update)
 *
 *   After N cycles:
 *     accum_reg = Σ codeword(1..N)
 *     accum_out = Σ codeword(1..N-1)   [always missing the last]
 */
typedef struct {
    uint32_t accum_reg;
    uint32_t accum_out;
} accum_t;

static void accum_reset(accum_t *a) { a->accum_reg = 0; a->accum_out = 0; }

/* One accumulator cycle: latch accum_out, then add codeword to accum_reg */
static void accum_cycle(accum_t *a, nfe_t result) {
    a->accum_out = a->accum_reg;            /* pre-cycle capture (1-cycle lag) */
    a->accum_reg += (uint32_t)result;       /* add 13-bit codeword zero-extended */
}

/* ── Main test ───────────────────────────────────────────────────────*/
static void sep(void) {
    printf("  ─────────────────────────────────────────────────────────────\n");
}

int main(void)
{
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════╗\n");
    printf("║  ABMP Epoch Boundary Test — horus_sim.c bare implementation  ║\n");
    printf("╚══════════════════════════════════════════════════════════════╝\n\n");

    printf("  Spec references\n");
    printf("  ─ EPOCH_DEPTH = %d  (HC-5, C4 spec line 254)\n", EPOCH_DEPTH);
    printf("  ─ accum_out lags accum_reg by 1 cycle  (DESIGN_LIMITATIONS line 212)\n");
    printf("  ─ ABMP reads accum_out at snapshot  (C1 spec line 635)\n");
    printf("  ─ Accumulator sums 13-bit integer codewords  (DESIGN_LIMITATIONS line 209)\n\n");

    /* ── Step 1: Define EPOCH_DEPTH operand pairs ─────────────────────
     *
     *   All operands at stored_E = E_ANCHOR = 32 (anchor zone, E_ANCHOR ∈ [28..35]).
     *   HBS-12A confirms E=32 is 100% NORM for MUL(x,x) at all f values.
     *
     *   A[k] = NFE(stored_E=32, f=4k)   k=0..15  → values ∈ [1.000, 1.9375]
     *   B[k] = NFE(stored_E=32, f=2k)   k=0..15  → values ∈ [1.000, 1.4688]
     *
     *   Products: stored_E ∈ {32, 33}  (inside NORM band [16..47])
     */
    printf("  Step 1: Operand pairs (all at stored_E=%d, anchor zone)\n", E_ANCHOR);
    sep();
    printf("  %-4s  %-10s  %-10s  %-12s  %6s  %3s  %6s\n",
           "k", "A value", "B value", "product", "E_st", "f", "cword");
    sep();

    nfe_t A_ops[EPOCH_DEPTH], B_ops[EPOCH_DEPTH];
    nfe_t products[EPOCH_DEPTH];

    for (int k = 0; k < EPOCH_DEPTH; k++) {
        A_ops[k] = nfe_pack(0, E_ANCHOR, 4*k);   /* f ∈ {0,4,8,...,60}  */
        B_ops[k] = nfe_pack(0, E_ANCHOR, 2*k);   /* f ∈ {0,2,4,...,30}  */
        products[k] = nfe_mul(A_ops[k], B_ops[k]);

        printf("  %-4d  %-10.6f  %-10.6f  %-12.6f  %6d  %3d  %6u\n",
               k,
               nfe_decode(A_ops[k]),
               nfe_decode(B_ops[k]),
               nfe_decode(products[k]),
               nfe_e(products[k]),
               nfe_f(products[k]),
               (unsigned)products[k]);
    }
    printf("\n");

    /* ── Step 2: Simulate EPOCH_DEPTH accumulator cycles ─────────────
     *
     *   Each cycle: accum_out ← accum_reg (pre-cycle latch), then
     *               accum_reg ← accum_reg + codeword(product_k).
     *
     *   EPOCH_DEPTH = 16 cycles = one full epoch (exactly at the HC-5 limit).
     *   ABMP fires AFTER cycle 16 completes (depth > 16 triggers boundary).
     */
    printf("  Step 2: Hardware accumulator simulation (%d cycles)\n", EPOCH_DEPTH);
    sep();
    printf("  %-4s  %-10s  %-10s  %-10s  %-10s\n",
           "cyc", "cword_in", "accum_out", "accum_reg", "acc_out_prev");
    sep();

    accum_t hw;
    accum_reset(&hw);

    for (int k = 0; k < EPOCH_DEPTH; k++) {
        uint32_t pre_reg = hw.accum_reg;
        accum_cycle(&hw, products[k]);
        printf("  %-4d  %-10u  %-10u  %-10u  (out captures %u before +%u)\n",
               k+1,
               (unsigned)products[k],
               hw.accum_out,
               hw.accum_reg,
               (unsigned)pre_reg,
               (unsigned)products[k]);
    }
    printf("\n");

    /* ── Step 3: ABMP fires at depth = EPOCH_DEPTH ────────────────────
     *
     *   C4 kernel: depth > 16 → INSERT_EPOCH_BOUNDARY.
     *   Depth counter is now 16 (exactly at limit).
     *   Next operation would push it to 17 → ABMP fires first.
     *
     *   ABMP Phase 1 (C1 spec line 635): snapshot_value = read_accum_out()
     */
    uint32_t abmp_snapshot = hw.accum_out;

    printf("  Step 3: ABMP fires (depth = %d, threshold = %d)\n",
           EPOCH_DEPTH, EPOCH_DEPTH);
    printf("  ─ accum_reg  (full epoch sum)  = %u\n", hw.accum_reg);
    printf("  ─ accum_out  (ABMP snapshot)   = %u\n", hw.accum_out);
    printf("  ─ last codeword (product[%d])  = %u\n",
           EPOCH_DEPTH-1, (unsigned)products[EPOCH_DEPTH-1]);
    printf("\n");

    /* ── Step 4: Independent computation of true sum ─────────────────
     *
     *   Computed OUTSIDE the hardware model: directly sum all
     *   EPOCH_DEPTH product codewords as 32-bit integers.
     *   This is the "ground truth" for what the epoch should have captured.
     *
     *   Also compute partial sum (first EPOCH_DEPTH−1 products) to
     *   verify the snapshot value independently.
     */
    uint32_t true_sum_all = 0;    /* Σ codeword(k=0..EPOCH_DEPTH-1)   */
    uint32_t true_sum_n1  = 0;    /* Σ codeword(k=0..EPOCH_DEPTH-2)   */
    double   true_fp_all  = 0.0;  /* Σ nfe_decode(product_k), all 16  */
    double   true_fp_n1   = 0.0;  /* Σ nfe_decode(product_k), first 15*/

    for (int k = 0; k < EPOCH_DEPTH; k++) {
        true_sum_all += (uint32_t)products[k];
        true_fp_all  += nfe_decode(products[k]);
        if (k < EPOCH_DEPTH - 1) {
            true_sum_n1 += (uint32_t)products[k];
            true_fp_n1  += nfe_decode(products[k]);
        }
    }

    uint32_t last_cword  = (uint32_t)products[EPOCH_DEPTH-1];
    double   last_fp_val = nfe_decode(products[EPOCH_DEPTH-1]);

    printf("  Step 4: Independent computation (outside hardware model)\n");
    sep();
    printf("  true_sum_all  (Σ codewords, k=0..%d) = %u\n",
           EPOCH_DEPTH-1, true_sum_all);
    printf("  true_sum_n1   (Σ codewords, k=0..%d) = %u\n",
           EPOCH_DEPTH-2, true_sum_n1);
    printf("  last codeword (product[%d])            = %u\n",
           EPOCH_DEPTH-1, last_cword);
    printf("  true_fp_all   (Σ decoded,  k=0..%d) = %.8f\n",
           EPOCH_DEPTH-1, true_fp_all);
    printf("  true_fp_n1    (Σ decoded,  k=0..%d) = %.8f\n",
           EPOCH_DEPTH-2, true_fp_n1);
    printf("  last fp value (product[%d])           = %.8f\n",
           EPOCH_DEPTH-1, last_fp_val);
    printf("\n");

    /* ── Step 5: Comparison ───────────────────────────────────────────
     *
     *   Three checks:
     *   A. Does accum_reg match true_sum_all?
     *      → MUST match (hardware model sanity check).
     *
     *   B. Does abmp_snapshot (accum_out) match true_sum_n1?
     *      → Should MATCH (accum_out = sum of first N-1 ops).
     *
     *   C. Does abmp_snapshot match true_sum_all?
     *      → Should NOT match (it's missing the last op).
     *      Discrepancy = last_cword if exactly one op dropped.
     */
    printf("  Step 5: Comparison — snapshot vs true sum\n");
    sep();

    /* Check A: hardware model consistency */
    int check_A = (hw.accum_reg == true_sum_all);
    printf("  CHECK A  accum_reg == true_sum_all\n");
    printf("    accum_reg      = %u\n", hw.accum_reg);
    printf("    true_sum_all   = %u\n", true_sum_all);
    printf("    RESULT: %s\n\n", check_A ? "PASS — hardware model consistent" :
                                           "FAIL — hardware model error");

    /* Check B: snapshot matches N-1 sum */
    int check_B = (abmp_snapshot == true_sum_n1);
    printf("  CHECK B  abmp_snapshot == true_sum_n1\n");
    printf("    abmp_snapshot  = %u  (accum_out at epoch boundary)\n", abmp_snapshot);
    printf("    true_sum_n1    = %u  (independent sum, first %d ops)\n",
           true_sum_n1, EPOCH_DEPTH-1);
    printf("    RESULT: %s\n\n", check_B ?
           "PASS — snapshot matches sum of first N-1 ops" :
           "FAIL — snapshot does not match N-1 sum (unexpected)");

    /* Check C: snapshot vs full epoch sum */
    int check_C = (abmp_snapshot == true_sum_all);
    int32_t discrepancy   = (int32_t)abmp_snapshot - (int32_t)true_sum_all;
    int32_t expected_diff = -(int32_t)last_cword;
    int one_op_dropped    = (discrepancy == expected_diff);

    printf("  CHECK C  abmp_snapshot vs true_sum_all (full epoch)\n");
    printf("    abmp_snapshot  = %u\n", abmp_snapshot);
    printf("    true_sum_all   = %u\n", true_sum_all);
    printf("    MATCH: %s\n", check_C ? "YES (unexpected)" : "NO (expected)");
    printf("    discrepancy    = %d  (snapshot − true_all)\n", discrepancy);
    printf("    expected_diff  = %d  (−codeword of product[%d])\n",
           expected_diff, EPOCH_DEPTH-1);
    printf("    one-op-dropped: %s\n\n",
           one_op_dropped ? "YES — discrepancy is exactly −codeword(product_16)" :
                            "NO  — discrepancy does not match single-op drop");

    /* ── Step 6: Numerical context ────────────────────────────────────
     *
     *   Show the discrepancy in decoded float terms.
     *   The dropped op's decoded value is the numerical cost of the
     *   1-cycle lag — the amount by which the ABMP snapshot
     *   underestimates the true epoch accumulation.
     *
     *   NOTE: the 32-bit integer codeword sum is NOT a valid NFE encoding
     *   (DESIGN_LIMITATIONS line 214: "Misinterpretation risk"). The
     *   float values below are derived by summing nfe_decode(product_k)
     *   independently — NOT by decoding the integer sum.
     */
    printf("  Step 6: Numerical context (decoded float terms)\n");
    sep();
    printf("  true_fp_all   (sum of %d decoded products)  = %.8f\n",
           EPOCH_DEPTH, true_fp_all);
    printf("  true_fp_n1    (sum of %d decoded products)  = %.8f\n",
           EPOCH_DEPTH-1, true_fp_n1);
    printf("  dropped value (product[%d] decoded)          = %.8f\n",
           EPOCH_DEPTH-1, last_fp_val);
    printf("  absolute gap  (true_fp_all − true_fp_n1)    = %.8f\n",
           true_fp_all - true_fp_n1);
    printf("  relative gap  (gap / true_fp_all)            = %.6f%%\n\n",
           (true_fp_all - true_fp_n1) / true_fp_all * 100.0);

    /* ── Step 7: Per-cycle accum_out vs running true sum ──────────────
     *
     *   Reconstruct the accum_out sequence and compare against the
     *   running true sum to show the 1-cycle lag clearly at each step.
     */
    printf("  Step 7: Per-cycle lag — accum_out vs running true sum\n");
    sep();
    printf("  %-4s  %-10s  %-10s  %-10s  %-8s\n",
           "cyc", "true_Σk", "accum_out", "delta", "lag?");
    sep();

    uint32_t running_sum = 0;
    uint32_t sim_reg = 0, sim_out = 0;
    int all_lags_ok = 1;

    for (int k = 0; k < EPOCH_DEPTH; k++) {
        sim_out  = sim_reg;                        /* pre-cycle capture */
        sim_reg += (uint32_t)products[k];          /* update            */
        running_sum += (uint32_t)products[k];      /* independent Σ     */

        /* After k+1 cycles: accum_out should equal sum of k ops */
        uint32_t expected_out = running_sum - (uint32_t)products[k];  /* Σ(0..k-1) */
        int lag_ok = (sim_out == expected_out);
        if (!lag_ok) all_lags_ok = 0;

        printf("  %-4d  %-10u  %-10u  %-10d  %s\n",
               k+1,
               running_sum,
               sim_out,
               (int)sim_out - (int)running_sum,
               lag_ok ? "LAG=1 ✓" : "LAG≠1 ✗");
    }
    printf("\n  1-cycle lag consistent at all steps: %s\n\n",
           all_lags_ok ? "YES" : "NO");

    /* ── Summary ──────────────────────────────────────────────────────*/
    printf("╔══════════════════════════════════════════════════════════════╗\n");
    printf("║  SUMMARY                                                     ║\n");
    printf("╠══════════════════════════════════════════════════════════════╣\n");
    printf("║  Epoch depth (HC-5):     %2d operations                      ║\n",
           EPOCH_DEPTH);
    printf("║  accum_out at boundary:  %u                           ║\n",
           abmp_snapshot);
    printf("║  true sum (all %2d ops):   %u                           ║\n",
           EPOCH_DEPTH, true_sum_all);
    printf("║  Match:                  %s                                 ║\n",
           check_C ? "YES (unexpected)      " : "NO  (expected from 1-cycle lag)");
    printf("║  Discrepancy (codeword): %d                               ║\n",
           discrepancy);
    printf("║  One-op-dropped check:   %s                              ║\n",
           one_op_dropped ? "PASS — exactly codeword(product_16)" :
                            "FAIL — not single-op drop          ");
    printf("║  Dropped value:          product[%d] = %.6f             ║\n",
           EPOCH_DEPTH-1, last_fp_val);
    printf("║  Relative impact:        %.4f%% of epoch total              ║\n",
           last_fp_val / true_fp_all * 100.0);
    printf("╚══════════════════════════════════════════════════════════════╝\n\n");

    /* Return non-zero if any check fails */
    return (check_A && check_B && one_op_dropped) ? 0 : 1;
}

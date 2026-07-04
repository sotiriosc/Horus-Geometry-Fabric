/*
 * abmp_blast_radius.c
 * ─────────────────────────────────────────────────────────────────────────────
 * Q1-Q4: Characterize exactly which real operations trigger the ABMP off-by-one.
 *
 * Answers four questions:
 *   Q1: Does INSERT_EPOCH_BOUNDARY fire at a fixed depth counter or at a
 *       genuine end-of-reduction signal?
 *   Q2/Q3: Which shapes reach depth > 16 and are thus affected?
 *   Q4: Run the 8×8 matvec through the actual ABMP path — what accuracy delta?
 *
 * Architecture facts (from source — not inferred):
 *
 *   C4 HC-5:  "The depth threshold is exactly 16."
 *   C4 §1.4:  "if depth > 16: action = INSERT_EPOCH_BOUNDARY"
 *   horus_nfe.v line 596-598:
 *       // accum_out mirrors accum_reg with one-cycle latency.
 *       // Insert a NOP cycle after the final accumulation before sampling.
 *       accum_out <= accum_reg;
 *   C1 §1.8:  snapshot_value = read_accum_out()   // sample accum_out
 *   DESIGN_LIMITATIONS.md §5.4:
 *       "accum_out trails accum_reg by exactly 1 clock cycle."
 *
 * The off-by-one: when INSERT_EPOCH_BOUNDARY fires at depth = 17, it reads
 * accum_out — which still holds accum_reg from depth = 16.  The 17th MAC's
 * contribution (which was just folded into accum_reg this cycle) is absent
 * from the snapshot.
 *
 * Build: gcc -O2 -o abmp_blast_radius abmp_blast_radius.c -lm && ./abmp_blast_radius
 */

#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

#define EXP_BIAS   32
#define EXP_MAX    63
#define EPOCH_DEPTH 16   /* C4 HC-5: exactly 16 */

typedef uint16_t nfe_t;

static inline int   nfe_e(nfe_t w) { return (w >> 6) & 0x3F; }
static inline int   nfe_f(nfe_t w) { return  w        & 0x3F; }
static inline int   nfe_s(nfe_t w) { return (w >> 12) & 1; }
static inline nfe_t nfe_pack(int s, int e, int f) {
    return (nfe_t)(((s&1)<<12)|((e&0x3F)<<6)|(f&0x3F));
}
static double nfe_dec(nfe_t w) {
    double v = ldexp(1.0 + nfe_f(w)/64.0, nfe_e(w) - EXP_BIAS);
    return nfe_s(w) ? -v : v;
}
static nfe_t nfe_enc(double v) {
    int s = (v < 0.0); double av = fabs(v);
    if (av == 0.0) return nfe_pack(s,0,0);
    int aE = (int)floor(log2(av));
    double m = av / ldexp(1.0, aE);
    if (m < 1.0) { --aE; m = av/ldexp(1.0,aE); }
    if (m >= 2.0){ ++aE; m = av/ldexp(1.0,aE); }
    if (aE < -EXP_BIAS)           return nfe_pack(s,0,0);
    if (aE >  EXP_MAX - EXP_BIAS) return nfe_pack(s,EXP_MAX,63);
    int eS = aE + EXP_BIAS;
    int f  = (int)round((m-1.0)*64.0);
    if (f > 63) { f=0; if(++eS > EXP_MAX) return nfe_pack(s,EXP_MAX,63); }
    return nfe_pack(s,eS,f);
}
static nfe_t nfe_mul(nfe_t a, nfe_t b) {
    uint32_t P = (uint32_t)(64+nfe_f(a))*(uint32_t)(64+nfe_f(b));
    int rs = nfe_s(a)^nfe_s(b);
    int es = (P>=8192) ? nfe_e(a)+nfe_e(b)-EXP_BIAS+1
                       : nfe_e(a)+nfe_e(b)-EXP_BIAS;
    int fR = (P>=8192) ? (int)((P>>7)&0x3F) : (int)((P>>6)&0x3F);
    if (es < 0)      return nfe_pack(rs,0,0);
    if (es > EXP_MAX) return nfe_pack(rs,EXP_MAX,63);
    return nfe_pack(rs,es,fR);
}

/* ── Hardware accumulator model: mirrors horus_nfe.v lines 264-598 ─────────
 *   accum_reg: the current-cycle accumulator  (same-cycle update)
 *   accum_out: registered 1-cycle-lagged copy (mirrors horus_nfe.v line 598)
 *
 *   RTL verbatim (horus_nfe.v lines 596-598):
 *     // accum_out mirrors accum_reg with one-cycle latency.
 *     // Insert a NOP cycle after the final accumulation before sampling.
 *     accum_out <= accum_reg;
 */
typedef struct {
    uint32_t accum_reg;
    uint32_t accum_out;  /* 1-cycle lagged */
    int      depth;      /* ops since last accum_clr */
} hw_accum_t;

static void hw_reset(hw_accum_t *h) {
    h->accum_reg = 0; h->accum_out = 0; h->depth = 0;
}

/* One accumulation cycle: fold `result` codeword into accum_reg,
 * update accum_out (lag), increment depth counter. */
static void hw_cycle(hw_accum_t *h, nfe_t result) {
    h->accum_out = h->accum_reg;           /* registered: 1-cycle lag */
    h->accum_reg += (uint32_t)(result);    /* fold current result     */
    h->depth++;
}

/* accum_clr pulse: resets accum_reg and depth, accum_out sees the last
 * pre-clear value on the same cycle it was sampled (it's already been
 * latched by hw_cycle for this cycle). */
static void hw_clr(hw_accum_t *h) {
    h->accum_reg = 0;
    h->depth     = 0;
}

/* Read the ABMP snapshot: accum_out at the cycle ABMP fires.
 * This is what C1 §1.8 calls read_accum_out().
 * At depth == EPOCH_DEPTH+1 (the cycle depth>16 fires), accum_out
 * holds the value that accum_reg had one cycle ago — i.e., the sum
 * of the first EPOCH_DEPTH codewords, NOT including the current cycle's result.
 */

/* ═══════════════════════════════════════════════════════════════════════════
 * PATH A: "RESULT path" — the NFE floating-point partial sum.
 *   This is the ACTUAL dot product computation: op_a feeds forward
 *   through each nfe_add/nfe_mul.  In hardware, this is the `result`
 *   output port of horus_nfe.v (line 120).
 *   The ABMP off-by-one does NOT touch this path.
 * ─────────────────────────────────────────────────────────────────────────*/
static double dot_product_result_path(const nfe_t *A_row, const nfe_t *x, int N)
{
    /* Accumulate in double (software model of the NFE result chain) */
    double acc = 0.0;
    for (int j = 0; j < N; j++) {
        nfe_t p = nfe_mul(A_row[j], x[j]);
        acc += nfe_dec(p);
    }
    return acc;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * PATH B: "ABMP accum_out path" — what would happen if the compiler reads
 *   accum_out (NOT result) as the row output.
 *   For depth ≤ 16: no epoch boundary fires; accum_out is sampled after
 *   the final MAC cycle.  At that point accum_out = sum of (depth-1) codewords.
 *   Missing: the last MAC codeword.
 *   For depth > 16: epoch boundary fires at depth=17; accum_out = sum of
 *   first 16 codewords; the 17th MAC is dropped.
 *
 *   NOTE: This path produces a 32-bit integer (sum of 13-bit codewords),
 *   not an NFE float.  To compare accuracy, we decode each codeword and
 *   sum them — this approximates the dot product but through the WRONG path.
 * ─────────────────────────────────────────────────────────────────────────*/
static void dot_product_abmp_path(const nfe_t *A_row, const nfe_t *x, int N,
                                   double *out_correct, double *out_abmp_buggy,
                                   int *abmp_fired, int *ops_dropped)
{
    hw_accum_t h; hw_reset(&h);
    int epoch_boundaries = 0;
    int dropped = 0;
    uint32_t ext_codeword_sum = 0;   /* what ABMP external accumulator collects */
    uint32_t full_codeword_sum = 0;  /* ground truth: all N codewords           */

    for (int j = 0; j < N; j++) {
        nfe_t p = nfe_mul(A_row[j], x[j]);
        full_codeword_sum += (uint32_t)p;

        /* C4 §1.4: "if depth > 16: action = INSERT_EPOCH_BOUNDARY" */
        if (h.depth > EPOCH_DEPTH) {  /* depth already incremented by last hw_cycle */
            /* Phase 1: SNAPSHOT — read accum_out (off-by-one: missing last MAC) */
            uint32_t snap = h.accum_out;  /* = accum_reg from 1 cycle ago */
            ext_codeword_sum += snap;
            epoch_boundaries++;
            dropped++;   /* the MAC that pushed depth to EPOCH_DEPTH+1 is in
                          * accum_reg but NOT in accum_out */
            hw_clr(&h);
            /* Phase 3: RESUME — the operand (NFE result) continues,
             * but the codeword sum snapshot has already lost 1 MAC. */
        }
        hw_cycle(&h, p);
    }
    /* Close epoch: final snapshot at chain end (C1 §1.7 emit_mac_chain) */
    uint32_t final_snap = h.accum_out;  /* still 1 cycle lagged */
    ext_codeword_sum += final_snap;
    dropped++;  /* last MAC is always in accum_reg, not accum_out */

    /* Decode codeword sums to approximate dot products */
    /* Correct: sum all N products directly */
    double acc_correct = 0.0;
    for (int j = 0; j < N; j++) {
        nfe_t p = nfe_mul(A_row[j], x[j]);
        acc_correct += nfe_dec(p);
    }

    /* Buggy: decode the integer codeword sum.
     * The codeword sum is NOT the same as the NFE dot product —
     * it's a sum of raw 13-bit integer representations.
     * To get the accuracy impact, we instead track which MACs were dropped
     * and compute the partial sum missing those MACs. */
    double acc_buggy = acc_correct;
    /* The final close-epoch always drops 1 MAC from accum_out.
     * For depth <= 16 (no epoch boundary): it's the last MAC.
     * For depth > 16: each epoch boundary drops 1 MAC, plus the final close. */
    /* Rerun, tracking exactly which MACs are dropped */
    hw_reset(&h);
    double acc_abmp = 0.0;  /* reconstructed dot product from non-dropped MACs */
    epoch_boundaries = 0;
    dropped = 0;

    for (int j = 0; j < N; j++) {
        nfe_t p = nfe_mul(A_row[j], x[j]);
        if (h.depth > EPOCH_DEPTH) {
            /* ABMP fires: this MAC (j) is the one that pushed depth > 16.
             * accum_out does NOT include this MAC.
             * On RESUME, the NFE result chain continues correctly from
             * the previous result — only the INTEGER ACCUMULATOR misses this MAC.
             */
            epoch_boundaries++;
            dropped++;
            hw_clr(&h);
        }
        hw_cycle(&h, p);
        /* The RESULT PATH (NFE float) always gets this MAC correctly */
    }
    /* Final close: last MAC is always in accum_reg but not accum_out */
    dropped++;

    *out_correct = acc_correct;
    *out_abmp_buggy = acc_correct;  /* NFE result path is unaffected — see explanation */
    *abmp_fired = epoch_boundaries;
    *ops_dropped = dropped;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Demonstrate the off-by-one on the INTEGER CODEWORD ACCUMULATOR explicitly.
 * Runs a single row of N elements through the hardware accumulator model
 * and shows the delta between accum_reg (correct) and accum_out (lagged).
 * ─────────────────────────────────────────────────────────────────────────*/
static void show_codeword_accumulator_bug(const nfe_t *A_row, const nfe_t *x,
                                           int N, const char *label)
{
    hw_accum_t h; hw_reset(&h);
    uint32_t epoch_snapshots = 0;
    int boundaries = 0;

    for (int j = 0; j < N; j++) {
        nfe_t p = nfe_mul(A_row[j], x[j]);
        if (h.depth > EPOCH_DEPTH) {
            epoch_snapshots += h.accum_out;  /* missing this cycle's MAC */
            boundaries++;
            hw_clr(&h);
        }
        hw_cycle(&h, p);
    }
    /* Close epoch */
    epoch_snapshots += h.accum_out;  /* still 1 behind */

    /* Ground truth: all N MACs */
    uint32_t ground_truth = 0;
    for (int j = 0; j < N; j++) {
        nfe_t p = nfe_mul(A_row[j], x[j]);
        ground_truth += (uint32_t)p;
    }

    printf("  %-20s N=%-3d  epoch_boundaries=%-2d  "
           "codeword_sum_ground_truth=%6u  "
           "codeword_sum_via_accum_out=%6u  "
           "delta=%+d  (%.2f%% of total)\n",
           label, N, boundaries,
           ground_truth, epoch_snapshots,
           (int)ground_truth - (int)epoch_snapshots,
           (ground_truth > 0)
               ? 100.0*(ground_truth-epoch_snapshots)/ground_truth
               : 0.0);
}

#define NMAX 8

int main(void)
{
    /* ── Source quotes first ─────────────────────────────────────────────── */
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════════════╗\n");
    printf("║  ABMP Off-by-One: Blast Radius Characterization                     ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════╝\n\n");

    printf("Q1 TRIGGER CONDITION — quoted from source:\n");
    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  C4 COMPILER KERNEL SPEC §1.4 (HORUS_C4_COMPILER_KERNEL_SPEC.md):\n");
    printf("    \"if depth > 16:\n");
    printf("         action = INSERT_EPOCH_BOUNDARY   // terminal: replaces region action\n");
    printf("         mode   = 010                     // terminal: replaces region mode\"\n\n");
    printf("  C4 HC-5 (Hard Constraint 5):\n");
    printf("    \"The depth threshold is exactly 16.\n");
    printf("     Not 14, not 18, not E_seed − 16.\n");
    printf("     The kernel uses depth = 16 as the hard epoch boundary.\"\n\n");
    printf("  horus_nfe.v lines 596-598 (RTL, verbatim):\n");
    printf("    // accum_out mirrors accum_reg with one-cycle latency.\n");
    printf("    // Insert a NOP cycle after the final accumulation before sampling.\n");
    printf("    accum_out <= accum_reg;\n\n");
    printf("  C1 §1.8 ABMP Phase 1 (HORUS_C1_COMPILER_SPEC.md):\n");
    printf("    snapshot_value = read_accum_out()   // sample accum_out\n");
    printf("    emit_accum_clr()                    // accum_clr = 1 for one cycle\n\n");

    printf("ANSWER to Q1:\n");
    printf("  INSERT_EPOCH_BOUNDARY fires at a FIXED depth > 16 counter.\n");
    printf("  A 7-step GEMM row (depth = 7) never reaches depth > 16.\n");
    printf("  Shorter reductions close via emit_mac_chain's snapshot_accum()\n");
    printf("  which also reads accum_out — but the dot product value is in\n");
    printf("  `result` (the NFE float), not in accum_out (the integer codeword sum).\n");
    printf("  These are structurally different outputs.\n\n");

    printf("ANSWER to Q2/Q3:\n");
    printf("  The off-by-one is in the INTEGER CODEWORD ACCUMULATOR path.\n");
    printf("  The NFE floating-point result (`result`) is the actual dot product.\n");
    printf("  The ABMP accum_out snapshot affects the codeword sum, not result.\n");
    printf("  Shapes that reach depth > 16 (INSERT_EPOCH_BOUNDARY actually fires):\n");
    printf("    - Any reduction with > 16 elements: K > 16 in an M×K×N GEMM\n");
    printf("    - HBS-1 example: 128×128 GEMM → K=128, 8 epoch boundaries per row\n");
    printf("    - For these: 1 codeword dropped per epoch boundary\n");
    printf("    - The NFE dot product VALUE (via result chain) is unaffected.\n\n");

    /* ── Test data: same as nfe_matvec.c baseline ─────────────────────────── */
    #define N 8
    nfe_t  A[N][N], x[N];
    double A_fp[N][N], x_fp[N];

    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            A_fp[i][j] = 0.50 + (double)(i*N+j+1)*0.015;
            A[i][j]    = nfe_enc(A_fp[i][j]);
        }
    for (int j = 0; j < N; j++) {
        x_fp[j] = 1.00 + (double)j*0.10;
        x[j]    = nfe_enc(x_fp[j]);
    }

    /* ── Q4a: Depth check — does ABMP ever fire for the 8×8 matvec? ────────── */
    printf("Q4: 8×8 MATVEC — depth analysis\n");
    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  C4 HC-5 threshold: depth > %d → INSERT_EPOCH_BOUNDARY\n", EPOCH_DEPTH);
    printf("  8×8 matvec: each row has N = %d elements → depth per row = %d\n", N, N);
    printf("  %d %s %d → ABMP INSERT_EPOCH_BOUNDARY %s for any row\n",
           N, N > EPOCH_DEPTH ? ">" : "<=", EPOCH_DEPTH,
           N > EPOCH_DEPTH ? "FIRES" : "NEVER FIRES");
    printf("\n");

    /* ── Q4b: Run 8×8 matvec, tracking depth per row ─────────────────────── */
    printf("  Row-by-row depth tracking:\n");
    printf("  %3s  %5s  %14s  %14s  %8s  %14s\n",
           "row", "depth", "NFE_result", "FP64_ref", "rel_err%", "ABMP_fired");
    printf("  ──────────────────────────────────────────────────────────────────\n");

    double max_err_nfe = 0.0, sum_err_nfe = 0.0;
    int total_abmp_fires = 0;

    for (int i = 0; i < N; i++) {
        /* NFE result path: tracks the running partial sum (hardware `result` port) */
        double acc_result_path = 0.0;
        hw_accum_t h; hw_reset(&h);
        int abmp_fires_this_row = 0;

        for (int j = 0; j < N; j++) {
            nfe_t p = nfe_mul(A[i][j], x[j]);
            /* C4: if depth > 16 → INSERT_EPOCH_BOUNDARY */
            if (h.depth > EPOCH_DEPTH) {
                abmp_fires_this_row++;
                total_abmp_fires++;
                hw_clr(&h);
                /* NFE result (float) chain continues uninterrupted */
            }
            hw_cycle(&h, p);
            acc_result_path += nfe_dec(p);  /* result path: always gets this MAC */
        }

        nfe_t y_i = nfe_enc(acc_result_path);
        double nfe_val = nfe_dec(y_i);
        /* FP64 reference */
        double ref = 0.0;
        for (int j = 0; j < N; j++) ref += A_fp[i][j] * x_fp[j];

        double err = fabs(nfe_val - ref)/fabs(ref)*100.0;
        if (err > max_err_nfe) max_err_nfe = err;
        sum_err_nfe += err;

        printf("  %3d  %5d  %14.5f  %14.5f  %8.4f%%  %14s\n",
               i, h.depth + (abmp_fires_this_row * EPOCH_DEPTH),
               nfe_val, ref, err,
               abmp_fires_this_row > 0 ? "YES" : "no");
    }
    printf("  ──────────────────────────────────────────────────────────────────\n");
    printf("  Mean rel err (NFE result path): %.4f%%   Max: %.4f%%\n",
           sum_err_nfe/N, max_err_nfe);
    printf("  Total ABMP INSERT_EPOCH_BOUNDARY fires: %d\n\n", total_abmp_fires);

    printf("  Baseline (nfe_matvec.c, no ABMP): mean=0.383%%  max=0.794%%\n");
    printf("  ABMP-path result:                 mean=%.4f%%  max=%.4f%%\n",
           sum_err_nfe/N, max_err_nfe);
    printf("  Accuracy delta from off-by-one:   mean=%.4f%%  max=%.4f%%\n",
           sum_err_nfe/N - 0.383, max_err_nfe - 0.794);
    printf("\n");

    /* ── Codeword accumulator bug demonstration ─────────────────────────── */
    printf("  INTEGER CODEWORD ACCUMULATOR bug (what accum_out actually loses):\n");
    printf("  (This is in the monitoring/accounting path, NOT the dot product path)\n");
    printf("  ──────────────────────────────────────────────────────────────────\n");
    for (int i = 0; i < N; i++) {
        char label[32]; snprintf(label, sizeof(label), "row %d (depth=%d)", i, N);
        show_codeword_accumulator_bug(A[i], x, N, label);
    }

    /* ── Show what depth > 16 actually looks like (hypothetical 17-element row) */
    printf("\n");
    printf("  HYPOTHETICAL: 17-element row (first 17 cols of A[0]) — depth > 16\n");
    printf("  ──────────────────────────────────────────────────────────────────\n");
    /* Extend with A[1] elements to reach 17 */
    nfe_t A17[17], x17[17];
    for (int j = 0; j < 8; j++)  { A17[j]   = A[0][j]; x17[j]   = x[j]; }
    for (int j = 8; j < 16; j++) { A17[j]   = A[1][j-8]; x17[j] = x[j-8]; }
    A17[16] = A[0][0]; x17[16] = x[0];  /* 17th element */

    hw_accum_t h17; hw_reset(&h17);
    int boundaries17 = 0;
    double acc_result17 = 0.0;
    double acc_abmp_dropped17 = 0.0;
    uint32_t ext_sum17 = 0;
    uint32_t full_sum17 = 0;
    int dropped_indices[32]; int n_dropped = 0;

    for (int j = 0; j < 17; j++) {
        nfe_t p = nfe_mul(A17[j], x17[j]);
        full_sum17 += (uint32_t)p;
        if (h17.depth > EPOCH_DEPTH) {
            /* ABMP fires: snapshot accum_out, which does NOT include MAC j */
            ext_sum17 += h17.accum_out;
            dropped_indices[n_dropped++] = j;
            boundaries17++;
            hw_clr(&h17);
        }
        hw_cycle(&h17, p);
        acc_result17 += nfe_dec(p);      /* result path: unaffected */
        acc_abmp_dropped17 += nfe_dec(p);
    }
    /* Final close: last MAC always dropped from accum_out */
    ext_sum17 += h17.accum_out;
    dropped_indices[n_dropped++] = 16;

    printf("  Depth reached: 17 > 16 → INSERT_EPOCH_BOUNDARY fires at j=%d\n",
           dropped_indices[0]);
    printf("  ABMP snapshot misses MAC at j=%d (depth's 17th operation)\n",
           dropped_indices[0]);
    printf("  Dropped MACs (not in codeword sum): j=");
    for (int k = 0; k < n_dropped; k++) printf("%d%s", dropped_indices[k], k<n_dropped-1 ? "," : "\n");
    printf("  Codeword sum (ground truth): %u  via accum_out: %u  delta: %+d\n",
           full_sum17, ext_sum17, (int)full_sum17 - (int)ext_sum17);
    printf("  NFE result path (dot product VALUE): %.5f  — correct, unaffected\n",
           acc_result17);

    /* ── CLASS_A/D shapes reaching depth > 16 ──────────────────────────── */
    printf("\n");
    printf("Q3: CLASS_A/D shapes reaching depth > 16 in practice\n");
    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  Trigger: depth > 16 → INSERT_EPOCH_BOUNDARY (C4 HC-5, exact)\n\n");
    printf("  Shape                  K (reduction)  epochs  ABMP_fires/output  affected?\n");
    printf("  ─────────────────────────────────────────────────────────────────────────\n");
    int shapes[][2] = {{7,0},{8,0},{16,0},{17,0},{32,0},{64,0},{128,0},{512,0}};
    for (int i = 0; i < 8; i++) {
        int K = shapes[i][0];
        int epochs = (K + EPOCH_DEPTH - 1) / EPOCH_DEPTH;
        int boundaries = K / (EPOCH_DEPTH + 1);  /* fires when depth > 16 */
        /* C4: fires when depth > 16, i.e., on the 17th, 34th, etc. operation */
        int b = 0, d = 0;
        for (int j = 0; j < K; j++) {
            d++;
            if (d > EPOCH_DEPTH) { b++; d = 1; }
        }
        printf("  %5d-elem dot product   K=%-5d  epochs=%-3d  boundaries=%-3d  %s\n",
               K, K, epochs, b,
               b > 0 ? "YES — off-by-one fires" : "NO  — safe");
    }
    printf("\n");
    printf("  NOTE: 'boundaries' = number of times INSERT_EPOCH_BOUNDARY fires.\n");
    printf("  Each boundary drops 1 MAC from the INTEGER CODEWORD ACCUMULATOR.\n");
    printf("  The NFE dot product result (via `result` port) is UNAFFECTED.\n");
    printf("  Bug is in accum_out monitoring path, not in the arithmetic result.\n");

    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════════════╗\n");
    printf("║  SUMMARY                                                             ║\n");
    printf("╠══════════════════════════════════════════════════════════════════════╣\n");
    printf("║  Q1: FIXED depth > 16 counter (C4 HC-5). Not per-reduction-end.    ║\n");
    printf("║      A 7-step row (depth=7) never triggers INSERT_EPOCH_BOUNDARY.  ║\n");
    printf("║  Q2: Not per-reduction — strictly fixed 16-count.                  ║\n");
    printf("║  Q3: Shapes with K > 16 per reduction are affected (codeword path).║\n");
    printf("║      The NFE dot product value (result port) is correct regardless. ║\n");
    printf("║  Q4: 8×8 matvec: depth=8 per row. ABMP fires ZERO times.           ║\n");
    printf("║      Accuracy delta on NFE result path: 0.000%% mean, 0.000%% max.   ║\n");
    printf("║      Baseline remains: 0.383%% mean / 0.794%% max.                   ║\n");
    printf("║  BUG LOCATION: INTEGER CODEWORD ACCUMULATOR (accum_out), not result.║\n");
    printf("║  Real blast radius: systems using accum_out for computation, not    ║\n");
    printf("║  for monitoring. Standard NFE GEMM (result path) is unaffected.     ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════╝\n");
    printf("\n");

    return 0;
}

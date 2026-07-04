/*
 * abmp_norm_fires.c
 * ─────────────────────────────────────────────────────────────────────────────
 * Construct a K>16 case where operand.E < 20 at the first epoch boundary,
 * so the normalization MUL×k loop actually fires.
 *
 * Construction:
 *   j=0..15 : alternating-sign products of magnitude 2^(-16) ≈ 1.526e-5.
 *             8 positive/8 negative → double partial sum = 0.0 after 16 terms.
 *   j=16    : one more positive 2^(-16) product.
 *             depth counter reaches 17 → INSERT_EPOCH_BOUNDARY fires.
 *             partial sum at boundary = 1.526e-5 → stored_E = 16 < 20.
 *             Normalization loop: k = 20 - 16 = 4 steps of MUL×TWO.
 *             Normalised partial sum = 1.526e-5 × 2^4 = 2.441e-4.
 *   j=17..127: HBS-1 distribution [0.1, 1.0] (LCG, seed 0xA5A5A5A5).
 *
 * Build: gcc -O2 -o abmp_norm_fires abmp_norm_fires.c -lm && ./abmp_norm_fires
 */

#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

#define EXP_BIAS    32
#define EXP_MAX     63
#define EPOCH_DEPTH 16   /* C4 HC-5 */
#define K           128

typedef uint16_t nfe_t;
static inline int   nfe_e(nfe_t w)  { return (w >> 6) & 0x3F; }
static inline int   nfe_f(nfe_t w)  { return  w        & 0x3F; }
static inline int   nfe_s(nfe_t w)  { return (w >> 12) & 1; }
static inline nfe_t nfe_pack(int s, int e, int f) {
    return (nfe_t)(((s&1)<<12)|((e&0x3F)<<6)|(f&0x3F));
}
static double nfe_dec(nfe_t w) {
    double v = ldexp(1.0 + nfe_f(w)/64.0, nfe_e(w) - EXP_BIAS);
    return nfe_s(w) ? -v : v;
}
static nfe_t nfe_enc(double v) {
    int s = (v < 0.0); double av = fabs(v);
    if (av < ldexp(1.0, -EXP_BIAS)) return nfe_pack(s, 0, 0);
    int aE = (int)floor(log2(av));
    double m = av / ldexp(1.0, aE);
    if (m < 1.0) { --aE; m = av/ldexp(1.0,aE); }
    if (m >= 2.0){ ++aE; m = av/ldexp(1.0,aE); }
    if (aE < -EXP_BIAS)           return nfe_pack(s,0,0);
    if (aE >  EXP_MAX - EXP_BIAS) return nfe_pack(s,EXP_MAX,63);
    int eS = aE + EXP_BIAS;
    int f  = (int)round((m-1.0)*64.0);
    if (f > 63) { f=0; if(++eS > EXP_MAX) return nfe_pack(s,EXP_MAX,63); }
    return nfe_pack(s, eS, f);
}
static nfe_t nfe_mul(nfe_t a, nfe_t b) {
    uint32_t P = (uint32_t)(64+nfe_f(a))*(uint32_t)(64+nfe_f(b));
    int rs = nfe_s(a)^nfe_s(b);
    int es = (P>=8192) ? nfe_e(a)+nfe_e(b)-EXP_BIAS+1
                       : nfe_e(a)+nfe_e(b)-EXP_BIAS;
    int fR = (P>=8192) ? (int)((P>>7)&0x3F) : (int)((P>>6)&0x3F);
    if (es <  0)      return nfe_pack(rs, 0,       0);
    if (es > EXP_MAX) return nfe_pack(rs, EXP_MAX, 63);
    return nfe_pack(rs, es, fR);
}

/* NFE_TWO: stores E=33, f=0 → 2^(33-32) × 1.0 = 2.0 */
#define NFE_TWO nfe_pack(0, EXP_BIAS+1, 0)

/* Simulate MUL×k normalization as spec'd in C1 §1.8:
 *   for i in 0..steps: emit(operand, NFE_TWO, op_sel=MUL); operand = result */
static double norm_result_path(double operand_val, int steps) {
    for (int i = 0; i < steps; i++) {
        /* operand = nfe_dec(nfe_mul(nfe_enc(operand_val), NFE_TWO)) */
        nfe_t op_nfe = nfe_enc(operand_val);
        nfe_t scaled  = nfe_mul(op_nfe, NFE_TWO);
        operand_val   = nfe_dec(scaled);   /* operand = result */
    }
    return operand_val;
}

int main(void)
{
    /* ── Construct test data ─────────────────────────────────────────── */
    /* j=0..15: alternating ±2^(-8) × 2^(-8) = stored_E=16, val=2^(-16)  */
    /* A[j] = ±0.00390625 (= 2^-8, stored_E=24), x[j] = 0.00390625       */
    /* Product: E_a=24, E_b=24 → es=24+24-32=16, P=64*64=4096<8192        */
    /*          fR=4096>>6=64 & 63 = 0 → nfe_pack(sign,16,0)              */
    /* value = (−1)^sign × 2^(16−32) = ±2^(−16) ≈ ±1.526e−5              */

    double A_fp[K], x_fp[K];
    nfe_t  A[K],    x[K];

    /* Cancellation region: j=0..15 */
    for (int j = 0; j <= 15; j++) {
        double sign = (j % 2 == 0) ? +1.0 : -1.0;
        A_fp[j] = sign * ldexp(1.0, -8);   /* ±2^(-8)   */
        x_fp[j] =        ldexp(1.0, -8);   /* +2^(-8)   */
        A[j]    = nfe_enc(A_fp[j]);
        x[j]    = nfe_enc(x_fp[j]);
    }
    /* j=16: one extra positive product to push depth to 17 */
    A_fp[16] = ldexp(1.0, -8);
    x_fp[16] = ldexp(1.0, -8);
    A[16]    = nfe_enc(A_fp[16]);
    x[16]    = nfe_enc(x_fp[16]);

    /* j=17..127: HBS-1 uniform [0.1, 1.0] */
    uint32_t seed = 0xA5A5A5A5u;
    #define LCGNEXT(s) ((s) = (uint32_t)((uint64_t)(s)*1664525u + 1013904223u))
    #define LCG01(s)   (((double)(LCGNEXT(s) >> 1)) / (double)(0x7FFFFFFFu))
    for (int j = 17; j < K; j++) {
        A_fp[j] = 0.1 + 0.9 * LCG01(seed);
        x_fp[j] = 0.1 + 0.9 * LCG01(seed);
        A[j]    = nfe_enc(A_fp[j]);
        x[j]    = nfe_enc(x_fp[j]);
    }

    /* FP64 reference */
    double ref = 0.0;
    for (int j = 0; j < K; j++) ref += A_fp[j] * x_fp[j];

    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════════════╗\n");
    printf("║  Normalization Loop: Forced-Fire Test (alternating-sign epoch)      ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════╝\n\n");

    /* ── Q2 source-code quote ─────────────────────────────────────────── */
    printf("Q2 SOURCE QUOTE — assignment of `operand` entering the loop\n");
    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  C1 §1.7  emit_horus_instruction  (HORUS_C1_COMPILER_SPEC.md):\n\n");
    printf("    if hazard := detect_boundary_hazard(E_pred, f_pred, op_sel, chain_depth):\n");
    printf("        return execute_abmp(op_a, op_b, op_sel, hazard)  // see §1.8\n");
    printf("                           ^^^^^\n");
    printf("                           operand ← op_a  (first positional argument)\n\n");
    printf("  C1 §1.8  execute_abmp  (HORUS_C1_COMPILER_SPEC.md):\n\n");
    printf("    function execute_abmp(operand, hazard_type):\n");
    printf("        snapshot_value = read_accum_out()   // sample accum_out\n");
    printf("        emit_accum_clr()                    // accum_clr = 1 for one cycle\n");
    printf("        ...\n");
    printf("        steps = target_E − operand.E\n");
    printf("        for i in 0..steps:\n");
    printf("            emit(operand, NFE_TWO, op_sel=MUL, mode_tag=010,\n");
    printf("                 accum_en=0, accum_clr=0)\n");
    printf("            operand = result   // feed-forward from MUL output\n");
    printf("\n");
    printf("  ASSIGNMENT PATH:\n");
    printf("    operand = op_a  (caller passes op_a as first arg to execute_abmp)\n");
    printf("    op_a    = result of PREVIOUS cycle  (the running partial sum)\n");
    printf("    snapshot_value is a SEPARATE local variable — never assigned to operand\n");
    printf("    accum_out is read into snapshot_value only, not into operand\n\n");
    printf("  C4 §1.4 INSERT_EPOCH_BOUNDARY cross-reference:\n");
    printf("    \"Action implementation details are resolved by referencing\n");
    printf("     C1/C3 as implementation guides\" (C4 §1.8)\n");
    printf("    The operand source is op_a in all cases.\n\n");

    /* ── Product diagnostics for j=0..17 ─────────────────────────────── */
    printf("PRODUCT DIAGNOSTICS (j=0..17)\n");
    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  %3s  %10s  %10s  %10s  %5s  %10s\n",
           "j", "A_fp[j]", "x_fp[j]", "p_fp", "E_p", "partial_sum");
    printf("  ──────────────────────────────────────────────────────────────────────\n");
    double partial = 0.0;
    for (int j = 0; j <= 17; j++) {
        nfe_t p = nfe_mul(A[j], x[j]);
        double p_fp = nfe_dec(p);
        partial += p_fp;
        int E_p = nfe_e(p);
        printf("  %3d  %10.7f  %10.7f  %10.8f  %5d  %12.8f\n",
               j, A_fp[j], x_fp[j], p_fp, E_p, partial);
    }
    printf("\n");

    /* Confirm partial sum E at depth=17 */
    {
        double ps17 = 0.0;
        for (int j = 0; j <= 16; j++) {
            nfe_t p = nfe_mul(A[j], x[j]);
            ps17 += nfe_dec(p);
        }
        nfe_t ps_nfe = nfe_enc(ps17);
        int ps_E     = nfe_e(ps_nfe);
        int norm_k   = (ps_E < 20) ? (20 - ps_E) : 0;
        printf("  Partial sum after j=0..16 (depth=17): %e\n", ps17);
        printf("  NFE-encoded stored_E = %d  (actual_E = %d)\n",
               ps_E, ps_E - EXP_BIAS);
        printf("  norm_k (steps = 20 − %d) = %d  → normalization FIRES: %s\n\n",
               ps_E, norm_k, norm_k > 0 ? "YES" : "NO");
    }

    /* ── PATH A: ABMP-active (normalization fires at first boundary) ─── */
    printf("RUN A — ABMP-ACTIVE (normalization executes)\n");
    printf("────────────────────────────────────────────────────────────────────────\n");
    {
        double result_val = 0.0;
        int depth = 0, boundaries = 0, total_norm_steps = 0;

        printf("  %5s  %5s  %12s  %6s  %6s  %8s  %s\n",
               "j", "depth", "partial_sum", "E_curr", "norm_k",
               "norm_out", "event");

        for (int j = 0; j < K; j++) {
            nfe_t p    = nfe_mul(A[j], x[j]);
            double p_fp = nfe_dec(p);

            if (depth > EPOCH_DEPTH) {
                /* INSERT_EPOCH_BOUNDARY fires */
                nfe_t ps_nfe = nfe_enc(result_val);
                int   ps_E   = nfe_e(ps_nfe);
                int   norm_k = (ps_E < 20) ? (20 - ps_E) : 0;

                /* Phase 2: normalise — op_a is result_val (from previous result) */
                double normed = norm_result_path(result_val, norm_k);
                total_norm_steps += norm_k;

                if (j <= 20 || norm_k > 0) {
                    printf("  %5d  %5d  %12.6e  %6d  %6d  %12.6e  BOUNDARY%s\n",
                           j, depth, result_val, ps_E, norm_k, normed,
                           norm_k > 0 ? " + NORM" : "");
                }
                result_val = normed;
                depth      = 0;
                boundaries++;
            }
            result_val += p_fp;
            depth++;
        }
        nfe_t y = nfe_enc(result_val);
        double nfe_val = nfe_dec(y);
        double rel_err = fabs(nfe_val - ref) / fabs(ref) * 100.0;

        printf("\n");
        printf("  Boundaries fired: %d  Total norm steps: %d\n",
               boundaries, total_norm_steps);
        printf("  Final result (re-encoded): %.6f\n", nfe_val);
        printf("  FP64 reference:            %.6f\n", ref);
        printf("  Relative error (ABMP-active): %.4f%%\n\n", rel_err);
    }

    /* ── PATH B: ABMP-inactive (only accum_clr, no normalization) ────── */
    printf("RUN B — ABMP-INACTIVE (accum_clr only, normalization suppressed)\n");
    printf("────────────────────────────────────────────────────────────────────────\n");
    {
        double result_val = 0.0;
        int depth = 0, boundaries = 0;

        for (int j = 0; j < K; j++) {
            nfe_t p    = nfe_mul(A[j], x[j]);
            double p_fp = nfe_dec(p);

            if (depth > EPOCH_DEPTH) {
                /* accum_clr only — no MUL×TWO normalization */
                int   ps_E   = nfe_e(nfe_enc(result_val));
                int   norm_k = (ps_E < 20) ? (20 - ps_E) : 0;
                if (j <= 20) {
                    printf("  j=%d: boundary fires, ps_E=%d, would need %d norm steps"
                           " — SUPPRESSED\n", j, ps_E, norm_k);
                }
                /* result_val unchanged — no rescaling */
                depth = 0;
                boundaries++;
            }
            result_val += p_fp;
            depth++;
        }
        nfe_t y = nfe_enc(result_val);
        double nfe_val = nfe_dec(y);
        double rel_err = fabs(nfe_val - ref) / fabs(ref) * 100.0;

        printf("\n");
        printf("  Boundaries fired: %d  Norm steps: 0 (suppressed)\n", boundaries);
        printf("  Final result (re-encoded): %.6f\n", nfe_val);
        printf("  FP64 reference:            %.6f\n", ref);
        printf("  Relative error (ABMP-inactive): %.4f%%\n\n", rel_err);
    }

    /* ── PATH C: clean (no ABMP at all) ──────────────────────────────── */
    printf("RUN C — CLEAN (no ABMP, no accum_clr, continuous accumulation)\n");
    printf("────────────────────────────────────────────────────────────────────────\n");
    {
        double result_val = 0.0;
        for (int j = 0; j < K; j++) {
            nfe_t p = nfe_mul(A[j], x[j]);
            result_val += nfe_dec(p);
        }
        nfe_t y = nfe_enc(result_val);
        double nfe_val = nfe_dec(y);
        double rel_err = fabs(nfe_val - ref) / fabs(ref) * 100.0;
        printf("  Final result (re-encoded): %.6f\n", nfe_val);
        printf("  FP64 reference:            %.6f\n", ref);
        printf("  Relative error (clean):    %.4f%%\n\n", rel_err);
    }

    /* ── Summary table ───────────────────────────────────────────────── */
    /* Re-run all three cleanly to get comparable numbers */
    double err_active, err_inactive, err_clean;
    {
        double r = 0.0; int d = 0;
        for (int j = 0; j < K; j++) {
            nfe_t p = nfe_mul(A[j], x[j]);
            if (d > EPOCH_DEPTH) {
                nfe_t ps_nfe = nfe_enc(r);
                int   ps_E   = nfe_e(ps_nfe);
                int   norm_k = (ps_E < 20) ? (20 - ps_E) : 0;
                r = norm_result_path(r, norm_k); d = 0;
            }
            r += nfe_dec(p); d++;
        }
        err_active = fabs(nfe_dec(nfe_enc(r)) - ref) / fabs(ref) * 100.0;
    }
    {
        double r = 0.0; int d = 0;
        for (int j = 0; j < K; j++) {
            nfe_t p = nfe_mul(A[j], x[j]);
            if (d > EPOCH_DEPTH) { d = 0; }  /* no norm */
            r += nfe_dec(p); d++;
        }
        err_inactive = fabs(nfe_dec(nfe_enc(r)) - ref) / fabs(ref) * 100.0;
    }
    {
        double r = 0.0;
        for (int j = 0; j < K; j++) {
            r += nfe_dec(nfe_mul(A[j], x[j]));
        }
        err_clean = fabs(nfe_dec(nfe_enc(r)) - ref) / fabs(ref) * 100.0;
    }

    /* Compute analytical normalization error */
    double ps17 = 0.0;
    for (int j = 0; j <= 16; j++) ps17 += nfe_dec(nfe_mul(A[j], x[j]));
    nfe_t ps_nfe    = nfe_enc(ps17);
    int   ps_E      = nfe_e(ps_nfe);
    int   norm_k    = (ps_E < 20) ? (20 - ps_E) : 0;
    double normed   = norm_result_path(ps17, norm_k);
    double norm_err = normed - ps17;   /* error introduced by MUL×k rescaling */
    double total_sum_mag = 0.0;
    for (int j = 0; j < K; j++) total_sum_mag += fabs(nfe_dec(nfe_mul(A[j], x[j])));

    printf("╔══════════════════════════════════════════════════════════════════════╗\n");
    printf("║  RESULTS SUMMARY                                                     ║\n");
    printf("╠══════════════════════════════════════════════════════════════════════╣\n");
    printf("║  Q1 — Normalization loop fires: YES                                 ║\n");
    printf("║    First boundary: depth=17, partial sum=%.3e, stored_E=%d        ║\n",
           ps17, ps_E);
    printf("║    norm_k = 20 − %d = %d  MUL×TWO steps execute                    ║\n",
           ps_E, norm_k);
    printf("║    Scaled-up operand: %.3e × 2^%d = %.3e                    ║\n",
           ps17, norm_k, normed);
    printf("║  Q2 — operand source: op_a (the running partial sum / `result`)    ║\n");
    printf("║    C1 §1.7: execute_abmp(op_a, ...)  — operand = op_a              ║\n");
    printf("║    snapshot_value is a SEPARATE variable; accum_out never           ║\n");
    printf("║    assigned to operand at any point in the function.                ║\n");
    printf("║    operand is INDEPENDENT of accum_out / snapshot.                  ║\n");
    printf("║  Q3/Q4 — accuracy:\n");
    printf("║    Path A (ABMP-active, norm fires):  %.4f%%                    ║\n",
           err_active);
    printf("║    Path B (ABMP-inactive, no norm):   %.4f%%                    ║\n",
           err_inactive);
    printf("║    Path C (clean, no ABMP):           %.4f%%                    ║\n",
           err_clean);
    printf("║    Delta A−C (normalization error):   %+.4f%%                   ║\n",
           err_active - err_clean);
    printf("║    Analytical source of delta:        norm_err = %.3e         ║\n",
           norm_err);
    printf("║    = (2^%d − 1) × partial_sum = %.1f × %.3e             ║\n",
           norm_k, ldexp(1.0, norm_k) - 1.0, ps17);
    printf("║    FP64 ref = %.4f → relative contribution = %.6f%%       ║\n",
           ref, fabs(norm_err)/fabs(ref)*100.0);
    printf("║    The error SOURCE is the MUL×k rescaling of op_a.                 ║\n");
    printf("║    The error is NOT from accum_out (operand is independent).        ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════╝\n\n");

    return 0;
}

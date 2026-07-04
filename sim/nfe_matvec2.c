/*
 * nfe_matvec2.c  —  Dual-path routed 8×8 NFE matrix-vector multiply
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Adds a second path alongside the original Horus NFE path.  The router
 * uses the actual HBS-12/13 boundary table, pulled from the measured logs.
 *
 * Boundary table — source lines cited from log files
 * ────────────────────────────────────────────────────
 *   HBS-12A (HBS12_SUMMARY.log line 79):
 *     First NORM E = 16   (actual_E = −16)
 *     Last  NORM E = 47   (actual_E = +15)
 *   HBS-12A (line 82-83):
 *     UF band  : E < 16          → floor sentinel
 *     OVF band : E > 47          → saturation sentinel
 *   HBS-12D (log line 171):
 *     Info-retention seeds: E ∈ [28..35]
 *     Depth ≤ 16: 29 unique outputs, 4.81 bits, 0% floor  ← anchor zone
 *   HBS-13F (HBS13_SUMMARY.log line 217-225):
 *     Collapse cliff  : E=15 PURE UF → E=16 PURE NORM (0% mixing)
 *     Saturation cliff: E=47 PURE NORM → E=48 PURE OVF (0% mixing)
 *
 * Router zones derived from the above
 * ─────────────────────────────────────
 *   ANCHOR  : stored_E ∈ [28..35]   — HBS-12D seed range; both operands
 *             must be in ANCHOR for the fast path to apply.
 *             Product E = E_a+E_b−32 ∈ [24..38]: provably in NORM zone,
 *             no UF/OVF guards needed (HBS-12A cliff at 16 and 48).
 *   STABLE  : stored_E ∈ [16..47]   — HBS-12A NORM band; outside ANCHOR.
 *   OUT_OF_RANGE: stored_E < 16 or > 47 — UF/OVF zone.
 *
 * Two arithmetic paths
 * ─────────────────────
 *   PATH_FAST (anchor zone): Fixed-point-style integer MAC.
 *     • Skips NFE-encode/decode of intermediate products.
 *     • Uses full 14-bit mantissa product (no intermediate 6-bit quantisation).
 *     • No UF/OVF guards (provably unnecessary for anchor-zone operands).
 *     • Returns decoded double directly; accumulates in double.
 *     • Op count: 1 FMAC per element.
 *
 *   PATH_NFE (full path): Original Horus NFE MUL + decode + double add.
 *     • Includes UF/OVF guards and NFE-encode of intermediate result.
 *     • Op count: 1 NFE_MUL + 1 ADD per element (ADD skipped for j=0).
 *
 * Operation taxonomy (same as nfe_matvec.c)
 * ─────────────────────────────────────────
 *   arith_ops  : NFE_MUL + ADD + FMAC   (routing NOT counted — combinational)
 *   route_ops  : routing decisions made  (shown separately)
 *   dmov_ops   : loads + stores          (unchanged from single-path version)
 *
 * Build: gcc -O2 -o nfe_matvec2 nfe_matvec2.c -lm && ./nfe_matvec2
 */

#include <stdio.h>
#include <stdint.h>
#include <math.h>

#define N         8
#define EXP_BIAS  32
#define EXP_MAX   63

/* ── Boundary constants from measured HBS-12/13 data ─────────────────────
 *   Values are NOT assumed — each is traceable to a specific log line.
 */
#define E_NORM_LO    16   /* HBS-12A log line 79: first NORM E */
#define E_NORM_HI    47   /* HBS-12A log line 80: last  NORM E */
#define E_ANCHOR_LO  28   /* HBS-12D log line 171: seed range low  */
#define E_ANCHOR_HI  35   /* HBS-12D log line 171: seed range high */

/* ── 13-bit NFE word ──────────────────────────────────────────────────── */
typedef uint16_t nfe_t;
static inline int   nfe_s(nfe_t w) { return (w >> 12) & 1; }
static inline int   nfe_e(nfe_t w) { return (w >>  6) & 0x3F; }
static inline int   nfe_f(nfe_t w) { return  w        & 0x3F; }
static inline nfe_t nfe_pack(int s, int e, int f) {
    return (nfe_t)(((s&1)<<12)|((e&0x3F)<<6)|(f&0x3F));
}

static double nfe_dec(nfe_t w) {
    double v = ldexp(1.0 + nfe_f(w)/64.0, nfe_e(w) - EXP_BIAS);
    return nfe_s(w) ? -v : v;
}

static nfe_t nfe_enc(double v) {
    int s = (v < 0.0);
    double av = fabs(v);
    if (av == 0.0) return nfe_pack(s, 0, 0);
    int aE = (int)floor(log2(av));
    double m = av / ldexp(1.0, aE);
    if (m < 1.0)  { --aE; m = av / ldexp(1.0, aE); }
    if (m >= 2.0) { ++aE; m = av / ldexp(1.0, aE); }
    if (aE < -EXP_BIAS)           return nfe_pack(s, 0,       0);
    if (aE >  EXP_MAX - EXP_BIAS) return nfe_pack(s, EXP_MAX, 63);
    int eS = aE + EXP_BIAS;
    int f  = (int)round((m - 1.0) * 64.0);
    if (f > 63) { f = 0; if (++eS > EXP_MAX) return nfe_pack(s, EXP_MAX, 63); }
    return nfe_pack(s, eS, f);
}

/* ── Full NFE MUL — with UF/OVF guards (required outside anchor zone) ─── */
static nfe_t nfe_mul(nfe_t a, nfe_t b) {
    uint32_t P = (uint32_t)(64 + nfe_f(a)) * (uint32_t)(64 + nfe_f(b));
    int rs = nfe_s(a) ^ nfe_s(b);
    int es = (P >= 8192) ? nfe_e(a) + nfe_e(b) - EXP_BIAS + 1
                         : nfe_e(a) + nfe_e(b) - EXP_BIAS;
    int fR = (P >= 8192) ? (int)((P >> 7) & 0x3F)
                         : (int)((P >> 6) & 0x3F);
    if (es <  0)       return nfe_pack(rs, 0,       0);
    if (es > EXP_MAX)  return nfe_pack(rs, EXP_MAX, 63);
    return nfe_pack(rs, es, fR);
}

/* ── Fast integer MAC — anchor zone only ─────────────────────────────────
 *
 * PRECONDITION (caller guarantees): both stored_E ∈ [E_ANCHOR_LO..E_ANCHOR_HI]
 *   → product stored_E = E_a+E_b-32 ∈ [24..38]
 *   → 24 ≥ E_NORM_LO (16) and 38 ≤ E_NORM_HI (47): no UF/OVF possible
 *
 * Keeps the full 14-bit mantissa product (P = A_m × B_m) without
 * quantising to 6-bit NFE fraction.  This avoids the intermediate
 * rounding that nfe_mul + nfe_dec would introduce per accumulated product.
 *
 * Derivation:
 *   A_m = 64 + f_a   →  value(a) = A_m × 2^(E_a − 38)
 *   B_m = 64 + f_b   →  value(b) = B_m × 2^(E_b − 38)
 *   product           = P × 2^(E_a + E_b − 76)
 *                     = P × ldexp(1, E_a + E_b − 76)
 */
static double nfe_fast_mac(nfe_t a, nfe_t b) {
    uint32_t P = (uint32_t)(64 + nfe_f(a)) * (uint32_t)(64 + nfe_f(b));
    int exp_sum = nfe_e(a) + nfe_e(b);   /* stored exponent sum (biased) */
    return ldexp((double)P, exp_sum - 76);
}

/* ── Router: classify operand pair ───────────────────────────────────────
 *
 * Returns 1 (fast path) when BOTH operands are in the HBS-12D anchor zone.
 * Returns 0 (full NFE path) otherwise.
 *
 * The boundary values E_ANCHOR_LO=28 and E_ANCHOR_HI=35 come directly
 * from HBS-12D measured seeds (HBS12_SUMMARY.log line 171).
 */
static int route_to_fast(nfe_t a, nfe_t b) {
    int ea = nfe_e(a), eb = nfe_e(b);
    return (ea >= E_ANCHOR_LO && ea <= E_ANCHOR_HI &&
            eb >= E_ANCHOR_LO && eb <= E_ANCHOR_HI);
}

/* ── Op counters ─────────────────────────────────────────────────────────
 *   g_fmac    : fast integer MAC ops  (PATH_FAST)
 *   g_mul_nfe : full NFE MUL ops      (PATH_NFE)
 *   g_add_nfe : decode+double ADD ops (PATH_NFE, j>0 only)
 *   g_route   : routing decisions     (NOT included in arith_ops)
 *   g_load, g_store : data movement   (unchanged from single-path)
 */
static unsigned g_fmac    = 0;
static unsigned g_mul_nfe = 0;
static unsigned g_add_nfe = 0;
static unsigned g_route   = 0;
static unsigned g_load    = 0;
static unsigned g_store   = 0;

/* ── Routed 8×8 NFE matvec ───────────────────────────────────────────────
 *
 * Memory model: identical to nfe_matvec.c
 *   x prefetched into 8 register slots: 8 loads
 *   A[i][j] loaded per access: 64 loads
 *   y[i] stored per result: 8 stores
 *   Total dmov_ops = 80 (unchanged from single-path version)
 *
 * Routing per (i,j):
 *   route_to_fast(A[i][j], x[j]) → PATH_FAST or PATH_NFE
 *   1 routing decision per element (counted in g_route, NOT in arith_ops)
 *
 * Accumulation:
 *   PATH_FAST: acc += nfe_fast_mac(a, b)   — 1 FMAC per element (j=0..7)
 *   PATH_NFE:  if j==0: acc  = nfe_dec(nfe_mul(a,b))   — 1 MUL, 0 ADD
 *              if j >0: acc += nfe_dec(nfe_mul(a,b))   — 1 MUL, 1 ADD
 */
static void nfe_matvec_routed(const nfe_t A[N][N], const nfe_t x[N], nfe_t y[N])
{
    nfe_t xr[N];
    for (int j = 0; j < N; j++) { xr[j] = x[j]; g_load++; }   /* 8 loads */

    for (int i = 0; i < N; i++) {
        double acc = 0.0;

        for (int j = 0; j < N; j++) {
            nfe_t aij = A[i][j];   g_load++;                   /* 1 load  */

            g_route++;                                          /* routing */

            if (route_to_fast(aij, xr[j])) {
                /* ── PATH_FAST: integer MAC, no NFE intermediate ── */
                acc += nfe_fast_mac(aij, xr[j]);  g_fmac++;   /* 1 FMAC  */
            } else {
                /* ── PATH_NFE: full Horus MUL + decode + add ── */
                nfe_t p = nfe_mul(aij, xr[j]);    g_mul_nfe++;/* 1 MUL   */
                if (j == 0) acc  = nfe_dec(p);
                else      { acc += nfe_dec(p);     g_add_nfe++; } /* ADD  */
            }
        }

        y[i] = nfe_enc(acc);   g_store++;                      /* 1 store */
    }
}

/* ── FP64 reference ──────────────────────────────────────────────────────*/
static void ref_matvec(const double A[N][N], const double x[N], double y[N]) {
    for (int i = 0; i < N; i++) {
        y[i] = 0.0;
        for (int j = 0; j < N; j++) y[i] += A[i][j] * x[j];
    }
}

/* ── helpers ─────────────────────────────────────────────────────────────*/
static void sep(void) {
    printf("  ─────────────────────────────────────────────────────────────\n");
}

int main(void)
{
    /* ── Same test data as nfe_matvec.c ──
     *   A[i][j] = 0.50 + (i·8+j+1) · 0.015   ∈ [0.515, 1.460]
     *   x[j]    = 1.00 + j · 0.10             ∈ [1.000, 1.700]
     */
    double A_fp[N][N], x_fp[N];
    nfe_t  A[N][N], x[N], y[N];

    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            A_fp[i][j] = 0.50 + (double)(i * N + j + 1) * 0.015;
            A[i][j]    = nfe_enc(A_fp[i][j]);
        }
    for (int j = 0; j < N; j++) {
        x_fp[j] = 1.00 + (double)j * 0.10;
        x[j]    = nfe_enc(x_fp[j]);
    }

    /* ── Run routed matvec ── */
    nfe_matvec_routed(A, x, y);

    /* ── FP64 reference ── */
    double y_fp[N];
    ref_matvec(A_fp, x_fp, y_fp);

    /* ═══════════════════════════════════════════════════════════════════ */
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════╗\n");
    printf("║  Horus-NFE 13-bit · Dual-Path Routed 8×8 Matvec           ║\n");
    printf("╚══════════════════════════════════════════════════════════════╝\n\n");

    printf("  Boundary table (from HBS-12/13 measured logs)\n");
    printf("  ───────────────────────────────────────────────────────────\n");
    printf("  NORM band   : E ∈ [%d..%d]  (HBS-12A log lines 79-80)\n",
           E_NORM_LO, E_NORM_HI);
    printf("  ANCHOR zone : E ∈ [%d..%d]  (HBS-12D log line 171, info-retention seeds)\n",
           E_ANCHOR_LO, E_ANCHOR_HI);
    printf("  Routing rule: both E in ANCHOR → PATH_FAST\n");
    printf("                any  E outside   → PATH_NFE\n");
    printf("  Anchor product range: [%d..%d]+[%d..%d]-32 = [%d..%d] (inside NORM)\n\n",
           E_ANCHOR_LO, E_ANCHOR_HI, E_ANCHOR_LO, E_ANCHOR_HI,
           2*E_ANCHOR_LO-32, 2*E_ANCHOR_HI-32);

    /* ── Operand zone audit ── */
    printf("  Operand E-values for this workload\n");
    sep();
    printf("  %-14s  stored_E  in_anchor\n", "operand");
    sep();
    int all_anchor_A = 1, all_anchor_x = 1;
    int eA_lo=63, eA_hi=0, ex_lo=63, ex_hi=0;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            int e = nfe_e(A[i][j]);
            if (e < eA_lo) eA_lo = e;
            if (e > eA_hi) eA_hi = e;
            if (e < E_ANCHOR_LO || e > E_ANCHOR_HI) all_anchor_A = 0;
        }
    for (int j = 0; j < N; j++) {
        int e = nfe_e(x[j]);
        if (e < ex_lo) ex_lo = e;
        if (e > ex_hi) ex_hi = e;
        if (e < E_ANCHOR_LO || e > E_ANCHOR_HI) all_anchor_x = 0;
    }
    printf("  A[8×8]        E=[%d..%d]   %s\n", eA_lo, eA_hi,
           all_anchor_A ? "ALL IN ANCHOR" : "some outside anchor");
    printf("  x[8]          E=[%d..%d]      %s\n", ex_lo, ex_hi,
           all_anchor_x ? "ALL IN ANCHOR" : "some outside anchor");
    printf("\n");

    /* ── Routing breakdown per row ── */
    printf("  Routing breakdown (PATH_FAST = anchor zone, PATH_NFE = full)\n");
    sep();
    printf("  %3s  %12s  %12s  %s\n", "row", "PATH_FAST ops", "PATH_NFE ops", "E range products");
    sep();
    for (int i = 0; i < N; i++) {
        int nfast=0, nnfe=0, eplo=63, ephi=0;
        for (int j = 0; j < N; j++) {
            nfe_t aij = A[i][j];
            nfe_t p   = nfe_mul(aij, x[j]);
            int ep = nfe_e(p);
            if (ep < eplo) eplo = ep;
            if (ep > ephi) ephi = ep;
            if (route_to_fast(aij, x[j])) nfast++; else nnfe++;
        }
        printf("  %3d  %12d  %12d  [%d..%d]\n", i, nfast, nnfe, eplo, ephi);
    }
    printf("\n");

    /* ── Results ── */
    printf("  Result: y[i] = Σ_j A[i][j] · x[j]  (PATH_FAST)\n");
    sep();
    printf("  %3s  %10s  %10s  %8s  %4s\n", "i", "FAST y[i]", "FP64 y[i]", "rel_err%", "E_st");
    sep();
    double max_err=0.0, sum_err=0.0;
    for (int i = 0; i < N; i++) {
        double nv  = nfe_dec(y[i]);
        double rv  = y_fp[i];
        double err = fabs(nv - rv) / fabs(rv) * 100.0;
        if (err > max_err) max_err = err;
        sum_err += err;
        printf("  %3d  %10.5f  %10.5f  %8.4f%%  %4d\n",
               i, nv, rv, err, nfe_e(y[i]));
    }
    sep();
    printf("  Mean rel err: %.4f%%   Max: %.4f%%\n\n",
           sum_err / N, max_err);

    /* ── Op count — routed system ── */
    unsigned arith_ops = g_fmac + g_mul_nfe + g_add_nfe;
    unsigned dmov_ops  = g_load + g_store;

    printf("  ══ Op Count: Routed System ══════════════════════════════════\n\n");
    printf("  ARITHMETIC OPS\n");
    printf("    PATH_FAST  FMAC (anchor zone)        %4u\n", g_fmac);
    printf("    PATH_NFE   NFE_MUL                   %4u\n", g_mul_nfe);
    printf("    PATH_NFE   decode+ADD                 %4u\n", g_add_nfe);
    printf("    ─────────────────────────────────────────\n");
    printf("    arith_ops total                      %4u\n", arith_ops);
    printf("\n");
    printf("  ROUTING OPS (combinational — not in arith_ops)\n");
    printf("    route decisions (1 per element)      %4u\n", g_route);
    printf("\n");
    printf("  DATA-MOVEMENT OPS\n");
    printf("    x prefetch   (8 regs, loaded once)   %4u  loads\n", N);
    printf("    A row loads  (8×8, per-access)        %4u  loads\n", N*N);
    printf("    y stores     (8 results)               %4u  stores\n", N);
    printf("    ─────────────────────────────────────────\n");
    printf("    dmov_ops total                       %4u\n", dmov_ops);
    printf("\n");

    /* ── Side-by-side comparison ── */
    unsigned arith_single = 64 + 56;      /* nfe_matvec.c: 64 MUL + 56 ADD */
    unsigned dmov_single  = 80;
    unsigned route_single = 0;

    printf("  ══ Comparison: Single-path vs Routed ════════════════════════\n\n");
    printf("  %-32s  %8s  %8s  %8s\n",
           "metric", "single", "routed", "delta");
    sep();
    printf("  %-32s  %8u  %8u  %+8d\n",
           "arith_ops (MUL+ADD+FMAC)",
           arith_single, arith_ops, (int)arith_ops - (int)arith_single);
    printf("    %-30s  %8s  %8u  %+8d\n",
           "NFE_MUL",        "64", g_mul_nfe, (int)g_mul_nfe - 64);
    printf("    %-30s  %8s  %8u  %+8d\n",
           "decode+ADD",     "56", g_add_nfe, (int)g_add_nfe - 56);
    printf("    %-30s  %8s  %8u  %+8d\n",
           "FMAC (fast int MAC)", "0", g_fmac,  (int)g_fmac);
    printf("  %-32s  %8u  %8u  %+8d\n",
           "route_ops",
           route_single, g_route, (int)g_route);
    printf("  %-32s  %8u  %8u  %+8d\n",
           "dmov_ops",
           dmov_single, dmov_ops, (int)dmov_ops - (int)dmov_single);
    printf("\n");

    /* ── Weighted cost ── */
    printf("  ══ Weighted Cost  (1 dmov = α × 1 arith) ═══════════════════\n\n");
    printf("  %-6s  %-14s  %-14s  %-14s  %s\n",
           "α", "single total", "routed total", "delta", "direction");
    sep();
    static const int alphas[] = {1, 10, 100, 1000};
    for (int k = 0; k < 4; k++) {
        int    a  = alphas[k];
        double sc = (double)arith_single + (double)dmov_single * a;
        double rc = (double)arith_ops    + (double)dmov_ops    * a;
        double d  = rc - sc;
        printf("  %-6d  %-14.0f  %-14.0f  %-14.0f  %s\n",
               a, sc, rc, d, d < 0 ? "DOWN" : (d > 0 ? "UP" : "flat"));
    }
    printf("\n");

    /* ── Accuracy comparison ── */
    printf("  ══ Accuracy: Single-path vs Routed PATH_FAST ════════════════\n\n");
    printf("  (Single-path errors from nfe_matvec.c run)\n");
    static const double single_err[] =
        { 0.0727, 0.6744, 0.3871, 0.7937, 0.0088, 0.3709, 0.6658, 0.0917 };
    double sum_fast_err=0.0, sum_single_err=0.0;
    printf("  %3s  %12s  %12s  %8s\n",
           "row", "single err%", "fast err%", "delta");
    sep();
    for (int i = 0; i < N; i++) {
        double nv  = nfe_dec(y[i]);
        double rv  = y_fp[i];
        double fe  = fabs(nv - rv) / fabs(rv) * 100.0;
        double se  = single_err[i];
        sum_fast_err   += fe;
        sum_single_err += se;
        printf("  %3d  %12.4f%%  %12.4f%%  %+8.4f%%\n",
               i, se, fe, fe - se);
    }
    sep();
    printf("  mean  %12.4f%%  %12.4f%%  %+8.4f%%\n",
           sum_single_err/N, sum_fast_err/N,
           (sum_fast_err - sum_single_err)/N);
    printf("\n");

    return 0;
}

/*
 * nfe_matvec.c  —  Horus-NFE 13-bit 8×8 matrix-vector multiply baseline
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Format:     V = (−1)^S · 2^(E−32) · (1 + f/64)
 *             [12] sign S  |  [11:6] stored exponent E  |  [5:0] fraction f
 *             actual_E = E − 32  (Bias-32)
 * Arithmetic: floor-and-saturate, no NaN / Inf
 *             UF (exp_sum < 0)  →  {S, 0, 0}   (floor sentinel)
 *             OVF (exp_sum > 63)→  {S, 63, 63} (saturation sentinel)
 *
 * Workload:   y = A · x,   A: 8×8 NFE,   x: 8 NFE   →   y: 8 NFE
 *
 * Operation taxonomy
 * ──────────────────
 *   arith_ops  : every NFE MUL + every accumulation ADD
 *   dmov_ops   : every load from A[], every load from x[], every store to y[]
 *                x is prefetched into a register file (8 slots) before the
 *                outer loop — those 8 loads are counted once, not per row.
 *
 * Build:  gcc -O2 -o nfe_matvec nfe_matvec.c -lm && ./nfe_matvec
 */

#include <stdio.h>
#include <stdint.h>
#include <math.h>

#define N         8
#define EXP_BIAS  32
#define EXP_MAX   63

/* ── 13-bit NFE word: packed into uint16_t ────────────────────────────────
 *   Bits [15:13] unused (always 0).
 *   Bit  [12]    sign S
 *   Bits [11:6]  stored exponent E
 *   Bits [5:0]   fraction f
 */
typedef uint16_t nfe_t;

static inline int   nfe_s(nfe_t w) { return (w >> 12) & 1; }
static inline int   nfe_e(nfe_t w) { return (w >>  6) & 0x3F; }
static inline int   nfe_f(nfe_t w) { return  w        & 0x3F; }
static inline nfe_t nfe_pack(int s, int e, int f) {
    return (nfe_t)(((s & 1) << 12) | ((e & 0x3F) << 6) | (f & 0x3F));
}

/* ── decode: NFE → double ──────────────────────────────────────────────── */
static double nfe_dec(nfe_t w) {
    double v = ldexp(1.0 + nfe_f(w) / 64.0, nfe_e(w) - EXP_BIAS);
    return nfe_s(w) ? -v : v;
}

/* ── encode: double → NFE  (round-to-nearest, floor on UF, sat on OVF) ── */
static nfe_t nfe_enc(double v) {
    int s = (v < 0.0);
    double av = fabs(v);
    if (av == 0.0) return nfe_pack(s, 0, 0);          /* zero → floor */

    int aE = (int)floor(log2(av));
    double m = av / ldexp(1.0, aE);
    if (m < 1.0)  { --aE; m = av / ldexp(1.0, aE); } /* guard log2 edge */
    if (m >= 2.0) { ++aE; m = av / ldexp(1.0, aE); }

    if (aE < -EXP_BIAS)           return nfe_pack(s, 0,       0);   /* UF  */
    if (aE >  EXP_MAX - EXP_BIAS) return nfe_pack(s, EXP_MAX, 63);  /* OVF */

    int eS = aE + EXP_BIAS;
    int f  = (int)round((m - 1.0) * 64.0);
    if (f > 63) { f = 0; if (++eS > EXP_MAX) return nfe_pack(s, EXP_MAX, 63); }
    return nfe_pack(s, eS, f);
}

/* ── NFE MUL: hidden-bit × hidden-bit, bias correction, floor/saturate ───
 *
 *   A = (64 + f_a)   (7-bit hidden-bit mantissa)
 *   B = (64 + f_b)
 *   P = A × B        (14-bit product, range [4096..16129])
 *
 *   stored_E_result = E_a + E_b − EXP_BIAS          when P < 8192  (P[13]=0)
 *                   = E_a + E_b − EXP_BIAS + 1       when P ≥ 8192  (P[13]=1)
 *   f_result = P[11:6]  or  P[12:7]  (6-bit mantissa, post-normalize)
 */
static nfe_t nfe_mul(nfe_t a, nfe_t b) {
    uint32_t P = (uint32_t)(64 + nfe_f(a)) * (uint32_t)(64 + nfe_f(b));
    int rs = nfe_s(a) ^ nfe_s(b);
    int es = (P >= 8192) ? nfe_e(a) + nfe_e(b) - EXP_BIAS + 1
                         : nfe_e(a) + nfe_e(b) - EXP_BIAS;
    int fR = (P >= 8192) ? (int)((P >> 7) & 0x3F)
                         : (int)((P >> 6) & 0x3F);
    if (es <  0)       return nfe_pack(rs, 0,       0);   /* floor    */
    if (es > EXP_MAX)  return nfe_pack(rs, EXP_MAX, 63);  /* saturate */
    return nfe_pack(rs, es, fR);
}

/* ── Op counters ─────────────────────────────────────────────────────────── */
static unsigned g_mul   = 0;   /* NFE MUL invocations     */
static unsigned g_add   = 0;   /* accumulation ADD steps  */
static unsigned g_load  = 0;   /* memory loads            */
static unsigned g_store = 0;   /* memory stores           */

/* ── 8×8 NFE matvec: y[i] = Σ_{j=0}^{7} A[i][j] · x[j] ─────────────────
 *
 * Memory model
 *   A[8][8]: main-memory tensor — one load per element access
 *   x[8]:   prefetched into 8 "register" slots before outer loop
 *              → 8 loads total, 0 per row (register reuse)
 *   y[8]:   written back to memory — 1 store per output element
 *
 * Accumulation model
 *   Each NFE product p = MUL(A[i][j], x[j]) is decoded to double and
 *   accumulated in a double-precision running sum.  This is the
 *   software-epoch model: the hardware equivalent is one accum_clr per
 *   row followed by 8 cycles of accum_en=1.
 *
 *   First product: acc ← dec(p₀)         [no ADD — initialisation]
 *   Products 1-7:  acc ← acc + dec(pⱼ)   [1 ADD each, 7 total per row]
 *
 *   Row result: re-encoded to NFE for storage.
 */
static void nfe_matvec(const nfe_t A[N][N], const nfe_t x[N], nfe_t y[N])
{
    /* ── Prefetch x into register file: 8 loads ── */
    nfe_t xr[N];
    for (int j = 0; j < N; j++) { xr[j] = x[j]; g_load++; }

    for (int i = 0; i < N; i++) {
        double acc = 0.0;

        for (int j = 0; j < N; j++) {
            nfe_t aij = A[i][j];           g_load++;  /* 1 load per A element */
            nfe_t p   = nfe_mul(aij, xr[j]); g_mul++; /* 1 NFE MUL            */
            if (j == 0) {
                acc = nfe_dec(p);                       /* init, no ADD         */
            } else {
                acc += nfe_dec(p);         g_add++;     /* 1 ADD                */
            }
        }
        y[i] = nfe_enc(acc);               g_store++;  /* 1 store              */
    }
}

/* ── FP64 reference: exact double-precision dot product ─────────────────── */
static void ref_matvec(const double A[N][N], const double x[N], double y[N]) {
    for (int i = 0; i < N; i++) {
        y[i] = 0.0;
        for (int j = 0; j < N; j++) y[i] += A[i][j] * x[j];
    }
}

/* ── helpers ─────────────────────────────────────────────────────────────── */
static void print_sep(void) {
    printf("  ─────────────────────────────────────────────────────────────\n");
}

int main(void)
{
    /* ── Initialise test data ─────────────────────────────────────────────
     *
     *  A[i][j] = 0.50 + (i·8 + j + 1) · 0.015   ∈ [0.515, 1.460]
     *  x[j]    = 1.00 + j · 0.10                  ∈ [1.000, 1.700]
     *
     *  Products A·x  ∈ [0.515, 2.482]  →  actual_E ∈ [−1, +1]
     *                                  →  stored_E ∈ [31, 33]  (STABLE)
     *  Row sums      ∈ [5.5, 16.0]     →  actual_E ∈ [2, 3]
     *                                  →  stored_E ∈ [34, 35]  (STABLE)
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

    /* ── Run NFE matvec ── */
    nfe_matvec(A, x, y);

    /* ── FP64 reference ── */
    double y_fp[N];
    ref_matvec(A_fp, x_fp, y_fp);

    /* ═══════════════════════════════════════════════════════════════════
     * Output
     * ═══════════════════════════════════════════════════════════════════ */
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════╗\n");
    printf("║  Horus-NFE 13-bit · 8×8 Matrix-Vector Multiply Baseline    ║\n");
    printf("╚══════════════════════════════════════════════════════════════╝\n");
    printf("\n");
    printf("  V = (−1)^S · 2^(E−32) · (1 + f/64)  [Bias-32, 6-bit fraction]\n");
    printf("  Arithmetic: floor-and-saturate, no NaN/Inf\n");
    printf("\n");

    /* ── Input matrix (decoded) ── */
    printf("  A[8×8] (decoded from NFE, row × col):\n");
    printf("  ");
    for (int j = 0; j < N; j++) printf("   x[%d]=%.3f", j, x_fp[j]);
    printf("\n");
    print_sep();
    for (int i = 0; i < N; i++) {
        printf("  row %d:", i);
        for (int j = 0; j < N; j++) printf("  %7.4f", nfe_dec(A[i][j]));
        printf("\n");
    }
    printf("\n");

    /* ── Result table ── */
    printf("  Result: y[i] = Σ_j A[i][j] · x[j]\n");
    print_sep();
    printf("  %3s  %10s  %10s  %8s  %4s  %3s  %3s\n",
           "i", "NFE y[i]", "FP64 y[i]", "rel_err%", "E_st", "E_ac", "f");
    print_sep();

    double max_relerr = 0.0, sum_relerr = 0.0;
    int    n_uf = 0, n_ovf = 0;
    for (int i = 0; i < N; i++) {
        double nv  = nfe_dec(y[i]);
        double rv  = y_fp[i];
        double err = fabs(nv - rv) / fabs(rv) * 100.0;
        if (err > max_relerr) max_relerr = err;
        sum_relerr += err;
        if (nfe_e(y[i]) == 0  && nfe_f(y[i]) == 0)  n_uf++;
        if (nfe_e(y[i]) == 63 && nfe_f(y[i]) == 63) n_ovf++;
        printf("  %3d  %10.5f  %10.5f  %8.4f%%  %4d  %4d  %3d\n",
               i, nv, rv, err,
               nfe_e(y[i]), nfe_e(y[i]) - EXP_BIAS, nfe_f(y[i]));
    }
    print_sep();
    printf("  Mean rel err: %.4f%%   Max: %.4f%%"
           "   Floor events: %d   Sat events: %d\n",
           sum_relerr / N, max_relerr, n_uf, n_ovf);
    printf("\n");

    /* ── Individual products for row 0 (diagnostic) ── */
    printf("  Row 0 products (diagnostic): A[0][j] · x[j]\n");
    print_sep();
    printf("  %3s  %8s  %8s  %8s  %4s  %3s\n",
           "j", "A[0][j]", "x[j]", "NFE prod", "E_st", "f");
    print_sep();
    for (int j = 0; j < N; j++) {
        nfe_t p = nfe_mul(A[0][j], x[j]);
        printf("  %3d  %8.4f  %8.4f  %8.4f  %4d  %3d\n",
               j, nfe_dec(A[0][j]), nfe_dec(x[j]), nfe_dec(p),
               nfe_e(p), nfe_f(p));
    }
    printf("\n");

    /* ── Op count table ── */
    unsigned arith_ops = g_mul + g_add;
    unsigned dmov_ops  = g_load + g_store;
    unsigned total_ops = arith_ops + dmov_ops;

    printf("  ══ Operation Count ══════════════════════════════════════════\n");
    printf("\n");
    printf("  ARITHMETIC OPS\n");
    printf("    NFE MUL  (8×8 products)           %4u\n", g_mul);
    printf("    Accum ADD  (7 per row × 8 rows)   %4u\n", g_add);
    printf("    ─────────────────────────────────────\n");
    printf("    arith_ops total                   %4u\n", arith_ops);
    printf("\n");
    printf("  DATA-MOVEMENT OPS\n");
    printf("    x prefetch  (8 regs, loaded once) %4u  loads\n", N);
    printf("    A row loads (8×8, per-access)     %4u  loads\n", N * N);
    printf("    y stores    (8 results)            %4u  stores\n", N);
    printf("    ─────────────────────────────────────\n");
    printf("    dmov_ops total                    %4u\n", dmov_ops);
    printf("\n");
    printf("  TOTALS\n");
    printf("    arith_ops                         %4u\n", arith_ops);
    printf("    dmov_ops                          %4u\n", dmov_ops);
    printf("    all ops                           %4u\n", total_ops);
    printf("    arithmetic intensity              %.3f  arith / dmov\n",
           (double)arith_ops / (double)dmov_ops);
    printf("\n");

    /* ── Weighted cost table ── */
    printf("  ══ Weighted Cost  (1 dmov = α × 1 arith) ═══════════════════\n");
    printf("\n");
    printf("  %-6s  %-14s  %-16s  %-14s  %s\n",
           "α", "arith_cost", "dmov_cost", "total_cost", "dmov fraction");
    print_sep();

    static const int alphas[] = {1, 10, 100, 1000};
    for (int k = 0; k < 4; k++) {
        int    a  = alphas[k];
        double ac = (double)arith_ops;
        double dc = (double)dmov_ops * (double)a;
        double tc = ac + dc;
        printf("  %-6d  %-14.0f  %-16.0f  %-14.0f  %.1f%%\n",
               a, ac, dc, tc, dc / tc * 100.0);
    }
    printf("\n");
    printf("  At α = 100 (typical DRAM):  dmov cost is %.0f× arith cost\n",
           (double)dmov_ops * 100.0 / (double)arith_ops);
    printf("  At α = 1000 (far DRAM):     dmov cost is %.0f× arith cost\n",
           (double)dmov_ops * 1000.0 / (double)arith_ops);
    printf("\n");

    /* ── Naive variant note ── */
    printf("  ── Naive variant (no x register cache, reload x each row) ──\n");
    unsigned dmov_naive = N*N + N*N + N;   /* 64 A + 64 x + 8 y = 136 */
    printf("  dmov_ops (naive) = %u  (x reloaded %d× per row)\n",
           dmov_naive, N);
    printf("  At α = 100: naive dmov cost = %.0f  vs cached = %.0f\n",
           (double)dmov_naive * 100.0,
           (double)dmov_ops   * 100.0);
    printf("\n");

    printf("  ── Reference exponent zones for this workload ──────────────\n");
    printf("  A elements:  stored_E ∈ [%d..%d]  (actual_E = E−32)\n",
           nfe_e(A[0][0]), nfe_e(A[N-1][N-1]));
    printf("  x elements:  stored_E ∈ [%d..%d]\n",
           nfe_e(x[0]), nfe_e(x[N-1]));
    int emin = 63, emax = 0;
    for (int i = 0; i < N; i++) {
        if (nfe_e(y[i]) < emin) emin = nfe_e(y[i]);
        if (nfe_e(y[i]) > emax) emax = nfe_e(y[i]);
    }
    printf("  y results:   stored_E ∈ [%d..%d]  (STABLE zone = [20..43])\n",
           emin, emax);
    printf("\n");

    return 0;
}

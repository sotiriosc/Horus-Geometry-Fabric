#!/usr/bin/env python3
"""
sim/norm_interval_sweep.py — Normalization-interval sweep.

For k ∈ {1, 2, 4, 8, 16, 32, 64, 128, ∞}:
  Run 256-step feedback chains where the FP64 harness rescales the state to
  unit norm every k steps (same division-of-labour as tb_pf18_power_iteration.v:
  DUT does the matvec, harness does the rescale).

Two workload families, 100 chains each:
  (a) SSC neutral row-stochastic: row sums = 1.0, initial y ∈ [1.0, 2.0),
      same LFSR construction as tb_second_source_chain.v.
      Metric: mean relative error vs FP64 golden at t=256 (percent).
  (b) PI symmetric-positive: entries ∈ [0.25, 1.25), SEED_PI construction,
      same as tb_pf18_power_iteration.v; initial y normalised.
      Metric: alignment |y_dut · y_gold| at t=256 (both normalised).

For k=∞ on PI workload: vector grows by λ_max^256 ≈ overflow; reported as N/A.

Two paths per chain:
  baseline — 6-bit NFE re-quantisation per product (mirrors second_source_chain.py
             step_nfe(), lines 135-148 / nfe_mul, lines 93-106)
  pf18     — W=18 saturating fixed-point accumulate (mirrors pf_width_sweep.py
             pf_accumulate(), lines 81-117 / pf_readout(), lines 120-154)

Seeds for 100 chains:
  SSC chain i: SEED_SSC_BASE ^ (i * 0x01010101 + 0x5555AAAA)
  PI  chain i: SEED_PI_BASE  ^ (i * 0x02020202 + 0xAABBCCDD)

Break-even table: largest k at which baseline holds
  SSC: mean rel err ≤ 1%
  PI : alignment ≥ 0.99
"""

import math
import sys
import os

# ── Constants ────────────────────────────────────────────────────────────────
N           = 8
EXP_BIAS    = 32
EXP_MAX     = 63
PF_K_REF    = 28
PF_SCALE_EXP = 16
W_PF18      = 18
MAX18       = (1 << 17) - 1   # +131071
MIN18       = -(1 << 17)      # -131072

SEED_SSC_BASE = 0xCAFEF00D    # matches tb_second_source_chain.v
SEED_PI_BASE  = 0xFACEFEED    # matches tb_pf18_power_iteration.v
DEPTH         = 256
N_CHAINS      = 100
K_VALUES      = [1, 2, 4, 8, 16, 32, 64, 128, None]  # None = ∞

# ── LFSR (mirrors Verilog, taps 31,21,1,0) ─────────────────────────────────
def lfsr_step(s):
    bit = ((s >> 31) ^ (s >> 21) ^ (s >> 1) ^ s) & 1
    return ((s << 1) & 0xFFFFFFFF) | bit

def lfsr_frac(s):
    return ((s >> 8) & 0xFFFFFF) / 16777216.0

# ── NFE helpers (mirrors second_source_chain.py lines 53-82 / pf_width_sweep.py 47-76) ──
class NFE:
    __slots__ = ("s", "e", "f")
    def __init__(self, s, e, f): self.s, self.e, self.f = s, e, f

def nfe_dec(w):
    v = math.ldexp(1.0 + w.f / 64.0, w.e - EXP_BIAS)
    return -v if w.s else v

def nfe_enc(v):
    """mirrors second_source_chain.py nfe_enc, lines 58-82."""
    s = 1 if v < 0.0 else 0
    av = abs(v)
    if av == 0.0: return NFE(s, 0, 0)
    aE = math.floor(math.log2(av))
    m  = av / math.ldexp(1.0, aE)
    if m < 1.0: aE -= 1; m = av / math.ldexp(1.0, aE)
    if m >= 2.0: aE += 1; m = av / math.ldexp(1.0, aE)
    if aE < -EXP_BIAS: return NFE(s, 0, 0)
    if aE > EXP_MAX - EXP_BIAS: return NFE(s, EXP_MAX, 63)
    eS = aE + EXP_BIAS
    f  = round((m - 1.0) * 64.0)
    if f > 63: f = 0; eS += 1
    if eS > EXP_MAX: return NFE(s, EXP_MAX, 63)
    return NFE(s, eS, f)

# ── Baseline multiply: 6-bit quantisation per product ───────────────────────
# Mirrors second_source_chain.py nfe_mul, lines 93-106.
def nfe_mul(a, b):
    P = (64 + a.f) * (64 + b.f)
    rs = a.s ^ b.s
    if P >= 8192: es = a.e + b.e - EXP_BIAS + 1; fR = (P >> 7) & 0x3F
    else:          es = a.e + b.e - EXP_BIAS;     fR = (P >> 6) & 0x3F
    if es < 0:       return NFE(rs, 0,      0 )
    if es > EXP_MAX: return NFE(rs, EXP_MAX, 63)
    return NFE(rs, es, fR)

# ── PF18 accumulate / readout ────────────────────────────────────────────────
# Mirrors pf_width_sweep.py pf_accumulate, lines 81-117 (W=18 specialised).
def pf_acc18(acc, a, b):
    """Returns (new_acc, did_clamp)."""
    scale_reg = (64 + a.f) * (64 + b.f)
    sreg_msb  = 1 if scale_reg >= 8192 else 0
    exp_sum   = a.e + b.e - EXP_BIAS + sreg_msb
    if exp_sum < 0 or exp_sum >= 64: return acc, 0   # guard
    k = max(-8, min(8, exp_sum - sreg_msb - PF_K_REF))
    term_u = (scale_reg << k) if k >= 0 else (scale_reg >> (-k))
    term   = -term_u if (a.s ^ b.s) else term_u
    nv     = acc + term
    if nv > MAX18: return MAX18, 1
    if nv < MIN18: return MIN18, 1
    return nv, 0

# Mirrors pf_width_sweep.py pf_readout, lines 120-154 (W=18 specialised).
def pf_rd18(acc):
    pf_sign = 1 if acc < 0 else 0
    pf_abs  = abs(acc) & (MAX18)     # 17-bit magnitude (MAX18 = 2^17-1)
    if pf_abs == 0: return NFE(pf_sign, 0, 0)
    pf_msb = pf_abs.bit_length() - 1
    pf_es  = pf_msb + PF_SCALE_EXP
    if pf_msb >= 6:
        pf_f = (pf_abs >> (pf_msb - 6)) & 0x3F
        if pf_msb >= 7 and ((pf_abs >> (pf_msb - 7)) & 1):
            if pf_f == 0x3F: pf_f = 0; pf_es += 1
            else:            pf_f += 1
    else:
        pf_f = (pf_abs << (6 - pf_msb)) & 0x3F
    if pf_es > EXP_MAX: return NFE(pf_sign, EXP_MAX, 63)
    return NFE(pf_sign, pf_es, pf_f)

# ── Matvec implementations ────────────────────────────────────────────────────
def mv_golden(A_fp, y):
    """FP64 matvec. Mirrors second_source_chain.py step_golden, line 117."""
    return [sum(A_fp[i][j] * y[j] for j in range(N)) for i in range(N)]

def mv_baseline(A_nfe, y_nfe):
    """PATH_NFE: 6-bit quantised product per element.
    Mirrors second_source_chain.py step_nfe, lines 135-148."""
    out = []; clamps = 0
    for i in range(N):
        acc = 0.0
        for j in range(N):
            acc += nfe_dec(nfe_mul(A_nfe[i][j], y_nfe[j]))
        w = nfe_enc(acc); out.append(w)
    return out, clamps

def mv_pf18(A_nfe, y_nfe):
    """PF18: W=18 saturating accumulate, NOP readout.
    Mirrors pf_width_sweep.py run_chain_width inner loop, lines 191-197."""
    out = []; total_cl = 0
    for i in range(N):
        acc = 0
        for j in range(N):
            acc, cl = pf_acc18(acc, A_nfe[i][j], y_nfe[j])
            total_cl += cl
        out.append(pf_rd18(acc))
    return out, total_cl

# ── Matrix / initial-vector generators ─────────────────────────────────────
def build_ssc_chain(seed):
    """Row-stochastic 8×8, initial y ∈ [1.0, 2.0).
    Mirrors tb_second_source_chain.v LFSR matrix construction."""
    lfsr = seed
    A_fp = [[0.0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            lfsr = lfsr_step(lfsr)
            A_fp[i][j] = lfsr_frac(lfsr) + 0.01  # all positive
        rs = sum(A_fp[i])
        A_fp[i] = [a / rs for a in A_fp[i]]       # row sum = 1.0 (neutral)
    A_nfe = [[nfe_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]
    y_fp  = []
    for j in range(N):
        lfsr = lfsr_step(lfsr)
        y_fp.append(lfsr_frac(lfsr) + 1.0)        # y ∈ [1.0, 2.0)
    y_nfe = [nfe_enc(v) for v in y_fp]
    y_fp  = [nfe_dec(w) for w in y_nfe]            # quantise initial state
    return A_fp, A_nfe, y_fp, y_nfe

def build_pi_chain(seed):
    """Symmetric positive 8×8, entries ∈ [0.25, 1.25), normalised initial y.
    Mirrors tb_pf18_power_iteration.v SEED_PI construction."""
    lfsr = seed
    A_fp = [[0.0]*N for _ in range(N)]
    for i in range(N):
        for j in range(i, N):
            lfsr = lfsr_step(lfsr)
            v = lfsr_frac(lfsr) + 0.25
            A_fp[i][j] = v; A_fp[j][i] = v
    A_nfe = [[nfe_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]
    y_fp  = []
    for j in range(N):
        lfsr = lfsr_step(lfsr)
        y_fp.append(lfsr_frac(lfsr) + 0.1)
    norm  = math.sqrt(sum(v*v for v in y_fp))
    y_nfe = [nfe_enc(v/norm) for v in y_fp]
    y_fp  = [nfe_dec(w) for w in y_nfe]
    return A_fp, A_nfe, y_fp, y_nfe

# ── Chain runner with k-step normalization ────────────────────────────────
def run_chain(mv_fn, A_nfe, A_fp, y_nfe0, y_g0, k):
    """
    Run DEPTH-step chain; harness normalises both DUT and golden every k steps.
    k=None means no normalisation (k=∞).
    Returns (final_mre_pct, final_alignment, total_clamps, overflowed).
    """
    y_nfe = list(y_nfe0)
    y_g   = list(y_g0)
    total_cl = 0

    for t in range(1, DEPTH + 1):
        z_nfe, cl = mv_fn(A_nfe, y_nfe)
        z_g       = mv_golden(A_fp, y_g)
        total_cl += cl

        y_nfe = z_nfe
        y_real = [nfe_dec(w) for w in y_nfe]
        y_g    = z_g

        # Check for overflow in golden (mainly for k=∞ PI workload)
        if any(not math.isfinite(v) or abs(v) > 1e290 for v in y_g):
            return None, None, total_cl, True

        # Harness normalisation every k steps
        if k is not None and t % k == 0:
            nd = math.sqrt(sum(v*v for v in y_real))
            ng = math.sqrt(sum(v*v for v in y_g))
            if nd <= 0 or ng <= 0 or not math.isfinite(nd) or not math.isfinite(ng):
                return None, None, total_cl, True
            y_real = [v/nd for v in y_real]
            y_g    = [v/ng for v in y_g]
            y_nfe  = [nfe_enc(v) for v in y_real]
            y_real = [nfe_dec(w) for w in y_nfe]

    # Final metrics
    # Mean relative error (unnormalised vectors)
    eps   = 1e-10
    mre   = sum(abs(y_real[i] - y_g[i]) / max(abs(y_g[i]), eps)
                for i in range(N)) / N * 100.0

    # Alignment (normalise both for direction-only metric)
    nd = math.sqrt(sum(v*v for v in y_real))
    ng = math.sqrt(sum(v*v for v in y_g))
    if nd > 0 and ng > 0:
        yu = [v/nd for v in y_real]
        ygu = [v/ng for v in y_g]
        alignment = abs(sum(yu[i]*ygu[i] for i in range(N)))
    else:
        alignment = 0.0

    return mre, alignment, total_cl, False

# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    # ── Run all chains ────────────────────────────────────────────────────────
    results = {}  # key: (workload, path, k) → (mean_mre, mean_align, mean_clamps, n_ovf)
    paths = [('baseline', mv_baseline), ('pf18', mv_pf18)]

    workloads = [
        ('ssc', build_ssc_chain, SEED_SSC_BASE),
        ('pi',  build_pi_chain,  SEED_PI_BASE ),
    ]

    total_runs = len(workloads) * len(paths) * len(K_VALUES) * N_CHAINS
    done = 0
    print(f"Running {total_runs} chain runs ({N_CHAINS} chains × "
          f"{len(paths)} paths × {len(K_VALUES)} k-values × {len(workloads)} workloads)...")
    sys.stdout.flush()

    for wl_name, build_fn, seed_base in workloads:
        for path_name, mv_fn in paths:
            # Build all chains once (same matrices for all k)
            chains = []
            for i in range(N_CHAINS):
                seed = (seed_base ^ (i * 0x01010101 + 0x5555AAAA)) & 0xFFFFFFFF
                chains.append(build_fn(seed))

            for k in K_VALUES:
                k_label = '∞' if k is None else str(k)
                mres   = []; aligns = []; clamps_l = []; n_ovf = 0
                for A_fp, A_nfe, y_g0, y_nfe0 in chains:
                    mre, align, cl, ovf = run_chain(mv_fn, A_nfe, A_fp, y_nfe0, y_g0, k)
                    if ovf:
                        n_ovf += 1
                    else:
                        mres.append(mre); aligns.append(align); clamps_l.append(cl)
                    done += 1

                n_valid = len(mres)
                avg_mre   = sum(mres)    / n_valid if n_valid else float('nan')
                avg_align = sum(aligns)  / n_valid if n_valid else float('nan')
                avg_cl    = sum(clamps_l)/ n_valid if n_valid else float('nan')
                results[(wl_name, path_name, k)] = (avg_mre, avg_align, avg_cl, n_ovf)

        print(f"  {wl_name} done")
        sys.stdout.flush()

    # ── Print tables ─────────────────────────────────────────────────────────
    def fmt_k(k): return '∞' if k is None else str(k)

    for wl_name, metric_label, threshold_mre, threshold_align in [
            ('ssc', 'mean_rel_err (%)',  1.0, 0.99),
            ('pi',  'alignment',         1.0, 0.99)]:

        print()
        print("=" * 80)
        title = ("SSC Neutral Row-Stochastic Workload" if wl_name == 'ssc'
                 else "PI Symmetric-Positive Workload (SEED_PI, entries [0.25,1.25))")
        print(f"Workload: {title}")
        if wl_name == 'ssc':
            print("  Metric: mean relative error vs FP64 golden at t=256 (lower = better)")
            print("  Threshold for PASS: ≤ 1.00%")
        else:
            print("  Metric: alignment |y_dut·y_gold| at t=256 (higher = better)")
            print("  Threshold for PASS: ≥ 0.99")
        print("-" * 80)

        k_header = "  " + "".join(f"{fmt_k(k):>9}" for k in K_VALUES)
        print(k_header)

        for path_name in ['baseline', 'pf18']:
            row = f"  {path_name:<10}"
            for k in K_VALUES:
                mre, align, cl, n_ovf = results[(wl_name, path_name, k)]
                if wl_name == 'ssc':
                    if n_ovf > 0:    row += f"{'N/A':>9}"
                    elif math.isnan(mre): row += f"{'NaN':>9}"
                    elif mre < 100:  row += f"{mre:>8.3f}%"
                    else:            row += f">100%   "
                else:  # pi: use alignment
                    if n_ovf == N_CHAINS: row += f"{'N/A(OVF)':>9}"
                    elif math.isnan(align): row += f"{'NaN':>9}"
                    else:            row += f"{align:>9.4f}"
            print(row)

        # Clamp counts for pf18
        print()
        row_cl = "  pf18 clamps/run"
        for k in K_VALUES:
            mre, align, cl, n_ovf = results[(wl_name, 'pf18', k)]
            if n_ovf == N_CHAINS: row_cl += f"{'N/A':>9}"
            elif math.isnan(cl):  row_cl += f"{'NaN':>9}"
            else:                 row_cl += f"{cl:>9.0f}"
        print(row_cl)

        # Break-even for baseline
        print()
        be_k = None
        for k in reversed(K_VALUES):
            mre, align, cl, n_ovf = results[(wl_name, 'baseline', k)]
            if n_ovf > 0: continue
            if wl_name == 'ssc':
                if not math.isnan(mre) and mre <= threshold_mre:
                    be_k = k; break
            else:
                if not math.isnan(align) and align >= threshold_align:
                    be_k = k; break

        if be_k is not None:
            k_lbl = fmt_k(be_k)
            print(f"  Break-even (baseline): largest passing k = {k_lbl}")
            # Also find first failing k above break-even
            idx = K_VALUES.index(be_k)
            if idx + 1 < len(K_VALUES):
                k_fail = K_VALUES[idx + 1]
                mre_f, al_f, _, _ = results[(wl_name, 'baseline', k_fail)]
                if wl_name == 'ssc':
                    print(f"  First failing k = {fmt_k(k_fail)}: mre = {mre_f:.3f}%")
                else:
                    print(f"  First failing k = {fmt_k(k_fail)}: alignment = {al_f:.4f}")
        else:
            print("  Break-even (baseline): NONE — baseline fails at all k values tested")

    # ── Comparison summary ────────────────────────────────────────────────────
    print()
    print("=" * 80)
    print("Comparison summary")
    print("-" * 80)
    for wl_name in ['ssc', 'pi']:
        print(f"\n  Workload: {wl_name.upper()}")
        for path_name in ['baseline', 'pf18']:
            for k in [1, 4, 16, None]:
                mre, align, cl, n_ovf = results[(wl_name, path_name, k)]
                k_lbl = fmt_k(k)
                if n_ovf == N_CHAINS:
                    val = "N/A(OVF)"
                elif wl_name == 'ssc':
                    val = f"{mre:.3f}% mre" if not math.isnan(mre) else "NaN"
                else:
                    val = f"{align:.4f} align" if not math.isnan(align) else "NaN"
                if wl_name == 'pi' and path_name == 'pf18':
                    val += f" [{cl:.0f} clamps]"
                print(f"    {path_name:<10} k={k_lbl:<5}  {val}")

    # ── Write CSV for Task 4 traceability ─────────────────────────────────────
    csv_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             'NORM_INTERVAL_SWEEP.csv')
    with open(csv_path, 'w') as fh:
        fh.write('workload,path,k,mean_mre_pct,mean_alignment,mean_clamps_per_run,n_overflow\n')
        for (wl_name, path_name, k), (mre, align, cl, n_ovf) in results.items():
            k_str = 'inf' if k is None else str(k)
            fh.write(f'{wl_name},{path_name},{k_str},'
                     f'{mre:.6f},{align:.6f},{cl:.2f},{n_ovf}\n')
    print(f"\nWritten: {csv_path}")


if __name__ == '__main__':
    main()

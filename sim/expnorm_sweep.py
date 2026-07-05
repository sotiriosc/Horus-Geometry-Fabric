#!/usr/bin/env python3
"""
sim/expnorm_sweep.py — Block-exponent normalizer sweep.

Extends sim/norm_interval_sweep.py with a second rescale mode:
  exact  — FP64 unit-norm (||y||=1) rescale (same as norm_interval_sweep.py)
  expnorm — Block-exponent rescale: find max stored E across the 8-element
             state, compute offset = E_TARGET − E_max, add offset to every
             element's stored exponent with UF/OVF clamping; mantissas
             untouched.  Lossless per-element but scale is power-of-2 quantized.

Key design parameters:
  E_TARGET = 32  (mid-anchor; HBS-12D log line 171, nfe_matvec2.c line 67-68)
  UF clamp : {sign, E=0,  f=0 } — floor sentinel (horus_nfe.v line 521)
  OVF clamp: {sign, E=63, f=63} — saturation sentinel (horus_nfe.v line 524)

Metric: scale-invariant alignment (|ŷ_dut · ŷ_golden|, both unit-normalised)
for BOTH workloads.  MRE is scale-dependent and meaningless for expnorm because
expnorm does not normalise to unit norm; alignment is the only valid comparison
metric and is used for both rescale modes throughout this script.

Pass criterion for expnorm architecture (per ADR_002 open item):
  SSC workload: alignment ≥ 0.99 at k=128 (same k as exact-FP64 break-even)
  PI  workload: alignment ≥ 0.99 at k=8  (same k as exact-FP64 break-even)
  Within one k-step tolerance (e.g. k=64 acceptable if exact break-even is k=128).

Functions reused from sim/norm_interval_sweep.py:
  lfsr_step      — lines 56-58
  lfsr_frac      — lines 60-61
  NFE class      — lines 64-66
  nfe_dec        — lines 68-70
  nfe_enc        — lines 72-87
  nfe_mul        — lines 91-98
  mv_golden      — lines 134-136
  mv_baseline    — lines 138-147
  build_ssc_chain — lines 162-180
  build_pi_chain  — lines 182-200

Also generates sim/EXPNORM_GOLDEN.csv: 1000 LFSR-random 8-element NFE vectors
with their expnorm outputs — used as the Python golden reference for RTL unit
tests (tb/tb_horus_norm.v).
"""

import math
import csv
import sys
import os

# ── Constants ─────────────────────────────────────────────────────────────────
N           = 8
EXP_BIAS    = 32
EXP_MAX     = 63
E_TARGET    = 32   # mid-anchor per HBS-12D; nfe_matvec2.c lines 67-68

SEED_SSC_BASE  = 0xCAFEF00D   # matches tb_second_source_chain.v
SEED_PI_BASE   = 0xFACEFEED   # matches tb_pf18_power_iteration.v
GOLDEN_SEED    = 0xABCD1234   # for EXPNORM_GOLDEN.csv generation

DEPTH          = 256
N_CHAINS       = 100
K_VALUES       = [1, 2, 4, 8, 16, 32, 64, 128, None]  # None = ∞
N_GOLDEN       = 1000

ALIGN_THRESHOLD = 0.99        # pass threshold for both workloads

# ── LFSR (mirrors norm_interval_sweep.py lines 56-61) ─────────────────────────
def lfsr_step(s):
    bit = ((s >> 31) ^ (s >> 21) ^ (s >> 1) ^ s) & 1
    return ((s << 1) & 0xFFFFFFFF) | bit

def lfsr_frac(s):
    return ((s >> 8) & 0xFFFFFF) / 16777216.0

# ── NFE helpers (mirrors norm_interval_sweep.py lines 64-98) ──────────────────
class NFE:
    __slots__ = ("s", "e", "f")
    def __init__(self, s, e, f): self.s, self.e, self.f = s, e, f
    def codeword(self): return (self.s << 12) | (self.e << 6) | self.f

def nfe_dec(w):
    v = math.ldexp(1.0 + w.f / 64.0, w.e - EXP_BIAS)
    return -v if w.s else v

def nfe_enc(v):
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

def nfe_mul(a, b):
    P = (64 + a.f) * (64 + b.f)
    rs = a.s ^ b.s
    if P >= 8192: es = a.e + b.e - EXP_BIAS + 1; fR = (P >> 7) & 0x3F
    else:          es = a.e + b.e - EXP_BIAS;     fR = (P >> 6) & 0x3F
    if es < 0:       return NFE(rs, 0, 0)
    if es > EXP_MAX: return NFE(rs, EXP_MAX, 63)
    return NFE(rs, es, fR)

# ── Matvec (mirrors norm_interval_sweep.py lines 134-147) ─────────────────────
def mv_golden(A_fp, y):
    return [sum(A_fp[i][j] * y[j] for j in range(N)) for i in range(N)]

def mv_baseline(A_nfe, y_nfe):
    out = []
    for i in range(N):
        acc = 0.0
        for j in range(N):
            acc += nfe_dec(nfe_mul(A_nfe[i][j], y_nfe[j]))
        out.append(nfe_enc(acc))
    return out, 0

# ── Matrix / vector generators (mirrors norm_interval_sweep.py lines 162-200) ─
def build_ssc_chain(seed):
    lfsr = seed
    A_fp = [[0.0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            lfsr = lfsr_step(lfsr)
            A_fp[i][j] = lfsr_frac(lfsr) + 0.01
        rs = sum(A_fp[i])
        A_fp[i] = [a / rs for a in A_fp[i]]
    A_nfe = [[nfe_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]
    y_fp  = []
    for j in range(N):
        lfsr = lfsr_step(lfsr)
        y_fp.append(lfsr_frac(lfsr) + 1.0)
    y_nfe = [nfe_enc(v) for v in y_fp]
    y_fp  = [nfe_dec(w) for w in y_nfe]
    return A_fp, A_nfe, y_fp, y_nfe

def build_pi_chain(seed):
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

# ── Block-exponent normalizer (the new function) ───────────────────────────────
def expnorm_rescale(y_nfe, e_target=E_TARGET):
    """Block-exponent normalization: find max stored exponent, compute
    power-of-2 offset = e_target − E_max, add offset to every element's
    stored exponent with UF/OVF clamping.  Mantissas untouched.

    UF clamp : NFE(sign, 0,  0 ) — floor sentinel, per horus_nfe.v line 521.
    OVF clamp: NFE(sign, 63, 63) — saturation sentinel, per horus_nfe.v line 524.
    If E_max = 0 (all elements at floor): return input unchanged.
    """
    e_max = max(w.e for w in y_nfe)
    if e_max == 0:
        return list(y_nfe)
    offset = e_target - e_max
    if offset == 0:
        return list(y_nfe)
    result = []
    for w in y_nfe:
        new_e = w.e + offset
        if new_e < 0:
            result.append(NFE(w.s, 0, 0))    # UF → floor sentinel
        elif new_e > EXP_MAX:
            result.append(NFE(w.s, EXP_MAX, 63))  # OVF → saturation sentinel
        else:
            result.append(NFE(w.s, new_e, w.f))   # mantissa unchanged
    return result

# ── Alignment metric (scale-invariant) ────────────────────────────────────────
def alignment(a_float, b_float):
    """Normalised dot product |â · b̂|.  Returns 0.0 if either vector is zero."""
    na = math.sqrt(sum(v*v for v in a_float))
    nb = math.sqrt(sum(v*v for v in b_float))
    if na <= 0 or nb <= 0 or not math.isfinite(na) or not math.isfinite(nb):
        return 0.0
    return abs(sum(a_float[i]/na * b_float[i]/nb for i in range(N)))

# ── Chain runner: exact-FP64 rescale ──────────────────────────────────────────
def run_chain_exact(A_nfe, A_fp, y_nfe0, y_g0, k):
    """Run chain with exact FP64 unit-norm rescale every k steps.
    Returns (align, overflowed) using scale-invariant alignment metric."""
    y_nfe = list(y_nfe0)
    y_g   = list(y_g0)

    for t in range(1, DEPTH + 1):
        z_nfe, _ = mv_baseline(A_nfe, y_nfe)
        z_g      = mv_golden(A_fp, y_g)

        y_nfe = z_nfe
        y_g   = z_g

        if any(not math.isfinite(v) or abs(v) > 1e290 for v in y_g):
            return None, True

        if k is not None and t % k == 0:
            y_real = [nfe_dec(w) for w in y_nfe]
            nd = math.sqrt(sum(v*v for v in y_real))
            ng = math.sqrt(sum(v*v for v in y_g))
            if nd <= 0 or ng <= 0 or not math.isfinite(nd) or not math.isfinite(ng):
                return None, True
            y_real = [v/nd for v in y_real]
            y_g    = [v/ng for v in y_g]
            y_nfe  = [nfe_enc(v) for v in y_real]
            y_real = [nfe_dec(w) for w in y_nfe]

    y_real = [nfe_dec(w) for w in y_nfe]
    return alignment(y_real, y_g), False

# ── Chain runner: expnorm rescale ──────────────────────────────────────────────
def run_chain_expnorm(A_nfe, A_fp, y_nfe0, y_g0, k, e_target=E_TARGET):
    """Run chain with block-exponent (expnorm) rescale every k steps on DUT,
    exact FP64 unit-norm rescale on golden (independent).

    Metric: scale-invariant alignment (|ŷ_dut · ŷ_golden|) at t=DEPTH.
    Both the DUT and golden state are unit-normalised only for the final metric
    computation; the DUT state magnitude during the chain is arbitrary.
    """
    y_nfe = list(y_nfe0)
    y_g   = list(y_g0)

    for t in range(1, DEPTH + 1):
        z_nfe, _ = mv_baseline(A_nfe, y_nfe)
        z_g      = mv_golden(A_fp, y_g)

        y_nfe = z_nfe
        y_g   = z_g

        if any(not math.isfinite(v) or abs(v) > 1e290 for v in y_g):
            return None, True

        if k is not None and t % k == 0:
            # DUT: block-exponent rescale (mantissa untouched)
            y_nfe = expnorm_rescale(y_nfe, e_target)
            # Golden: exact unit-norm rescale (unchanged from prior sweep)
            ng = math.sqrt(sum(v*v for v in y_g))
            if ng <= 0 or not math.isfinite(ng):
                return None, True
            y_g = [v/ng for v in y_g]

    y_real = [nfe_dec(w) for w in y_nfe]
    return alignment(y_real, y_g), False

# ── Generate EXPNORM_GOLDEN.csv ────────────────────────────────────────────────
def gen_golden_csv(out_path, n=N_GOLDEN, seed=GOLDEN_SEED):
    """Generate N_GOLDEN random 8-element NFE input vectors and their
    expnorm outputs.  Used as Python golden reference for tb_horus_norm.v.
    Writes both EXPNORM_GOLDEN.csv (documentation) and EXPNORM_GOLDEN.dat
    (space-separated integers, no header — read by tb_horus_norm.v $fscanf)."""
    lfsr = seed & 0xFFFFFFFF
    rows = []
    dat_lines = []
    for idx in range(n):
        # Build a random 8-element NFE state with varied exponents
        in_cw = []
        for _ in range(N):
            lfsr = lfsr_step(lfsr)
            raw = (lfsr & 0x1FFF)  # 13 bits: random NFE codeword
            w = NFE((raw >> 12) & 1, (raw >> 6) & 63, raw & 63)
            in_cw.append(w)
        out_cw = expnorm_rescale(in_cw, E_TARGET)
        e_max  = max(w.e for w in in_cw)
        offset = (E_TARGET - e_max) if e_max > 0 else 0
        row = {'idx': idx, 'e_max': e_max, 'offset': offset}
        for k_idx in range(N):
            row[f'in_{k_idx}']  = in_cw[k_idx].codeword()
            row[f'out_{k_idx}'] = out_cw[k_idx].codeword()
        rows.append(row)
        # .dat line: idx e_max offset in_0..in_7 out_0..out_7  (space-separated)
        vals = [idx, e_max, offset]
        vals += [in_cw[k_idx].codeword() for k_idx in range(N)]
        vals += [out_cw[k_idx].codeword() for k_idx in range(N)]
        dat_lines.append(' '.join(str(v) for v in vals))
    fields = (['idx','e_max','offset'] +
              [f'in_{k}' for k in range(N)] +
              [f'out_{k}' for k in range(N)])
    with open(out_path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    dat_path = out_path.replace('.csv', '.dat')
    with open(dat_path, 'w') as f:
        f.write('\n'.join(dat_lines) + '\n')
    print(f"  Golden CSV written: {out_path}  ({n} vectors)")
    print(f"  Golden DAT written: {dat_path}")

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=" * 74)
    print("sim/expnorm_sweep.py — Block-exponent normalizer sweep")
    print(f"  E_TARGET = {E_TARGET}  |  N_CHAINS = {N_CHAINS}  |"
          f"  DEPTH = {DEPTH}  |  ALIGN_THRESHOLD = {ALIGN_THRESHOLD}")
    print("  Metric: alignment (scale-invariant, used for BOTH rescale modes)")
    print("=" * 74)

    workloads = [
        ('ssc', build_ssc_chain, SEED_SSC_BASE),
        ('pi',  build_pi_chain,  SEED_PI_BASE),
    ]
    modes = [
        ('exact',   run_chain_exact),
        ('expnorm', run_chain_expnorm),
    ]

    results = {}
    total = len(workloads) * len(modes) * len(K_VALUES) * N_CHAINS
    done  = 0
    print(f"Running {total} chain runs ...")
    sys.stdout.flush()

    for wl_name, build_fn, seed_base in workloads:
        chains = []
        for i in range(N_CHAINS):
            seed = (seed_base ^ (i * 0x01010101 + 0x5555AAAA)) & 0xFFFFFFFF
            chains.append(build_fn(seed))

        for mode_name, run_fn in modes:
            for k in K_VALUES:
                aligns = []; n_ovf = 0
                for A_fp, A_nfe, y_g0, y_nfe0 in chains:
                    al, ovf = run_fn(A_nfe, A_fp, y_nfe0, y_g0, k)
                    if ovf:
                        n_ovf += 1
                    else:
                        aligns.append(al)
                    done += 1

                k_label = '∞' if k is None else str(k)
                mean_al = (sum(aligns) / len(aligns)) if aligns else 0.0
                results[(wl_name, mode_name, k_label)] = {
                    'mean_align': mean_al,
                    'n_valid': len(aligns),
                    'n_ovf': n_ovf,
                    'pass': (mean_al >= ALIGN_THRESHOLD and len(aligns) >= N_CHAINS // 2),
                }
    print("Done.\n")

    # ── Side-by-side break-even tables ────────────────────────────────────────
    for wl_name in ['ssc', 'pi']:
        print(f"── {wl_name.upper()} workload "
              f"({'row-stochastic' if wl_name=='ssc' else 'symmetric-positive'}) "
              f"────────────────────────────────────")
        print(f"  {'k':>5}  {'exact align':>14}  {'exact pass':>10}  "
              f"{'expnorm align':>14}  {'expnorm pass':>12}")
        print("  " + "-" * 62)
        for k in K_VALUES:
            k_label = '∞' if k is None else str(k)
            r_ex  = results[(wl_name, 'exact',   k_label)]
            r_en  = results[(wl_name, 'expnorm', k_label)]
            mark_ex = '✓' if r_ex['pass'] else '✗'
            mark_en = '✓' if r_en['pass'] else '✗'
            al_ex  = f"{r_ex['mean_align']:.6f}" if r_ex['n_valid'] > 0 else "  N/A  "
            al_en  = f"{r_en['mean_align']:.6f}" if r_en['n_valid'] > 0 else "  N/A  "
            ovf_ex = f"  (ovf:{r_ex['n_ovf']})" if r_ex['n_ovf'] > 0 else ""
            ovf_en = f"  (ovf:{r_en['n_ovf']})" if r_en['n_ovf'] > 0 else ""
            print(f"  {k_label:>5}  {al_ex:>14}{ovf_ex:12}  {mark_ex:>10}  "
                  f"{al_en:>14}{ovf_en:12}  {mark_en:>12}")
        print()

    # ── Break-even summary ────────────────────────────────────────────────────
    print("── Break-even summary (largest k with alignment ≥ 0.99) ────────────")
    print(f"  {'workload':<8}  {'mode':<10}  {'break-even k'}")
    print("  " + "-" * 36)
    for wl_name in ['ssc', 'pi']:
        for mode_name in ['exact', 'expnorm']:
            breakeven_k = None
            for k in K_VALUES:
                k_label = '∞' if k is None else str(k)
                if results[(wl_name, mode_name, k_label)]['pass']:
                    breakeven_k = k_label
            print(f"  {wl_name:<8}  {mode_name:<10}  {breakeven_k if breakeven_k else 'none (all fail)'}")
    print()

    # ── Pass / fail verdict for the expnorm architecture ──────────────────────
    print("── Architecture verdict ─────────────────────────────────────────────")
    ssc_exact_be  = next((k for k in ['128','64','32','16','8','4','2','1']
                          if results[('ssc','exact',  k)]['pass']), None)
    ssc_en_be     = next((k for k in ['128','64','32','16','8','4','2','1']
                          if results[('ssc','expnorm',k)]['pass']), None)
    pi_exact_be   = next((k for k in ['8','4','2','1']
                          if results[('pi', 'exact',  k)]['pass']), None)
    pi_en_be      = next((k for k in ['8','4','2','1']
                          if results[('pi', 'expnorm',k)]['pass']), None)

    def within_one_kstep(be_ref, be_test):
        order = [None, '1','2','4','8','16','32','64','128','∞']
        if be_ref is None or be_test is None: return False
        ri = order.index(be_ref); ti = order.index(be_test)
        return abs(ri - ti) <= 1

    ssc_ok = within_one_kstep(ssc_exact_be, ssc_en_be)
    pi_ok  = within_one_kstep(pi_exact_be,  pi_en_be)

    print(f"  SSC: exact break-even k={ssc_exact_be}, "
          f"expnorm break-even k={ssc_en_be} → "
          f"{'PASS' if ssc_ok else 'FAIL'}")
    print(f"  PI:  exact break-even k={pi_exact_be},  "
          f"expnorm break-even k={pi_en_be}  → "
          f"{'PASS' if pi_ok else 'FAIL'}")

    overall = ssc_ok and pi_ok
    print()
    if overall:
        print("  RESULT: expnorm break-evens match exact-FP64 within one k-step.")
        print("  → Task 2 (RTL module) is UNBLOCKED.")
    else:
        print("  RESULT: expnorm does NOT match exact-FP64 break-evens.")
        print("  → Task 2 is BLOCKED.  See tables above for the failure mode.")
        print("  → Document as EXPNORM_RESULTS.md (negative finding).")
    print()

    # ── Write CSV ─────────────────────────────────────────────────────────────
    out_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(out_dir, "EXPNORM_SWEEP.csv")
    rows = []
    for (wl, mode, k_label), r in results.items():
        rows.append({'workload': wl, 'mode': mode, 'k': k_label,
                     'mean_align': f"{r['mean_align']:.6f}",
                     'n_valid': r['n_valid'], 'n_ovf': r['n_ovf'],
                     'pass': 1 if r['pass'] else 0})
    with open(csv_path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=['workload','mode','k','mean_align',
                                          'n_valid','n_ovf','pass'])
        w.writeheader(); w.writerows(rows)
    print(f"  Sweep CSV written: {csv_path}")

    # ── Generate golden file for RTL unit tests ────────────────────────────────
    golden_path = os.path.join(out_dir, "EXPNORM_GOLDEN.csv")
    gen_golden_csv(golden_path)
    print()

    return overall


if __name__ == '__main__':
    ok = main()
    sys.exit(0 if ok else 1)

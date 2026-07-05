#!/usr/bin/env python3
"""
pf_width_sweep.py — accumulator-width sensitivity for the PATH_FAST RTL variant.

Mirrors the fixed-point accumulation and readout logic of rtl/horus_nfe_pf.v at
parameterized widths W ∈ {16, 18, 20, 24, 28, 32}, all other parameters fixed.

Mirrored RTL logic:
  Accumulation  — rtl/horus_nfe_pf.v lines 572–585
                  k = exp_sum[5:0] − scale_reg[13] − PF_K_REF  (PF_K_REF = 28)
                  clamped shift of 14-bit scale_reg product, added to pf_accum
  Readout       — rtl/horus_nfe_pf.v lines 613–679
                  find MSB of |pf_accum|, stored_E = msb_pos + PF_SCALE_EXP (16),
                  extract 6-bit mantissa with round-to-nearest (guard bit check),
                  return NFE codeword

For width W < 32 the accumulator clips to the W-bit signed range; PF_SCALE_EXP = 16
and PF_K_REF = 28 are unchanged.  The readout MSB search spans bits 0..(W-2).

Each width is exercised over 100 neutral-regime chains of depth 256, using Python's
random.Random with a fixed seed so the run is reproducible.

Usage:
    python3 pf_width_sweep.py [--chains 100] [--depth 256] [--seed 42]
"""

import argparse
import math
import random

# ── NFE constants (must match rtl/horus_nfe_pf.v) ──────────────────────────
N          = 8
EXP_BIAS   = 32
EXP_MAX    = 63
# PF accumulator constants — mirror rtl/horus_nfe_pf.v lines 160–161
PF_K_REF    = 28   # rtl line 161
PF_SCALE_EXP = 16  # rtl line 160


class NFE:
    __slots__ = ("s", "e", "f")

    def __init__(self, s, e, f):
        self.s, self.e, self.f = s, e, f


def nfe_dec(w):
    v = math.ldexp(1.0 + w.f / 64.0, w.e - EXP_BIAS)
    return -v if w.s else v


def nfe_enc(v):
    s = 1 if v < 0.0 else 0
    av = abs(v)
    if av == 0.0:
        return NFE(s, 0, 0)
    aE = math.floor(math.log2(av))
    m = av / math.ldexp(1.0, aE)
    if m < 1.0:
        aE -= 1
        m = av / math.ldexp(1.0, aE)
    if m >= 2.0:
        aE += 1
        m = av / math.ldexp(1.0, aE)
    if aE < -EXP_BIAS:
        return NFE(s, 0, 0)
    if aE > EXP_MAX - EXP_BIAS:
        return NFE(s, EXP_MAX, 63)
    eS = aE + EXP_BIAS
    f = round((m - 1.0) * 64.0)
    if f > 63:
        f = 0
        eS += 1
        if eS > EXP_MAX:
            return NFE(s, EXP_MAX, 63)
    return NFE(s, eS, f)


# ── RTL-faithful fixed-point accumulation (mirror lines 572–585) ────────────

def pf_accumulate(pf_accum_int, a, b, W):
    """
    Accumulate a×b into pf_accum_int (W-bit signed).
    Mirrors rtl/horus_nfe_pf.v lines 533–585.

    Key RTL detail (lines 538–544): exp_sum already includes +1 for
    scale_reg[13]=1 (P >= 8192 normalization).  The k formula then
    subtracts scale_reg[13] back out, so k = e_a + e_b - EXP_BIAS - PF_K_REF
    always, independent of scale_reg[13].  Mirroring this correctly:
      exp_sum_rtl = a.e + b.e - EXP_BIAS + sreg_msb   (RTL lines 538–544)
      k           = exp_sum_rtl - sreg_msb - PF_K_REF  (RTL line 573–575)
                  = a.e + b.e - EXP_BIAS - PF_K_REF   (simplifies)
    """
    # scale_reg = (64+a.f) * (64+b.f)  — 14-bit max  (mirror: scale_reg[13:0])
    scale_reg = (64 + a.f) * (64 + b.f)
    sreg_msb  = 1 if scale_reg >= 8192 else 0
    scale14   = scale_reg & 0x3FFF
    # exp_sum mirrors RTL lines 538–544: includes +1 correction for P >= 8192
    exp_sum = a.e + b.e - EXP_BIAS + sreg_msb
    # Guard: !exp_sum[7] && !exp_sum[6] (mirror RTL line 572)
    if exp_sum < 0 or exp_sum >= 64:
        return pf_accum_int
    res_sign = a.s ^ b.s
    # k = exp_sum[5:0] − scale_reg[13] − PF_K_REF (mirror RTL lines 573–575)
    # Simplifies to: k = a.e + b.e − EXP_BIAS − PF_K_REF (sreg_msb cancels)
    k = exp_sum - sreg_msb - PF_K_REF
    k = max(-8, min(8, k))       # clamp |k| ≤ 8 (mirror: if pf_k_abs > 4'd8)
    if k >= 0:
        term_u = scale14 << k
    else:
        term_u = scale14 >> (-k)
    term = -term_u if res_sign else term_u
    new_acc = pf_accum_int + term
    # Clip to W-bit signed range (overflow behaviour for W < 32)
    max_val = (1 << (W - 1)) - 1
    min_val = -(1 << (W - 1))
    return max(min_val, min(max_val, new_acc))


def pf_readout(pf_accum_int, W):
    """
    Convert pf_accum_int (W-bit signed fixed-point, 1 unit = 2^(-PF_SCALE_EXP))
    to an NFE codeword.
    Mirrors rtl/horus_nfe_pf.v lines 613–679.
    """
    pf_sign = 1 if pf_accum_int < 0 else 0
    pf_abs  = abs(pf_accum_int) & ((1 << (W - 1)) - 1)  # W-1 bit magnitude

    if pf_abs == 0:
        return NFE(pf_sign, 0, 0)

    # Priority encoder: find MSB position (mirror lines 621–651)
    pf_msb = pf_abs.bit_length() - 1  # Python bit_length() = msb_pos + 1

    # stored_E = pf_msb + PF_SCALE_EXP  (mirror line 657)
    pf_es = pf_msb + PF_SCALE_EXP

    # 6-bit mantissa with round-to-nearest (mirror lines 661–671)
    if pf_msb >= 6:
        pf_f = (pf_abs >> (pf_msb - 6)) & 0x3F
        # Guard bit at position (pf_msb - 7) (mirror line 663)
        if pf_msb >= 7 and ((pf_abs >> (pf_msb - 7)) & 1):
            if pf_f == 0x3F:
                pf_f  = 0
                pf_es += 1  # carry into exponent (mirror line 666)
            else:
                pf_f += 1
    else:
        pf_f = (pf_abs << (6 - pf_msb)) & 0x3F

    # Saturation (mirror lines 672–675)
    if pf_es > EXP_MAX:
        return NFE(pf_sign, EXP_MAX, 63)
    return NFE(pf_sign, pf_es, pf_f)


# ── Chain runner ─────────────────────────────────────────────────────────────

def run_chain_width(rng, depth, W):
    """
    Run one neutral-regime 256-cycle chain with W-bit accumulator.
    Returns final mean relative error (percent).

    Initial y vector: values in [1.0, 2.0) to match the testbench initial-state
    range used in tb/tb_horus_nfe_pf.v (SEED=0xCAFEF00D, y_nfe[j] = 1.0 +
    lfsr[5:0]/64).  This keeps k values in a narrow band (~0–2) so the
    fixed-point accumulation error reflects the operating regime the RTL is
    designed for.  Using a wide initial-exponent range (e.g. rng.randint(28,35))
    introduces large mixed-magnitude errors that are independent of W and do not
    correspond to the RTL's intended use.
    """
    target = 1.0  # neutral regime row-sum target
    # Build 8×8 matrix (same structure as second_source_chain.py make_chain_instance)
    A_fp  = [[rng.random() for _ in range(N)] for _ in range(N)]
    for i in range(N):
        rs = sum(A_fp[i])
        A_fp[i] = [a / rs * target for a in A_fp[i]]
    A_nfe = [[nfe_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]

    # Initial state: [1.0, 2.0) to match tb/tb_horus_nfe_pf.v SEED initial vector
    # (tb line 194: fval = 1.0 + lfsr[5:0]/64, values in [1.0, 1.984])
    x_fp  = [1.0 + rng.random() for _ in range(N)]
    y_nfe = [nfe_enc(v) for v in x_fp]
    y_g   = list(x_fp)

    for _ in range(depth):
        # Golden step (FP64, no re-encode)
        y_g = [sum(A_fp[i][j] * y_g[j] for j in range(N)) for i in range(N)]

        # PF step with W-bit accumulator
        y_nfe_new = []
        for i in range(N):
            acc_int = 0
            for j in range(N):
                acc_int = pf_accumulate(acc_int, A_nfe[i][j], y_nfe[j], W)
            y_nfe_new.append(pf_readout(acc_int, W))
        y_nfe = y_nfe_new

    # Final mean relative error
    errs = []
    for i in range(N):
        g = y_g[i]
        if g != 0.0 and math.isfinite(g):
            errs.append(abs(nfe_dec(y_nfe[i]) - g) / abs(g) * 100.0)
    return sum(errs) / len(errs) if errs else float("inf")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chains", type=int, default=100)
    ap.add_argument("--depth",  type=int, default=256)
    ap.add_argument("--seed",   type=int, default=42)
    args = ap.parse_args()

    widths = [16, 18, 20, 24, 28, 32]
    baseline_w = 32

    print()
    print("PATH_FAST accumulator width sweep — neutral-regime 256-cycle chains")
    print(f"  {args.chains} chains per width  depth={args.depth}  seed={args.seed}")
    print(f"  RTL constants: PF_K_REF={PF_K_REF}  PF_SCALE_EXP={PF_SCALE_EXP}")
    print(f"  Mirroring rtl/horus_nfe_pf.v lines 572–585 (accum) and 613–679 (readout)")
    print()
    print(f"  {'W':>4}  {'mean final err':>16}  {'DFF savings vs 32':>18}  {'note':}")
    print("  " + "-" * 64)

    min_viable_w = None
    results = {}
    for W in widths:
        rng = random.Random(args.seed)
        errs = [run_chain_width(rng, args.depth, W) for _ in range(args.chains)]
        mean_err = sum(errs) / len(errs)
        results[W] = mean_err
        dff_save = (baseline_w - W)  # per-accumulator savings; PF RTL has 1 acc per NFE
        note = ""
        if mean_err <= 0.5 and min_viable_w is None:
            min_viable_w = W
            note = "<-- minimum viable (≤0.5%)"
        print(f"  {W:>4}  {mean_err:>15.4f}%  {dff_save:>18}  {note}")

    print()
    if min_viable_w is not None:
        dff_save_per = baseline_w - min_viable_w
        print(f"  Minimum viable width   : W = {min_viable_w} bits  (mean err ≤ 0.5%)")
        print(f"  DFF savings vs W=32    : {dff_save_per} DFFs per accumulator")
        print(f"  (PF RTL has 1 accumulator per NFE tile; system has 16 tiles in horus_top)")
        print(f"  Total DFF savings at W={min_viable_w}: {16 * dff_save_per} DFFs across 16-tile horus_top")
    else:
        print("  No width in the sweep achieved ≤0.5% final mean error.")
    print()


if __name__ == "__main__":
    main()

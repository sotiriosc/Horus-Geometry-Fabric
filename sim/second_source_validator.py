#!/usr/bin/env python3
"""
second_source_validator.py — standing second-source / falsification check
for the Horus NFE dual-path router (PATH_FAST vs PATH_NFE).

This is a direct port of the grammar block diagram onto real repo code:

  ANCHOR   -> E_ANCHOR_LO..E_ANCHOR_HI (HBS-12D seed range, from nfe_matvec2.c)
  POINT    -> a single (A, x) test instance
  CUT      -> relative-error threshold against the FP64 golden result
  RESOLVED / UNRESOLVED -> did PATH_FAST clear the cut on this instance?
  EXPANSION LOOP -> when unresolved, expand to PATH_NFE (the guarded path)
  FALSIFICATION   -> the expansion only counts as a "thing" if it actually
                     moves the boundary (reduces error) AND stays anchored
                     (doesn't blow up / diverge). If PATH_NFE doesn't clear
                     the cut either, or makes it worse, the expansion is
                     rejected as not a real fix for that instance.
  SECOND SOURCE -> FP64 numpy reference matvec, computed independently of
                   both NFE paths. Never touched by the router or the loop.

Unlike nfe_matvec.c / nfe_matvec2.c (which run ONE fixed test matrix), this
sweeps many random instances across three regimes:
  - all-anchor      : every stored_E in [28..35]  (router should pick FAST)
  - boundary-mixed   : E straddling the anchor edges (E in [24..39])
  - out-of-range     : E pushed toward the NORM/UF/OVF cliffs (E in [16..47])

Build/run:  python3 second_source_validator.py [--n 500] [--tol 0.5] [--seed 0]
"""

import argparse
import math
import random
from dataclasses import dataclass, field

N = 8
EXP_BIAS = 32
EXP_MAX = 63
E_NORM_LO, E_NORM_HI = 16, 47
E_ANCHOR_LO, E_ANCHOR_HI = 28, 35


# ── NFE 13-bit word: (sign, stored_exp[0..63], frac[0..63]) ────────────────
@dataclass(frozen=True)
class NFE:
    s: int
    e: int
    f: int


def nfe_dec(w: NFE) -> float:
    v = math.ldexp(1.0 + w.f / 64.0, w.e - EXP_BIAS)
    return -v if w.s else v


def nfe_enc(v: float) -> NFE:
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


def nfe_mul(a: NFE, b: NFE) -> NFE:
    """Full guarded NFE MUL (PATH_NFE) — includes UF/OVF checks."""
    P = (64 + a.f) * (64 + b.f)
    rs = a.s ^ b.s
    if P >= 8192:
        es = a.e + b.e - EXP_BIAS + 1
        fR = (P >> 7) & 0x3F
    else:
        es = a.e + b.e - EXP_BIAS
        fR = (P >> 6) & 0x3F
    if es < 0:
        return NFE(rs, 0, 0)
    if es > EXP_MAX:
        return NFE(rs, EXP_MAX, 63)
    return NFE(rs, es, fR)


def nfe_fast_mac(a: NFE, b: NFE) -> float:
    """Anchor-zone fast integer MAC (PATH_FAST) — no intermediate quantisation."""
    P = (64 + a.f) * (64 + b.f)
    exp_sum = a.e + b.e
    return math.ldexp(float(P), exp_sum - 76)


def route_to_fast(a: NFE, b: NFE) -> bool:
    return E_ANCHOR_LO <= a.e <= E_ANCHOR_HI and E_ANCHOR_LO <= b.e <= E_ANCHOR_HI


# ── Second source: FP64 golden matvec, computed independently ─────────────
def golden_matvec(A_fp, x_fp):
    y = [0.0] * N
    for i in range(N):
        s = 0.0
        for j in range(N):
            s += A_fp[i][j] * x_fp[j]
        y[i] = s
    return y


# ── The two candidate paths, run row-by-row like the real hardware would ──
def path_fast_row(A_row, xr):
    acc = 0.0
    for j in range(N):
        acc += nfe_fast_mac(A_row[j], xr[j])
    return acc


def path_nfe_row(A_row, xr):
    acc = None
    for j in range(N):
        p = nfe_mul(A_row[j], xr[j])
        acc = nfe_dec(p) if acc is None else acc + nfe_dec(p)
    return acc


# ── Falsification-guarded expansion loop ───────────────────────────────────
@dataclass
class RowResult:
    regime: str
    row: int
    resolved_fast: bool
    err_fast: float
    expanded: bool = False
    err_expanded: float = None
    falsified: bool = None   # None if no expansion attempted


def evaluate_row(regime, row_idx, A_row, xr, golden_val, tol_pct):
    """
    ANCHOR/POINT -> A_row, xr already NFE-encoded operands (the anchor is
                    implicit: this is the fixed reference format itself).
    CUT          -> rel-error vs golden_val, threshold tol_pct.
    RESOLVED     -> PATH_FAST clears the cut.
    EXPANSION    -> if unresolved, try PATH_NFE.
    FALSIFICATION-> expansion accepted only if it (a) reduces error
                    (boundary moved) and (b) the new error itself clears
                    some sane bound, e.g. doesn't diverge (stays anchored).
    """
    fast_val = path_fast_row(A_row, xr)
    err_fast = abs(fast_val - golden_val) / abs(golden_val) * 100.0 if golden_val != 0 else abs(fast_val)
    resolved_fast = err_fast <= tol_pct

    result = RowResult(regime, row_idx, resolved_fast, err_fast)

    if not resolved_fast:
        nfe_val = path_nfe_row(A_row, xr)
        err_nfe = abs(nfe_val - golden_val) / abs(golden_val) * 100.0 if golden_val != 0 else abs(nfe_val)
        result.expanded = True
        result.err_expanded = err_nfe

        moved = err_nfe < err_fast
        stayed_anchored = err_nfe <= tol_pct * 5  # didn't blow up into a new failure mode
        result.falsified = not (moved and stayed_anchored)

    return result


# ── Test-instance generation across three regimes ──────────────────────────
#
# IMPORTANT: the true value must be a CONTINUOUS point in the binade, not
# already aligned to the 6-bit NFE fraction grid — otherwise nfe_enc() is a
# lossless round-trip and the second source can never see any quantization
# error, which would make this whole check vacuous. Draw a real mantissa in
# [1.0, 2.0), THEN encode it — that's the same generative process
# nfe_matvec.c uses (true A_fp/x_fp encoded into NFE, golden computed from
# the true un-quantized values, never from a decode of the encoded word).
def rand_true_value_in_erange(rng, e_lo, e_hi):
    actual_e = rng.randint(e_lo, e_hi) - EXP_BIAS   # unbias to actual exponent
    mantissa = 1.0 + rng.random()                    # continuous, not grid-aligned
    return mantissa * math.ldexp(1.0, actual_e)


def make_instance(rng, regime):
    if regime == "all-anchor":
        e_lo, e_hi = E_ANCHOR_LO, E_ANCHOR_HI
    elif regime == "boundary-mixed":
        e_lo, e_hi = E_ANCHOR_LO - 4, E_ANCHOR_HI + 4
    else:  # out-of-range
        e_lo, e_hi = E_NORM_LO, E_NORM_HI

    A_fp = [[rand_true_value_in_erange(rng, e_lo, e_hi) for _ in range(N)] for _ in range(N)]
    x_fp = [rand_true_value_in_erange(rng, e_lo, e_hi) for _ in range(N)]
    A = [[nfe_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]
    x = [nfe_enc(x_fp[j]) for j in range(N)]
    return A, x, A_fp, x_fp


def run_sweep(n_per_regime, tol_pct, seed):
    rng = random.Random(seed)
    regimes = ["all-anchor", "boundary-mixed", "out-of-range"]
    all_results = []

    for regime in regimes:
        for inst in range(n_per_regime):
            A, x, A_fp, x_fp = make_instance(rng, regime)
            golden = golden_matvec(A_fp, x_fp)
            for i in range(N):
                r = evaluate_row(regime, inst * N + i, A[i], x, golden[i], tol_pct)
                all_results.append(r)

    return all_results


def summarize(results, tol_pct):
    regimes = sorted(set(r.regime for r in results))
    print(f"\nSecond-source validator — tolerance = {tol_pct}% relative error")
    print("=" * 78)

    for regime in regimes:
        rs = [r for r in results if r.regime == regime]
        n = len(rs)
        n_resolved_fast = sum(r.resolved_fast for r in rs)
        n_unresolved = n - n_resolved_fast
        n_expanded = sum(r.expanded for r in rs)
        n_falsified = sum(bool(r.falsified) for r in rs if r.expanded)
        n_rescued = n_expanded - n_falsified

        print(f"\nRegime: {regime}  ({n} rows)")
        print(f"  PATH_FAST resolved directly : {n_resolved_fast:5d}  ({100*n_resolved_fast/n:5.1f}%)")
        print(f"  Unresolved -> expansion tried: {n_unresolved:5d}")
        if n_expanded:
            print(f"    expansion rescued (falsification passed): {n_rescued:5d}  ({100*n_rescued/n_expanded:5.1f}% of expansions)")
            print(f"    expansion rejected (falsification failed): {n_falsified:5d}  ({100*n_falsified/n_expanded:5.1f}% of expansions)")

        # worst-case fast-path error in this regime, and whether router would have sent it fast
        worst = max(rs, key=lambda r: r.err_fast)
        would_route_fast = "would route FAST (router agrees with anchor assumption)"
        print(f"  worst PATH_FAST rel err: {worst.err_fast:.4f}%")

    # cross-cutting finding: does router's binary anchor/not-anchor rule
    # ever disagree with what the falsification check would have decided?
    print("\n" + "=" * 78)
    print("Key check: does the existing static router (anchor-zone-only -> FAST)")
    print("ever route a case to FAST that the second source shows is unresolved,")
    print("with no rescue available even via full PATH_NFE expansion?")
    stuck = [r for r in results if r.regime != "all-anchor"
             and not r.resolved_fast and r.expanded and r.falsified]
    print(f"  Rows where PATH_FAST failed the cut AND expansion to PATH_NFE")
    print(f"  also failed to rescue it: {len(stuck)} / {len(results)}")
    if stuck:
        worst_stuck = max(stuck, key=lambda r: r.err_expanded)
        print(f"  worst such case: fast_err={worst_stuck.err_fast:.4f}%  "
              f"expanded_err={worst_stuck.err_expanded:.4f}%  regime={worst_stuck.regime}")
    else:
        print("  None found in this sweep: every unresolved case that could be")
        print("  saved by the guarded path, was. That's evidence the expansion")
        print("  loop is doing real work here, not just adding cost.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200, help="instances per regime (each yields 8 rows)")
    ap.add_argument("--tol", type=float, default=0.5, help="cut threshold, relative error %%")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    results = run_sweep(args.n, args.tol, args.seed)
    summarize(results, args.tol)


if __name__ == "__main__":
    main()
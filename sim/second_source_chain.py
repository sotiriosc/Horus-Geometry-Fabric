#!/usr/bin/env python3
"""
second_source_chain.py — deep-chain extension of the second-source validator.

Methodology matches tb_fidelity_benchmark.v:
  - Feedback chain: state feeds back into the next step
  - Hardware paths re-quantize (nfe_enc) the state EVERY step -> error compounds
  - Golden FP64 chain never re-encodes -> the independent second source
  - Divergence is tracked per cycle; saturation/floor events are counted

Difference from the TB: the chain step is a full 8x8 matvec (y <- A.y),
not a scalar ADD, because the open questions (matvec breakeven, block
scaling on chains) live at the matvec level.

Three spectral regimes control where the chain drifts:
  contractive : row sums ~0.9  -> state shrinks, tests floor/UF drift
  neutral     : row sums ~1.0  -> state bounded, pure quantization compounding
  expansive   : row sums ~1.1  -> state grows, drives toward the OVF cliff
                                  (this regime re-tests saturation-vs-rollover)

Per chain, both hardware paths run to full depth:
  PATH_FAST : anchor-style full-mantissa MAC per element, state re-encoded
              to NFE at the end of each step (feedback re-quantization)
  PATH_NFE  : guarded NFE MUL per element (intermediate 6-bit quantization
              of every product), state re-encoded per step

Falsification rule applied per chain:
  Expansion (PATH_NFE) is accepted as "a thing" only if it survives LONGER
  than PATH_FAST before crossing the divergence cut (boundary moved) AND
  its final error is not catastrophically worse (stayed anchored).

Run: python3 second_source_chain.py [--depth 256] [--chains 100] [--tol 1.0]
"""

import argparse
import math
import random
from dataclasses import dataclass

N = 8
EXP_BIAS = 32
EXP_MAX = 63
E_ANCHOR_LO, E_ANCHOR_HI = 28, 35


@dataclass(frozen=True)
class NFE:
    s: int
    e: int
    f: int


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


def is_sat(w):
    return w.e == EXP_MAX and w.f == 63


def is_floor(w):
    return w.e == 0 and w.f == 0


def nfe_mul(a, b):
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


def nfe_fast_mac(a, b):
    P = (64 + a.f) * (64 + b.f)
    sign = -1.0 if (a.s ^ b.s) else 1.0
    return sign * math.ldexp(float(P), a.e + b.e - 76)


# ── Chain step for each track ───────────────────────────────────────────────
def step_golden(A_fp, y_fp):
    return [sum(A_fp[i][j] * y_fp[j] for j in range(N)) for i in range(N)]


def step_fast(A_nfe, y_nfe):
    """Full-mantissa MAC per element, then re-encode state (feedback quantize)."""
    out = []
    sat = floor = 0
    for i in range(N):
        acc = 0.0
        for j in range(N):
            acc += nfe_fast_mac(A_nfe[i][j], y_nfe[j])
        w = nfe_enc(acc)
        sat += is_sat(w)
        floor += is_floor(w)
        out.append(w)
    return out, sat, floor


def step_nfe(A_nfe, y_nfe):
    """Guarded NFE MUL per element (6-bit intermediate quantization), re-encode state."""
    out = []
    sat = floor = 0
    for i in range(N):
        acc = None
        for j in range(N):
            p = nfe_mul(A_nfe[i][j], y_nfe[j])
            acc = nfe_dec(p) if acc is None else acc + nfe_dec(p)
        w = nfe_enc(acc)
        sat += is_sat(w)
        floor += is_floor(w)
        out.append(w)
    return out, sat, floor


def vec_rel_err(y_nfe, y_fp):
    """Mean relative error of decoded state vs golden, ignoring zero golden entries."""
    errs = []
    for i in range(N):
        g = y_fp[i]
        if g != 0.0 and math.isfinite(g):
            errs.append(abs(nfe_dec(y_nfe[i]) - g) / abs(g) * 100.0)
    return sum(errs) / len(errs) if errs else float("inf")


# ── Instance generation ─────────────────────────────────────────────────────
def make_chain_instance(rng, regime):
    """A scaled so row sums hit the target spectral behavior; x in anchor zone."""
    target = {"contractive": 0.90, "neutral": 1.00, "expansive": 1.10}[regime]
    A_fp = [[rng.random() for _ in range(N)] for _ in range(N)]
    for i in range(N):
        rs = sum(A_fp[i])
        A_fp[i] = [a / rs * target for a in A_fp[i]]
    # initial state: continuous values with actual_E in anchor band
    x_fp = [(1.0 + rng.random()) * math.ldexp(1.0, rng.randint(E_ANCHOR_LO, E_ANCHOR_HI) - EXP_BIAS)
            for _ in range(N)]
    A_nfe = [[nfe_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]
    x_nfe = [nfe_enc(v) for v in x_fp]
    return A_fp, x_fp, A_nfe, x_nfe


@dataclass
class ChainResult:
    regime: str
    onset_fast: int      # first cycle mean rel err > tol (or depth+1 if never)
    onset_nfe: int
    final_err_fast: float
    final_err_nfe: float
    sat_fast: int
    sat_nfe: int
    floor_fast: int
    floor_nfe: int
    golden_overflowed: bool
    falsified: bool      # expansion (PATH_NFE) rejected by the rule?


def run_chain(rng, regime, depth, tol):
    A_fp, x_fp, A_nfe, x_nfe = make_chain_instance(rng, regime)

    y_g = list(x_fp)
    y_f = list(x_nfe)
    y_n = list(x_nfe)

    onset_f = onset_n = depth + 1
    sat_f = sat_n = floor_f = floor_n = 0
    golden_ovf = False
    err_f = err_n = 0.0

    for t in range(1, depth + 1):
        y_g = step_golden(A_fp, y_g)
        if any(not math.isfinite(v) or abs(v) > 1e300 for v in y_g):
            golden_ovf = True
            break

        y_f, s, fl = step_fast(A_nfe, y_f)
        sat_f += s
        floor_f += fl

        y_n, s, fl = step_nfe(A_nfe, y_n)
        sat_n += s
        floor_n += fl

        err_f = vec_rel_err(y_f, y_g)
        err_n = vec_rel_err(y_n, y_g)
        if onset_f > depth and err_f > tol:
            onset_f = t
        if onset_n > depth and err_n > tol:
            onset_n = t

    # Falsification: expansion (PATH_NFE) is "a thing" only if it survives
    # longer (boundary moved) and doesn't end catastrophically worse (anchored).
    moved = onset_n > onset_f
    anchored = err_n <= max(err_f * 2.0, tol)
    falsified = not (moved and anchored)

    return ChainResult(regime, onset_f, onset_n, err_f, err_n,
                       sat_f, sat_n, floor_f, floor_n, golden_ovf, falsified)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--depth", type=int, default=256)
    ap.add_argument("--chains", type=int, default=100, help="chains per regime")
    ap.add_argument("--tol", type=float, default=1.0, help="divergence cut, mean rel err %%")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    regimes = ["contractive", "neutral", "expansive"]

    print(f"\nDeep-chain second-source validator")
    print(f"  depth={args.depth}  chains/regime={args.chains}  cut={args.tol}% mean rel err")
    print("=" * 78)

    for regime in regimes:
        results = [run_chain(rng, regime, args.depth, args.tol) for _ in range(args.chains)]
        nc = len(results)

        def avg(xs):
            xs = [x for x in xs if x is not None]
            return sum(xs) / len(xs) if xs else float("nan")

        never_f = sum(r.onset_fast > args.depth for r in results)
        never_n = sum(r.onset_nfe > args.depth for r in results)
        n_fals = sum(r.falsified for r in results)
        n_g_ovf = sum(r.golden_overflowed for r in results)

        print(f"\nRegime: {regime}  ({nc} chains)")
        print(f"  divergence onset (first cycle > cut), mean:")
        print(f"    PATH_FAST : {avg([min(r.onset_fast, args.depth+1) for r in results]):7.1f}"
              f"   (never diverged: {never_f}/{nc})")
        print(f"    PATH_NFE  : {avg([min(r.onset_nfe, args.depth+1) for r in results]):7.1f}"
              f"   (never diverged: {never_n}/{nc})")
        print(f"  final mean rel err:")
        print(f"    PATH_FAST : {avg([r.final_err_fast for r in results]):9.4f}%")
        print(f"    PATH_NFE  : {avg([r.final_err_nfe for r in results]):9.4f}%")
        print(f"  saturation events / chain:  FAST {avg([r.sat_fast for r in results]):7.1f}"
              f"   NFE {avg([r.sat_nfe for r in results]):7.1f}")
        print(f"  floor events / chain:       FAST {avg([r.floor_fast for r in results]):7.1f}"
              f"   NFE {avg([r.floor_nfe for r in results]):7.1f}")
        if n_g_ovf:
            print(f"  golden chains that overflowed FP64 range: {n_g_ovf} (chain truncated there)")
        print(f"  FALSIFICATION: expansion to PATH_NFE rejected on {n_fals}/{nc} chains"
              f"  ({100*n_fals/nc:.0f}%)")


if __name__ == "__main__":
    main()
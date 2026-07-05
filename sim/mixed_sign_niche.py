#!/usr/bin/env python3
"""
sim/mixed_sign_niche.py — Task 1: Mixed-sign Hopfield stress test.

Tests whether NFE-13's wider dynamic range helps in a genuinely mixed-sign
workload (Hebbian weight matrix has entries {-3/N, -1/N, +1/N, +3/N}).

Methodology: same 64-neuron, 3-pattern Hopfield network as hopfield_demo.py.
Scale weights by λ ∈ {1, 4, 16, 64, 256}.  Four format conditions:
  NFE-13 bare, E4M3 bare, NFE-13+norm, E4M3+norm.
"norm" = W re-grounded to max ≈ 1.0 in format before running network.
"bare" = W encoded at raw λ scale.
Battery: 120 cases (3 patterns × 2 corruption levels × 20 LFSR seeds).
Seeds, patterns, and corruption algorithm match hopfield_demo.py exactly.

Per-λ metrics: retrieval_rate, pos_sat_count, neg_sat_count.
Saturation events counted by encoding the row-sum (pre-sign field) in format
— this makes the mechanism visible even though sign() absorbs same-sign sat.

Pre-registered observation: because sign(α·x) = sign(x) for any α > 0,
re-grounding the field vector before sign() cannot change the retrieval
outcome.  Norm and bare conditions differ only in whether the encoded W
precision changes with λ.  This is verified in the output.
"""

import csv, math, os, random, sys
import numpy as np

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)
from format_zoo import (
    nfe_enc, nfe_dec, nfe_mul_fields,
    fp8_e4m3_enc, fp8_e4m3_dec, fp8_e4m3_mul,
    bf16_enc, bf16_dec,
    BITS,
)
from recurrent_niche import (
    nfe_reground, fp8_e4m3_reground,
    N as CHAIN_N,
)

# ── Constants (must match hopfield_demo.py exactly) ───────────────────────────
N_NEURONS   = 64
NB          = 8
K_PATTERNS  = 3
MAX_ITERS   = 32
N_TRIALS    = 20
FLIP_LEVELS = [8, 13]
CORRUPT_SEED_BASE = 0xBEEFCAFE
SEED_RNG          = 0xDEADC0DE   # for this script; chains use different seeds

# ── LFSR (matches hopfield_demo.py / norm_interval_sweep.py) ─────────────────
def _lfsr_step(s):
    bit = ((s >> 31) ^ (s >> 21) ^ (s >> 1) ^ s) & 1
    return ((s << 1) & 0xFFFFFFFF) | bit

def _lfsr_frac(s):
    return ((s >> 8) & 0xFFFFFF) / 16777216.0

# ── Patterns (copied from hopfield_demo.py verbatim) ─────────────────────────
_PATTERN_H = [
    [ 1,-1,-1,-1,-1,-1,-1, 1], [ 1,-1,-1,-1,-1,-1,-1, 1],
    [ 1,-1,-1,-1,-1,-1,-1, 1], [ 1, 1, 1, 1, 1, 1, 1, 1],
    [ 1,-1,-1,-1,-1,-1,-1, 1], [ 1,-1,-1,-1,-1,-1,-1, 1],
    [ 1,-1,-1,-1,-1,-1,-1, 1], [ 1,-1,-1,-1,-1,-1,-1, 1],
]
_PATTERN_T = [
    [ 1, 1, 1, 1, 1, 1, 1, 1], [-1,-1,-1, 1,-1,-1,-1,-1],
    [-1,-1,-1, 1,-1,-1,-1,-1], [-1,-1,-1, 1,-1,-1,-1,-1],
    [-1,-1,-1, 1,-1,-1,-1,-1], [-1,-1,-1, 1,-1,-1,-1,-1],
    [-1,-1,-1, 1,-1,-1,-1,-1], [-1,-1,-1, 1,-1,-1,-1,-1],
]
_PATTERN_X = [
    [ 1,-1,-1,-1,-1,-1,-1, 1], [-1, 1,-1,-1,-1,-1, 1,-1],
    [-1,-1, 1,-1,-1, 1,-1,-1], [-1,-1,-1, 1, 1,-1,-1,-1],
    [-1,-1,-1, 1, 1,-1,-1,-1], [-1,-1, 1,-1,-1, 1,-1,-1],
    [-1, 1,-1,-1,-1,-1, 1,-1], [ 1,-1,-1,-1,-1,-1,-1, 1],
]
PATTERNS = [[v for row in p2d for v in row]
            for p2d in [_PATTERN_H, _PATTERN_T, _PATTERN_X]]

# ── Hebbian weights (mixed-sign, inherently) ─────────────────────────────────
def _build_weights_raw():
    """W_ij = Σ_k p_k[i]*p_k[j] / N, zero diagonal.  Values ∈ {-3/N,-1/N,+1/N,+3/N}."""
    N = N_NEURONS
    W = [0.0] * (N * N)
    for p in PATTERNS:
        for i in range(N):
            for j in range(N):
                if i != j:
                    W[i * N + j] += p[i] * p[j] / N
    return W


def _weight_sign_stats(W):
    pos = sum(1 for v in W if v > 0)
    neg = sum(1 for v in W if v < 0)
    zer = sum(1 for v in W if v == 0)
    return pos, neg, zer


# ── Per-format encode / decode (single value, no INT8 for Hopfield) ───────────
def _enc1(v, fmt):
    if fmt == "NFE-13":    return nfe_enc(v)
    if fmt == "FP8-E4M3":  return fp8_e4m3_enc(v)
    raise ValueError(fmt)


def _dec1(cw, fmt):
    if fmt == "NFE-13":
        return nfe_dec(*cw)
    if fmt == "FP8-E4M3":
        return fp8_e4m3_dec(cw)
    raise ValueError(fmt)


def _is_max_finite(cw, fmt):
    """True if the codeword represents ±max-finite for this format."""
    if fmt == "NFE-13":
        s, e, f = cw
        return e == 63 and f == 63
    if fmt == "FP8-E4M3":
        return (cw & 0x7F) == 0x7E    # abs-max codeword = 0x7E (= 448)
    return False


# ── Encode weight matrix in format (bare or norm) ────────────────────────────
def _encode_W(W_raw, lam, fmt, norm):
    """Scale W by λ, encode in format.  If norm=True, lossless-shift to max≈1."""
    W_scaled = [v * lam for v in W_raw]
    W_enc = [_enc1(v, fmt) for v in W_scaled]
    if norm:
        # Lossless block-exponent shift on the entire flat weight vector
        if fmt == "NFE-13":
            W_enc = nfe_reground(W_enc)
        elif fmt == "FP8-E4M3":
            W_enc = fp8_e4m3_reground(W_enc)
    return W_enc


# ── Hopfield update step in format ────────────────────────────────────────────
def _hopfield_step(W_enc, s, fmt):
    """One synchronous update.  Returns (new_s, pos_sat, neg_sat).
    Field accumulated in FP64.  Field also encoded in format for sat counting
    (mechanism visible; sign() applied to FP64 field, so sat does NOT affect outcome).
    """
    N = N_NEURONS
    pos_sat = neg_sat = 0
    new_s = []
    for i in range(N):
        acc = sum(_dec1(W_enc[i * N + j], fmt) * s[j] for j in range(N))
        # Encode row-sum for saturation counting (does not affect sign())
        acc_cw = _enc1(acc, fmt)
        if _is_max_finite(acc_cw, fmt):
            if acc >= 0:
                pos_sat += 1
            else:
                neg_sat += 1
        new_s.append(1 if acc >= 0.0 else -1)
    return new_s, pos_sat, neg_sat


# ── Corruption (matches hopfield_demo.py corrupt_pattern exactly) ─────────────
def _corrupt(pattern, n_flip, seed):
    p = list(pattern)
    lfsr = seed & 0xFFFFFFFF
    avail = list(range(len(p)))
    avail_len = len(p)
    for _ in range(n_flip):
        lfsr = _lfsr_step(lfsr)
        pos = int(_lfsr_frac(lfsr) * avail_len)
        if pos >= avail_len:
            pos = avail_len - 1
        idx = avail[pos]
        p[idx] = -p[idx]
        avail[pos] = avail[avail_len - 1]
        avail_len -= 1
    return p


def _nearest_pattern(s):
    dists = [sum(1 for x, y in zip(s, p) if x != y) for p in PATTERNS]
    k = min(range(K_PATTERNS), key=lambda i: dists[i])
    return k, dists[k]


# ── Run 120-case battery ──────────────────────────────────────────────────────
def _run_battery(W_enc, fmt):
    """Returns (retrieval_rate, total_pos_sat, total_neg_sat)."""
    correct = total = 0
    total_pos = total_neg = 0
    for ki, pat in enumerate(PATTERNS):
        for flip in FLIP_LEVELS:
            for trial in range(N_TRIALS):
                seed = CORRUPT_SEED_BASE ^ (ki * 0x1000 + flip * 0x100 + trial)
                s0 = _corrupt(pat, flip, seed)
                s = list(s0)
                for _ in range(MAX_ITERS):
                    s_new, ps, ns = _hopfield_step(W_enc, s, fmt)
                    total_pos += ps
                    total_neg += ns
                    if s_new == s:
                        break
                    s = s_new
                nearest, hd = _nearest_pattern(s)
                if nearest == ki and hd == 0:
                    correct += 1
                total += 1
    return correct / total, total_pos, total_neg


# ── Task 1 main ───────────────────────────────────────────────────────────────
LAMBDAS    = [1, 4, 16, 64, 256]
CONDITIONS = [
    ("NFE-13",   "NFE-13 bare",  False),
    ("NFE-13",   "NFE-13+norm",  True),
    ("FP8-E4M3", "E4M3 bare",    False),
    ("FP8-E4M3", "E4M3+norm",    True),
]


def run_task1(verbose=False):
    W_raw = _build_weights_raw()
    pos, neg, zer = _weight_sign_stats(W_raw)
    n_off_diag = N_NEURONS * (N_NEURONS - 1)
    print(f"  Weight matrix ({N_NEURONS}×{N_NEURONS}, {K_PATTERNS} patterns):")
    print(f"  Off-diagonal entries: {n_off_diag}  "
          f"positive: {pos} ({100*pos/n_off_diag:.1f}%)  "
          f"negative: {neg} ({100*neg/n_off_diag:.1f}%)  "
          f"zero: {zer}")
    vals = sorted(set(round(abs(v), 8) for v in W_raw if abs(v) > 1e-10))
    print(f"  Nonzero |weight| values: {[round(v,5) for v in vals]}")
    print()

    results = {}  # (lam, cond_name) → {rate, pos_sat, neg_sat}
    for lam in LAMBDAS:
        for fmt, cond_name, norm in CONDITIONS:
            W_enc = _encode_W(W_raw, lam, fmt, norm)
            rate, ps, ns = _run_battery(W_enc, fmt)
            results[(lam, cond_name)] = {
                "rate": rate, "pos_sat": ps, "neg_sat": ns
            }
            if verbose:
                print(f"  λ={lam:3d} {cond_name:<16s} "
                      f"recall={rate:.3f} +sat={ps:5d} -sat={ns:5d}")
    return results


def print_task1(results):
    print()
    print("Task 1 — Mixed-sign Hopfield retrieval (120-case battery)")
    print("  Saturation events: encoded row-sum at ±max_finite (does not affect sign()).")
    print(f"  {'λ':>5} | {'NFE-13 bare':>12} {'E4M3 bare':>10} "
          f"{'NFE-13+norm':>12} {'E4M3+norm':>10} | "
          f"{'E4M3 bare +sat':>15} {'E4M3+norm +sat':>15}")
    print("  " + "-" * 95)
    for lam in LAMBDAS:
        nb = results.get((lam,"NFE-13 bare"),{})
        eb = results.get((lam,"E4M3 bare"),{})
        nn = results.get((lam,"NFE-13+norm"),{})
        en = results.get((lam,"E4M3+norm"),{})
        same = "=" if abs(nb.get("rate",0)-eb.get("rate",0)) < 0.001 else "≠"
        print(f"  {lam:>5} | "
              f"{nb.get('rate',0):>12.3f} {eb.get('rate',0):>10.3f} "
              f"{nn.get('rate',0):>12.3f} {en.get('rate',0):>10.3f} | "
              f"{eb.get('pos_sat',0):>15d} {en.get('pos_sat',0):>15d}  {same}")
    print()
    # Verify sign-invariance of norm (pre-registered observation)
    print("  Sign-invariance check (norm = bare for Hopfield?):")
    for lam in LAMBDAS:
        nb_rate = results.get((lam,"NFE-13 bare"),{}).get("rate",0)
        nn_rate = results.get((lam,"NFE-13+norm"),{}).get("rate",0)
        eb_rate = results.get((lam,"E4M3 bare"),{}).get("rate",0)
        en_rate = results.get((lam,"E4M3+norm"),{}).get("rate",0)
        print(f"    λ={lam:3d}: NFE bare={nb_rate:.3f} norm={nn_rate:.3f} {'SAME' if abs(nb_rate-nn_rate)<0.001 else 'DIFF'}  "
              f"E4M3 bare={eb_rate:.3f} norm={en_rate:.3f} {'SAME' if abs(eb_rate-en_rate)<0.001 else 'DIFF'}")
    print()


def save_task1_csv(results, path):
    rows = []
    for (lam, cond), v in results.items():
        rows.append({"lam": lam, "cond": cond, **v})
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["lam","cond","rate","pos_sat","neg_sat"])
        w.writeheader(); w.writerows(rows)
    print(f"Task 1 raw data → {path}")


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--out", default=os.path.join(DIR, "MIXED_SIGN_T1_RAW.csv"))
    args = ap.parse_args()

    print("Task 1: Mixed-sign Hopfield stress test…", flush=True)
    r1 = run_task1(args.verbose)
    print("  done.")
    print_task1(r1)
    save_task1_csv(r1, args.out)


if __name__ == "__main__":
    main()

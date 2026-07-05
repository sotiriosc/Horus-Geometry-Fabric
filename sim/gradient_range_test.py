#!/usr/bin/env python3
"""
sim/gradient_range_test.py — Task 2: Gradient-signal proxy for mixed-sign range.

Hypothesis: when gradients span many orders of magnitude (heavy-tailed,
mixed-sign), NFE-13's wider representable range [~4.7e-10, 4.3e9] preserves
small-magnitude contributions that E4M3 [~2e-3, 448] and even E5M2 [~6e-5,
57344] lose after re-grounding, causing sign errors in accumulated sums.

Experiment:
  For each dynamic-range setting R ∈ {10^2, 10^4, 10^6, 10^8, 10^10}:
    Generate N_TRIALS=1000 gradient sequences of 256 steps.
    Each gradient: magnitude = R^u, u ~ Uniform[0,1], sign ~ uniform {±1}.
    Normalize all magnitudes to [1/R, 1.0] (divide by max magnitude).
    Run 256-step accumulate-and-requantize chain in each format condition:
      bare: encode s_t = q(s_{t-1} + g_t)    (no re-grounding)
      norm: encode + reground s_t after each step
    FP64 reference: exact sum of all 256 gradients.

Six format conditions (per task spec; E5M2 must appear):
  NFE-13 bare, NFE-13+norm, FP8-E4M3 bare, FP8-E4M3+norm,
  FP8-E5M2 bare, FP8-E5M2+norm.

Metrics (per R per condition):
  mean_relerr : mean |sum_fmt - sum_fp64| / max(|sum_fp64|, floor) over trials
  sign_flip   : fraction of trials where sign(sum_fmt) ≠ sign(sum_fp64)
                (trials where |sum_fp64| < 1e-4 × R excluded as ambiguous)

Min representable relative values (analytic, after re-grounding to max=1):
  NFE-13   : 2^(1-32) ≈ 4.7×10^-10   (6-bit mantissa, 31-bit exponent range)
  FP8-E4M3 : ~2^(-9)  ≈ 0.002        (3-bit mantissa, denorm min)
  FP8-E5M2 : ~2^(-14) ≈ 6.1×10^-5   (2-bit mantissa, 5-bit exponent)

Predicted sign-flip onset (re-grounding active):
  E4M3+norm  : R > ~500   (1/R < 0.002 min_rel)
  E5M2+norm  : R > ~16000 (1/R < 6.1e-5 min_rel)
  NFE-13+norm: R > ~2e9   (effectively never in this test)

Pre-registered niche criterion: NFE-13+norm must show fewer sign flips than
E4M3+norm AND E5M2+norm.  Beating bare E4M3 alone is a footnote only.
"""

import csv, math, os, random, sys
import numpy as np

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)
from format_zoo import (
    nfe_enc, nfe_dec,
    fp8_e4m3_enc, fp8_e4m3_dec,
    fp8_e5m2_enc, fp8_e5m2_dec,
    BITS,
)
from recurrent_niche import (
    nfe_reground, fp8_e4m3_reground, fp8_e5m2_reground,
)

SEED_GRAD   = 0xA1B2C3D4
N_TRIALS    = 1000
N_STEPS     = 256
DYN_RANGES  = [1e2, 1e4, 1e6, 1e8, 1e10]
# Exclude trial if |fp64_sum| < AMBIG_ABS.
# FP64 sum std ≈ sqrt(N_STEPS) × 1/sqrt(2 ln R) for log-uniform [1/R,1].
# At R=10^10 that is ≈ 16 × 0.10 ≈ 1.6 — use 0.1 so almost nothing is excluded.
AMBIG_ABS   = 0.1

# Analytic min relative values (after re-grounding to max=1)
MIN_REL = {
    "NFE-13":   2**(-31),       # e=1, f=0: 2^(1-32)
    "FP8-E4M3": 2**(-9),        # subnormal: 2^(-6) × 1/8 = 2^(-9)
    "FP8-E5M2": 2**(-14),       # subnormal: 2^(-14)
}

# ── Encode / decode / reground (scalar, for accumulator) ─────────────────────
def _enc(v, fmt):
    if fmt == "NFE-13":   return nfe_enc(v)
    if fmt == "FP8-E4M3": return fp8_e4m3_enc(v)
    if fmt == "FP8-E5M2": return fp8_e5m2_enc(v)
    raise ValueError(fmt)


def _dec(cw, fmt):
    if fmt == "NFE-13":   return nfe_dec(*cw)
    if fmt == "FP8-E4M3": return fp8_e4m3_dec(cw)
    if fmt == "FP8-E5M2":
        v = fp8_e5m2_dec(cw)
        return v if math.isfinite(v) else 0.0
    raise ValueError(fmt)


def _rg(cw_list, fmt):
    """Lossless re-ground a 1-element list (scalar accumulator as list)."""
    if fmt == "NFE-13":   return nfe_reground(cw_list)
    if fmt == "FP8-E4M3": return fp8_e4m3_reground(cw_list)
    if fmt == "FP8-E5M2": return fp8_e5m2_reground(cw_list)
    raise ValueError(fmt)


# ── Generate gradient sequence ────────────────────────────────────────────────
def _make_grads(R, rng):
    """256 gradients, log-uniform mag in [1/R, 1], random sign."""
    mags   = [R ** (rng.random() - 1.0) for _ in range(N_STEPS)]  # R^(u-1)
    signs  = [1 if rng.random() < 0.5 else -1 for _ in range(N_STEPS)]
    return [m * sg for m, sg in zip(mags, signs)]


# ── Single trial in one format condition ─────────────────────────────────────
def _is_max_finite(cw, fmt):
    """True if codeword is at the format's maximum finite value (any sign)."""
    if fmt == "NFE-13":   return cw[1] == 63 and cw[2] == 63
    if fmt == "FP8-E4M3": return (cw & 0x7F) == 0x7E
    if fmt == "FP8-E5M2": return (cw & 0x7F) == ((30 << 2) | 3)
    return False


def _run_trial(grads, fmt, norm):
    """Returns accumulated sum in format after 256 steps.

    bare: encode s_t = q(s_{t-1} + g_t)  — no re-grounding.
    norm: same, but re-ground only when the encoded running sum reaches
          max-finite (overflow-triggered re-grounding).  The decoded value
          is the format's best estimate of the absolute running total.
          This preserves the absolute scale between re-groundings and only
          normalises to prevent saturation-clipping, which is the correct
          analogue of the recurrent-chain norm condition for an accumulator.
    """
    acc = [_enc(0.0, fmt)]

    for g in grads:
        v   = _dec(acc[0], fmt) + g
        acc = [_enc(v, fmt)]
        if norm and _is_max_finite(acc[0], fmt):
            acc = _rg(acc, fmt)   # re-ground only at overflow

    return _dec(acc[0], fmt)


# ── Batch run ─────────────────────────────────────────────────────────────────
FORMATS_T2 = ["NFE-13", "FP8-E4M3", "FP8-E5M2"]
CONDITIONS_T2 = []
for _f in FORMATS_T2:
    CONDITIONS_T2.append((_f, f"{_f} bare",  False))
    CONDITIONS_T2.append((_f, f"{_f}+norm",  True))


def run_task2(verbose=False):
    results = {}  # (R, cond_name) → {mean_relerr, sign_flip, n_valid}

    for R in DYN_RANGES:
        rng = random.Random(SEED_GRAD ^ int(math.log10(R) * 100))

        # Pre-generate gradients (same for all conditions)
        grad_seqs = [_make_grads(R, rng) for _ in range(N_TRIALS)]
        fp64_sums = [sum(g) for g in grad_seqs]

        for fmt, cond_name, norm in CONDITIONS_T2:
            rel_errs   = []
            sign_flips = 0
            n_valid    = 0

            for trial, (grads, fp64_sum) in enumerate(zip(grad_seqs, fp64_sums)):
                fmt_sum = _run_trial(grads, fmt, norm)

                # Exclude ambiguous trials (fp64 sum too close to zero)
                if abs(fp64_sum) < AMBIG_ABS:
                    continue
                n_valid += 1

                denom = abs(fp64_sum)
                rel_errs.append(abs(fmt_sum - fp64_sum) / denom)

                if (fmt_sum >= 0) != (fp64_sum >= 0):
                    sign_flips += 1

            results[(R, cond_name)] = {
                "mean_relerr": sum(rel_errs) / len(rel_errs) if rel_errs else float('nan'),
                "sign_flip":   sign_flips / n_valid if n_valid > 0 else float('nan'),
                "n_valid":     n_valid,
            }
            if verbose:
                r = results[(R, cond_name)]
                print(f"  R=10^{round(math.log10(R),0):.0f}  {cond_name:<18s} "
                      f"relerr={r['mean_relerr']:.4f}  "
                      f"sign_flip={r['sign_flip']:.4f}  "
                      f"n_valid={r['n_valid']}")

    return results


def print_task2(results):
    print()
    print("Task 2 — Gradient-range test: relative error and sign-flip fraction")
    print(f"  {N_TRIALS} trials × {N_STEPS} steps per (R, format).  "
          f"Ambiguous trials (|fp64_sum| < {AMBIG_ABS}) excluded.")
    print()

    # Sign-flip table
    print("  Sign-flip fraction (lower is better):")
    col_hdr = "".join(f" {c[1]:>16s}" for c in CONDITIONS_T2)
    print(f"  {'R':>10s} |{col_hdr}")
    print("  " + "-" * (12 + 17 * len(CONDITIONS_T2)))
    for R in DYN_RANGES:
        rlog = round(math.log10(R))
        row = "".join(
            f" {results.get((R, c[1]), {}).get('sign_flip', float('nan')):>16.4f}"
            for c in CONDITIONS_T2
        )
        print(f"  10^{rlog:<7d} |{row}")

    print()
    # Relative error table
    print("  Mean relative error (lower is better):")
    print(f"  {'R':>10s} |{col_hdr}")
    print("  " + "-" * (12 + 17 * len(CONDITIONS_T2)))
    for R in DYN_RANGES:
        rlog = round(math.log10(R))
        row = "".join(
            f" {results.get((R, c[1]), {}).get('mean_relerr', float('nan')):>16.4f}"
            for c in CONDITIONS_T2
        )
        print(f"  10^{rlog:<7d} |{row}")

    print()
    # Pivotal comparison summary
    print("  Pivotal: NFE-13+norm vs E4M3+norm vs E5M2+norm sign-flip fraction:")
    print(f"  {'R':>10s} | {'NFE-13+norm':>14} {'E4M3+norm':>14} "
          f"{'E5M2+norm':>14} | verdict")
    print("  " + "-" * 70)
    for R in DYN_RANGES:
        rlog = round(math.log10(R))
        nfe  = results.get((R, "NFE-13+norm"),   {}).get("sign_flip", float('nan'))
        e4m3 = results.get((R, "FP8-E4M3+norm"), {}).get("sign_flip", float('nan'))
        e5m2 = results.get((R, "FP8-E5M2+norm"), {}).get("sign_flip", float('nan'))
        if math.isnan(nfe) or math.isnan(e4m3) or math.isnan(e5m2):
            verdict = "N/A"
        elif nfe < e4m3 and nfe < e5m2:
            verdict = "NFE-13 WINS"
        elif nfe < e4m3 or nfe < e5m2:
            verdict = "NFE-13 partial"
        else:
            verdict = "no advantage"
        print(f"  10^{rlog:<7d} | {nfe:>14.4f} {e4m3:>14.4f} {e5m2:>14.4f} | {verdict}")
    print()


def save_task2_csv(results, path):
    rows = []
    for (R, cond), v in results.items():
        rows.append({"R": R, "log10R": round(math.log10(R)), "cond": cond, **v})
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["R","log10R","cond",
                                          "mean_relerr","sign_flip","n_valid"])
        w.writeheader(); w.writerows(rows)
    print(f"Task 2 raw data → {path}")


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--out", default=os.path.join(DIR, "MIXED_SIGN_T2_RAW.csv"))
    args = ap.parse_args()

    print(f"Task 2: Gradient range test "
          f"({N_TRIALS} trials × {N_STEPS} steps × "
          f"{len(DYN_RANGES)} ranges × {len(CONDITIONS_T2)} conditions)…", flush=True)
    print(f"  Analytic min-rel predictions: "
          f"NFE-13 ≈{MIN_REL['NFE-13']:.1e}  "
          f"E4M3 ≈{MIN_REL['FP8-E4M3']:.1e}  "
          f"E5M2 ≈{MIN_REL['FP8-E5M2']:.1e}")
    r2 = run_task2(args.verbose)
    print("  done.")
    print_task2(r2)
    save_task2_csv(r2, args.out)


if __name__ == "__main__":
    main()

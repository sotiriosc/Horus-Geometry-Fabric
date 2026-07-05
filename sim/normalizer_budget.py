#!/usr/bin/env python3
"""
sim/normalizer_budget.py — Option-3 experiment: constrained or absent normalizer.

Hypothesis: when block-exponent normalization is infrequent or absent,
NFE-13's extra dynamic range (max ≈ 2^31 ≈ 4.3 billion) delays saturation
vs FP8-E4M3 (max = 448) and prevents NaN propagation vs FP8-E5M2.

Experiment:
  Expansive regime (row sums = 1.1) and neutral regime (row sums = 1.0),
  100 chains, 256 steps, k ∈ {∞, 32, 64, 128}, all 5 formats.
  Same LFSR-based seeds as format_zoo.py Arena B (SEED_CHAIN = 0xCAFEF00D).

Metrics per (format, regime, k):
  - mean_align   : mean cosine alignment at t=256
  - div_onset    : mean step at which alignment first drops below 0.90
                   (or 256+1 if it never drops)
  - frac_sat     : fraction of chains where any element is saturated at t=256
  - frac_inf_nan : fraction of chains with Inf/NaN in state at t=256

The "normalizer breakeven k" for a format pair is the smallest k where both
formats maintain alignment ≥ 0.90 at t=256.  Below that k all formats are
equivalent (as shown in recurrent_niche.py Task 1).

Dynamic range predictions (analytic):
  E4M3   max = 448     → saturation after ≈ log(448)/log(1.1) ≈  64 steps
  E5M2   max = 57344   → Inf           after ≈ log(57344)/log(1.1) ≈ 113 steps
  NFE-13 max ≈ 4.3e9   → saturation after ≈ log(4.3e9)/log(1.1) ≈ 222 steps
  BF16   max ≈ 3.4e38  → never in 256 steps
  INT8   implicit k=1  → not applicable (its scale is always recalibrated)

Predictions tested:
  P1  k=∞, expansive: NFE-13 alignment > E4M3 alignment at t=256
  P2  k=∞, expansive: div_onset(NFE-13) > div_onset(E4M3)  [≈3× longer]
  P3  k=∞, expansive: E5M2 generates Inf/NaN before E4M3 saturates
  P4  k=64, expansive: E4M3 alignment degrades; NFE-13 holds
  P5  k=32, expansive: all formats survive (normalizer rescues E4M3)
"""

import csv, math, os, random, sys
import numpy as np

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)
from format_zoo import (
    nfe_enc, nfe_dec, nfe_mul_fields, nfe_is_sat, nfe_is_floor,
    fp8_e4m3_enc, fp8_e4m3_dec, fp8_e4m3_mul,
    fp8_e5m2_enc, fp8_e5m2_dec, fp8_e5m2_mul,
    bf16_enc, bf16_dec, bf16_mul,
    int8_enc, int8_dec, int8_calibrate,
    BITS,
)
from recurrent_niche import (
    reground, enc, dec, matvec_step, enc_matrix, alignment,
    nfe_reground, fp8_e4m3_reground, fp8_e5m2_reground, bf16_reground,
    FORMATS, N,
)

SEED_CHAIN = 0xCAFEF00D
REGIMES    = ["neutral", "expansive"]
K_NOSYNC   = [None, 32, 64, 128]   # None = k=∞ (no normalization)
N_CHAINS   = 100
DEPTH      = 256
DIV_THRESH = 0.90   # alignment below this = "diverged"

# ── max representable value per format (analytic) ────────────────────────────
MAX_FIN = {
    "NFE-13":   (1.0 + 63/64) * 2**(63 - 32),   # ≈ 4.3e9
    "FP8-E4M3": 448.0,                            # OCP FP8 spec §3.2
    "FP8-E5M2": 57344.0,                          # OCP FP8 spec §3.3 (below Inf)
    "BF16":     3.389e38,                         # IEEE 754 bfloat16 max
    "INT8":     127.0,                            # symbolic; scale makes it ∞
}


def _make_chain(rng, regime):
    target = {"neutral": 1.0, "expansive": 1.1}[regime]
    A = [[rng.random() for _ in range(N)] for _ in range(N)]
    for i in range(N):
        rs = sum(A[i])
        A[i] = [a / rs * target for a in A[i]]
    x = [(1.0 + rng.random()) * math.ldexp(1.0, rng.randint(28, 35) - 32)
         for _ in range(N)]
    return A, x


def _has_inf_nan(y_enc, fmt, scale):
    """True if decoded vector contains any non-finite value."""
    if fmt == "INT8":
        return False   # INT8 always finite
    if fmt == "NFE-13":
        return False   # NFE never produces Inf/NaN by design
    d = dec(y_enc, fmt, scale)
    return any(not math.isfinite(v) for v in d)


def _any_saturated(y_enc, fmt):
    """True if any element is at the format's saturation value."""
    if fmt == "NFE-13":
        return any(e == 63 and f == 63 for s, e, f in y_enc)
    if fmt == "FP8-E4M3":
        return any((cw & 0x7F) == (15 << 3) | 6 for cw in y_enc)  # 0x7E / 0xFE
    if fmt == "FP8-E5M2":
        return any((cw & 0x7F) == (30 << 2) | 3 for cw in y_enc)  # max finite
    if fmt == "BF16":
        return any((cw & 0x7FFF) == (0xFE << 7) | 0x7F for cw in y_enc)
    return False   # INT8: scale recalibrates, never "saturates"


def run_budget(n_chains=N_CHAINS, depth=DEPTH, verbose=False):
    results = {}

    for regime in REGIMES:
        for k in K_NOSYNC:
            k_label = "inf" if k is None else str(k)
            for fmt in FORMATS:
                rng = random.Random(SEED_CHAIN ^ (hash(regime) & 0xFFFF)
                                    ^ (0 if k is None else k) * 0x7654321)
                aligns_final  = []
                div_onsets     = []
                sat_count      = 0
                infnan_count   = 0

                for _ in range(n_chains):
                    A_fp, x_fp = _make_chain(rng, regime)
                    A_np = np.array(A_fp)
                    y_g  = list(x_fp)

                    A_enc, sA = enc_matrix(A_fp, fmt)
                    y_enc, sy = enc(x_fp, fmt)
                    if k is not None:          # initial re-ground only if normalizer active
                        y_enc, sy = reground(y_enc, fmt, sy)

                    diverged     = False
                    div_onset_t  = depth + 1
                    golden_ovf   = False

                    for t in range(1, depth + 1):
                        y_g = list(A_np @ np.array(y_g))
                        if any(not math.isfinite(v) or abs(v) > 1e300 for v in y_g):
                            golden_ovf = True
                            break

                        y_enc, sy = matvec_step(A_enc, sA, y_enc, sy, fmt)

                        if k is not None and t % k == 0:
                            y_enc, sy = reground(y_enc, fmt, sy)

                        if not diverged:
                            d = dec(y_enc, fmt, sy)
                            if any(not math.isfinite(v) for v in d):
                                al = 0.0
                            else:
                                al = alignment(d, y_g)
                            if al < DIV_THRESH:
                                diverged = True
                                div_onset_t = t

                    if golden_ovf:
                        continue

                    d_final = dec(y_enc, fmt, sy)
                    if any(not math.isfinite(v) for v in d_final):
                        al_final = 0.0
                    else:
                        al_final = alignment(d_final, y_g)

                    aligns_final.append(al_final)
                    div_onsets.append(div_onset_t)

                    if _has_inf_nan(y_enc, fmt, sy):
                        infnan_count += 1
                    if _any_saturated(y_enc, fmt):
                        sat_count += 1

                n = len(aligns_final)
                results[(regime, k_label, fmt)] = {
                    "mean_align":   sum(aligns_final) / n if n else 0.0,
                    "div_onset":    sum(div_onsets) / n if n else 0.0,
                    "frac_sat":     sat_count / n if n else 0.0,
                    "frac_infnan":  infnan_count / n if n else 0.0,
                    "n":            n,
                }
                if verbose:
                    r = results[(regime, k_label, fmt)]
                    print(f"  {regime:10s} k={k_label:4s} {fmt:<12s} "
                          f"align={r['mean_align']:.4f} "
                          f"onset={r['div_onset']:5.1f} "
                          f"sat={r['frac_sat']:.2f} inf={r['frac_infnan']:.2f}")

    return results


def print_results(results):
    print()
    print("=" * 100)
    print("NORMALIZER BUDGET — RESULTS")
    print("=" * 100)
    print(f"  Divergence threshold: alignment < {DIV_THRESH}")
    print(f"  k=inf means no normalization at all.")
    print()

    for regime in REGIMES:
        for k in K_NOSYNC:
            k_label = "inf" if k is None else str(k)
            tag = f"{regime}, k={k_label}"
            print(f"  {tag}")
            print(f"  {'Format':<12} {'Bits':>4} | "
                  f"{'mean_align':>10} {'div_onset':>10} "
                  f"{'frac_sat':>9} {'frac_inf/nan':>12}")
            print("  " + "-" * 62)
            for fmt in FORMATS:
                r = results.get((regime, k_label, fmt), {})
                ma = r.get("mean_align",  float('nan'))
                do = r.get("div_onset",   float('nan'))
                fs = r.get("frac_sat",    float('nan'))
                fi = r.get("frac_infnan", float('nan'))
                print(f"  {fmt:<12} {BITS[fmt]:>4} | "
                      f"  {ma:>8.4f}   {do:>8.1f} "
                      f"  {fs:>7.3f}    {fi:>10.3f}")
            print()

    # Summary: breakeven k for expansive regime
    print()
    print("  BREAKEVEN ANALYSIS — expansive regime")
    print("  (smallest k where format alignment at t=256 stays ≥ 0.90)")
    print(f"  {'Format':<12} {'Bits':>4} | {'breakeven k':>12} {'max_representable':>20}")
    print("  " + "-" * 54)
    for fmt in FORMATS:
        breakeven = "never>0.90"
        for k in K_NOSYNC:
            k_label = "inf" if k is None else str(k)
            r = results.get(("expansive", k_label, fmt), {})
            if r.get("mean_align", 0.0) >= DIV_THRESH:
                breakeven = k_label
                break
        print(f"  {fmt:<12} {BITS[fmt]:>4} | {breakeven:>12} "
              f"  {MAX_FIN.get(fmt, 0.0):>18.3e}")

    # Pivotal comparison
    print()
    nfe_inf = results.get(("expansive","inf","NFE-13"), {})
    e4m_inf = results.get(("expansive","inf","FP8-E4M3"), {})
    e5m_inf = results.get(("expansive","inf","FP8-E5M2"), {})
    print("  Pivotal (expansive, k=inf):")
    print(f"    NFE-13   align={nfe_inf.get('mean_align',0):.4f}  "
          f"div_onset={nfe_inf.get('div_onset',0):.1f}  "
          f"frac_sat={nfe_inf.get('frac_sat',0):.3f}")
    print(f"    E4M3     align={e4m_inf.get('mean_align',0):.4f}  "
          f"div_onset={e4m_inf.get('div_onset',0):.1f}  "
          f"frac_sat={e4m_inf.get('frac_sat',0):.3f}")
    print(f"    E5M2     align={e5m_inf.get('mean_align',0):.4f}  "
          f"div_onset={e5m_inf.get('div_onset',0):.1f}  "
          f"frac_inf/nan={e5m_inf.get('frac_infnan',0):.3f}")
    onset_ratio = (nfe_inf.get('div_onset', 1) /
                   max(e4m_inf.get('div_onset', 1), 1))
    print(f"    onset ratio NFE-13 / E4M3 = {onset_ratio:.2f}×  "
          f"(predicted ≈ 3.5×)")
    print()


def save_csv(results, path):
    rows = []
    for (regime, k_label, fmt), v in results.items():
        rows.append({"regime": regime, "k": k_label, "fmt": fmt,
                     "bits": BITS[fmt], **v})
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["regime","k","fmt","bits",
                                          "mean_align","div_onset",
                                          "frac_sat","frac_infnan","n"])
        w.writeheader()
        w.writerows(rows)
    print(f"Raw data → {path}")


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--chains",  type=int, default=N_CHAINS)
    ap.add_argument("--depth",   type=int, default=DEPTH)
    ap.add_argument("--out",     default=os.path.join(DIR, "NORMALIZER_BUDGET_RAW.csv"))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    print(f"Normalizer-budget experiment "
          f"({args.chains} chains × {len(REGIMES)} regimes × "
          f"{len(K_NOSYNC)} k-values × {len(FORMATS)} formats)…", flush=True)
    results = run_budget(args.chains, args.depth, args.verbose)
    print("  done.")

    print_results(results)
    if args.out:
        save_csv(results, args.out)


if __name__ == "__main__":
    main()

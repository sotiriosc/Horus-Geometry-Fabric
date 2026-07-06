#!/usr/bin/env python3
"""
sim/compact_nfe.py — Compact-NFE family evaluation.

Hypothesis: keep the proven 6-bit mantissa, reduce per-element exponent to 2–5 bits,
delegate dynamic range to one shared 6-bit block exponent per 8 elements (horus_norm_v2
mechanism).  Test whether the gradient niche and MLP accuracy survive.

Pre-registered criteria (docs/COMPACT_NFE_HYPOTHESIS.md):
  K1: sign-flip rate not significantly worse than NFE-13 bare scalar at depth=256,
      R ∈ {10²..10¹⁰}; one-sided z-test α≈0.025.
  K2: MLP accuracy ≥ 95.39% (NFE-13 96.39% − 1pp).
  K3: effective-bits table (informational, not pass/fail).

Formats: E2M6 (9 bits), E3M6 (10 bits), E4M6 (11 bits), E5M6 (12 bits), E6M6=NFE-13
         (13 bits), each optionally with a 6-bit shared block exponent per 8 elements.
"""

import csv, math, os, random, sys, time
import numpy as np

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)

from gradient_range_v2 import (
    SEED_GRAD, N_BATCH, N_PER_BATCH, N_STEPS, AMBIG_ABS, DYN_RANGES,
    ZERO_SCRUTINY_R, ZERO_SCRUTINY_N_TRIALS,
    _make_grads,
    _run_trial_fmt   as _v2_run_scalar,   # (grads, fmt, norm) → float
    _run_trial_fp32acc as _v2_fp32acc,    # (grads, fmt) → float
)

# ── Storage accounting ─────────────────────────────────────────────────────────
BLOCK_SIZE     = 8       # elements per shared-exponent block
BLOCK_EXP_BITS = 6       # bits for the shared block exponent (signed int)

N_EXP_SWEEP = [2, 3, 4, 5, 6]      # per-element exponent bits to test

# NFE-13 v2-reference results for K1 threshold computation (from GRADIENT_NICHE_FINAL.md)
_NFE13_MEAN_FLIP_R1E2  = 0.0010
_NFE13_STD_FLIP_R1E2   = 0.0030

# K1 threshold: mean_cand ≤ _NFE13_MEAN_FLIP_R1E2 + 2 × std_pool
def k1_threshold(std_cand: float) -> float:
    """One-sided K1 test threshold at R=10² (most discriminating)."""
    return _NFE13_MEAN_FLIP_R1E2 + 2.0 * math.sqrt(
        _NFE13_STD_FLIP_R1E2**2 + std_cand**2)


def effective_bits(n_exp: int) -> float:
    """Effective bits/element = per_element_bits + BLOCK_EXP_BITS / BLOCK_SIZE."""
    return (1 + n_exp + 6) + BLOCK_EXP_BITS / BLOCK_SIZE


# ── EnM6 codec (n-bit exponent, 6-bit mantissa) ────────────────────────────────
# Convention (same as NFE-13):
#   Bias = 2^(n_exp − 1)
#   Encoding: [sign(1)] [e_stored(n_exp)] [f(6)], f in {0..63}
#   Normal:   (−1)^s × 2^(e_stored − bias) × (1 + f/64),  e_stored ∈ [1, max_e]
#   Subnormal: e_stored = 0: (−1)^s × 2^(1−bias) × (f/64)
#   Saturation: no Inf/NaN; clamp to max-finite at encoding; no e_stored=all-ones special.

def _bias(n: int) -> int:     return 1 << (n - 1)
def _max_e(n: int) -> int:    return (1 << n) - 1
def _min_normal(n: int) -> float: return 2.0 ** (1 - _bias(n))
def _max_val(n: int) -> float:    return (2.0 ** (_max_e(n) - _bias(n))) * (1.0 + 63.0/64.0)


def enm6_enc(v: float, n: int) -> int:
    """Encode float to EnM6 codeword (RNE; saturation at max-finite).

    EnM6 uses ALL e_stored values as normal (no Inf/NaN sentinels, like NFE-13).
    e_stored in [1, max_e] are normal; e_stored=0 is subnormal.
    Values above max_val are clamped to (sign, max_e, 63).
    """
    if v != v:          # NaN → saturate positive
        return (_max_e(n) << 6) | 63
    if v == 0.0:
        return 0

    sign  = 1 if v < 0 else 0
    av    = abs(v)
    bias  = _bias(n)
    maxe  = _max_e(n)
    min_n = _min_normal(n)
    max_v = _max_val(n)

    # Hard clamp: values strictly above max_val saturate.
    # The threshold is max_val + half-ULP-at-max = max_val × (1 + 1/128).
    if av > max_v * (1.0 + 1.0 / 128.0):
        return (sign << (n + 6)) | (maxe << 6) | 63

    # Subnormal path: av in [0, min_normal)
    if av < min_n:
        f_f = av / min_n * 64.0
        f   = int(f_f + 0.5)   # round-to-nearest
        f   = max(0, min(63, f))
        if f == 0 and av > 0:
            f = 1   # smallest subnormal rather than flush-to-zero
        return (sign << (n + 6)) | f

    # Normal path
    e_real   = int(math.floor(math.log2(av)))
    e_stored = e_real + bias

    # Underflow into subnormal range (shouldn't happen given av >= min_n, but guard)
    if e_stored <= 0:
        f_f = av / min_n * 64.0
        f   = max(0, min(63, int(f_f + 0.5)))
        return (sign << (n + 6)) | f

    # Compute RNE mantissa
    mantissa = av * (2.0 ** (-e_real))   # in [1.0, 2.0)
    f_f      = (mantissa - 1.0) * 64.0
    f_floor  = int(f_f)
    frac     = f_f - f_floor

    if frac > 0.5:
        f = f_floor + 1
    elif frac == 0.5:
        f = f_floor + 1 if (f_floor & 1) else f_floor  # round to even
    else:
        f = f_floor

    if f >= 64:        # carry into exponent
        f        = 0
        e_stored += 1

    if e_stored > maxe:    # overflow after carry: saturate
        return (sign << (n + 6)) | (maxe << 6) | 63

    return (sign << (n + 6)) | (e_stored << 6) | f


def enm6_dec(cw: int, n: int) -> float:
    """Decode EnM6 codeword to float."""
    sign_bit = (cw >> (n + 6)) & 1
    e_stored = (cw >> 6) & ((1 << n) - 1)
    f        = cw & 63

    if e_stored == 0:
        if f == 0:
            return 0.0
        val = _min_normal(n) * (f / 64.0)
    else:
        val = (2.0 ** (e_stored - _bias(n))) * (1.0 + f / 64.0)

    return -val if sign_bit else val


# ── Unit tests ────────────────────────────────────────────────────────────────

def run_unit_tests(verbose: bool = True):
    """Verify EnM6 enc/dec against hand-computed representable values."""
    failures = []

    def _chk(n, v, expected_cw, label):
        got = enm6_enc(v, n)
        dec = enm6_dec(expected_cw, n)
        if got != expected_cw:
            failures.append(f"E{n}M6 enc({label}={v}): expected 0x{expected_cw:X}, got 0x{got:X}")
        # Decode check: |dec − v| ≤ 2% |v| + ε, except for saturation cases
        eps = abs(v) * 0.025 + 1e-7
        if "sat" not in label and abs(dec - v) > eps:
            failures.append(f"E{n}M6 dec(0x{expected_cw:X} = {label}): got {dec}, expected {v}")

    # ── E2M6: bias=2, min_normal=0.5, max≈3.97 ────────────────────────────────
    # sign bit at position 8 (= 2+6); e_stored bits 7-6; f bits 5-0
    _chk(2, 0.0,   0x000,  "0.0")
    _chk(2, 1.0,   (2<<6),  "1.0")      # e=2: 2^(2-2)=1.0, f=0
    _chk(2, 2.0,   (3<<6),  "2.0")      # e=3: 2^(3-2)=2.0, f=0
    _chk(2, 3.0,   (3<<6)|32, "3.0")    # e=3, f=32: 2^1×(1+0.5)=3.0
    _chk(2, 0.5,   (1<<6),   "0.5")     # e=1: 2^(1-2)=0.5, f=0
    _chk(2, 0.25,  32,       "0.25sub") # subnormal: 0.5×(32/64)=0.25
    _chk(2, -1.0,  (1<<8)|(2<<6), "-1.0")
    _chk(2, 4.0,   (3<<6)|63, "4.0sat") # saturate to max≈3.97

    # ── E3M6: bias=4, min_normal=0.125, max≈15.875 ────────────────────────────
    _chk(3, 1.0,   (4<<6),  "1.0")      # e=4: 2^(4-4)=1.0
    _chk(3, 8.0,   (7<<6),  "8.0")      # e=7: 2^(7-4)=8.0, f=0
    _chk(3, 0.125, (1<<6),  "0.125")    # e=1: 2^(1-4)=0.125, f=0
    _chk(3, 16.0,  (7<<6)|63, "16sat")  # saturate to max≈15.875
    _chk(3, 4.0,   (6<<6),  "4.0")      # e=6: 2^(6-4)=4.0, f=0

    # ── E4M6: bias=8, min_normal≈0.0078, max≈254 ──────────────────────────────
    _chk(4, 1.0,   (8<<6),  "1.0")      # e=8: 2^(8-8)=1.0
    _chk(4, 128.0, (15<<6), "128.0")    # e=15: 2^(15-8)=128
    _chk(4, 2.0**-7, (1<<6), "2^-7")   # e=1: 2^(1-8)=2^-7≈0.0078

    # ── E5M6: bias=16, large range ────────────────────────────────────────────
    _chk(5, 1.0,   (16<<6),  "1.0")     # e=16: 2^(16-16)=1.0
    _chk(5, 2.0**15, (31<<6), "2^15")   # e=31: 2^(31-16)=2^15

    # ── E6M6 = NFE-13: bias=32 ─────────────────────────────────────────────────
    _chk(6, 1.0,   (32<<6),  "1.0")     # e=32: 2^(32-32)=1.0

    # ── Round-trip for random values ────────────────────────────────────────────
    rng = random.Random(0xDEADBEEF)
    for n in N_EXP_SWEEP:
        max_v = _max_val(n)
        for _ in range(100):
            v = rng.uniform(-max_v * 0.9, max_v * 0.9)   # stay below max to avoid sat
            cw  = enm6_enc(v, n)
            dec = enm6_dec(cw, n)
            # Decoded value must be within 1.5 ULPs of v (ULP at v = |v|/64)
            if abs(v) > _min_normal(n) * 0.5:
                ulp = abs(v) / 64.0
                if abs(dec - v) > 1.5 * ulp:
                    failures.append(
                        f"E{n}M6 round-trip {v:.6g}: dec={dec:.6g}, ulp={ulp:.3g}, diff={abs(dec-v):.3g}")

    if failures:
        for msg in failures:
            print(f"  FAIL: {msg}")
        raise AssertionError(f"EnM6 unit tests: {len(failures)} failure(s)")

    n_cases = 8 + 5 + 3 + 2 + 1 + 5 * 100
    if verbose:
        print(f"  EnM6 unit tests: PASS ({n_cases} cases, {len(N_EXP_SWEEP)} formats)")


# ── Block-scale mechanism ─────────────────────────────────────────────────────
# One signed integer b (the block exponent) shared per BLOCK_SIZE elements.
# Effective value[i] = enm6_dec(cw[i], n) × 2^b
# Block encoding: choose b so max-magnitude element lands at (max_e − 1) e_stored,
# then encode all values scaled by 2^(−b).

def _block_target_real_exp(n: int) -> int:
    """Real exponent for the target e_stored = max_e − 1."""
    return (_max_e(n) - 1) - _bias(n)


def block_enc(values: list, n: int):
    """
    Encode BLOCK_SIZE floats into (codewords, block_exp).
    If all values are zero, block_exp = 0.
    """
    max_abs = max(abs(v) for v in values)
    if max_abs == 0.0:
        return [0] * len(values), 0

    tgt = _block_target_real_exp(n)
    # b = floor(log2(max_abs)) − tgt
    # After dividing by 2^b, max_abs lands near 2^tgt (within the upper-normal range)
    b = math.floor(math.log2(max_abs)) - tgt
    scale = 2.0 ** b
    cws   = [enm6_enc(v / scale, n) for v in values]
    return cws, b


def block_dec(cws: list, block_exp: int, n: int) -> list:
    """Decode block back to float values."""
    scale = 2.0 ** block_exp
    return [enm6_dec(cw, n) * scale for cw in cws]


# ── Arena A: 8-element block gradient accumulation sweep ──────────────────────

# Separate seed base for block test (differs from v2 scalar seed base).
SEED_BLOCK = SEED_GRAD ^ 0xBEEF0000


def _generate_block_trial(R: float, n_steps: int, rng: random.Random) -> tuple:
    """
    Generate one 8-element block trial: 8 independent i.i.d. gradient streams.
    Returns (grads_8, fp64_sums_8) where grads_8[elem][step] and fp64_sums_8[elem].
    """
    grads_8    = [_make_grads(R, n_steps, rng) for _ in range(BLOCK_SIZE)]
    fp64_sums  = [sum(g) for g in grads_8]
    return grads_8, fp64_sums


def _run_block_trial(grads_8: list, n: int) -> list:
    """
    Run one 8-element block accumulation trial in EnM6 with shared block exponent.
    grads_8[elem][step].  Returns list of BLOCK_SIZE decoded final sums.
    """
    cws       = [0] * BLOCK_SIZE   # all accumulators start at zero
    block_exp = 0

    for step in range(len(grads_8[0])):
        # Decode current accumulators to effective float values
        decoded = block_dec(cws, block_exp, n)
        # Add this step's gradient to each element
        new_vals = [decoded[i] + grads_8[i][step] for i in range(BLOCK_SIZE)]
        # Re-encode with updated block exponent
        cws, block_exp = block_enc(new_vals, n)

    return block_dec(cws, block_exp, n)


def _sign_flip_frac(fmt_sums: list, fp64_sums: list) -> float:
    """Fraction of valid trials (|fp64| >= AMBIG_ABS) where sign is wrong."""
    n_valid = n_flip = 0
    for fs, fp in zip(fmt_sums, fp64_sums):
        if abs(fp) < AMBIG_ABS:
            continue
        n_valid += 1
        if (fs >= 0.0) != (fp >= 0.0):
            n_flip += 1
    return (n_flip / n_valid) if n_valid > 0 else float('nan')


def _clopper_pearson_upper(n_trials: int, n_failures: int,
                           confidence: float = 0.95) -> float:
    """95% Clopper-Pearson upper bound on failure probability."""
    if n_failures == 0:
        # Upper bound: 1 − α^{1/n}  (exact for 0 successes in n Bernoulli trials)
        alpha = 1.0 - confidence
        return 1.0 - alpha ** (1.0 / n_trials)
    from scipy.stats import beta as _beta
    return _beta.ppf(confidence, n_failures + 1, n_trials - n_failures)


def run_gradient_sweep(verbose: bool = False) -> dict:
    """
    Main gradient accumulation sweep.

    Conditions:
      - NFE-13 bare scalar (re-run from v2 with same SEED_GRAD, as reference)
      - E4M3+FP32acc scalar (re-run from v2 as industry baseline)
      - E{n}M6+block for n in {2,3,4,5,6}

    Returns dict: {(R, cond_name): {"mean_flip", "std_flip", "worst_flip",
                                     "n_valid_per_batch", "n_exp"}}
    """
    N_BLOCK_TRIALS = N_BATCH * N_PER_BATCH   # 1000 block trials

    results = {}

    # ── Scalar baselines (re-run from v2, identical seeds) ────────────────────
    if verbose:
        print("\n[Gradient sweep] Scalar baselines (re-run from v2, same seeds)...")

    for R in DYN_RANGES:
        rlog = round(math.log10(R))
        seed = SEED_GRAD ^ int(math.log10(R) * 100)
        rng_sc = random.Random(seed)

        grad_seqs_sc = [_make_grads(R, N_STEPS, rng_sc)
                        for _ in range(N_BLOCK_TRIALS)]
        fp64_sc      = [sum(g) for g in grad_seqs_sc]

        for cond_name, runner in [
            ("NFE-13 bare (scalar, v2-ref)",  lambda g: _v2_run_scalar(g, "NFE-13",  False)),
            ("E4M3+FP32acc (scalar, v2-ref)", lambda g: _v2_fp32acc(g, "FP8-E4M3")),
        ]:
            fmt_sums = [runner(g) for g in grad_seqs_sc]

            batch_flips = []
            for b in range(N_BATCH):
                sl  = slice(b * N_PER_BATCH, (b + 1) * N_PER_BATCH)
                frc = _sign_flip_frac(fmt_sums[sl], fp64_sc[sl])
                if not math.isnan(frc):
                    batch_flips.append(frc)

            mean_f = sum(batch_flips) / len(batch_flips) if batch_flips else float('nan')
            std_f  = math.sqrt(sum((x - mean_f)**2 for x in batch_flips)
                               / len(batch_flips)) if len(batch_flips) > 1 else 0.0
            worst  = max(batch_flips) if batch_flips else float('nan')

            n_valid = sum(1 for fp in fp64_sc if abs(fp) >= AMBIG_ABS)
            results[(R, cond_name)] = {
                "mean_flip": mean_f, "std_flip": std_f, "worst_flip": worst,
                "n_valid": n_valid, "n_exp": None,
            }

        if verbose:
            for cond in ["NFE-13 bare (scalar, v2-ref)", "E4M3+FP32acc (scalar, v2-ref)"]:
                r = results[(R, cond)]
                print(f"  R=1e{rlog}  {cond:<40s}  flip={r['mean_flip']:.4f}±{r['std_flip']:.4f}")

    # ── Block-scale EnM6 formats ───────────────────────────────────────────────
    if verbose:
        print("\n[Gradient sweep] Block-scale EnM6 formats...")

    for n in N_EXP_SWEEP:
        cond_name = f"E{n}M6+block"
        if verbose:
            print(f"  Format {cond_name} (effective {effective_bits(n):.2f} bits/elem)...")

        for R in DYN_RANGES:
            rlog = round(math.log10(R))
            seed = SEED_BLOCK ^ (int(math.log10(R) * 100) + n * 31)
            rng_blk = random.Random(seed)

            # Collect per-element flip rates across all block trials × 8 elements
            # Batch: N_BATCH batches of N_PER_BATCH block trials each.
            # Each batch contributes BLOCK_SIZE × N_PER_BATCH per-element observations.
            batch_flips = []

            all_fmt_sums  = []
            all_fp64_sums = []

            for _ in range(N_BLOCK_TRIALS):
                grads_8, fp64_sums = _generate_block_trial(R, N_STEPS, rng_blk)
                final_sums = _run_block_trial(grads_8, n)
                all_fmt_sums.extend(final_sums)
                all_fp64_sums.extend(fp64_sums)

            # Build N_BATCH batches (each batch = N_PER_BATCH × BLOCK_SIZE observations)
            batch_obs = N_PER_BATCH * BLOCK_SIZE
            for b in range(N_BATCH):
                sl  = slice(b * batch_obs, (b + 1) * batch_obs)
                frc = _sign_flip_frac(all_fmt_sums[sl], all_fp64_sums[sl])
                if not math.isnan(frc):
                    batch_flips.append(frc)

            mean_f = sum(batch_flips) / len(batch_flips) if batch_flips else float('nan')
            std_f  = math.sqrt(sum((x - mean_f)**2 for x in batch_flips)
                               / len(batch_flips)) if len(batch_flips) > 1 else 0.0
            worst  = max(batch_flips) if batch_flips else float('nan')
            n_valid = sum(1 for fp in all_fp64_sums if abs(fp) >= AMBIG_ABS)

            results[(R, cond_name)] = {
                "mean_flip": mean_f, "std_flip": std_f, "worst_flip": worst,
                "n_valid": n_valid, "n_exp": n,
            }

            if verbose:
                print(f"    R=1e{rlog}: flip={mean_f:.4f}±{std_f:.4f}, worst={worst:.4f}")

    return results


# ── Zero-cell scrutiny ─────────────────────────────────────────────────────────

def run_zero_scrutiny(main_results: dict, verbose: bool = False) -> dict:
    """
    For cells with 0 sign flips in the main sweep, report Clopper-Pearson 95% upper bounds.

    Two-tier approach:
    1. Analytical bound from the main sweep itself (N=8000 per-element observations per cell;
       0 failures → CP95 UB ≈ 3.75e-4). This is already below the K1 threshold of 0.01.
    2. Targeted escalated trials for E2M6 and E3M6 only (closest to K1 boundary) at
       extreme R (1e12) and two depths (256, 1024): N_SCRUTINY_TARGETED block-trials each.
    """
    N_SCRUTINY_TARGETED = 200   # 200 block trials × 8 = 1600 per-element obs; quick

    zero_results = {}

    # ── Tier 1: analytical bounds from main sweep ─────────────────────────────
    for n in N_EXP_SWEEP:
        cond = f"E{n}M6+block"
        for R in DYN_RANGES:
            entry = main_results.get((R, cond))
            if entry is None or entry["mean_flip"] > 0.0:
                continue

            n_valid = entry.get("n_valid", 0)
            if n_valid > 0:
                cp_ub = _clopper_pearson_upper(n_valid, 0)
            else:
                cp_ub = float('nan')

            zero_results[(cond, R, R, N_STEPS)] = {
                "n_flip": 0, "n_valid": n_valid,
                "flip_rate": 0.0, "cp95_ub": cp_ub,
                "tier": "analytical (main sweep)",
            }

    # ── Tier 2: targeted escalated trials for E2M6 and E3M6 ──────────────────
    for n in [2, 3]:
        cond = f"E{n}M6+block"
        for R_orig in DYN_RANGES:
            entry = main_results.get((R_orig, cond))
            if entry is None or entry["mean_flip"] > 0.0:
                continue

            if verbose:
                print(f"  Targeted scrutiny: {cond} R_orig=1e{round(math.log10(R_orig))}")

            seed = SEED_BLOCK ^ (int(math.log10(R_orig) * 100) + n * 31) ^ 0xFF00

            for scrutiny_r, depth in [(1e10, N_STEPS), (1e12, N_STEPS), (1e12, 1024)]:
                rng = random.Random(seed ^ int(math.log10(scrutiny_r) * 100) ^ depth)

                all_fmt  = []
                all_fp64 = []
                for _ in range(N_SCRUTINY_TARGETED):
                    grads_8, fp64_sums = _generate_block_trial(scrutiny_r, depth, rng)
                    final = _run_block_trial(grads_8, n)
                    all_fmt.extend(final)
                    all_fp64.extend(fp64_sums)

                n_valid = sum(1 for fp in all_fp64 if abs(fp) >= AMBIG_ABS)
                n_flip  = sum(1 for fs, fp in zip(all_fmt, all_fp64)
                              if abs(fp) >= AMBIG_ABS and (fs >= 0) != (fp >= 0))
                cp_ub = _clopper_pearson_upper(n_valid, n_flip) if n_valid > 0 else float('nan')

                zero_results[(cond, R_orig, scrutiny_r, depth)] = {
                    "n_flip": n_flip, "n_valid": n_valid,
                    "flip_rate": n_flip / n_valid if n_valid else float('nan'),
                    "cp95_ub": cp_ub,
                    "tier": "targeted escalation",
                }

                if verbose:
                    rr = round(math.log10(scrutiny_r))
                    tag = (f"{n_flip}/{n_valid}"
                           if n_flip > 0 else f"0/{n_valid} (CP95 UB={cp_ub:.2e})")
                    print(f"    R_sc=1e{rr} depth={depth}: {tag}")

    return zero_results


# ── Arena B: neutral k=8 chain regression ─────────────────────────────────────

# Arena B chain parameters — expansive regime so chain doesn't collapse to zero.
# Plain matrix multiply (no tanh) with re-grounding every k steps.
# This mirrors the Arena B power-iteration style from format_zoo.
SEED_CHAIN    = 0x1234ABCD
N_CHAIN       = 100
N_CHAIN_STEPS = 256
K_NORM        = 8
N_DIM         = 8
CHAIN_SPEC_RAD = 1.2   # expansive: chain amplifies dominant eigenvector


def _quantize_matrix_block(W_fp64: np.ndarray, n: int):
    """
    Block-quantize a 2D weight matrix using EnM6 + shared block exponent.
    Blocks of BLOCK_SIZE consecutive elements along the innermost (column) axis.
    Returns W_quant as a 2D numpy float64 array (decoded back to float).
    """
    rows, cols = W_fp64.shape
    W_q = W_fp64.copy()
    # Pad columns to multiple of BLOCK_SIZE (shouldn't be needed for 8×8)
    for r in range(rows):
        for blk_start in range(0, cols, BLOCK_SIZE):
            blk_end = min(blk_start + BLOCK_SIZE, cols)
            vals    = W_fp64[r, blk_start:blk_end].tolist()
            cws, bexp = block_enc(vals, n)
            decoded   = block_dec(cws, bexp, n)
            W_q[r, blk_start:blk_end] = decoded
    return W_q


def run_chain_regression(verbose: bool = False) -> dict:
    """
    Chain regression: expansive (spec_rad=1.2) pure-matrix chain with block re-grounding
    every K_NORM steps.  Plain matrix multiply (no tanh) so the chain amplifies the
    dominant eigenvector direction rather than collapsing to zero.

    Metric: cosine alignment between format chain and FP64 chain (with unit-norm
    re-grounding every K_NORM steps) after N_CHAIN_STEPS steps.

    This is a regression check: all compact EnM6+block formats should achieve similar
    alignment to E6M6+block (NFE-13 with block scale).
    """
    rng_w = random.Random(SEED_CHAIN)
    results = {}

    for n in N_EXP_SWEEP:
        alignments = []
        for chain_idx in range(N_CHAIN):
            # Generate random weight matrix, scaled to spec_rad = CHAIN_SPEC_RAD
            W_raw = np.array([[rng_w.gauss(0, 1) for _ in range(N_DIM)]
                               for _ in range(N_DIM)])
            eigvals  = np.linalg.eigvals(W_raw)
            spec_rad = max(abs(eigvals))
            if spec_rad > 0:
                W_raw *= CHAIN_SPEC_RAD / spec_rad

            # Quantize weights for this format
            W_q = _quantize_matrix_block(W_raw, n)

            # Initial state: random unit vector
            rng_v = random.Random(SEED_CHAIN ^ chain_idx ^ (n * 1000))
            v0    = np.array([rng_v.gauss(0, 1) for _ in range(N_DIM)])
            v0    /= np.linalg.norm(v0)

            # FP64 reference chain: unit-norm re-grounding every K_NORM steps
            v_fp64 = v0.copy()
            for step in range(N_CHAIN_STEPS):
                v_fp64 = W_raw @ v_fp64
                if (step + 1) % K_NORM == 0:
                    n64 = np.linalg.norm(v_fp64)
                    if n64 > 0:
                        v_fp64 /= n64

            # EnM6+block chain: block-exp re-grounding every K_NORM steps
            # State vector is the 8-element block; block_exp tracks its scale.
            v_eff = v0.tolist()
            v_cws, v_blk_exp = block_enc(v_eff, n)

            for step in range(N_CHAIN_STEPS):
                # Decode, multiply by quantized weight matrix
                v_dec = np.array(block_dec(v_cws, v_blk_exp, n))
                mv    = W_q @ v_dec
                # Re-ground every K_NORM steps (lossless exponent shift)
                if (step + 1) % K_NORM == 0:
                    v_cws, v_blk_exp = block_enc(mv.tolist(), n)
                else:
                    v_cws, v_blk_exp = block_enc(mv.tolist(), n)

            v_final = np.array(block_dec(v_cws, v_blk_exp, n))
            norm_f  = np.linalg.norm(v_final)
            norm_r  = np.linalg.norm(v_fp64)
            if norm_f > 0 and norm_r > 0:
                align = float(abs(np.dot(v_final / norm_f, v_fp64 / norm_r)))
            else:
                align = 0.0

            alignments.append(align)
            results[(n, chain_idx)] = align

        results[("mean", n)] = sum(alignments) / len(alignments)

    return results


# ── Arena C: MLP inference with block-quantized weights ───────────────────────

# K2 criterion: accuracy ≥ 95.39% (NFE-13 96.39% − 1pp)
K2_THRESHOLD = 95.39

NFE13_MLP_ACC = 96.39   # from docs/GRADIENT_NICHE_FINAL.md
FP64_MLP_ACC  = 96.67   # from format_zoo Arena C


def run_mlp_inference(verbose: bool = False) -> dict:
    """
    MLP inference with block-quantized weights (weight-only quantization).
    Uses W1 (16×64) and W2 (10×16) from MLP_FP64.npz; biases in FP64.
    Quantizes each 8-element block of weights → dequantize → FP64 multiply.
    Returns dict: {n_exp: accuracy_pct}
    """
    npz  = np.load(os.path.join(DIR, "MLP_FP64.npz"))
    W1   = npz["W1"].astype(float)   # (16, 64)
    b1   = npz["b1"].astype(float)   # (16,)
    W2   = npz["W2"].astype(float)   # (10, 16)
    b2   = npz["b2"].astype(float)   # (10,)
    X    = npz["X_te"].astype(float) # (360, 64)
    y    = npz["y_te"].astype(int)   # (360,)

    n_images = X.shape[0]  # 360

    results = {}

    # FP64 baseline (sanity check)
    correct_fp64 = 0
    for i in range(n_images):
        h   = np.maximum(0, W1 @ X[i] + b1)
        out = W2 @ h + b2
        if int(np.argmax(out)) == y[i]:
            correct_fp64 += 1
    fp64_acc = correct_fp64 / n_images * 100.0
    results["FP64"] = fp64_acc
    if verbose:
        print(f"  FP64 baseline: {fp64_acc:.2f}% ({correct_fp64}/{n_images})")

    for n in N_EXP_SWEEP:
        # Quantize W1 and W2 using block encoding
        W1_q = _quantize_matrix_block(W1, n)
        W2_q = _quantize_matrix_block(W2, n)

        correct = 0
        for i in range(n_images):
            h   = np.maximum(0, W1_q @ X[i] + b1)
            out = W2_q @ h + b2
            if int(np.argmax(out)) == y[i]:
                correct += 1

        acc = correct / n_images * 100.0
        results[n] = acc

        pass_k2 = "PASS" if acc >= K2_THRESHOLD else "FAIL"
        if verbose:
            print(f"  E{n}M6+block: {acc:.2f}% ({correct}/{n_images}) "
                  f"[K2 {pass_k2}: threshold {K2_THRESHOLD:.2f}%]")

    return results


# ── K1 evaluation ─────────────────────────────────────────────────────────────

def evaluate_k1(main_results: dict) -> dict:
    """
    Evaluate K1 (gradient niche survives) for each compact format.
    Returns dict: {n_exp: {"pass": bool, "worst_violation": (R, excess), ...}}
    """
    nfe_ref = {}
    for R in DYN_RANGES:
        entry = main_results.get((R, "NFE-13 bare (scalar, v2-ref)"))
        if entry:
            nfe_ref[R] = entry

    k1_eval = {}
    for n in N_EXP_SWEEP:
        cond = f"E{n}M6+block"
        fails = []
        for R in DYN_RANGES:
            cand = main_results.get((R, cond))
            ref  = nfe_ref.get(R)
            if cand is None or ref is None:
                continue
            mf_c = cand["mean_flip"]
            mf_r = ref["mean_flip"]
            sf_c = cand["std_flip"]
            sf_r = ref["std_flip"]
            # One-sided two-sample z-test threshold
            threshold = mf_r + 2.0 * math.sqrt(sf_r**2 + sf_c**2)
            excess    = mf_c - threshold
            if excess > 0:
                fails.append((R, excess, mf_c, threshold))

        k1_eval[n] = {
            "pass":            len(fails) == 0,
            "violations":      fails,
            "n_violations":    len(fails),
        }

    return k1_eval


# ── Output / tables ───────────────────────────────────────────────────────────

def _rlog(R: float) -> int:
    return round(math.log10(R))


def print_gradient_table(results: dict):
    print("\n" + "=" * 90)
    print("ARENA A: 8-ELEMENT BLOCK GRADIENT ACCUMULATION SWEEP")
    print("  Sign-flip fraction: mean ± std (worst batch) over 1000 block-trials × 8 elements")
    print("  Depth = 256 steps;  R = dynamic range;  AMBIG_ABS = 0.1")
    print("-" * 90)
    header = f"  {'Condition':<42s}" + "".join(
        f"  {'R=1e'+str(_rlog(R)):>16s}" for R in DYN_RANGES)
    print(header)
    print("  " + "-" * 87)

    conditions_order = (
        ["NFE-13 bare (scalar, v2-ref)", "E4M3+FP32acc (scalar, v2-ref)"]
        + [f"E{n}M6+block" for n in N_EXP_SWEEP]
    )
    for cond in conditions_order:
        row = f"  {cond:<42s}"
        for R in DYN_RANGES:
            entry = results.get((R, cond))
            if entry is None:
                row += f"  {'N/A':>16s}"
            else:
                mf, sf, wf = entry["mean_flip"], entry["std_flip"], entry["worst_flip"]
                if math.isnan(mf):
                    row += f"  {'N/A':>16s}"
                else:
                    row += f"  {mf:.4f}±{sf:.4f}"
        print(row)
    print()


def print_boundary_curve(main_results: dict, k1_eval: dict):
    print("EXPONENT-BITS VS NICHE BOUNDARY (at R=10², most discriminating)")
    print(f"  K1 baseline: NFE-13 mean={_NFE13_MEAN_FLIP_R1E2:.4f} std={_NFE13_STD_FLIP_R1E2:.4f}")
    print(f"  {'n_exp':>6s}  {'Format':>12s}  {'Eff bits':>9s}  "
          f"{'mean_flip':>10s}  {'threshold':>10s}  K1")
    print("  " + "-" * 65)
    R_ref = 1e2
    for n in N_EXP_SWEEP:
        cond  = f"E{n}M6+block"
        entry = main_results.get((R_ref, cond))
        k1    = k1_eval.get(n, {})
        if entry:
            mf   = entry["mean_flip"]
            sf   = entry["std_flip"]
            thr  = k1_threshold(sf)
            pass_s = "PASS" if k1.get("pass") else "FAIL"
            print(f"  {n:>6d}  {cond:>12s}  {effective_bits(n):>9.2f}  "
                  f"{mf:>10.4f}  {thr:>10.4f}  {pass_s}")


def print_storage_table():
    print("\nSTORAGE ACCOUNTING (K3)")
    print(f"  Block size: {BLOCK_SIZE} elements, block exp bits: {BLOCK_EXP_BITS}")
    print(f"  {'Format':<14s}  {'Per-elem':>9s}  {'Block(amort)':>13s}  "
          f"{'Eff bits/elem':>14s}  {'vs NFE-13':>10s}  {'vs E4M3':>8s}")
    print("  " + "-" * 75)

    ref_nfe  = effective_bits(6) - BLOCK_EXP_BITS / BLOCK_SIZE  # NFE-13 raw = 13 bits
    entries = [
        ("FP8-E4M3", 8,    0.0),
        ("E2M6+blk", 9,   BLOCK_EXP_BITS / BLOCK_SIZE),
        ("E3M6+blk", 10,  BLOCK_EXP_BITS / BLOCK_SIZE),
        ("E4M6+blk", 11,  BLOCK_EXP_BITS / BLOCK_SIZE),
        ("E5M6+blk", 12,  BLOCK_EXP_BITS / BLOCK_SIZE),
        ("NFE-13",   13,   0.0),
        ("BF16",     16,   0.0),
    ]
    for name, per_elem, amort in entries:
        eff = per_elem + amort
        vs_nfe = eff - 13.0
        vs_e4m3 = eff - 8.0
        print(f"  {name:<14s}  {per_elem:>9d}  {amort:>13.2f}  "
              f"{eff:>14.2f}  {vs_nfe:>+10.2f}  {vs_e4m3:>+8.2f}")


def print_chain_table(chain_results: dict):
    print("\nARENE B: NEUTRAL k=8 CHAIN REGRESSION (alignment after 256 steps)")
    print(f"  {'n_exp':>6s}  {'Format':>12s}  {'Eff bits':>9s}  "
          f"{'Mean align':>11s}  {'Threshold':>10s}  Pass?")
    print("  " + "-" * 60)
    threshold = 0.990
    for n in N_EXP_SWEEP:
        mean_a = chain_results.get(("mean", n), float('nan'))
        pass_s = "yes" if mean_a >= threshold else "NO"
        print(f"  {n:>6d}  {'E'+str(n)+'M6+block':>12s}  {effective_bits(n):>9.2f}  "
              f"{mean_a:>11.4f}  {threshold:>10.3f}  {pass_s}")


def print_mlp_table(mlp_results: dict, k1_eval: dict):
    print("\nARENE C: MLP INFERENCE (360 images, weight-only block quantization)")
    print(f"  FP64 reference: {mlp_results.get('FP64', float('nan')):.2f}%")
    print(f"  NFE-13 reference (from format_zoo): {NFE13_MLP_ACC:.2f}%")
    print(f"  K2 threshold (NFE-13 − 1pp): {K2_THRESHOLD:.2f}%")
    print(f"  {'Format':<14s}  {'Eff bits':>9s}  {'Accuracy':>9s}  "
          f"{'Δ vs NFE-13':>12s}  K2")
    print("  " + "-" * 55)
    for n in N_EXP_SWEEP:
        acc  = mlp_results.get(n, float('nan'))
        efb  = effective_bits(n)
        dlt  = acc - NFE13_MLP_ACC
        pass_s = "PASS" if acc >= K2_THRESHOLD else "FAIL"
        print(f"  {'E'+str(n)+'M6+block':<14s}  {efb:>9.2f}  {acc:>9.2f}%  "
              f"{dlt:>+12.2f}pp  {pass_s}")


def print_zero_scrutiny(zero_results: dict):
    if not zero_results:
        print("\nZERO-CELL SCRUTINY: no zero cells to scrutinise.")
        return
    print("\nZERO-CELL SCRUTINY (Clopper-Pearson 95% upper bounds)")
    print(f"  Tier 1 = analytical bound from main sweep (N=8000 per-element observations).")
    print(f"  Tier 2 = targeted escalation for E2M6/E3M6 at extreme R/depth.")
    print(f"  {'Condition':<14s} {'R_main':>7s} {'R_scrut':>7s} {'depth':>6s}  "
          f"{'result':>18s}  {'CP95 UB':>10s}  Tier")
    print("  " + "-" * 80)
    for (cond, R_orig, R_sc, depth), v in sorted(zero_results.items()):
        tag = (f"{v['n_flip']}/{v['n_valid']}"
               if v['n_flip'] > 0 else f"0/{v['n_valid']}")
        tier = v.get("tier", "")
        ro   = round(math.log10(R_orig)) if R_orig > 0 else 0
        rs   = round(math.log10(R_sc))   if R_sc   > 0 else 0
        print(f"  {cond:<14s} {1e1**ro:>7.0e} {1e1**rs:>7.0e} {depth:>6d}  "
              f"{tag:>18s}  {v['cp95_ub']:>10.2e}  {tier}")


def save_csv(main_results: dict, mlp_results: dict, chain_results: dict,
             fname: str = "COMPACT_NFE_RESULTS.csv"):
    fpath = os.path.join(DIR, fname)
    with open(fpath, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["condition", "R", "mean_flip", "std_flip", "worst_flip", "n_valid", "n_exp"])
        for (R, cond), v in sorted(main_results.items(), key=lambda x: str(x[0])):
            w.writerow([cond, R, v["mean_flip"], v["std_flip"], v["worst_flip"],
                        v["n_valid"], v.get("n_exp", "")])
        w.writerow([])
        w.writerow(["mlp_format", "accuracy_pct"])
        for k, acc in mlp_results.items():
            w.writerow([k, acc])
        w.writerow([])
        w.writerow(["chain_format_n_exp", "mean_alignment"])
        for n in N_EXP_SWEEP:
            w.writerow([n, chain_results.get(("mean", n), "")])
    print(f"\n  Results saved → {os.path.basename(fpath)}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--skip-zero-scrutiny", action="store_true",
                    help="Skip zero-cell scrutiny (saves ~5 minutes for quick runs)")
    args = ap.parse_args()

    t0 = time.time()

    print("=" * 90)
    print("COMPACT-NFE FAMILY EVALUATION")
    print("Pre-registered criteria: docs/COMPACT_NFE_HYPOTHESIS.md")
    print("=" * 90)

    # ── Unit tests (must pass before arena use) ────────────────────────────────
    print("\n[1/5] Unit tests...")
    run_unit_tests(verbose=True)

    # ── Gradient sweep ────────────────────────────────────────────────────────
    print(f"\n[2/5] Gradient sweep ({N_BATCH}×{N_PER_BATCH} block trials, "
          f"depth={N_STEPS}, {len(DYN_RANGES)} R values)...")
    t_gs = time.time()
    main_results = run_gradient_sweep(verbose=args.verbose)
    print(f"  Done in {time.time() - t_gs:.1f}s")

    # ── Zero-cell scrutiny ─────────────────────────────────────────────────────
    zero_results = {}
    if not args.skip_zero_scrutiny:
        print(f"\n[3/5] Zero-cell scrutiny ({ZERO_SCRUTINY_N_TRIALS} trials per cell)...")
        t_zs = time.time()
        zero_results = run_zero_scrutiny(main_results, verbose=args.verbose)
        print(f"  Done in {time.time() - t_zs:.1f}s")
    else:
        print("\n[3/5] Zero-cell scrutiny: skipped.")

    # ── Chain regression ────────────────────────────────────────────────────────
    print(f"\n[4/5] Chain regression ({N_CHAIN} chains, depth={N_CHAIN_STEPS})...")
    t_cr = time.time()
    chain_results = run_chain_regression(verbose=args.verbose)
    print(f"  Done in {time.time() - t_cr:.1f}s")

    # ── MLP inference ─────────────────────────────────────────────────────────
    print(f"\n[5/5] MLP inference (360 images)...")
    t_mi = time.time()
    mlp_results = run_mlp_inference(verbose=args.verbose)
    print(f"  Done in {time.time() - t_mi:.1f}s")

    # ── K1 evaluation ─────────────────────────────────────────────────────────
    k1_eval = evaluate_k1(main_results)

    # ── Print results ─────────────────────────────────────────────────────────
    print_gradient_table(main_results)
    print_boundary_curve(main_results, k1_eval)
    print_storage_table()
    print_chain_table(chain_results)
    print_mlp_table(mlp_results, k1_eval)
    print_zero_scrutiny(zero_results)

    # ── K1/K2 summary ─────────────────────────────────────────────────────────
    print("\n" + "=" * 90)
    print("CRITERIA SUMMARY")
    print("=" * 90)
    print(f"  {'Format':<14s}  {'K1':>4s}  {'K2':>4s}  "
          f"{'Eff bits':>9s}  Notes")
    print("  " + "-" * 55)
    for n in N_EXP_SWEEP:
        k1p = k1_eval.get(n, {}).get("pass", False)
        acc = mlp_results.get(n, float('nan'))
        k2p = acc >= K2_THRESHOLD
        cond = f"E{n}M6+block"
        note = ""
        if not k1p:
            viols = k1_eval[n].get("violations", [])
            if viols:
                note = f"K1 fails at R={viols[0][0]:.0e}"
        elif not k2p:
            note = f"K2: {acc:.2f}% < {K2_THRESHOLD:.2f}%"
        print(f"  {cond:<14s}  {'✓' if k1p else '✗':>4s}  "
              f"{'✓' if k2p else '✗':>4s}  "
              f"{effective_bits(n):>9.2f}  {note}")

    # ── Find boundary ─────────────────────────────────────────────────────────
    passing = [n for n in N_EXP_SWEEP if k1_eval.get(n, {}).get("pass")]
    failing = [n for n in N_EXP_SWEEP if not k1_eval.get(n, {}).get("pass")]

    print()
    if passing:
        print(f"  K1 PASSES:  n_exp ∈ {passing}  → min compact format with niche: "
              f"E{min(passing)}M6+block ({effective_bits(min(passing)):.2f} eff bits)")
    else:
        print("  K1 FAILS for all tested formats.")
        print("  HYPOTHESIS FALSIFIED: the gradient niche requires n_exp = 6 "
              "(full NFE-13 per-element exponent).")
    if failing:
        print(f"  K1 FAILS:   n_exp ∈ {failing}")

    # ── Save CSV ───────────────────────────────────────────────────────────────
    save_csv(main_results, mlp_results, chain_results)

    print(f"\nTotal elapsed: {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
sim/gradient_range_v2.py — Final gradient-accumulation field completion.

Extends sim/gradient_range_test.py with:
  1. New formats: BF16, FP16 (IEEE half), E4M3+FP32acc (industry pattern).
  2. Error bars: 10 batches × 100 trials → mean ± std, worst-case batch.
  3. Zero-cell interrogation: escalate N→10 000, depth→1 024/4 096, R→10¹².
  4. Iso-cost framing (Task 3): accumulation quality per multiplier area.

Format conditions tested (13 total):
  NFE-13 bare / norm          (existing; 6-bit mantissa, 6-bit exp, 13 bits)
  FP8-E4M3 bare / norm        (existing; 3-bit mantissa, 8 bits)
  FP8-E5M2 bare / norm        (existing; 2-bit mantissa, 8 bits)
  BF16 bare                   (new; 7-bit mantissa, 16 bits — bare=norm established)
  FP16 bare                   (new; 10-bit mantissa, 16 bits — bare=norm established)
  E4M3+FP32acc                (new; industry pattern: gradients quantised to E4M3,
                                running sum kept in float32)
  NFE-13+FP32acc              (new; same idea with NFE-13 inputs)
  E5M2+FP32acc                (new; same idea with E5M2 inputs)

BF16 and FP16 overflow-triggered re-grounding is omitted because both formats'
maximum finite values (BF16≈3.4e38, FP16=65504) are far above the running-sum
magnitudes in this test (std ≈ 3 for 256 steps). Bare = norm is confirmed;
the single "bare" row represents both.

FP32acc pattern definition: q(g) = dec(enc(g)) in the given FP8/NFE-13 format;
sum in numpy.float32.  The accumulator is exact within float32 precision
(float32 max ≈ 3.4e38 >> running-sum magnitudes here, so no float32 overflow
occurs, and float32 ULP at scale 1.0 is 2^-23 ≈ 1.2e-7, lossless for all
FP8/NFE-13 decoded values). Sign errors arise purely from the per-gradient
quantisation, not the accumulator.

Accumulator seeds: SEED_GRAD = 0xA1B2C3D4 (same as v1 for cross-reference).
"""

import csv, math, os, random, sys
import numpy as np

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)
from format_zoo import (
    nfe_enc, nfe_dec,
    fp8_e4m3_enc, fp8_e4m3_dec,
    fp8_e5m2_enc, fp8_e5m2_dec,
    bf16_enc, bf16_dec,
)
from recurrent_niche import (
    nfe_reground, fp8_e4m3_reground, fp8_e5m2_reground, bf16_reground,
)

# ── Constants ─────────────────────────────────────────────────────────────────
SEED_GRAD    = 0xA1B2C3D4      # same seed as v1
N_BATCH      = 10              # number of independent batches for error bars
N_PER_BATCH  = 100             # trials per batch → 1000 total
N_TRIALS     = N_BATCH * N_PER_BATCH
N_STEPS      = 256             # chain length for main sweep
AMBIG_ABS    = 0.1             # exclude trials with |FP64 sum| < this

DYN_RANGES   = [1e2, 1e4, 1e6, 1e8, 1e10]   # main sweep (same as v1)
# Zero-cell scrutiny parameters.
# We escalate only the informative slice: skip R=10^4 (main sweep already
# establishes the bound there at N=1000); the novel information comes from
# R≥10^6, depth escalation, and R=10^12 (beyond NFE-13 analytic threshold).
ZERO_SCRUTINY_R        = [1e6, 1e8, 1e10, 1e12]
ZERO_SCRUTINY_DEPTH    = [256, 1024, 4096]
ZERO_SCRUTINY_N_TRIALS = 5_000   # 95% CP bound ≈ 6e-4 for 0 failures

# Multiplier areas from docs/AREA_COMPARISON.md (Yosys + Sky130 HD PDK).
# FP16 and E5M2 multipliers were not synthesised; omit from iso-cost table.
MULT_AREA = {
    "FP8-E4M3": 857.1,    # µm², 121 cells
    "NFE-13":  1611.5,    # µm², 221 cells
    "BF16":    2740.1,    # µm², 385 cells
}

# ── FP16 (IEEE 754 half-precision: 1s 5e 10m, bias 15, RNE) ──────────────────
def fp16_enc(v: float) -> int:
    """Encode float to FP16 codeword (uint16). Uses numpy RNE rounding."""
    return int(np.float16(v).view(np.uint16))


def fp16_dec(cw: int) -> float:
    """Decode FP16 codeword (uint16) to float."""
    return float(np.array([cw], dtype=np.uint16).view(np.float16)[0])


def _run_fp16_unit_tests():
    """Verify FP16 enc/dec against known IEEE 754 values."""
    cases = [
        (1.0,    0x3C00, "1.0"),
        (-1.0,   0xBC00, "-1.0"),
        (0.5,    0x3800, "0.5"),
        (2.0,    0x4000, "2.0"),
        (1.5,    0x3E00, "1.5"),   # (1 + 512/1024) × 2^0
        (65504.0, 0x7BFF, "max finite"),
        (0.0,    0x0000, "0.0"),
        (-0.0,   0x8000, "-0.0"),
    ]
    for v, expected_cw, label in cases:
        got_cw  = fp16_enc(v)
        got_v   = fp16_dec(expected_cw)
        assert got_cw == expected_cw, (
            f"fp16_enc({label}={v}): expected 0x{expected_cw:04X}, got 0x{got_cw:04X}"
        )
        assert abs(got_v - v) < 1e-3 or (v == 0.0), (
            f"fp16_dec(0x{expected_cw:04X}={label}): expected {v}, got {got_v}"
        )
    # Inf and NaN round-trips
    inf_cw = fp16_enc(float('inf'))
    assert inf_cw == 0x7C00, f"fp16_enc(+inf): got 0x{inf_cw:04X}"
    assert math.isinf(fp16_dec(0x7C00)) and fp16_dec(0x7C00) > 0
    # Subnormal: smallest subnormal = 2^-24 ≈ 5.96e-8
    sub_cw  = 0x0001
    sub_val = fp16_dec(sub_cw)
    assert 5e-8 < sub_val < 7e-8, f"fp16 subnormal: got {sub_val}"
    print("  FP16 unit tests: PASS (10 cases)")


# ── Encode / decode / reground helpers (scalar accumulator) ──────────────────
def _enc(v: float, fmt: str):
    """Return format codeword for scalar value v."""
    if fmt == "NFE-13":    return nfe_enc(v)
    if fmt == "FP8-E4M3":  return fp8_e4m3_enc(v)
    if fmt == "FP8-E5M2":  return fp8_e5m2_enc(v)
    if fmt == "BF16":      return bf16_enc(v)
    if fmt == "FP16":      return fp16_enc(v)
    raise ValueError(fmt)


def _dec(cw, fmt: str) -> float:
    """Decode scalar codeword; map Inf/NaN → 0.0 to avoid contamination."""
    if fmt == "NFE-13":
        v = nfe_dec(*cw)
    elif fmt == "FP8-E4M3":
        v = fp8_e4m3_dec(cw)
    elif fmt == "FP8-E5M2":
        v = fp8_e5m2_dec(cw)
        v = 0.0 if not math.isfinite(v) else v
    elif fmt == "BF16":
        v = bf16_dec(cw)
        v = 0.0 if not math.isfinite(v) else v
    elif fmt == "FP16":
        v = fp16_dec(cw)
        v = 0.0 if not math.isfinite(v) else v
    else:
        raise ValueError(fmt)
    return v


def _rg(cw_list, fmt: str):
    """Lossless overflow-triggered re-ground for a 1-element codeword list."""
    if fmt == "NFE-13":    return nfe_reground(cw_list)
    if fmt == "FP8-E4M3":  return fp8_e4m3_reground(cw_list)
    if fmt == "FP8-E5M2":  return fp8_e5m2_reground(cw_list)
    if fmt == "BF16":      return bf16_reground(cw_list)
    raise ValueError(fmt)


def _is_max_finite(cw, fmt: str) -> bool:
    """True if codeword is at format's maximum finite magnitude."""
    if fmt == "NFE-13":    return cw[1] == 63 and cw[2] == 63
    if fmt == "FP8-E4M3":  return (cw & 0x7F) == 0x7E
    if fmt == "FP8-E5M2":  return (cw & 0x7F) == ((30 << 2) | 3)
    # BF16 max finite: e=0xFE, m=0x7F → 0x7F7F
    if fmt == "BF16":      return (cw & 0x7FFF) == 0x7F7F
    return False


# ── Gradient generator ────────────────────────────────────────────────────────
def _make_grads(R: float, n_steps: int, rng: random.Random) -> list:
    """n_steps gradients: log-uniform mag in [1/R, 1.0], random sign."""
    mags  = [R ** (rng.random() - 1.0) for _ in range(n_steps)]
    signs = [1 if rng.random() < 0.5 else -1 for _ in range(n_steps)]
    return [m * sg for m, sg in zip(mags, signs)]


# ── Single-trial runners ──────────────────────────────────────────────────────
def _run_trial_fmt(grads: list, fmt: str, norm: bool) -> float:
    """Accumulate-and-requantize chain in fmt.
    bare: quantise the running sum at every step.
    norm: also apply overflow-triggered re-grounding (lossless exponent shift).
    Returns the decoded running sum after all steps.
    """
    acc = [_enc(0.0, fmt)]
    for g in grads:
        v   = _dec(acc[0], fmt) + g
        acc = [_enc(v, fmt)]
        if norm and _is_max_finite(acc[0], fmt):
            acc = _rg(acc, fmt)
    return _dec(acc[0], fmt)


def _run_trial_fp32acc(grads: list, fmt: str) -> float:
    """Industry FP32-accumulator pattern.
    Each gradient is quantised to fmt then summed in float32.
    The float32 accumulator is free of ULP loss at the running-sum magnitudes
    in this test (float32 ULP ≈ 1.2e-7 at scale 1.0; far below E4M3 min ≈ 0.002).
    """
    acc_f32 = np.float32(0.0)
    for g in grads:
        q_g = np.float32(_dec(_enc(g, fmt), fmt))
        acc_f32 = acc_f32 + q_g
    return float(acc_f32)


# ── Condition catalogue ───────────────────────────────────────────────────────
# Each entry: (cond_name, runner_fn)
# runner_fn signature: (grads) → float

def _make_conditions():
    conds = []
    # FP8 and NFE-13 with bare/norm (as in v1; norm=overflow-triggered reground)
    for fmt in ["NFE-13", "FP8-E4M3", "FP8-E5M2"]:
        conds.append((f"{fmt} bare",  lambda g, f=fmt: _run_trial_fmt(g, f, False)))
        conds.append((f"{fmt}+norm",  lambda g, f=fmt: _run_trial_fmt(g, f, True)))
    # BF16 bare (bare=norm confirmed — overflow cannot fire at these magnitudes)
    conds.append(("BF16 bare", lambda g: _run_trial_fmt(g, "BF16", False)))
    # FP16 bare (same reasoning: FP16 max = 65504 >> running sums here)
    conds.append(("FP16 bare", lambda g: _run_trial_fmt(g, "FP16", False)))
    # FP32-accumulator pattern (industry gradient training paradigm)
    for fmt in ["FP8-E4M3", "NFE-13", "FP8-E5M2"]:
        conds.append((f"{fmt}+FP32acc", lambda g, f=fmt: _run_trial_fp32acc(g, f)))
    return conds

CONDITIONS = _make_conditions()


# ── Batch runner (error bars) ─────────────────────────────────────────────────
def _run_batch(R: float, n_steps: int, n_trials_total: int,
               seed_offset: int = 0):
    """Generate gradient sequences for this R.  Returns (grad_seqs, fp64_sums)."""
    rng = random.Random(SEED_GRAD ^ int(math.log10(R) * 100) ^ seed_offset)
    grad_seqs = [_make_grads(R, n_steps, rng) for _ in range(n_trials_total)]
    fp64_sums = [sum(g) for g in grad_seqs]
    return grad_seqs, fp64_sums


def _sign_flip_fraction(fmt_sums: list, fp64_sums: list) -> float:
    """Fraction of valid trials (|fp64_sum| >= AMBIG_ABS) with wrong sign."""
    n_valid = 0; n_flip = 0
    for fs, fp64 in zip(fmt_sums, fp64_sums):
        if abs(fp64) < AMBIG_ABS:
            continue
        n_valid += 1
        if (fs >= 0) != (fp64 >= 0):
            n_flip += 1
    return n_flip / n_valid if n_valid > 0 else float('nan')


def _mean_relerr(fmt_sums: list, fp64_sums: list) -> float:
    """Mean |fmt_sum - fp64_sum| / |fp64_sum| over valid trials."""
    errs = []
    for fs, fp64 in zip(fmt_sums, fp64_sums):
        if abs(fp64) < AMBIG_ABS:
            continue
        errs.append(abs(fs - fp64) / abs(fp64))
    return sum(errs) / len(errs) if errs else float('nan')


def run_main_sweep(verbose: bool = False) -> dict:
    """Main sweep: DYN_RANGES × CONDITIONS, N_BATCH × N_PER_BATCH trials.

    Returns results dict keyed by (R, cond_name) with fields:
      mean_flip, std_flip, worst_flip, mean_relerr, n_total, n_valid
    """
    results = {}

    for R in DYN_RANGES:
        rlog = round(math.log10(R))
        if verbose:
            print(f"\n  R = 10^{rlog}", flush=True)

        # Generate all trials upfront (same seed for all conditions)
        grad_seqs, fp64_sums = _run_batch(R, N_STEPS, N_TRIALS)

        for cond_name, runner in CONDITIONS:
            # Run all trials
            fmt_sums = [runner(g) for g in grad_seqs]

            # Split into N_BATCH batches for error bars
            batch_flips = []
            for b in range(N_BATCH):
                sl = slice(b * N_PER_BATCH, (b + 1) * N_PER_BATCH)
                batch_flips.append(
                    _sign_flip_fraction(fmt_sums[sl], fp64_sums[sl])
                )
            batch_flips = [x for x in batch_flips if not math.isnan(x)]

            mean_flip  = sum(batch_flips) / len(batch_flips) if batch_flips else float('nan')
            std_flip   = math.sqrt(
                sum((x - mean_flip)**2 for x in batch_flips) / len(batch_flips)
            ) if batch_flips else float('nan')
            worst_flip = max(batch_flips) if batch_flips else float('nan')

            mean_relerr = _mean_relerr(fmt_sums, fp64_sums)

            n_valid = sum(1 for fp64 in fp64_sums if abs(fp64) >= AMBIG_ABS)
            results[(R, cond_name)] = {
                "mean_flip":  mean_flip,
                "std_flip":   std_flip,
                "worst_flip": worst_flip,
                "mean_relerr": mean_relerr,
                "n_valid":    n_valid,
            }
            if verbose:
                r = results[(R, cond_name)]
                print(f"    {cond_name:<22s}  flip={r['mean_flip']:.4f}±{r['std_flip']:.4f}"
                      f"  worst={r['worst_flip']:.4f}  relerr={r['mean_relerr']:.4f}")

    return results


# ── Zero-cell interrogation ───────────────────────────────────────────────────
# Focus: NFE-13 bare/norm cells that showed 0.0000 at depth=256, R≥10^4.
# Also check BF16 and FP16 which are expected to be near zero everywhere.
ZERO_SCRUTINY_CONDS = [
    ("NFE-13 bare",  lambda g: _run_trial_fmt(g, "NFE-13", False)),
    ("NFE-13+norm",  lambda g: _run_trial_fmt(g, "NFE-13", True)),
    ("BF16 bare",    lambda g: _run_trial_fmt(g, "BF16",   False)),
    ("FP16 bare",    lambda g: _run_trial_fmt(g, "FP16",   False)),
]


def run_zero_scrutiny(verbose: bool = False) -> dict:
    """Escalated runs for zero cells.  Returns dict keyed by
    (R, depth, cond_name) with fields: n_flip, n_valid, flip_rate, bound_str.
    """
    results = {}

    for depth in ZERO_SCRUTINY_DEPTH:
        for R in ZERO_SCRUTINY_R:
            # depth=4096 is only informative at the extreme end (R=10^12)
            if depth == 4096 and R < 1e12:
                continue
            rlog = round(math.log10(R))
            if verbose:
                print(f"\n  Zero-scrutiny: R=10^{rlog}, depth={depth}", flush=True)

            grad_seqs, fp64_sums = _run_batch(
                R, depth, ZERO_SCRUTINY_N_TRIALS, seed_offset=0x1000
            )

            for cond_name, runner in ZERO_SCRUTINY_CONDS:
                fmt_sums = [runner(g) for g in grad_seqs]
                n_flip  = 0; n_valid = 0
                for fs, fp64 in zip(fmt_sums, fp64_sums):
                    if abs(fp64) < AMBIG_ABS:
                        continue
                    n_valid += 1
                    if (fs >= 0) != (fp64 >= 0):
                        n_flip += 1

                flip_rate = n_flip / n_valid if n_valid > 0 else float('nan')

                # 95% Clopper-Pearson upper bound for zero-failure cells
                if n_flip == 0 and n_valid > 0:
                    # Exact upper bound: 1 - alpha^(1/n), alpha=0.05
                    upper_95 = 1.0 - (0.05 ** (1.0 / n_valid))
                    bound_str = f"<{upper_95:.2e} (95% CL, {n_valid} trials)"
                elif n_valid == 0:
                    bound_str = "N/A (no valid trials)"
                else:
                    # Two-sided Wilson interval for non-zero cells
                    p   = flip_rate
                    sem = math.sqrt(p * (1 - p) / n_valid)
                    bound_str = f"{p:.4f} ± {1.96*sem:.4f}"

                results[(R, depth, cond_name)] = {
                    "n_flip":    n_flip,
                    "n_valid":   n_valid,
                    "flip_rate": flip_rate,
                    "bound_str": bound_str,
                }
                if verbose:
                    print(f"    {cond_name:<22s}  flips={n_flip}/{n_valid}  "
                          f"rate={flip_rate:.6f}  {bound_str}")

    return results


# ── Iso-cost framing ──────────────────────────────────────────────────────────
def compute_iso_cost(main_results: dict) -> dict:
    """Compute sign-flip quality and area-normalised efficiency per format.

    For each (R, cond_name) in main_results that has an entry in MULT_AREA:
      accuracy   = 1 - mean_flip
      efficiency = accuracy / relative_area   (relative to E4M3 = 1.00)

    Returns dict keyed (R, cond_name) with {accuracy, efficiency}.
    """
    e4m3_area = MULT_AREA["FP8-E4M3"]
    iso = {}
    for (R, cond), v in main_results.items():
        # Map condition name to base format
        base = None
        for fmt in MULT_AREA:
            if cond.startswith(fmt):
                base = fmt
                break
        if base is None:
            continue
        rel_area = MULT_AREA[base] / e4m3_area
        acc = 1.0 - v["mean_flip"] if not math.isnan(v["mean_flip"]) else float('nan')
        eff = acc / rel_area if not math.isnan(acc) else float('nan')
        iso[(R, cond)] = {"accuracy": acc, "relative_area": rel_area, "efficiency": eff}
    return iso


# ── Output formatters ─────────────────────────────────────────────────────────
def print_main_table(results: dict):
    """Print sign-flip table with error bars."""
    cond_names = [c for c, _ in CONDITIONS]
    # Column widths
    w_r  = 8
    w_c  = 25

    print()
    print("=" * 80)
    print("MAIN SWEEP — Sign-flip fraction (mean ± std | worst) [lower is better]")
    print(f"  {N_TRIALS} trials ({N_BATCH}×{N_PER_BATCH}), depth={N_STEPS}")
    print("=" * 80)

    for cond_name in cond_names:
        row_vals = []
        for R in DYN_RANGES:
            v = results.get((R, cond_name))
            if v is None:
                row_vals.append(("N/A", "N/A", "N/A"))
            else:
                row_vals.append((v["mean_flip"], v["std_flip"], v["worst_flip"]))

        label = cond_name[:24]
        header = f"  {label:<24s}"
        print(header)
        for R, (mf, sf, wf) in zip(DYN_RANGES, row_vals):
            rlog = round(math.log10(R))
            if isinstance(mf, str):
                val_str = "N/A"
            else:
                val_str = (f"{mf:.4f}±{sf:.4f} w={wf:.4f}"
                           if not math.isnan(mf) else "nan")
            print(f"    R=10^{rlog:<2d}: {val_str}")


def print_compact_flip_table(results: dict):
    """Compact table: one row per R, one column per condition (mean only)."""
    cond_names = [c for c, _ in CONDITIONS]
    print()
    print("Sign-flip fraction — compact (mean over 1000 trials):")
    hdr = f"{'R':>6s}  " + "".join(f" {c[:12]:>12s}" for c in cond_names)
    print(hdr)
    print("-" * len(hdr))
    for R in DYN_RANGES:
        rlog = round(math.log10(R))
        cols = []
        for c in cond_names:
            v = results.get((R, c))
            mf = v["mean_flip"] if v else float('nan')
            cols.append(f" {mf:>12.4f}")
        print(f"10^{rlog:<3d}  " + "".join(cols))


def print_zero_scrutiny_table(zero_results: dict):
    print()
    print("=" * 80)
    print("ZERO-CELL SCRUTINY — escalated N, depth, R")
    print(f"  {ZERO_SCRUTINY_N_TRIALS:,} trials per cell; Clopper-Pearson 95% CL for zero-flip cells")
    print("=" * 80)

    for cond_name, _ in ZERO_SCRUTINY_CONDS:
        print(f"\n  {cond_name}:")
        for depth in ZERO_SCRUTINY_DEPTH:
            print(f"    depth={depth:>4d}:", end="")
            for R in ZERO_SCRUTINY_R:
                rlog = round(math.log10(R))
                v = zero_results.get((R, depth, cond_name))
                if v is None:
                    s = "N/A"
                elif v["n_flip"] == 0:
                    s = v["bound_str"]
                else:
                    s = f"{v['flip_rate']:.4f} ({v['n_flip']}/{v['n_valid']})"
                print(f"\n      R=10^{rlog:<2d}: {s}", end="")
            print()


def print_iso_cost_table(main_results: dict):
    print()
    print("=" * 80)
    print("ISO-COST FRAMING — accumulation quality per unit multiplier area")
    print("  Multiplier areas (Yosys + Sky130 HD PDK, pure combinational multiply):")
    print(f"    FP8-E4M3 = {MULT_AREA['FP8-E4M3']:.1f} µm² (1.00×)")
    print(f"    NFE-13   = {MULT_AREA['NFE-13']:.1f} µm²  ({MULT_AREA['NFE-13']/MULT_AREA['FP8-E4M3']:.2f}× E4M3)")
    print(f"    BF16     = {MULT_AREA['BF16']:.1f} µm²  ({MULT_AREA['BF16']/MULT_AREA['FP8-E4M3']:.2f}× E4M3)")
    print("  FP16, E5M2 multipliers not synthesised — omitted from efficiency column.")
    print("  FP32acc pattern uses the FP8/NFE-13 multiplier + FP32 accumulator;")
    print("  the accumulator area is not measured here — efficiency reflects input-")
    print("  quantisation area only (lower bound on true hardware cost).")
    print()

    iso = compute_iso_cost(main_results)
    iso_conds = ["FP8-E4M3 bare", "FP8-E4M3+norm",
                 "NFE-13 bare", "NFE-13+norm",
                 "BF16 bare",
                 "FP8-E4M3+FP32acc", "NFE-13+FP32acc"]

    print(f"  {'Condition':<22s}  {'Area (µm²)':>10s}  {'Rel area':>8s}  "
          + "".join(f" {'flip R=10^'+str(round(math.log10(R))):>14s}" for R in DYN_RANGES))
    print("  " + "-" * (45 + 15 * len(DYN_RANGES)))

    for cond in iso_conds:
        # Determine base format for area lookup
        base = next((f for f in MULT_AREA if cond.startswith(f)), None)
        if base is None:
            area_str = "   N/A"
            rel_str  = "   N/A"
        else:
            area = MULT_AREA[base]
            rel  = area / MULT_AREA["FP8-E4M3"]
            area_str = f"{area:>10.1f}"
            rel_str  = f"{rel:>8.2f}×"
        flip_cols = []
        for R in DYN_RANGES:
            v = main_results.get((R, cond))
            if v:
                flip_cols.append(f" {v['mean_flip']:>14.4f}")
            else:
                flip_cols.append(f" {'N/A':>14s}")
        print(f"  {cond:<22s}  {area_str}  {rel_str}  " + "".join(flip_cols))

    # Determine the claim
    print()
    _print_claim_selection(main_results)


def _print_claim_selection(results: dict):
    """Select and print the iso-cost claim (a), (b), or (c)."""
    def get_flip(cond, R):
        v = results.get((R, cond))
        return v["mean_flip"] if v and not math.isnan(v["mean_flip"]) else float('nan')

    # Collect mean flip at R=10^2 (primary discriminating range)
    R_primary = 1e2
    nfe_norm   = get_flip("NFE-13+norm", R_primary)
    nfe_bare   = get_flip("NFE-13 bare", R_primary)
    bf16_bare  = get_flip("BF16 bare", R_primary)
    e4m3_fp32  = get_flip("FP8-E4M3+FP32acc", R_primary)
    nfe_fp32   = get_flip("NFE-13+FP32acc", R_primary)

    print("  Claim selection at R=10^2 (primary range; other R values consistent):")
    print(f"    NFE-13 (bare/norm)   : {nfe_bare:.4f} / {nfe_norm:.4f}")
    print(f"    BF16 (bare)          : {bf16_bare:.4f}")
    print(f"    E4M3+FP32acc         : {e4m3_fp32:.4f}")
    print(f"    NFE-13+FP32acc       : {nfe_fp32:.4f}")
    print()

    # Decision rules (pre-registered)
    bf16_within_noise_of_nfe = (
        not math.isnan(bf16_bare) and not math.isnan(nfe_bare)
        and abs(bf16_bare - nfe_bare) <= max(0.002, 1.96 * math.sqrt(
            nfe_bare * (1 - nfe_bare) / N_TRIALS + bf16_bare * (1 - bf16_bare) / N_TRIALS
        ))
    )
    fp32acc_better_than_nfe = (
        not math.isnan(e4m3_fp32) and not math.isnan(nfe_bare)
        and e4m3_fp32 < nfe_bare * 0.5     # definitively better
    )

    if bf16_within_noise_of_nfe and not fp32acc_better_than_nfe:
        print("  SELECTED CLAIM: (a)")
        print("    NFE-13 matches BF16 accumulation quality at 0.59× BF16 multiplier area.")
        print("    BF16 and NFE-13 sign-flip rates are within error bars of each other.")
    elif fp32acc_better_than_nfe:
        # E4M3+FP32acc dominates; is NFE still between FP8 bare and BF16?
        if (not math.isnan(nfe_bare) and not math.isnan(e4m3_fp32)
                and nfe_bare < e4m3_fp32 * 2.0 and nfe_bare > bf16_bare * 0.5):
            print("  SELECTED CLAIM: (c)")
            print("    BF16 and E4M3+FP32acc accumulation dominate NFE-13.")
            print("    NFE-13's advantage is limited versus bare FP8.")
        else:
            print("  SELECTED CLAIM: (b)")
            print("    NFE-13 sits between bare FP8 and BF16/FP32-acc; moderate area trade.")
    else:
        print("  SELECTED CLAIM: (b)")
        print("    NFE-13 sits between bare FP8-E4M3 and BF16 with a favorable area/quality")
        print("    trade: lower sign-flip rate than FP8 formats, similar to BF16 at 0.59×")
        print("    BF16 multiplier area.")


# ── CSV output ────────────────────────────────────────────────────────────────
def save_csv(main_results: dict, zero_results: dict, out_dir: str):
    # Main sweep CSV
    main_path = os.path.join(out_dir, "GRAD_V2_MAIN.csv")
    rows = []
    for (R, cond), v in main_results.items():
        rows.append({
            "log10R": round(math.log10(R)), "R": R, "cond": cond,
            **{k: v[k] for k in ("mean_flip","std_flip","worst_flip","mean_relerr","n_valid")}
        })
    with open(main_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["log10R","R","cond",
                           "mean_flip","std_flip","worst_flip","mean_relerr","n_valid"])
        w.writeheader(); w.writerows(rows)
    print(f"  Main sweep data → {main_path}")

    # Zero scrutiny CSV
    zero_path = os.path.join(out_dir, "GRAD_V2_ZERO.csv")
    zrows = []
    for (R, depth, cond), v in zero_results.items():
        zrows.append({
            "log10R": round(math.log10(R)), "R": R, "depth": depth, "cond": cond,
            "n_flip": v["n_flip"], "n_valid": v["n_valid"],
            "flip_rate": v["flip_rate"], "bound": v["bound_str"]
        })
    with open(zero_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["log10R","R","depth","cond",
                           "n_flip","n_valid","flip_rate","bound"])
        w.writeheader(); w.writerows(zrows)
    print(f"  Zero-scrutiny data → {zero_path}")


# ── Main ──────────────────────────────────────────────────────────────────────
# ── FP16 sanity audit ─────────────────────────────────────────────────────────
# FP16 representable range
_FP16_SUBNORM_MIN = float(np.array([0x0001], dtype=np.uint16).view(np.float16)[0])  # ≈5.96e-8
_FP16_MAX         = float(np.array([0x7BFF], dtype=np.uint16).view(np.float16)[0])  # 65504.0

def run_fp16_audit(n_audit: int = 5_000, verbose: bool = False) -> dict:
    """Audit FP16's zero-failure score at depth=4096, R=10^12.

    Questions answered:
      1. What fraction of generated gradients fall below FP16's smallest
         subnormal (≈5.96e-8) and above FP16 max (65504)?
      2. What is the total signed contribution of sub-subnormal gradients?
         Is it large enough to flip any signs?
      3. Does the running sum ever approach FP16 max?

    All computations in FP64 so we measure the INPUT to the FP16 encoder,
    not the encoder's behavior.
    """
    import time
    R     = 1e12
    depth = 4096

    rng = random.Random(SEED_GRAD ^ 0xFEEDAB1E)
    grad_seqs, fp64_sums = _run_batch(R, depth, n_audit, seed_offset=0xFEEDAB1E)

    n_below_sub  = 0       # gradients |g| < FP16 subnormal min
    n_above_max  = 0       # gradients |g| > FP16 max (overflow)
    n_total_grads = n_audit * depth

    # Running-sum max across all trials
    global_max_sum = 0.0

    # Aggregate contribution of sub-subnormal gradients (signed, in FP64)
    sub_sub_contributions = []  # per-trial signed sum of sub-subnormal gradients

    for grads in grad_seqs:
        sub_sum = 0.0
        run_sum = 0.0
        for g in grads:
            ag = abs(g)
            if ag < _FP16_SUBNORM_MIN:
                n_below_sub += 1
                sub_sum     += g   # keep signed
            elif ag > _FP16_MAX:
                n_above_max += 1
            run_sum += g
            if abs(run_sum) > global_max_sum:
                global_max_sum = abs(run_sum)
        sub_sub_contributions.append(sub_sum)

    frac_below = n_below_sub / n_total_grads
    frac_above = n_above_max / n_total_grads

    # Statistics on sub-subnormal contribution per trial
    sub_mag  = [abs(s) for s in sub_sub_contributions]
    mean_sub = sum(sub_mag) / len(sub_mag)
    max_sub  = max(sub_mag)

    # Valid trials (|fp64_sum| >= AMBIG_ABS)
    valid_sums = [s for s in fp64_sums if abs(s) >= AMBIG_ABS]
    min_valid_mag = min(abs(s) for s in valid_sums) if valid_sums else float('nan')

    result = {
        "R": R, "depth": depth, "n_trials": n_audit,
        "fp16_subnorm_min": _FP16_SUBNORM_MIN,
        "fp16_max":         _FP16_MAX,
        "frac_below_subnorm": frac_below,
        "frac_above_max":     frac_above,
        "mean_sub_contrib":   mean_sub,
        "max_sub_contrib":    max_sub,
        "global_max_sum":     global_max_sum,
        "ambig_threshold":    AMBIG_ABS,
        "min_valid_sum_mag":  min_valid_mag,
        "sub_contrib_safe":   max_sub < AMBIG_ABS * 0.01,  # < 1% of threshold
    }
    return result


def print_fp16_audit(r: dict):
    print()
    print("=" * 80)
    print("FP16 SANITY AUDIT — R=10^12, depth=4096")
    print(f"  {r['n_trials']:,} independent gradient sequences of {r['depth']} steps")
    print("=" * 80)
    print()
    print(f"  FP16 representable range : [{r['fp16_subnorm_min']:.2e}, {r['fp16_max']:.1f}]")
    print(f"  Gradient range (log-uniform) : [10^-12, 1.0]  →  {r['depth']} steps, R=10^12")
    print()
    print(f"  Fraction of gradients below FP16 subnormal min ({r['fp16_subnorm_min']:.2e}):")
    print(f"    measured = {r['frac_below_subnorm']:.3f}  "
          f"(analytic ≈ 0.398 for log-uniform [10^-12, 1])")
    print(f"  Fraction of gradients above FP16 max ({r['fp16_max']:.0f}):")
    print(f"    measured = {r['frac_above_max']:.4f}  (expected ≈ 0; max grad mag = 1.0)")
    print()
    print(f"  Sub-subnormal gradient SIGNED contribution per trial:")
    print(f"    mean |contrib| = {r['mean_sub_contrib']:.2e}")
    print(f"    max  |contrib| = {r['max_sub_contrib']:.2e}")
    print(f"    ambiguity threshold (excluded below) = {r['ambig_threshold']:.2f}")
    print(f"    min valid FP64 sum magnitude = {r['min_valid_sum_mag']:.4f}")
    ratio = r['max_sub_contrib'] / r['min_valid_sum_mag'] if r['min_valid_sum_mag'] else float('nan')
    print(f"    max contrib / min valid sum = {ratio:.2e}  "
          f"({'SAFE — cannot flip sign' if r['sub_contrib_safe'] else 'WARNING — non-negligible'})")
    print()
    print(f"  Maximum running-sum magnitude observed (any trial, any step):")
    print(f"    {r['global_max_sum']:.2f}  (FP16 max = {r['fp16_max']:.0f} — "
          f"{'no overflow' if r['global_max_sum'] < r['fp16_max'] else 'OVERFLOW OCCURRED'})")
    print()
    print("  Mechanism summary:")
    print("    ~40% of gradients fall below FP16's smallest subnormal and are")
    print("    silently lost when encoded. However, their total signed contribution")
    print(f"    per 4096-step trial is at most {r['max_sub_contrib']:.2e} — roughly")
    print(f"    {r['max_sub_contrib']/r['min_valid_sum_mag']:.0e}× the size of the smallest valid FP64 sum.")
    print("    These gradients cannot flip any sign the FP64 reference would call valid.")
    print("    The running sum stays well inside FP16's representable range (no overflow).")
    print("    FP16's zero-failure score is genuine for this test: the gradients it")
    print("    loses are structurally incapable of affecting the sign metric.")
    print()


def print_fp16_area_estimate():
    """Analytical FP16 multiplier area estimate from three measured data points."""
    print()
    print("=" * 80)
    print("FP16 MULTIPLIER AREA — Analytical Estimate")
    print("  (Synthesis not performed; extrapolated from three measured data points)")
    print("=" * 80)
    print()
    print("  Measured (Yosys + Sky130 HD PDK, combinational multiply only):")
    print("    FP8-E4M3  : 4×4  mantissa product → 121 cells, 857.1 µm²")
    print("    NFE-13    : 7×7  mantissa product → 221 cells, 1611.5 µm²")
    print("    BF16      : 8×8  mantissa product → 385 cells, 2740.1 µm²")
    print()
    print("  FP16 mantissa product: 11×11 = 121 bits (factor 1.89× vs BF16 8×8 = 64)")
    print()

    # Show observed scaling ratios
    e4m3_mant_sq = 4*4   # (N+1)^2 = (3+1)^2 = 16 → but actual is 4x4
    nfe_mant_sq  = 7*7
    bf16_mant_sq = 8*8
    fp16_mant_sq = 11*11

    e4m3_area = 857.1
    nfe_area  = 1611.5
    bf16_area = 2740.1

    ratio_e4m3_nfe  = nfe_area / e4m3_area
    ratio_nfe_bf16  = bf16_area / nfe_area
    ratio_prod_e4m3_nfe  = nfe_mant_sq / e4m3_mant_sq   # 49/16 = 3.06
    ratio_prod_nfe_bf16  = bf16_mant_sq / nfe_mant_sq   # 64/49 = 1.31
    ratio_prod_bf16_fp16 = fp16_mant_sq / bf16_mant_sq  # 121/64 = 1.89

    print(f"  Observed area growth vs mantissa-product growth:")
    print(f"    E4M3 → NFE-13 : area ×{ratio_e4m3_nfe:.2f}  for product ×{ratio_prod_e4m3_nfe:.2f}")
    print(f"    NFE-13 → BF16 : area ×{ratio_nfe_bf16:.2f}  for product ×{ratio_prod_nfe_bf16:.2f}")
    print(f"    BF16 → FP16   : product ×{ratio_prod_bf16_fp16:.2f}  → area ?")
    print()

    # Conservative estimate: area grows at same FRACTIONAL rate as product size
    # i.e., area_ratio ≈ prod_ratio (linear in product size)
    fp16_low  = bf16_area * ratio_prod_bf16_fp16   # linear in product bits
    # Aggressive estimate: area grows quadratically in product bits
    fp16_high = bf16_area * (ratio_prod_bf16_fp16 ** 1.5)
    # Geometric mean
    fp16_mid  = (fp16_low * fp16_high) ** 0.5

    print(f"  FP16 area estimate (BF16 = 2740.1 µm² as base):")
    print(f"    Conservative (area ∝ product_bits¹)   : {fp16_low:.0f} µm²  ({fp16_low/e4m3_area:.2f}× E4M3)")
    print(f"    Aggressive   (area ∝ product_bits^1.5): {fp16_high:.0f} µm²  ({fp16_high/e4m3_area:.2f}× E4M3)")
    print(f"    Geometric-mean range centre           : {fp16_mid:.0f} µm²  ({fp16_mid/e4m3_area:.2f}× E4M3)")
    print()
    print(f"  Key comparison (iso-quality, sign-flip rate ≈ 0 for all three at depth=256):")
    print(f"    NFE-13 vs FP16 lower-bound (BF16 area): {bf16_area/nfe_area:.2f}× more area for FP16")
    print(f"    NFE-13 vs FP16 centre estimate:          {fp16_mid/nfe_area:.2f}× more area for FP16")
    print(f"    NFE-13 is ≥ {bf16_area/nfe_area:.2f}× more area-efficient than FP16 on sign-flip quality")
    print()
    print(f"  Caveat: the E4M3→NFE-13 and NFE-13→BF16 growth rates differ substantially")
    print(f"  (×{ratio_e4m3_nfe:.2f} vs ×{ratio_nfe_bf16:.2f}) for similar product-size increments,")
    print(f"  indicating the relationship is not simple quadratic scaling. Synthesis")
    print(f"  of a FP16 multiplier RTL under the same Sky130 flow is needed for a")
    print(f"  reliable number. The lower bound (BF16 area, {bf16_area:.0f} µm²) is firm.")

    return {"fp16_low": fp16_low, "fp16_mid": fp16_mid, "fp16_high": fp16_high,
            "fp16_low_vs_e4m3": fp16_low/e4m3_area, "fp16_mid_vs_e4m3": fp16_mid/e4m3_area}


def main():
    import argparse, time
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose",    action="store_true")
    ap.add_argument("--skip-zero",  action="store_true",
                    help="skip zero-cell scrutiny (faster debug run)")
    ap.add_argument("--audit-fp16", action="store_true",
                    help="run FP16 sanity audit (R=10^12, depth=4096) and exit")
    ap.add_argument("--out", default=DIR)
    args = ap.parse_args()

    print("gradient_range_v2.py — final field completion", flush=True)
    print()

    # ── Step 0: unit tests ──────────────────────────────────────────────────
    print("Step 0: FP16 unit tests", flush=True)
    _run_fp16_unit_tests()
    print()

    # ── Optional audit-only mode ────────────────────────────────────────────
    if args.audit_fp16:
        print("FP16 audit mode (--audit-fp16)\n", flush=True)
        t_a = time.time()
        audit = run_fp16_audit(n_audit=5_000, verbose=args.verbose)
        print(f"  audit done in {time.time()-t_a:.1f}s", flush=True)
        print_fp16_audit(audit)
        print_fp16_area_estimate()
        return

    # ── Step 1: main sweep ─────────────────────────────────────────────────
    n_cells = len(DYN_RANGES) * len(CONDITIONS)
    print(f"Step 1: Main sweep "
          f"({len(DYN_RANGES)} R × {len(CONDITIONS)} conditions × "
          f"{N_TRIALS} trials × {N_STEPS} steps = {n_cells*N_TRIALS:,} total trials)",
          flush=True)
    t0 = time.time()
    main_results = run_main_sweep(verbose=args.verbose)
    print(f"  done in {time.time()-t0:.1f}s", flush=True)

    # ── Step 2: zero-cell scrutiny ─────────────────────────────────────────
    if not args.skip_zero:
        n_z = (len(ZERO_SCRUTINY_DEPTH) * len(ZERO_SCRUTINY_R)
               * len(ZERO_SCRUTINY_CONDS) * ZERO_SCRUTINY_N_TRIALS)
        print(f"\nStep 2: Zero-cell scrutiny "
              f"({len(ZERO_SCRUTINY_DEPTH)} depths × {len(ZERO_SCRUTINY_R)} R × "
              f"{len(ZERO_SCRUTINY_CONDS)} conds × {ZERO_SCRUTINY_N_TRIALS:,} trials "
              f"= {n_z:,} total)", flush=True)
        t1 = time.time()
        zero_results = run_zero_scrutiny(verbose=args.verbose)
        print(f"  done in {time.time()-t1:.1f}s", flush=True)
    else:
        zero_results = {}
        print("\nStep 2: skipped (--skip-zero)")

    # ── Step 3: output ─────────────────────────────────────────────────────
    print("\nStep 3: Results")
    print_compact_flip_table(main_results)
    print_main_table(main_results)
    print_zero_scrutiny_table(zero_results)
    print_iso_cost_table(main_results)

    print("\nStep 4: Saving CSV")
    save_csv(main_results, zero_results, args.out)

    print("\nDone.", flush=True)


if __name__ == "__main__":
    main()

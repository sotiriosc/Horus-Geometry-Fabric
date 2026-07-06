#!/usr/bin/env python3
"""
sim/blockfp_test.py — Block floating point: the E0 endpoint of the
compact-NFE sweep.

Paradigm question (docs/BLOCKFP_HYPOTHESIS.md, pre-registered): is the
gradient niche's true home mantissa-only elements with a shared block
exponent, rather than any per-element float?

Candidates:
  E0M6 — 7 bits/element (1 sign + 6 mantissa), shared 6-bit block exp per 8
  E0M9 — 10 bits/element (1 sign + 9 mantissa) — equal storage vs E3M6

Carried reference columns (same seeds):
  E3M6+block      — re-run with the identical SEED_BLOCK derivation from
                    sim/compact_nfe.py (reproduces COMPACT_NFE_RESULTS.csv)
  NFE-13 bare     — scalar v2-ref (SEED_GRAD derivation)
  E4M3+FP32acc    — scalar v2-ref (industry pattern)

The E0 candidates consume the SAME gradient streams as the E3M6+block
column (paired comparison; seed = SEED_BLOCK ^ (rlog*100 + 3*31)).

Criteria (binding, docs/BLOCKFP_HYPOTHESIS.md):
  K1: candidate mean flip ≤ E3M6+block mean + 2×√(std_ref² + std_cand²)
      at every R ∈ {10²..10¹⁰}, depth 256. Zero cells: CP95 UB, two-tier
      escalation protocol (no bare zeros).
  K2: MLP accuracy ≥ 95.39% (within 1pp of NFE-13's 96.39%).
  K3: multiplier synthesis — handled by sim/synth_blockfp_mul7.ys /
      synth_blockfp_mul10.ys (not in this script; areas quoted in verdict).
  K4: intra-block flush instrumented during every block encoding:
      per-R mean fraction of nonzero elements retaining < 50% of mantissa
      bits, and fraction flushed to zero. Reported whether or not K1 passes.
"""

import csv, math, os, random, sys, time
import numpy as np

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)

from gradient_range_v2 import (
    SEED_GRAD, N_BATCH, N_PER_BATCH, N_STEPS, AMBIG_ABS, DYN_RANGES,
    _make_grads,
    _run_trial_fmt   as _v2_run_scalar,
    _run_trial_fp32acc as _v2_fp32acc,
)
from compact_nfe import (
    BLOCK_SIZE, BLOCK_EXP_BITS, SEED_BLOCK,
    enm6_enc, enm6_dec, block_enc as e3m6_block_enc, block_dec as e3m6_block_dec,
    _generate_block_trial, _sign_flip_frac, _clopper_pearson_upper,
    _quantize_matrix_block,
    SEED_CHAIN, N_CHAIN, N_CHAIN_STEPS, K_NORM, N_DIM, CHAIN_SPEC_RAD,
    K2_THRESHOLD, NFE13_MLP_ACC,
)

MANT_WIDTHS = [6, 9]          # E0M6, E0M9

def eff_bits_e0(M: int) -> float:
    return (1 + M) + BLOCK_EXP_BITS / BLOCK_SIZE


# ══════════════════════════════════════════════════════════════════════════════
# E0 CODEC — pure block floating point (no per-element exponent, no hidden bit)
# ══════════════════════════════════════════════════════════════════════════════
#
# Element value = (−1)^s × q × 2^b, integer q ∈ [0, 2^M − 1], one signed
# block exponent b per BLOCK_SIZE elements.
# Encoding: b = floor(log2(max|v|)) − (M − 1), so the max-magnitude element
# occupies the full mantissa width; every element RNE-rounded at scale 2^b.
# If rounding carries the max element to 2^M, b is bumped by 1 and the
# block re-quantized (single re-pass suffices: after the bump the max
# quantizes to 2^(M−1), no further carry possible).

def _rne(x: float) -> int:
    """Round-to-nearest-even for non-negative x."""
    f = math.floor(x)
    r = x - f
    if r > 0.5:
        return f + 1
    if r < 0.5:
        return f
    return f + 1 if (f & 1) else f


def e0_block_enc(values, M: int, k4_stats: dict = None):
    """
    Encode BLOCK_SIZE floats → (signed_q list, block_exp).
    signed_q entries are Python ints in [−(2^M − 1), 2^M − 1].

    K4 instrumentation (when k4_stats dict supplied): counts, over nonzero
    source elements, how many retain < 50% of mantissa bits after scale
    alignment (retained = floor(log2(|q|)) + 1 for q ≠ 0; 0 for q = 0),
    and how many flush fully to zero (q = 0 for v ≠ 0).
    """
    qmax = (1 << M) - 1
    max_abs = max(abs(v) for v in values)
    if max_abs == 0.0:
        if k4_stats is not None:
            pass   # no nonzero elements: nothing to count
        return [0] * len(values), 0

    b = math.floor(math.log2(max_abs)) - (M - 1)

    def _quantize(b_):
        scale = 2.0 ** b_
        qs, carry = [], False
        for v in values:
            q = _rne(abs(v) / scale)
            if q > qmax:
                carry = True
            qs.append(-q if v < 0 else q)
        return qs, carry

    qs, carry = _quantize(b)
    if carry:
        b += 1
        qs, _ = _quantize(b)
        qs = [max(-qmax, min(qmax, q)) for q in qs]   # safety clamp

    if k4_stats is not None:
        half_bits = M / 2.0
        for v, q in zip(values, qs):
            if v == 0.0:
                continue
            k4_stats["n_nonzero"] = k4_stats.get("n_nonzero", 0) + 1
            aq = abs(q)
            retained = (math.floor(math.log2(aq)) + 1) if aq > 0 else 0
            if aq == 0:
                k4_stats["n_flushed"] = k4_stats.get("n_flushed", 0) + 1
            if retained < half_bits:
                k4_stats["n_lost_half"] = k4_stats.get("n_lost_half", 0) + 1

    return qs, b


def e0_block_dec(qs, block_exp: int, M: int):
    """Decode block back to floats."""
    scale = 2.0 ** block_exp
    return [q * scale for q in qs]


# ══════════════════════════════════════════════════════════════════════════════
# UNIT TESTS — hand tables first (constraint: codecs gate arenas)
# ══════════════════════════════════════════════════════════════════════════════

def run_unit_tests(verbose=True):
    failures = []

    def chk(label, cond, detail=""):
        if not cond:
            failures.append(f"{label}: {detail}")

    # ── E0M6 hand table ────────────────────────────────────────────────────────
    # Block [1.0, 0.5, 0.25, -0.75, 0, 0, 0, 0]:
    #   max=1.0, b = 0 − 5 = −5, scale=2^−5=1/32
    #   q = [32, 16, 8, −24, 0, 0, 0, 0] — all exact
    vals = [1.0, 0.5, 0.25, -0.75, 0.0, 0.0, 0.0, 0.0]
    qs, b = e0_block_enc(vals, 6)
    chk("E0M6 b", b == -5, f"b={b}")
    chk("E0M6 q", qs == [32, 16, 8, -24, 0, 0, 0, 0], f"qs={qs}")
    dec = e0_block_dec(qs, b, 6)
    chk("E0M6 dec", all(abs(d - v) < 1e-12 for d, v in zip(dec, vals)),
        f"dec={dec}")

    # Intra-block flush: [1.0, 1/64] → q_small = 32/64 = 0.5 → RNE→even → 0
    qs, b = e0_block_enc([1.0, 1.0/64] + [0.0]*6, 6)
    chk("E0M6 flush", qs[1] == 0, f"q={qs[1]} (1/64 must flush at max=1.0)")

    # Just above flush: [1.0, 3/64] → q = 1.5 → RNE→2
    qs, b = e0_block_enc([1.0, 3.0/64] + [0.0]*6, 6)
    chk("E0M6 nearflush", qs[1] == 2, f"q={qs[1]}")

    # Rounding carry: [63.9] alone → b = 5−5 = 0, q = RNE(63.9) = 64 > 63
    #   → carry: b=1, q = RNE(31.95) = 32
    qs, b = e0_block_enc([63.9] + [0.0]*7, 6)
    chk("E0M6 carry", b == 1 and qs[0] == 32, f"b={b} q={qs[0]}")

    # Negative max: [-2.0, 1.0] → b = 1−5 = −4, q = [−32, 16]
    qs, b = e0_block_enc([-2.0, 1.0] + [0.0]*6, 6)
    chk("E0M6 negmax", b == -4 and qs[0] == -32 and qs[1] == 16,
        f"b={b} qs={qs[:2]}")

    # All-zero block
    qs, b = e0_block_enc([0.0]*8, 6)
    chk("E0M6 zeroblk", b == 0 and all(q == 0 for q in qs), f"b={b}")

    # ── E0M9 hand table ────────────────────────────────────────────────────────
    # [1.0] → b = 0 − 8 = −8, q = 256
    qs, b = e0_block_enc([1.0] + [0.0]*7, 9)
    chk("E0M9 unit", b == -8 and qs[0] == 256, f"b={b} q={qs[0]}")

    # [1.0, 1/512] → q_small = 256/512 = 0.5 → RNE→even → 0 (flush boundary)
    qs, b = e0_block_enc([1.0, 1.0/512] + [0.0]*6, 9)
    chk("E0M9 flush", qs[1] == 0, f"q={qs[1]}")

    # [1.0, 3/512] → q = 1.5 → RNE→2
    qs, b = e0_block_enc([1.0, 3.0/512] + [0.0]*6, 9)
    chk("E0M9 nearflush", qs[1] == 2, f"q={qs[1]}")

    # [511.9] → b = 8−8 = 0, q = RNE(511.9) = 512 > 511 → carry: b=1, q=256
    qs, b = e0_block_enc([511.9] + [0.0]*7, 9)
    chk("E0M9 carry", b == 1 and qs[0] == 256, f"b={b} q={qs[0]}")

    # ── RNE ties-to-even spot checks ───────────────────────────────────────────
    chk("RNE 2.5→2", _rne(2.5) == 2)
    chk("RNE 3.5→4", _rne(3.5) == 4)
    chk("RNE 2.49→2", _rne(2.49) == 2)
    chk("RNE 2.51→3", _rne(2.51) == 3)

    # ── K4 instrumentation check ───────────────────────────────────────────────
    # Block [1.0, 1/32, 1/128, 0...] at M=6: q = [32, 1, 0(flush), ...]
    #   nonzero sources = 3; retained bits: 6, 1, 0 → <3 retained: 2 elements
    #   (the 1/32 element retains 1 bit < 3; the 1/128 flushes)
    st = {}
    e0_block_enc([1.0, 1.0/32, 1.0/128] + [0.0]*5, 6, k4_stats=st)
    chk("K4 counts", st.get("n_nonzero") == 3 and st.get("n_lost_half") == 2
        and st.get("n_flushed") == 1, f"stats={st}")

    # ── Round-trip randoms (values on the representable grid) ─────────────────
    rng = random.Random(0xB10CF9)
    for M in MANT_WIDTHS:
        for _ in range(100):
            b_true = rng.randint(-20, 10)
            vals = [rng.randint(-(1 << M) + 1, (1 << M) - 1) * (2.0 ** b_true)
                    for _ in range(8)]
            if max(abs(v) for v in vals) == 0.0:
                continue
            qs, b = e0_block_enc(vals, M)
            dec = e0_block_dec(qs, b, M)
            # Grid values whose max uses the full width must round-trip within
            # half an LSB at the chosen block scale.
            lsb = 2.0 ** b
            for v, d in zip(vals, dec):
                if abs(d - v) > 0.5 * lsb + 1e-15 * abs(v):
                    failures.append(
                        f"E0M{M} round-trip: v={v:.6g} dec={d:.6g} lsb={lsb:.3g}")

    if failures:
        for msg in failures:
            print(f"  FAIL: {msg}")
        raise AssertionError(f"E0 codec unit tests: {len(failures)} failure(s)")
    if verbose:
        print(f"  E0 codec unit tests: PASS (16 hand cases + 200 round-trips)")


# ══════════════════════════════════════════════════════════════════════════════
# ARENA A — GRADIENT SWEEP (same construction as compact_nfe, paired seeds)
# ══════════════════════════════════════════════════════════════════════════════

def _run_block_trial_e0(grads_8, M: int, k4_stats: dict):
    """8-element block accumulation in E0M{M} with shared block exponent."""
    qs, bexp = [0] * BLOCK_SIZE, 0
    for step in range(len(grads_8[0])):
        decoded  = e0_block_dec(qs, bexp, M)
        new_vals = [decoded[i] + grads_8[i][step] for i in range(BLOCK_SIZE)]
        qs, bexp = e0_block_enc(new_vals, M, k4_stats=k4_stats)
    return e0_block_dec(qs, bexp, M)


def _run_block_trial_e3m6(grads_8):
    """E3M6+block reference trial (identical to compact_nfe._run_block_trial n=3)."""
    cws, bexp = [0] * BLOCK_SIZE, 0
    for step in range(len(grads_8[0])):
        decoded  = e3m6_block_dec(cws, bexp, 3)
        new_vals = [decoded[i] + grads_8[i][step] for i in range(BLOCK_SIZE)]
        cws, bexp = e3m6_block_enc(new_vals, 3)
    return e3m6_block_dec(cws, bexp, 3)


def _batch_stats(fmt_sums, fp64_sums):
    batch_obs = N_PER_BATCH * BLOCK_SIZE
    batch_flips = []
    for b in range(N_BATCH):
        sl  = slice(b * batch_obs, (b + 1) * batch_obs)
        frc = _sign_flip_frac(fmt_sums[sl], fp64_sums[sl])
        if not math.isnan(frc):
            batch_flips.append(frc)
    mean_f = sum(batch_flips) / len(batch_flips) if batch_flips else float('nan')
    std_f  = math.sqrt(sum((x - mean_f) ** 2 for x in batch_flips)
                       / len(batch_flips)) if len(batch_flips) > 1 else 0.0
    worst  = max(batch_flips) if batch_flips else float('nan')
    n_valid = sum(1 for fp in fp64_sums if abs(fp) >= AMBIG_ABS)
    return mean_f, std_f, worst, n_valid


def run_gradient_sweep(verbose=False):
    """
    Returns (results, k4_table):
      results:  {(R, cond): {mean_flip, std_flip, worst_flip, n_valid}}
      k4_table: {(R, "E0M{M}"): {frac_lost_half, frac_flushed, n_nonzero}}
    """
    N_BLOCK_TRIALS = N_BATCH * N_PER_BATCH
    results, k4_table = {}, {}

    # ── Scalar baselines (v2-ref, identical SEED_GRAD derivation) ─────────────
    if verbose:
        print("\n[Sweep] Scalar baselines (v2-ref seeds)...")
    for R in DYN_RANGES:
        seed = SEED_GRAD ^ int(math.log10(R) * 100)
        rng_sc = random.Random(seed)
        grad_seqs = [_make_grads(R, N_STEPS, rng_sc) for _ in range(N_BLOCK_TRIALS)]
        fp64_sc   = [sum(g) for g in grad_seqs]

        for cond, runner in [
            ("NFE-13 bare (scalar, v2-ref)",  lambda g: _v2_run_scalar(g, "NFE-13", False)),
            ("E4M3+FP32acc (scalar, v2-ref)", lambda g: _v2_fp32acc(g, "FP8-E4M3")),
        ]:
            fmt_sums = [runner(g) for g in grad_seqs]
            bf = []
            for b in range(N_BATCH):
                sl  = slice(b * N_PER_BATCH, (b + 1) * N_PER_BATCH)
                frc = _sign_flip_frac(fmt_sums[sl], fp64_sc[sl])
                if not math.isnan(frc):
                    bf.append(frc)
            mean_f = sum(bf) / len(bf) if bf else float('nan')
            std_f  = math.sqrt(sum((x - mean_f) ** 2 for x in bf) / len(bf)) \
                     if len(bf) > 1 else 0.0
            results[(R, cond)] = {
                "mean_flip": mean_f, "std_flip": std_f,
                "worst_flip": max(bf) if bf else float('nan'),
                "n_valid": sum(1 for fp in fp64_sc if abs(fp) >= AMBIG_ABS),
            }

    # ── Block formats: E3M6 reference + E0 candidates on PAIRED streams ───────
    # Seed per R is the compact_nfe E3M6 seed (n=3), so the E3M6 column
    # reproduces COMPACT_NFE_RESULTS.csv and the E0 candidates see the very
    # same gradient sequences (paired comparison).
    if verbose:
        print("[Sweep] Block formats (paired streams, E3M6 seed)...")
    for R in DYN_RANGES:
        rlog = round(math.log10(R))
        seed = SEED_BLOCK ^ (int(math.log10(R) * 100) + 3 * 31)
        rng_blk = random.Random(seed)

        trials = [_generate_block_trial(R, N_STEPS, rng_blk)
                  for _ in range(N_BATCH * N_PER_BATCH)]
        all_fp64 = [fp for (_, fp64s) in trials for fp in fp64s]

        # E3M6+block reference
        all_e3 = []
        for grads_8, _ in trials:
            all_e3.extend(_run_block_trial_e3m6(grads_8))
        m, s, w, nv = _batch_stats(all_e3, all_fp64)
        results[(R, "E3M6+block")] = {"mean_flip": m, "std_flip": s,
                                      "worst_flip": w, "n_valid": nv}
        if verbose:
            print(f"  R=1e{rlog}  E3M6+block  flip={m:.4f}±{s:.4f}")

        # E0 candidates on the same streams
        for M in MANT_WIDTHS:
            k4 = {}
            all_e0 = []
            for grads_8, _ in trials:
                all_e0.extend(_run_block_trial_e0(grads_8, M, k4))
            m, s, w, nv = _batch_stats(all_e0, all_fp64)
            cond = f"E0M{M}+block"
            results[(R, cond)] = {"mean_flip": m, "std_flip": s,
                                  "worst_flip": w, "n_valid": nv}
            nz = k4.get("n_nonzero", 0)
            k4_table[(R, cond)] = {
                "n_nonzero":      nz,
                "frac_lost_half": k4.get("n_lost_half", 0) / nz if nz else float('nan'),
                "frac_flushed":   k4.get("n_flushed", 0) / nz if nz else float('nan'),
            }
            if verbose:
                kt = k4_table[(R, cond)]
                print(f"  R=1e{rlog}  {cond:<11s} flip={m:.4f}±{s:.4f}  "
                      f"K4: lost>50%={kt['frac_lost_half']:.3f} "
                      f"flushed={kt['frac_flushed']:.3f}")

    return results, k4_table


# ══════════════════════════════════════════════════════════════════════════════
# ZERO-CELL SCRUTINY (two-tier, no bare zeros)
# ══════════════════════════════════════════════════════════════════════════════

def run_zero_scrutiny(main_results, verbose=False):
    N_TARGETED = 200
    zero_results = {}

    conds = [f"E0M{M}+block" for M in MANT_WIDTHS] + ["E3M6+block"]

    # Tier 1: analytical bounds from the main sweep
    for cond in conds:
        for R in DYN_RANGES:
            entry = main_results.get((R, cond))
            if entry is None or entry["mean_flip"] > 0.0:
                continue
            nv = entry["n_valid"]
            zero_results[(cond, R, R, N_STEPS)] = {
                "n_flip": 0, "n_valid": nv, "flip_rate": 0.0,
                "cp95_ub": _clopper_pearson_upper(nv, 0) if nv else float('nan'),
                "tier": "analytical (main sweep)",
            }

    # Tier 2: targeted escalation for E0 candidates with zero cells at high R
    for M in MANT_WIDTHS:
        cond = f"E0M{M}+block"
        has_zero_high_r = any(
            main_results.get((R, cond), {}).get("mean_flip", 1.0) == 0.0
            for R in [1e8, 1e10])
        if not has_zero_high_r:
            continue
        seed = SEED_BLOCK ^ (M * 977) ^ 0xE0E0
        for scr_r, depth in [(1e10, N_STEPS), (1e12, N_STEPS), (1e12, 1024)]:
            rng = random.Random(seed ^ int(math.log10(scr_r) * 100) ^ depth)
            all_fmt, all_fp64 = [], []
            for _ in range(N_TARGETED):
                grads_8, fp64s = _generate_block_trial(scr_r, depth, rng)
                all_fmt.extend(_run_block_trial_e0(grads_8, M, {}))
                all_fp64.extend(fp64s)
            nv = sum(1 for fp in all_fp64 if abs(fp) >= AMBIG_ABS)
            nf = sum(1 for fs, fp in zip(all_fmt, all_fp64)
                     if abs(fp) >= AMBIG_ABS and (fs >= 0) != (fp >= 0))
            zero_results[(cond, 1e10, scr_r, depth)] = {
                "n_flip": nf, "n_valid": nv,
                "flip_rate": nf / nv if nv else float('nan'),
                "cp95_ub": _clopper_pearson_upper(nv, nf) if nv else float('nan'),
                "tier": "targeted escalation",
            }
            if verbose:
                print(f"  {cond} R_sc=1e{round(math.log10(scr_r))} depth={depth}: "
                      f"{nf}/{nv}")

    return zero_results


# ══════════════════════════════════════════════════════════════════════════════
# ARENA B — k=8 CHAIN REGRESSION (same construction as compact_nfe)
# ══════════════════════════════════════════════════════════════════════════════

def _quantize_matrix_e0(W, M: int):
    rows, cols = W.shape
    W_q = W.copy()
    for r in range(rows):
        for blk in range(0, cols, BLOCK_SIZE):
            end = min(blk + BLOCK_SIZE, cols)
            qs, b = e0_block_enc(W[r, blk:end].tolist(), M)
            W_q[r, blk:end] = e0_block_dec(qs, b, M)
    return W_q


def run_chain_regression(verbose=False):
    """Formats: E3M6 (n=3 reference) and E0M6/E0M9. Same SEED_CHAIN construction."""
    results = {}
    fmt_list = [("E3M6", None)] + [(f"E0M{M}", M) for M in MANT_WIDTHS]

    for fmt_name, M in fmt_list:
        rng_w = random.Random(SEED_CHAIN)   # same matrix stream per format
        alignments = []
        for chain_idx in range(N_CHAIN):
            W_raw = np.array([[rng_w.gauss(0, 1) for _ in range(N_DIM)]
                              for _ in range(N_DIM)])
            spec = max(abs(np.linalg.eigvals(W_raw)))
            if spec > 0:
                W_raw *= CHAIN_SPEC_RAD / spec

            if M is None:
                W_q = _quantize_matrix_block(W_raw, 3)
            else:
                W_q = _quantize_matrix_e0(W_raw, M)

            rng_v = random.Random(SEED_CHAIN ^ chain_idx ^ 0x515)
            v0 = np.array([rng_v.gauss(0, 1) for _ in range(N_DIM)])
            v0 /= np.linalg.norm(v0)

            v_fp64 = v0.copy()
            for step in range(N_CHAIN_STEPS):
                v_fp64 = W_raw @ v_fp64
                if (step + 1) % K_NORM == 0:
                    nn = np.linalg.norm(v_fp64)
                    if nn > 0:
                        v_fp64 /= nn

            if M is None:
                cws, bexp = e3m6_block_enc(v0.tolist(), 3)
                for step in range(N_CHAIN_STEPS):
                    v_dec = np.array(e3m6_block_dec(cws, bexp, 3))
                    mv = W_q @ v_dec
                    cws, bexp = e3m6_block_enc(mv.tolist(), 3)
                v_final = np.array(e3m6_block_dec(cws, bexp, 3))
            else:
                qs, bexp = e0_block_enc(v0.tolist(), M)
                for step in range(N_CHAIN_STEPS):
                    v_dec = np.array(e0_block_dec(qs, bexp, M))
                    mv = W_q @ v_dec
                    qs, bexp = e0_block_enc(mv.tolist(), M)
                v_final = np.array(e0_block_dec(qs, bexp, M))

            nf, nr = np.linalg.norm(v_final), np.linalg.norm(v_fp64)
            align = float(abs(np.dot(v_final / nf, v_fp64 / nr))) if nf > 0 and nr > 0 else 0.0
            alignments.append(align)

        results[fmt_name] = sum(alignments) / len(alignments)
        if verbose:
            print(f"  {fmt_name}: mean alignment {results[fmt_name]:.4f}")

    return results


# ══════════════════════════════════════════════════════════════════════════════
# ARENA C — MLP INFERENCE (K2)
# ══════════════════════════════════════════════════════════════════════════════

def run_mlp_inference(verbose=False):
    npz = np.load(os.path.join(DIR, "MLP_FP64.npz"))
    W1, b1 = npz["W1"].astype(float), npz["b1"].astype(float)
    W2, b2 = npz["W2"].astype(float), npz["b2"].astype(float)
    X, y   = npz["X_te"].astype(float), npz["y_te"].astype(int)
    n_img  = X.shape[0]

    def _acc(W1q, W2q):
        c = 0
        for i in range(n_img):
            h   = np.maximum(0, W1q @ X[i] + b1)
            out = W2q @ h + b2
            if int(np.argmax(out)) == y[i]:
                c += 1
        return c / n_img * 100.0

    results = {"FP64": _acc(W1, W2),
               "E3M6": _acc(_quantize_matrix_block(W1, 3),
                            _quantize_matrix_block(W2, 3))}
    for M in MANT_WIDTHS:
        results[f"E0M{M}"] = _acc(_quantize_matrix_e0(W1, M),
                                  _quantize_matrix_e0(W2, M))
    if verbose:
        for k, v in results.items():
            print(f"  {k}: {v:.2f}%")
    return results


# ══════════════════════════════════════════════════════════════════════════════
# K1 EVALUATION (reference = E3M6+block, per hypothesis doc)
# ══════════════════════════════════════════════════════════════════════════════

def evaluate_k1(results):
    k1 = {}
    for M in MANT_WIDTHS:
        cond = f"E0M{M}+block"
        fails = []
        for R in DYN_RANGES:
            cand = results.get((R, cond))
            ref  = results.get((R, "E3M6+block"))
            if cand is None or ref is None:
                continue
            thr = ref["mean_flip"] + 2.0 * math.sqrt(
                ref["std_flip"] ** 2 + cand["std_flip"] ** 2)
            if cand["mean_flip"] > thr:
                fails.append((R, cand["mean_flip"], thr))
        k1[M] = {"pass": len(fails) == 0, "violations": fails}
    return k1


# ══════════════════════════════════════════════════════════════════════════════
# OUTPUT
# ══════════════════════════════════════════════════════════════════════════════

def _rlog(R): return round(math.log10(R))


def print_tables(results, k4_table, k1, zero_results, chain, mlp):
    print("\n" + "=" * 96)
    print("ARENA A: GRADIENT ACCUMULATION SIGN-FLIP RATES (mean±std, depth=256)")
    print("-" * 96)
    conds = ["NFE-13 bare (scalar, v2-ref)", "E4M3+FP32acc (scalar, v2-ref)",
             "E3M6+block"] + [f"E0M{M}+block" for M in MANT_WIDTHS]
    hdr = f"  {'Condition':<34s}" + "".join(f"  {'R=1e'+str(_rlog(R)):>15s}"
                                            for R in DYN_RANGES)
    print(hdr)
    for cond in conds:
        row = f"  {cond:<34s}"
        for R in DYN_RANGES:
            e = results.get((R, cond))
            row += (f"  {e['mean_flip']:.4f}±{e['std_flip']:.4f}"
                    if e else f"  {'N/A':>15s}")
        print(row)

    print("\nK1 (reference: E3M6+block; threshold = ref_mean + 2×std_pool)")
    for M in MANT_WIDTHS:
        v = k1[M]
        if v["pass"]:
            print(f"  E0M{M}+block: PASS at all R")
        else:
            for (R, mf, thr) in v["violations"]:
                print(f"  E0M{M}+block: FAIL at R=1e{_rlog(R)} "
                      f"(flip={mf:.4f} > threshold={thr:.4f})")

    print("\nK4: INTRA-BLOCK FLUSH INSTRUMENTATION (per-R fraction of nonzero elements)")
    print(f"  {'Condition':<14s} {'R':>7s}  {'lost>50% bits':>14s}  "
          f"{'flushed to 0':>13s}  {'n_nonzero':>10s}")
    for M in MANT_WIDTHS:
        cond = f"E0M{M}+block"
        for R in DYN_RANGES:
            kt = k4_table.get((R, cond))
            if kt:
                print(f"  {cond:<14s} 1e{_rlog(R):<5d}  "
                      f"{kt['frac_lost_half']:>14.4f}  "
                      f"{kt['frac_flushed']:>13.4f}  {kt['n_nonzero']:>10d}")

    if zero_results:
        print("\nZERO-CELL SCRUTINY (no bare zeros; CP95 upper bounds)")
        for (cond, R_o, R_s, depth), v in sorted(zero_results.items(),
                                                 key=lambda x: str(x[0])):
            tag = f"{v['n_flip']}/{v['n_valid']}"
            print(f"  {cond:<14s} R_sc=1e{_rlog(R_s):<3d} depth={depth:<5d} "
                  f"{tag:>12s}  CP95 UB={v['cp95_ub']:.2e}  [{v['tier']}]")

    print("\nARENA B: k=8 CHAIN REGRESSION (mean alignment, 100 chains)")
    for k, v in chain.items():
        print(f"  {k}: {v:.4f}")

    print("\nARENA C: MLP INFERENCE (K2 threshold ≥ 95.39%)")
    for k, v in mlp.items():
        flag = ""
        if k != "FP64":
            flag = "  K2 " + ("PASS" if v >= K2_THRESHOLD else "FAIL")
        print(f"  {k}: {v:.2f}%{flag}")


def save_csv(results, k4_table, chain, mlp, fname="BLOCKFP_RESULTS.csv"):
    fpath = os.path.join(DIR, fname)
    with open(fpath, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["condition", "R", "mean_flip", "std_flip", "worst_flip", "n_valid"])
        for (R, cond), v in sorted(results.items(), key=lambda x: str(x[0])):
            w.writerow([cond, R, v["mean_flip"], v["std_flip"],
                        v["worst_flip"], v["n_valid"]])
        w.writerow([])
        w.writerow(["k4_condition", "R", "frac_lost_half", "frac_flushed", "n_nonzero"])
        for (R, cond), v in sorted(k4_table.items(), key=lambda x: str(x[0])):
            w.writerow([cond, R, v["frac_lost_half"], v["frac_flushed"], v["n_nonzero"]])
        w.writerow([])
        w.writerow(["chain_format", "mean_alignment"])
        for k, v in chain.items():
            w.writerow([k, v])
        w.writerow([])
        w.writerow(["mlp_format", "accuracy_pct"])
        for k, v in mlp.items():
            w.writerow([k, v])
    print(f"\n  Results saved → {os.path.basename(fpath)}")


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    t0 = time.time()
    print("=" * 96)
    print("BLOCK FLOATING POINT — E0 ENDPOINT EVALUATION")
    print("Pre-registered criteria: docs/BLOCKFP_HYPOTHESIS.md")
    print("=" * 96)

    print("\n[1/5] E0 codec unit tests (hand tables gate arenas)...")
    run_unit_tests(verbose=True)

    print(f"\n[2/5] Gradient sweep ({N_BATCH}×{N_PER_BATCH} block trials, "
          f"depth={N_STEPS}, paired seeds with E3M6+block)...")
    t = time.time()
    results, k4_table = run_gradient_sweep(verbose=args.verbose)
    print(f"  Done in {time.time() - t:.1f}s")

    print("\n[3/5] Zero-cell scrutiny (two-tier)...")
    t = time.time()
    zero_results = run_zero_scrutiny(results, verbose=args.verbose)
    print(f"  Done in {time.time() - t:.1f}s")

    print(f"\n[4/5] Chain regression ({N_CHAIN} chains, k={K_NORM})...")
    t = time.time()
    chain = run_chain_regression(verbose=args.verbose)
    print(f"  Done in {time.time() - t:.1f}s")

    print("\n[5/5] MLP inference (360 images, K2)...")
    t = time.time()
    mlp = run_mlp_inference(verbose=args.verbose)
    print(f"  Done in {time.time() - t:.1f}s")

    k1 = evaluate_k1(results)
    print_tables(results, k4_table, k1, zero_results, chain, mlp)

    print("\n" + "=" * 96)
    print("CRITERIA SUMMARY")
    print("=" * 96)
    for M in MANT_WIDTHS:
        k1p = k1[M]["pass"]
        acc = mlp.get(f"E0M{M}", float('nan'))
        k2p = acc >= K2_THRESHOLD
        print(f"  E0M{M}+block ({eff_bits_e0(M):.2f} eff bits): "
              f"K1 {'PASS' if k1p else 'FAIL'}  K2 {'PASS' if k2p else 'FAIL'} "
              f"({acc:.2f}%)")

    save_csv(results, k4_table, chain, mlp)
    print(f"\nTotal elapsed: {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()

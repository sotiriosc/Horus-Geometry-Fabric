#!/usr/bin/env python3
"""
sim/recurrent_niche.py — Mantissa-precision hypothesis test.

Hypothesis: under per-step block-exponent re-grounding, a 3-bit mantissa
(E4M3) degrades where a 6-bit mantissa (NFE-13) holds, because normalization
corrects scale but not per-element precision.

Three tasks, all designed to be losable:

Task 1 — Normalized-chain rematch (methodology: sim/second_source_chain.py,
  sim/format_zoo.py Arena B, sim/norm_interval_sweep.py §k-norm).
  All five formats, 256-cycle neutral-regime chains, k ∈ {1,4,8,16},
  lossless block-exponent re-grounding per format.  Metric: cosine alignment
  with FP64 golden at t=256.  Pivotal: E4M3@k=8 vs NFE-13@k=8.

Task 2a — Power-iteration convergence (methodology: sim/norm_interval_sweep.py
  SEED_PI construction, lines 184-198).
  50 symmetric-positive 8×8 matrices.  Per format: fraction converging to
  alignment ≥ 0.99 within 256 steps, and mean iterations to convergence.
  Re-grounding every step (k=1).

Task 2b — Echo-state-network (ESN) recall.
  Reservoir RNN (16 hidden units, spectral radius 0.9).  Trained in FP64 via
  least-squares on a delayed-recall task (8-class one-hot, recall distance
  N ∈ {4, 8, 16}).  Quantized inference: all weights kept in FP64; hidden
  state h_t quantized to format with re-grounding after each tanh step.
  Metric: fraction of tokens correctly recalled vs N per format.

Re-grounding per format (most favorable treatment for each):
  NFE-13    : lossless exponent shift to E_TARGET=32 (mirrors horus_norm_v2;
              sim/mlp_infer_nfe.py lines 118-137).
  FP8-E4M3  : lossless exponent shift to target_e=7 (bias point: max→1.0).
              OCP FP8 Spec v1.0; Micikevicius et al. NeurIPS 2022.
  FP8-E5M2  : lossless exponent shift to target_e=15.  Same sources.
  BF16      : lossless exponent shift to target_e=127 (IEEE 754 float32 bias).
  INT8      : decode → find new scale=max_abs/127 → re-quantize.
              Standard per-tensor symmetric quantization (Jacob et al. CVPR 2018).
              The only option for INT8 (no exponent field to shift directly).

Same PRNG seeds as prior sessions within each task family.
Every number traceable to this script + docs/RECURRENT_NICHE.md.
"""

import argparse
import csv
import math
import os
import random
import sys

import numpy as np

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)
from format_zoo import (
    nfe_enc, nfe_dec, nfe_mul_fields,
    fp8_e4m3_enc, fp8_e4m3_dec, fp8_e4m3_mul,
    fp8_e5m2_enc, fp8_e5m2_dec, fp8_e5m2_mul,
    bf16_enc, bf16_dec, bf16_mul,
    int8_enc, int8_dec, int8_calibrate,
    BITS,
)

# ── Constants ─────────────────────────────────────────────────────────────────
N            = 8       # state dimension (chains / power iteration)
N_H          = 16      # hidden units for ESN
N_IN         = 8       # input classes for ESN (one-hot)
N_CHAINS     = 100
DEPTH        = 256
MAX_PI_ITER  = 256
N_PI         = 50

# NFE exponent constants
_NFE_EMAX    = 63
_NFE_ETGT    = 32      # E_TARGET for block-exponent normalizer
# Per-format re-grounding target biased exponent (brings max element to ≈ 1.0)
_E4M3_ETGT   = 7       # bias 7, so 2^(e-7) = 1 at e=7
_E5M2_ETGT   = 15      # bias 15
_BF16_ETGT   = 127     # bias 127

# Seeds (matching existing session seeds)
SEED_CHAIN   = 0xCAFEF00D   # matches second_source_chain.py SEED_SSC_BASE
SEED_PI      = 0xFACEFEED   # matches norm_interval_sweep.py SEED_PI_BASE line 50
SEED_ESN     = 0x3B8E1F27   # fresh seed for ESN task

FORMATS = ["NFE-13", "FP8-E4M3", "FP8-E5M2", "BF16", "INT8"]
K_VALUES = [1, 4, 8, 16]

# ─────────────────────────────────────────────────────────────────────────────
# PART 1 — LOSSLESS BLOCK-EXPONENT RE-GROUNDING
# For FP formats: add offset to exponent field, mantissa bits preserved exactly.
# This is strictly lossless: the re-grounding step itself costs zero precision.
# ─────────────────────────────────────────────────────────────────────────────

def nfe_reground(state, tgt=_NFE_ETGT):
    """Lossless exponent shift for NFE-13 vector.  Mirrors horus_norm_v2."""
    e_vals = [e for s, e, f in state if e > 0]
    if not e_vals:
        return list(state)
    off = tgt - max(e_vals)
    if off == 0:
        return list(state)
    out = []
    for s, e, f in state:
        if e == 0:
            out.append((s, 0, 0))
        else:
            ne = e + off
            if ne <= 0:
                out.append((s, 0, 0))
            elif ne > _NFE_EMAX:
                out.append((s, _NFE_EMAX, 63))
            else:
                out.append((s, ne, f))
    return out


def _e4m3_shift_cw(cw, off):
    s = (cw >> 7) & 1
    e = (cw >> 3) & 0xF
    m = cw & 0x7
    if e == 0xF and m == 7:            # NaN — preserve
        return cw
    if e == 0:                          # zero/subnormal — preserve
        return cw
    ne = e + off
    if ne <= 0:
        return s << 7                   # flush to zero
    if ne >= 15:
        return (s << 7) | (15 << 3) | 6  # clamp to ±448 (avoid NaN codeword)
    return (s << 7) | (ne << 3) | m


def fp8_e4m3_reground(state, tgt=_E4M3_ETGT):
    """Lossless exponent shift for E4M3FN. Target e=7 → max element ≈ 1.0."""
    e_vals = [((cw >> 3) & 0xF) for cw in state
              if ((cw >> 3) & 0xF) not in (0, 0xF) and (cw & 0x7F) != 0]
    if not e_vals:
        return list(state)
    off = tgt - max(e_vals)
    if off == 0:
        return list(state)
    return [_e4m3_shift_cw(cw, off) for cw in state]


def _e5m2_shift_cw(cw, off):
    s = (cw >> 7) & 1
    e = (cw >> 2) & 0x1F
    m = cw & 0x3
    if e == 0x1F:                       # Inf/NaN — preserve
        return cw
    if e == 0:
        return cw
    ne = e + off
    if ne <= 0:
        return s << 7
    if ne >= 0x1F:
        return (s << 7) | (30 << 2) | 3  # clamp to max finite
    return (s << 7) | (ne << 2) | m


def fp8_e5m2_reground(state, tgt=_E5M2_ETGT):
    """Lossless exponent shift for E5M2FN. Target e=15 → max element ≈ 1.0."""
    e_vals = [((cw >> 2) & 0x1F) for cw in state
              if ((cw >> 2) & 0x1F) not in (0, 0x1F) and (cw & 0x7F) != 0]
    if not e_vals:
        return list(state)
    off = tgt - max(e_vals)
    if off == 0:
        return list(state)
    return [_e5m2_shift_cw(cw, off) for cw in state]


def _bf16_shift_cw(cw, off):
    s = (cw >> 15) & 1
    e = (cw >> 7) & 0xFF
    m = cw & 0x7F
    if e == 0xFF:                       # Inf/NaN — preserve
        return cw
    if e == 0:
        return cw
    ne = e + off
    if ne <= 0:
        return s << 15
    if ne >= 0xFF:
        return (s << 15) | (0xFF << 7)  # Inf
    return (s << 15) | (ne << 7) | m


def bf16_reground(state, tgt=_BF16_ETGT):
    """Lossless exponent shift for BF16. Target e=127 → max element ≈ 1.0."""
    e_vals = [((cw >> 7) & 0xFF) for cw in state
              if ((cw >> 7) & 0xFF) not in (0, 0xFF) and (cw & 0x7FFF) != 0]
    if not e_vals:
        return list(state)
    off = tgt - max(e_vals)
    if off == 0:
        return list(state)
    return [_bf16_shift_cw(cw, off) for cw in state]


def int8_reground(q, scale):
    """INT8: decode → max_abs/127 scale → re-quantize.
    Standard per-tensor symmetric rescaling (Jacob et al. CVPR 2018)."""
    dec = [float(qi) * scale for qi in q]
    ma = max(abs(v) for v in dec)
    if ma < 1e-15:
        return q, scale
    ns = ma / 127.0
    return [int8_enc(v, ns) for v in dec], ns


def reground(state, fmt, scale=None):
    """Dispatch per-format re-grounding."""
    if fmt == "NFE-13":
        return nfe_reground(state), scale
    if fmt == "FP8-E4M3":
        return fp8_e4m3_reground(state), scale
    if fmt == "FP8-E5M2":
        return fp8_e5m2_reground(state), scale
    if fmt == "BF16":
        return bf16_reground(state), scale
    if fmt == "INT8":
        nq, ns = int8_reground(state, scale)
        return nq, ns
    raise ValueError(fmt)


# ─────────────────────────────────────────────────────────────────────────────
# PART 2 — ENCODE / DECODE HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def enc(v_list, fmt):
    """Encode a list of floats into the given format. Returns (encoded, scale)."""
    if fmt == "NFE-13":
        return [nfe_enc(v) for v in v_list], None
    if fmt == "FP8-E4M3":
        return [fp8_e4m3_enc(v) for v in v_list], None
    if fmt == "FP8-E5M2":
        return [fp8_e5m2_enc(v) for v in v_list], None
    if fmt == "BF16":
        return [bf16_enc(v) for v in v_list], None
    if fmt == "INT8":
        sc = int8_calibrate(v_list)
        return [int8_enc(v, sc) for v in v_list], sc
    raise ValueError(fmt)


def dec(state, fmt, scale=None):
    """Decode a list of encoded values to float64."""
    if fmt == "NFE-13":
        return [nfe_dec(s, e, f) for s, e, f in state]
    if fmt == "FP8-E4M3":
        return [fp8_e4m3_dec(cw) for cw in state]
    if fmt == "FP8-E5M2":
        v = [fp8_e5m2_dec(cw) for cw in state]
        return [x if math.isfinite(x) else 0.0 for x in v]
    if fmt == "BF16":
        v = [bf16_dec(cw) for cw in state]
        return [x if math.isfinite(x) else 0.0 for x in v]
    if fmt == "INT8":
        return [float(q) * scale for q in state]
    raise ValueError(fmt)


def alignment(a, b):
    """Cosine similarity (absolute value) between two equal-length vectors."""
    n1 = math.sqrt(sum(x * x for x in a))
    n2 = math.sqrt(sum(x * x for x in b))
    if n1 < 1e-15 or n2 < 1e-15:
        return 0.0
    return abs(sum(x * y for x, y in zip(a, b))) / (n1 * n2)


# ─────────────────────────────────────────────────────────────────────────────
# PART 3 — MATVEC STEP (per-product quantization, FP64 accumulate)
# ─────────────────────────────────────────────────────────────────────────────

def matvec_step(A_enc, sA, y_enc, sy, fmt, n=N):
    """One y ← A·y step.  Per-product format quantization, FP64 accumulate.
    Returns (new_y_enc, new_sy).  Matches format_zoo.py Arena-B methodology."""
    raw = []
    for i in range(n):
        acc = 0.0
        if fmt == "NFE-13":
            for j in range(n):
                sp, ep, fp = nfe_mul_fields(*A_enc[i][j], *y_enc[j])
                acc += nfe_dec(sp, ep, fp)
        elif fmt == "FP8-E4M3":
            for j in range(n):
                acc += fp8_e4m3_dec(fp8_e4m3_mul(A_enc[i][j], y_enc[j]))
        elif fmt == "FP8-E5M2":
            for j in range(n):
                v = fp8_e5m2_dec(fp8_e5m2_mul(A_enc[i][j], y_enc[j]))
                acc += v if math.isfinite(v) else 0.0
        elif fmt == "BF16":
            for j in range(n):
                v = bf16_dec(bf16_mul(A_enc[i][j], y_enc[j]))
                acc += v if math.isfinite(v) else 0.0
        elif fmt == "INT8":
            acc = sum(float(A_enc[i][j] * int(y_enc[j])) * sA * sy
                      for j in range(n))
        raw.append(acc)

    # Re-encode output
    if fmt == "INT8":
        ma = max(abs(v) for v in raw)
        ns = ma / 127.0 if ma > 0.0 else sy
        return [int8_enc(v, ns) for v in raw], ns
    else:
        new_enc, new_sc = enc(raw, fmt)
        return new_enc, new_sc


def enc_matrix(A_fp, fmt, n=N):
    """Encode an n×n FP64 matrix.  Returns (encoded_rows, scale_A or None)."""
    if fmt == "INT8":
        flat = [A_fp[i][j] for i in range(n) for j in range(n)]
        sA = int8_calibrate(flat)
        return [[int8_enc(A_fp[i][j], sA) for j in range(n)]
                for i in range(n)], sA
    enc_fn = {"NFE-13": nfe_enc, "FP8-E4M3": fp8_e4m3_enc,
              "FP8-E5M2": fp8_e5m2_enc, "BF16": bf16_enc}[fmt]
    return [[enc_fn(A_fp[i][j]) for j in range(n)] for i in range(n)], None


# ─────────────────────────────────────────────────────────────────────────────
# PART 4 — TASK 1: NORMALIZED CHAIN REMATCH
# ─────────────────────────────────────────────────────────────────────────────

def _neutral_chain_instance(rng):
    """Row-stochastic neutral matrix and initial vector. Matches format_zoo.py."""
    A = [[rng.random() for _ in range(N)] for _ in range(N)]
    for i in range(N):
        rs = sum(A[i])
        A[i] = [a / rs for a in A[i]]
    x = [(1.0 + rng.random()) * math.ldexp(1.0, rng.randint(28, 35) - 32)
         for _ in range(N)]
    return A, x


def run_task1(n_chains=N_CHAINS, depth=DEPTH, verbose=False):
    """Normalized chain rematch: all formats × k ∈ {1,4,8,16}, neutral regime."""
    results = {}   # (fmt, k) → {"mean_align", "frac_099", "n"}

    for k in K_VALUES:
        for fmt in FORMATS:
            rng = random.Random(SEED_CHAIN ^ (k * 0x11223344))
            aligns = []
            for _ in range(n_chains):
                A_fp, x_fp = _neutral_chain_instance(rng)
                A_np = np.array(A_fp)
                y_g  = list(x_fp)

                A_enc, sA = enc_matrix(A_fp, fmt)
                y_enc, sy = enc(x_fp, fmt)
                y_enc, sy = reground(y_enc, fmt, sy)   # initial re-ground

                golden_ovf = False
                for t in range(1, depth + 1):
                    y_g = list(A_np @ np.array(y_g))
                    if any(not math.isfinite(v) or abs(v) > 1e300 for v in y_g):
                        golden_ovf = True
                        break
                    y_enc, sy = matvec_step(A_enc, sA, y_enc, sy, fmt)
                    if t % k == 0:
                        y_enc, sy = reground(y_enc, fmt, sy)

                if not golden_ovf:
                    aligns.append(alignment(dec(y_enc, fmt, sy), y_g))

            n_v = len(aligns)
            results[(fmt, k)] = {
                "mean_align": sum(aligns) / n_v if n_v else 0.0,
                "frac_099":   sum(a >= 0.99 for a in aligns) / n_v if n_v else 0.0,
                "n":          n_v,
            }
    return results


# ─────────────────────────────────────────────────────────────────────────────
# PART 5 — TASK 2a: POWER-ITERATION CONVERGENCE
# SEED_PI construction mirrors norm_interval_sweep.py build_pi_chain.
# ─────────────────────────────────────────────────────────────────────────────

def _lfsr_step(s):
    """32-bit LFSR. Matches norm_interval_sweep.py lines 56-58."""
    bit = ((s >> 31) ^ (s >> 21) ^ (s >> 1) ^ s) & 1
    return ((s << 1) & 0xFFFFFFFF) | bit


def _lfsr_frac(s):
    return ((s >> 8) & 0xFFFFFF) / 16777216.0


def _pi_instance(seed):
    """Symmetric-positive 8×8 matrix and normalised initial vector.
    Mirrors norm_interval_sweep.py build_pi_chain (lines 184-198)."""
    lfsr = seed
    A = [[0.0] * N for _ in range(N)]
    for i in range(N):
        for j in range(i, N):
            lfsr = _lfsr_step(lfsr)
            v = _lfsr_frac(lfsr) + 0.25
            A[i][j] = v
            A[j][i] = v
    y = []
    for j in range(N):
        lfsr = _lfsr_step(lfsr)
        y.append(_lfsr_frac(lfsr) + 0.1)
    norm = math.sqrt(sum(v * v for v in y))
    y = [v / norm for v in y]
    return A, y


def run_task2a(n_matrices=N_PI, max_iter=MAX_PI_ITER, verbose=False):
    """Power iteration: convergence to alignment ≥ 0.99 vs dominant eigenvector."""
    results = {}

    for fmt in FORMATS:
        frac_conv = 0
        iter_list = []
        for idx in range(n_matrices):
            seed = SEED_PI ^ (idx * 0x02020202 + 0xAABBCCDD)
            A_fp, x_fp = _pi_instance(seed)
            A_np = np.array(A_fp)
            # True dominant eigenvector (FP64)
            evals, evecs = np.linalg.eigh(A_np)
            v_true = evecs[:, -1]     # largest eigenvalue
            # Align sign: ensure positive dominant component
            if float(v_true @ np.array(x_fp)) < 0:
                v_true = -v_true

            A_enc, sA = enc_matrix(A_fp, fmt)
            y_enc, sy = enc(x_fp, fmt)
            y_enc, sy = reground(y_enc, fmt, sy)

            converged = False
            conv_iter = max_iter + 1
            for t in range(1, max_iter + 1):
                y_enc, sy = matvec_step(A_enc, sA, y_enc, sy, fmt)
                y_enc, sy = reground(y_enc, fmt, sy)    # normalize every step
                d = dec(y_enc, fmt, sy)
                al = alignment(d, list(v_true))
                if al >= 0.99 and not converged:
                    converged = True
                    conv_iter = t
                    break

            if converged:
                frac_conv += 1
                iter_list.append(conv_iter)

        results[fmt] = {
            "frac_converged": frac_conv / n_matrices,
            "mean_iter":      sum(iter_list) / len(iter_list) if iter_list else float('nan'),
            "n":              n_matrices,
        }
    return results


# ─────────────────────────────────────────────────────────────────────────────
# PART 6 — TASK 2b: ESN RECALL
# Weights fixed in FP64; only hidden state h_t quantized at each step.
# This isolates the effect of per-step activation quantization on N-back recall.
# ─────────────────────────────────────────────────────────────────────────────

N_RECALL_VALUES = [4, 8, 16]
SEQ_LEN         = 22      # sequence length (must be > max N_recall)
N_TRAIN         = 600     # training sequences for lstsq
N_TEST          = 200     # test sequences per (N_recall, fmt)


def _build_reservoir(seed):
    """Fixed-random reservoir (spectral radius 0.9, same for all formats)."""
    rng = np.random.RandomState(seed)
    W_hh = rng.randn(N_H, N_H)
    sr = max(abs(np.linalg.eigvals(W_hh)))
    W_hh = W_hh / sr * 0.9             # spectral radius exactly 0.9
    W_ih = rng.randn(N_H, N_IN) * 0.4  # input coupling
    b_h  = np.zeros(N_H)
    return W_hh, W_ih, b_h


def _fp64_esn_run(x_seq, W_hh, W_ih, b_h):
    """FP64 ESN forward pass.  Returns list of hidden states."""
    h = np.zeros(N_H)
    hiddens = []
    for x in x_seq:
        h = np.tanh(W_hh @ h + W_ih @ x + b_h)
        hiddens.append(h.copy())
    return hiddens


def _train_w_out(W_hh, W_ih, b_h, n_recall, n_train, seed):
    """Train read-out matrix via least-squares (FP64).  Returns W_out (N_IN×N_H)."""
    rng = random.Random(seed ^ n_recall)
    H, T = [], []
    for _ in range(n_train):
        lbls = [rng.randint(0, N_IN - 1) for _ in range(SEQ_LEN)]
        x_seq = [np.eye(N_IN)[l] for l in lbls]
        hiddens = _fp64_esn_run(x_seq, W_hh, W_ih, b_h)
        for t in range(n_recall, SEQ_LEN):
            H.append(hiddens[t])
            T.append(np.eye(N_IN)[lbls[t - n_recall]])
    H = np.array(H)
    T = np.array(T)
    W_out_T, _, _, _ = np.linalg.lstsq(H, T, rcond=None)
    return W_out_T.T                    # shape (N_IN, N_H)


def _fp64_recall_accuracy(W_hh, W_ih, b_h, W_out, n_recall, n_test, seed):
    """FP64 baseline accuracy on recall task."""
    rng = random.Random(seed ^ n_recall ^ 0xF0F0F0F0)
    correct = total = 0
    for _ in range(n_test):
        lbls = [rng.randint(0, N_IN - 1) for _ in range(SEQ_LEN)]
        x_seq = [np.eye(N_IN)[l] for l in lbls]
        hiddens = _fp64_esn_run(x_seq, W_hh, W_ih, b_h)
        for t in range(n_recall, SEQ_LEN):
            pred = int(np.argmax(W_out @ hiddens[t]))
            correct += int(pred == lbls[t - n_recall])
            total += 1
    return correct / total if total > 0 else 0.0


def _quantized_recall_accuracy(W_hh, W_ih, b_h, W_out, n_recall, fmt, n_test, seed):
    """Quantized inference: hidden state h_t encoded in format with re-grounding.
    All weights (W_hh, W_ih, W_out) kept in FP64 — tests pure activation quantization."""
    rng = random.Random(seed ^ n_recall ^ 0xF0F0F0F0)
    correct = total = 0

    for _ in range(n_test):
        lbls = [rng.randint(0, N_IN - 1) for _ in range(SEQ_LEN)]
        x_seq = [np.eye(N_IN)[l] for l in lbls]

        # Initial hidden state: zero
        if fmt == "INT8":
            h_q    = [0] * N_H
            h_sc   = 1.0 / 127.0
        else:
            h_enc, _ = enc([0.0] * N_H, fmt)

        for t in range(SEQ_LEN):
            x_t = x_seq[t]

            # Decode h from format
            if fmt == "INT8":
                h_fp = [float(q) * h_sc for q in h_q]
            else:
                h_fp = dec(h_enc, fmt)

            # FP64 matvec + tanh (weights stay FP64)
            z    = W_hh @ np.array(h_fp) + W_ih @ x_t + b_h
            h_new = np.tanh(z)

            # Re-encode in format with re-grounding (every step)
            if fmt == "INT8":
                sc_new = int8_calibrate(list(h_new))
                h_q    = [int8_enc(v, sc_new) for v in h_new]
                h_sc   = sc_new
            else:
                h_enc, _ = enc(list(h_new), fmt)
                h_enc, _ = reground(h_enc, fmt, None)

            if t >= n_recall:
                if fmt == "INT8":
                    h_eval = np.array([float(q) * h_sc for q in h_q])
                else:
                    h_eval = np.array(dec(h_enc, fmt))
                pred = int(np.argmax(W_out @ h_eval))
                correct += int(pred == lbls[t - n_recall])
                total   += 1

    return correct / total if total > 0 else 0.0


def run_task2b(n_train=N_TRAIN, n_test=N_TEST, verbose=False):
    """Task 2b: ESN recall, format × N_recall table."""
    W_hh, W_ih, b_h = _build_reservoir(SEED_ESN)

    # Train one W_out per recall distance (FP64 training, fixed weights)
    W_outs = {nr: _train_w_out(W_hh, W_ih, b_h, nr, n_train, SEED_ESN)
              for nr in N_RECALL_VALUES}

    results = {}
    # FP64 baseline first
    results["FP64-baseline"] = {
        nr: _fp64_recall_accuracy(W_hh, W_ih, b_h, W_outs[nr], nr, n_test, SEED_ESN)
        for nr in N_RECALL_VALUES
    }
    if verbose:
        print("  FP64 baseline:", results["FP64-baseline"])

    for fmt in FORMATS:
        results[fmt] = {
            nr: _quantized_recall_accuracy(
                W_hh, W_ih, b_h, W_outs[nr], nr, fmt, n_test, SEED_ESN)
            for nr in N_RECALL_VALUES
        }
        if verbose:
            print(f"  {fmt}:", results[fmt])

    return results


# ─────────────────────────────────────────────────────────────────────────────
# PART 7 — OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

def _f(v, p=3):
    return f"{v:.{p}f}" if math.isfinite(v) else "N/A"


def print_results(r1, r2a, r2b):
    print()
    print("=" * 90)
    print("RECURRENT NICHE — RESULTS")
    print("=" * 90)

    # Task 1
    print()
    print("Task 1 — Normalized-chain alignment at t=256 (neutral regime, 100 chains)")
    print("  Re-grounding: lossless exponent shift (FP formats) / rescale (INT8)")
    print(f"  {'Format':<12} {'Bits':>4} | {'k=1':>7} {'k=4':>7} {'k=8':>7} {'k=16':>7}")
    print("  " + "-" * 58)
    for fmt in FORMATS:
        bits = BITS[fmt]
        vals = [_f(r1.get((fmt, k), {}).get("mean_align", float('nan')), 4)
                for k in K_VALUES]
        print(f"  {fmt:<12} {bits:>4} | {vals[0]:>7} {vals[1]:>7} {vals[2]:>7} {vals[3]:>7}")
    print()
    print("  Fraction of chains with alignment ≥ 0.99 at t=256:")
    print(f"  {'Format':<12} {'Bits':>4} | {'k=1':>7} {'k=4':>7} {'k=8':>7} {'k=16':>7}")
    print("  " + "-" * 58)
    for fmt in FORMATS:
        bits = BITS[fmt]
        vals = [_f(r1.get((fmt, k), {}).get("frac_099", float('nan')), 3)
                for k in K_VALUES]
        print(f"  {fmt:<12} {bits:>4} | {vals[0]:>7} {vals[1]:>7} {vals[2]:>7} {vals[3]:>7}")

    # Task 2a
    print()
    print("Task 2a — Power iteration: convergence to alignment ≥ 0.99")
    print("  50 symmetric-positive 8×8 matrices (SEED_PI), k=1 re-grounding.")
    print(f"  {'Format':<12} {'Bits':>4} | {'Frac conv':>10} {'Mean iters':>12}")
    print("  " + "-" * 40)
    for fmt in FORMATS:
        r = r2a.get(fmt, {})
        fc = _f(r.get("frac_converged", float('nan')), 3)
        mi = _f(r.get("mean_iter",      float('nan')), 1)
        print(f"  {fmt:<12} {BITS[fmt]:>4} | {fc:>10} {mi:>12}")

    # Task 2b
    print()
    print("Task 2b — ESN recall accuracy by recall distance N")
    print("  16-unit reservoir (spectral radius 0.9), 8-class one-hot,")
    print("  weights FP64; only h_t quantized per step with re-grounding.")
    print(f"  {'Format':<16} {'Bits':>4} | {'N=4':>8} {'N=8':>8} {'N=16':>8}")
    print("  " + "-" * 50)
    # FP64 baseline
    bl = r2b.get("FP64-baseline", {})
    vals = [_f(bl.get(nr, float('nan')), 3) for nr in N_RECALL_VALUES]
    print(f"  {'FP64-baseline':<16} {'—':>4} | {vals[0]:>8} {vals[1]:>8} {vals[2]:>8}")
    for fmt in FORMATS:
        bits = BITS[fmt]
        vals = [_f(r2b.get(fmt, {}).get(nr, float('nan')), 3) for nr in N_RECALL_VALUES]
        print(f"  {fmt:<16} {bits:>4} | {vals[0]:>8} {vals[1]:>8} {vals[2]:>8}")

    print()
    # Pivotal comparison summary
    nfe_k8 = r1.get(("NFE-13",   8), {}).get("mean_align", float('nan'))
    e4m_k8 = r1.get(("FP8-E4M3", 8), {}).get("mean_align", float('nan'))
    print(f"  Pivotal (Task 1, k=8): NFE-13={nfe_k8:.4f}  FP8-E4M3={e4m_k8:.4f}"
          f"  Δ={nfe_k8 - e4m_k8:.4f}")
    if abs(nfe_k8 - e4m_k8) < 0.01:
        print("  → Difference < 0.01: MANTISSA HYPOTHESIS NOT SUPPORTED at k=8.")
    else:
        print("  → Difference ≥ 0.01: MANTISSA HYPOTHESIS SUPPORTED at k=8.")
    print()


def save_csv(r1, r2a, r2b, path):
    rows = []
    for (fmt, k), v in r1.items():
        rows.append({"task": "T1", "fmt": fmt, "bits": BITS[fmt],
                     "condition": f"k={k}",
                     "metric": "mean_align", "value": v.get("mean_align", "")})
        rows.append({"task": "T1", "fmt": fmt, "bits": BITS[fmt],
                     "condition": f"k={k}",
                     "metric": "frac_099", "value": v.get("frac_099", "")})
    for fmt, v in r2a.items():
        rows.append({"task": "T2a", "fmt": fmt, "bits": BITS.get(fmt, ""),
                     "condition": "k=1",
                     "metric": "frac_converged", "value": v.get("frac_converged", "")})
        rows.append({"task": "T2a", "fmt": fmt, "bits": BITS.get(fmt, ""),
                     "condition": "k=1",
                     "metric": "mean_iter", "value": v.get("mean_iter", "")})
    for fmt, d in r2b.items():
        for nr, acc in d.items():
            rows.append({"task": "T2b",
                         "fmt": fmt, "bits": BITS.get(fmt, ""),
                         "condition": f"N_recall={nr}",
                         "metric": "accuracy", "value": acc})
    os.makedirs(os.path.dirname(path) if os.path.dirname(path) else ".", exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["task", "fmt", "bits", "condition",
                                          "metric", "value"])
        w.writeheader()
        w.writerows(rows)
    print(f"Raw data → {path}")


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task",    choices=["1", "2a", "2b", "all"], default="all")
    ap.add_argument("--chains",  type=int, default=N_CHAINS)
    ap.add_argument("--depth",   type=int, default=DEPTH)
    ap.add_argument("--pi",      type=int, default=N_PI)
    ap.add_argument("--train",   type=int, default=N_TRAIN)
    ap.add_argument("--test",    type=int, default=N_TEST)
    ap.add_argument("--out",     default=os.path.join(DIR, "RECURRENT_NICHE_RAW.csv"))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    r1 = {}; r2a = {}; r2b = {}

    if args.task in ("1", "all"):
        print(f"Task 1: normalized chains "
              f"({args.chains} chains × 4 k-values × 5 formats)…", flush=True)
        r1 = run_task1(args.chains, args.depth, args.verbose)
        print("  done.")

    if args.task in ("2a", "all"):
        print(f"Task 2a: power iteration ({args.pi} matrices × 5 formats)…",
              flush=True)
        r2a = run_task2a(args.pi, args.depth, args.verbose)
        print("  done.")

    if args.task in ("2b", "all"):
        print(f"Task 2b: ESN recall ({args.train} train, {args.test} test × "
              f"{len(N_RECALL_VALUES)} N values × 5 formats)…", flush=True)
        r2b = run_task2b(args.train, args.test, args.verbose)
        print("  done.")

    print_results(r1, r2a, r2b)
    if args.out:
        save_csv(r1, r2a, r2b, args.out)


if __name__ == "__main__":
    main()

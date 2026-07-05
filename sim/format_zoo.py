#!/usr/bin/env python3
"""
sim/format_zoo.py — Head-to-head format comparison on three workload arenas.

Five formats under test:
  NFE-13   : 1s 6e 6f, bias-32, floor/sat sentinels (13 bits)  [this repo]
  FP8-E4M3 : 1s 4e 3f, bias-7,  no Inf, NaN=s.1111.111          (8 bits)
  FP8-E5M2 : 1s 5e 2f, bias-15, ±Inf, NaN=s.11111.{01..11}      (8 bits)
  BF16     : 1s 8e 7f, bias-127, IEEE 754 single-width exponent  (16 bits)
  INT8     : signed 8-bit integer with per-tensor symmetric scale (8 bits)

Spec citations:
  E4M3/E5M2: "FP8 Formats for Deep Learning" (Micikevicius et al., NeurIPS 2022),
             OCP 8-Bit Floating Point Specification v1.0 (OCP Alliance, 2023).
  BF16    : Google Brain format; IEEE 754 float32 upper 16 bits (ARM ACLE, Intel
             intrinsics); round-to-nearest-even via float32 intermediate.
  INT8    : Symmetric per-tensor quantization; scale = max_abs / 127; INT32
             accumulate, round-to-nearest saturation semantics.
             (Jacob et al., "Quantization and Training of Neural Networks for
             Efficient Integer-Arithmetic-Only Inference", CVPR 2018.)

Three arenas:
  A  Single-pass 8×8 matvec accuracy vs FP64 golden (methodology: second_source_validator.py)
  B  256-cycle feedback chains, neutral and expansive regimes,
     unnormalized (k=∞) and k=8-normalized (methodology: second_source_chain.py)
  C  MLP 64→16→10 digit inference with quantized weights and activations
     (methodology: mlp_infer_nfe.py; shared-offset expnorm for NFE)

Design invariant: same PRNG seeds across formats within each arena.  If NFE
loses a comparison, the table says so with equal prominence.  No workloads were
tuned toward any format.

Usage:
  python3 format_zoo.py                # all arenas, print master table
  python3 format_zoo.py --arena A      # single arena
  python3 format_zoo.py --out results/FORMAT_COMPARISON_RAW.csv
"""

import argparse
import csv
import math
import os
import random
import struct
import sys

import numpy as np

DIR = os.path.dirname(os.path.abspath(__file__))

# ── Bit-width registry (all outputs annotate bits) ──────────────────────────
BITS = {"NFE-13": 13, "FP8-E4M3": 8, "FP8-E5M2": 8, "BF16": 16, "INT8": 8}

# ─────────────────────────────────────────────────────────────────────────────
# PART 1 — FORMAT IMPLEMENTATIONS
# ─────────────────────────────────────────────────────────────────────────────

# ── NFE-13 ───────────────────────────────────────────────────────────────────
# Reused from mlp_infer_nfe.py (lines 47-87) and norm_interval_sweep.py (lines 63-98).
# 1 sign + 6 exponent (bias 32) + 6 mantissa = 13 bits.
# Sentinel: e==0 → floor (underflow); e==63 → saturated (overflow).

_NFE_BIAS = 32
_NFE_EMAX = 63


def nfe_dec(s, e, f):
    """Decode NFE-13 fields to float64.  Mirrors mlp_infer_nfe.py nfe_dec."""
    v = math.ldexp(1.0 + f / 64.0, e - _NFE_BIAS)
    return -v if s else v


def nfe_enc(v):
    """Encode float64 → (s,e,f).  Mirrors mlp_infer_nfe.py nfe_enc lines 62-76."""
    s = 1 if v < 0.0 else 0
    av = abs(v)
    if av == 0.0:
        return s, 0, 0
    aE = math.floor(math.log2(av))
    m = av / math.ldexp(1.0, aE)
    if m < 1.0:
        aE -= 1
        m = av / math.ldexp(1.0, aE)
    if m >= 2.0:
        aE += 1
        m = av / math.ldexp(1.0, aE)
    if aE < -_NFE_BIAS:
        return s, 0, 0
    if aE > _NFE_EMAX - _NFE_BIAS:
        return s, _NFE_EMAX, 63
    eS = aE + _NFE_BIAS
    f = round((m - 1.0) * 64.0)
    if f > 63:
        f = 0
        eS += 1
    if eS > _NFE_EMAX:
        return s, _NFE_EMAX, 63
    return s, eS, f


def nfe_mul_fields(sa, ea, fa, sb, eb, fb):
    """NFE-13 multiply: per-product 6-bit mantissa truncation.
    Mirrors mlp_infer_nfe.py nfe_mul lines 78-87 / norm_interval_sweep.py lines 91-98.
    Returns (s, e, f) of the truncated 13-bit product."""
    if ea == 0 or eb == 0:
        return sa ^ sb, 0, 0
    P = (64 + fa) * (64 + fb)
    rs = sa ^ sb
    if P >= 8192:
        es = ea + eb - _NFE_BIAS + 1
        fR = (P >> 7) & 0x3F
    else:
        es = ea + eb - _NFE_BIAS
        fR = (P >> 6) & 0x3F
    if es <= 0:
        return rs, 0, 0
    if es > _NFE_EMAX:
        return rs, _NFE_EMAX, 63
    return rs, es, fR


def nfe_is_sat(e, f):
    return e == _NFE_EMAX


def nfe_is_floor(e, f):
    return e == 0


# ── FP8-E4M3FN ───────────────────────────────────────────────────────────────
# Source: OCP 8-Bit Floating Point Specification v1.0, Table 1 (E4M3FN variant).
#         "FP8 Formats for Deep Learning", Micikevicius et al. (NeurIPS 2022), §3.
#
# Format: 1 sign | 4 exponent (bias 7) | 3 mantissa.
# Special: s.1111.111 = NaN (both signs).  No ±Inf.
# Subnormals: e=0000, value = (-1)^s × (0.mmm) × 2^(1−7) = (-1)^s × (m/8) × 2^(−6).
# Normals   : e=0001..1111, value = (-1)^s × (1.mmm) × 2^(e−7).
# Max finite: 0.1111.110 = 1.75 × 2^8 = 448.0.

_E4M3_BIAS = 7
_E4M3_EMAX = 15      # all-ones exponent field
_E4M3_MAX  = 448.0   # codeword 0x7E


def fp8_e4m3_dec(cw):
    """Decode 8-bit E4M3FN codeword → float64."""
    cw = int(cw) & 0xFF
    s = (cw >> 7) & 1
    e = (cw >> 3) & 0xF
    m = cw & 0x7
    if e == _E4M3_EMAX and m == 7:          # NaN pattern
        return float('nan')
    if e == 0:                               # subnormal
        v = (m / 8.0) * math.ldexp(1.0, 1 - _E4M3_BIAS)
    else:                                    # normal
        v = (1.0 + m / 8.0) * math.ldexp(1.0, e - _E4M3_BIAS)
    return -v if s else v


def fp8_e4m3_enc(v):
    """Encode float64 → 8-bit E4M3FN. Round-to-nearest, clamp overflow to 448."""
    if math.isnan(v) or math.isinf(v):
        # NaN/Inf not representable; saturate to ±max
        s = 1 if (not math.isnan(v) and v < 0) else 0
        return (s << 7) | (_E4M3_EMAX << 3) | 6   # ±448
    s = 1 if v < 0.0 else 0
    av = abs(v)
    if av == 0.0:
        return s << 7
    # Overflow: clamp to max (no Inf representation)
    if av > _E4M3_MAX:
        return (s << 7) | (_E4M3_EMAX << 3) | 6
    # Underflow: below half of minimum subnormal
    min_sub = math.ldexp(1.0, 1 - _E4M3_BIAS - 3)   # (1/8) × 2^(-6) / 2 = 2^(-10)
    if av < min_sub:
        return s << 7
    # Subnormal range: [2^(-10), 2^(-6))
    norm_min = math.ldexp(1.0, 1 - _E4M3_BIAS)       # 2^(-6)
    if av < norm_min:
        m_f = av / math.ldexp(1.0, 1 - _E4M3_BIAS) * 8.0
        m = int(round(m_f))
        if m <= 0:
            return s << 7
        if m >= 8:                                    # round up to min normal
            return (s << 7) | (1 << 3) | 0
        return (s << 7) | m
    # Normal
    ue = math.floor(math.log2(av))
    be = int(ue) + _E4M3_BIAS
    if be < 1:
        be = 1
    m_f = (av / math.ldexp(1.0, be - _E4M3_BIAS) - 1.0) * 8.0
    m = int(round(m_f))
    if m >= 8:
        m = 0
        be += 1
    if be > _E4M3_EMAX:                               # overflow
        return (s << 7) | (_E4M3_EMAX << 3) | 6
    if be == _E4M3_EMAX and m == 7:                   # avoid NaN codeword
        m = 6
    return (s << 7) | (be << 3) | m


def fp8_e4m3_mul(cw_a, cw_b):
    """Multiply two E4M3FN codewords: decode → FP64 multiply → encode."""
    a = fp8_e4m3_dec(cw_a)
    b = fp8_e4m3_dec(cw_b)
    if math.isnan(a) or math.isnan(b):
        return 0x7F      # NaN
    return fp8_e4m3_enc(a * b)


def fp8_e4m3_is_overflow(cw):
    """True if codeword encodes the maximum finite value ±448 (clipped)."""
    return (cw & 0x7F) == (_E4M3_EMAX << 3) | 6      # 0x7E


def fp8_e4m3_is_floor(cw):
    """True if codeword is ±0 (subnormal flush or exact zero)."""
    return (cw & 0x7F) == 0


# ── FP8-E5M2FN ───────────────────────────────────────────────────────────────
# Source: OCP 8-Bit Floating Point Specification v1.0, Table 2 (E5M2 variant).
#         "FP8 Formats for Deep Learning", Micikevicius et al. (NeurIPS 2022), §3.
#
# Format: 1 sign | 5 exponent (bias 15) | 2 mantissa.
# Special: e=11111, m=00 → ±Inf.  e=11111, m≠00 → NaN.
# Subnormals: e=00000, value = (-1)^s × (m/4) × 2^(1−15).
# Normals   : e=00001..11110, value = (-1)^s × (1.mm) × 2^(e−15).
# Max finite: 0.11110.11 = 1.75 × 2^15 = 57344.0.

_E5M2_BIAS = 15
_E5M2_EMAX = 31      # all-ones exponent
_E5M2_MAX  = 57344.0  # codeword 0x7B


def fp8_e5m2_dec(cw):
    """Decode 8-bit E5M2FN codeword → float64."""
    cw = int(cw) & 0xFF
    s = (cw >> 7) & 1
    e = (cw >> 2) & 0x1F
    m = cw & 0x3
    if e == _E5M2_EMAX:
        if m == 0:
            return float('-inf') if s else float('inf')
        return float('nan')
    if e == 0:                               # subnormal
        v = (m / 4.0) * math.ldexp(1.0, 1 - _E5M2_BIAS)
    else:
        v = (1.0 + m / 4.0) * math.ldexp(1.0, e - _E5M2_BIAS)
    return -v if s else v


def fp8_e5m2_enc(v):
    """Encode float64 → 8-bit E5M2FN. Round-to-nearest, overflow → ±Inf."""
    if math.isnan(v):
        return 0x7F      # canonical NaN
    s = 1 if v < 0.0 else 0
    if math.isinf(v):
        return (s << 7) | (_E5M2_EMAX << 2) | 0    # ±Inf
    av = abs(v)
    if av == 0.0:
        return s << 7
    # Overflow → Inf
    if av > _E5M2_MAX:
        return (s << 7) | (_E5M2_EMAX << 2) | 0
    min_sub = math.ldexp(1.0, 1 - _E5M2_BIAS - 2)   # (1/4) × 2^(-14) / 2 = 2^(-17)
    if av < min_sub:
        return s << 7
    norm_min = math.ldexp(1.0, 1 - _E5M2_BIAS)       # 2^(-14)
    if av < norm_min:
        m_f = av / math.ldexp(1.0, 1 - _E5M2_BIAS) * 4.0
        m = int(round(m_f))
        if m <= 0:
            return s << 7
        if m >= 4:
            return (s << 7) | (1 << 2) | 0
        return (s << 7) | m
    ue = math.floor(math.log2(av))
    be = int(ue) + _E5M2_BIAS
    if be < 1:
        be = 1
    m_f = (av / math.ldexp(1.0, be - _E5M2_BIAS) - 1.0) * 4.0
    m = int(round(m_f))
    if m >= 4:
        m = 0
        be += 1
    if be >= _E5M2_EMAX:
        return (s << 7) | (_E5M2_EMAX << 2) | 0    # Inf
    return (s << 7) | (be << 2) | m


def fp8_e5m2_mul(cw_a, cw_b):
    """Multiply two E5M2FN codewords: decode → FP64 multiply → encode."""
    a = fp8_e5m2_dec(cw_a)
    b = fp8_e5m2_dec(cw_b)
    if math.isnan(a) or math.isnan(b):
        return 0x7F
    if math.isinf(a) or math.isinf(b):
        if a == 0.0 or b == 0.0:
            return 0x7F      # Inf × 0 = NaN
        s = 1 if (a < 0) ^ (b < 0) else 0
        return (s << 7) | (_E5M2_EMAX << 2) | 0
    return fp8_e5m2_enc(a * b)


def fp8_e5m2_is_overflow(cw):
    """True if codeword is ±Inf (overflow)."""
    return (cw & 0x7F) == (_E5M2_EMAX << 2)


def fp8_e5m2_is_nan(cw):
    """True if codeword is NaN."""
    e = (cw >> 2) & 0x1F
    m = cw & 0x3
    return e == _E5M2_EMAX and m != 0


def fp8_e5m2_is_floor(cw):
    return (cw & 0x7F) == 0


# ── BF16 ─────────────────────────────────────────────────────────────────────
# Source: IEEE 754-2019 (single-precision subset); Google Brain float16;
#         ARM ACLE §6.1.6; defined as the upper 16 bits of IEEE 754 float32.
# Format: 1 sign | 8 exponent (bias 127) | 7 mantissa = 16 bits.
# Round-to-nearest-even via float32 struct intermediate.


def bf16_dec(cw):
    """Decode 16-bit bfloat16 codeword → float64."""
    b = struct.pack('>H', int(cw) & 0xFFFF) + b'\x00\x00'
    return float(struct.unpack('>f', b)[0])


def bf16_enc(v):
    """Encode float64 → 16-bit bfloat16 codeword.  Round-to-nearest-even."""
    try:
        b = struct.pack('>f', float(v))
    except (OverflowError, struct.error):
        s = 1 if (not math.isnan(v) and v < 0) else 0
        return (s << 15) | 0x7F80    # ±Inf or NaN
    hi, lo = struct.unpack('>HH', b)
    # Round-to-nearest-even: round up if lo > 0x8000, or lo == 0x8000 and hi is odd
    if lo > 0x8000 or (lo == 0x8000 and (hi & 1)):
        hi = (hi + 1) & 0xFFFF
        if hi == 0:
            hi = 0x8000   # overflow into sign bit; handle gracefully
    return hi


def bf16_mul(cw_a, cw_b):
    """Multiply two bfloat16 codewords: decode → FP64 multiply → encode."""
    return bf16_enc(bf16_dec(cw_a) * bf16_dec(cw_b))


def bf16_is_overflow(cw):
    e = (cw >> 7) & 0xFF
    m = cw & 0x7F
    return e == 0xFF and m == 0    # ±Inf


def bf16_is_nan(cw):
    e = (cw >> 7) & 0xFF
    m = cw & 0x7F
    return e == 0xFF and m != 0


def bf16_is_floor(cw):
    return (cw & 0x7FFF) == 0


# ── INT8 (per-tensor symmetric) ───────────────────────────────────────────────
# Standard symmetric per-tensor quantization:
#   scale = max_abs(tensor) / 127
#   q     = round(v / scale), clamped to [−127, 127]
#   dequantize: v' = q × scale
# Multiply: accumulate integer products in FP64, apply combined scale.
# No per-product INT8 requantization; models INT32 accumulate then INT8 output.

def int8_calibrate(arr):
    """Per-tensor symmetric scale from max absolute value."""
    ma = float(np.max(np.abs(arr)))
    return ma / 127.0 if ma != 0.0 else 1.0


def int8_enc(v, scale):
    """Encode float → int8 with given scale.  Round-to-nearest, clamp ±127."""
    q = int(round(float(v) / scale))
    return max(-127, min(127, q))


def int8_dec(q, scale):
    return float(q) * scale


def int8_enc_vec(arr, scale):
    """Vectorize int8 encoding of a numpy array."""
    q = np.round(arr / scale).astype(np.int32)
    return np.clip(q, -127, 127).astype(np.int8)


def int8_is_saturated(q):
    return abs(int(q)) >= 127


# ─────────────────────────────────────────────────────────────────────────────
# PART 2 — UNIT TESTS
# Every format tested against published reference values before use.
# ─────────────────────────────────────────────────────────────────────────────

def _assert_close(got, want, tol=1e-9, label=""):
    if math.isnan(want):
        assert math.isnan(got), f"{label}: expected NaN, got {got}"
        return
    if math.isinf(want):
        assert math.isinf(got) and (got > 0) == (want > 0), \
            f"{label}: expected {want}, got {got}"
        return
    err = abs(got - want)
    assert err <= tol, f"{label}: |{got} − {want}| = {err} > {tol}"


def run_unit_tests():
    """Unit tests for all five formats against published reference values."""
    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)

    # ── NFE-13 ────────────────────────────────────────────────────────────────
    # Round-trip: known values in anchor zone
    for v in [1.0, -1.0, 1.25, 2.0, 0.5, 3.75, 100.0, -100.0]:
        s, e, f = nfe_enc(v)
        rt = nfe_dec(s, e, f)
        check(abs(rt - v) / abs(v) < 0.02,
              f"NFE round-trip {v}: got {rt}")
    # Zero encoding
    s, e, f = nfe_enc(0.0)
    check(e == 0, f"NFE enc(0): expected e=0, got e={e}")
    # Saturation
    s, e, f = nfe_enc(1e50)
    check(e == _NFE_EMAX, f"NFE enc(1e50): expected e=63, got {e}")
    # Floor
    s, e, f = nfe_enc(1e-50)
    check(e == 0, f"NFE enc(1e-50): expected e=0, got {e}")
    # Multiply sign
    s, e, f = nfe_mul_fields(0, 32, 0, 1, 32, 0)   # +1 × −1 = −1
    check(s == 1, f"NFE mul sign: expected s=1, got {s}")

    # ── FP8-E4M3FN ───────────────────────────────────────────────────────────
    # Published reference values from OCP FP8 spec Table 1 / Micikevicius §A.
    # Codeword 0x38 = 0.0111.000 → e=7,m=0 → 1.000 × 2^(7−7) = 1.0
    check(abs(fp8_e4m3_dec(0x38) - 1.0) < 1e-9,
          f"E4M3 dec(0x38) = {fp8_e4m3_dec(0x38)}, expected 1.0")
    # Codeword 0x3A = 0.0111.010 → e=7,m=2 → 1.25 × 1.0 = 1.25
    check(abs(fp8_e4m3_dec(0x3A) - 1.25) < 1e-9,
          f"E4M3 dec(0x3A) = {fp8_e4m3_dec(0x3A)}, expected 1.25")
    # Max positive: 0x7E = 0.1111.110 → 1.75 × 2^8 = 448
    check(abs(fp8_e4m3_dec(0x7E) - 448.0) < 1e-6,
          f"E4M3 dec(0x7E) = {fp8_e4m3_dec(0x7E)}, expected 448.0")
    # NaN: 0x7F
    check(math.isnan(fp8_e4m3_dec(0x7F)),
          "E4M3 dec(0x7F) should be NaN")
    # Min positive normal: 0x08 = 0.0001.000 → e=1,m=0 → 1.0 × 2^(1−7) = 2^−6
    check(abs(fp8_e4m3_dec(0x08) - 2.0**-6) < 1e-12,
          f"E4M3 dec(0x08) = {fp8_e4m3_dec(0x08)}, expected {2.0**-6}")
    # Min subnormal: 0x01 = m=1, e=0 → (1/8) × 2^−6 = 2^−9
    check(abs(fp8_e4m3_dec(0x01) - 2.0**-9) < 1e-15,
          f"E4M3 dec(0x01) = {fp8_e4m3_dec(0x01)}, expected {2.0**-9}")
    # Encode round-trip
    for v in [1.0, 1.25, 0.0, -1.5, 448.0, -448.0, 2.0, 0.5]:
        cw = fp8_e4m3_enc(v)
        rt = fp8_e4m3_dec(cw)
        if v != 0.0:
            check(abs(rt - v) / abs(v) < 0.1,
                  f"E4M3 round-trip {v}: cw=0x{cw:02X}, got {rt}")
    # Overflow clamps to max
    check(fp8_e4m3_enc(1000.0) == 0x7E,
          f"E4M3 enc(1000) = 0x{fp8_e4m3_enc(1000.0):02X}, expected 0x7E")
    check(fp8_e4m3_enc(-1000.0) == 0xFE,
          f"E4M3 enc(-1000) = 0x{fp8_e4m3_enc(-1000.0):02X}, expected 0xFE")
    # enc(0x38) round-trip
    check(fp8_e4m3_enc(1.0) == 0x38,
          f"E4M3 enc(1.0) = 0x{fp8_e4m3_enc(1.0):02X}, expected 0x38")

    # ── FP8-E5M2FN ───────────────────────────────────────────────────────────
    # 0x3C = 0.00111.00 → e=7,m=0 → wait: 0x3C=60 = 0b00111100
    #   s=0, e=(60>>2)&0x1F = 0b01111 = 15, m=60&0x3 = 0b00 → 1.0 × 2^(15−15) = 1.0
    check(abs(fp8_e5m2_dec(0x3C) - 1.0) < 1e-9,
          f"E5M2 dec(0x3C) = {fp8_e5m2_dec(0x3C)}, expected 1.0")
    # 0x3F = 0b00111111: e=15, m=3 → 1.75 × 2^0 = 1.75
    check(abs(fp8_e5m2_dec(0x3F) - 1.75) < 1e-9,
          f"E5M2 dec(0x3F) = {fp8_e5m2_dec(0x3F)}, expected 1.75")
    # Max finite: 0x7B = 0b01111011 → e=30, m=3 → 1.75 × 2^15 = 57344
    check(abs(fp8_e5m2_dec(0x7B) - 57344.0) < 1e-3,
          f"E5M2 dec(0x7B) = {fp8_e5m2_dec(0x7B)}, expected 57344.0")
    # ±Inf: 0x7C = 0b01111100 → e=31, m=0 → +Inf
    check(math.isinf(fp8_e5m2_dec(0x7C)) and fp8_e5m2_dec(0x7C) > 0,
          f"E5M2 dec(0x7C) = {fp8_e5m2_dec(0x7C)}, expected +Inf")
    # NaN: 0x7D = 0b01111101 → e=31, m=1 → NaN
    check(math.isnan(fp8_e5m2_dec(0x7D)),
          f"E5M2 dec(0x7D) should be NaN")
    # Encode round-trip
    for v in [1.0, -1.0, 1.75, 0.0, 57344.0, -57344.0, 2.0]:
        cw = fp8_e5m2_enc(v)
        rt = fp8_e5m2_dec(cw)
        if v != 0.0:
            check(abs(rt - v) / abs(v) < 0.3,
                  f"E5M2 round-trip {v}: cw=0x{cw:02X}, got {rt}")
    # Overflow → Inf
    check(math.isinf(fp8_e5m2_dec(fp8_e5m2_enc(100000.0))),
          "E5M2 enc(100000) should produce Inf codeword")
    check(fp8_e5m2_enc(1.0) == 0x3C,
          f"E5M2 enc(1.0) = 0x{fp8_e5m2_enc(1.0):02X}, expected 0x3C")

    # ── BF16 ─────────────────────────────────────────────────────────────────
    # Published: float32(1.0) = 0x3F800000 → bf16 upper 16 bits = 0x3F80 → 1.0
    check(bf16_dec(0x3F80) == 1.0,
          f"BF16 dec(0x3F80) = {bf16_dec(0x3F80)}, expected 1.0")
    check(bf16_dec(0x4000) == 2.0,
          f"BF16 dec(0x4000) = {bf16_dec(0x4000)}, expected 2.0")
    check(bf16_dec(0x3FC0) == 1.5,
          f"BF16 dec(0x3FC0) = {bf16_dec(0x3FC0)}, expected 1.5")
    check(bf16_dec(0x0000) == 0.0,
          f"BF16 dec(0x0000) = {bf16_dec(0x0000)}, expected 0.0")
    check(math.isinf(bf16_dec(0x7F80)),
          "BF16 dec(0x7F80) should be +Inf")
    # Round-trip
    check(bf16_enc(1.0) == 0x3F80,
          f"BF16 enc(1.0) = 0x{bf16_enc(1.0):04X}, expected 0x3F80")
    check(bf16_enc(2.0) == 0x4000,
          f"BF16 enc(2.0) = 0x{bf16_enc(2.0):04X}, expected 0x4000")
    check(bf16_enc(1.5) == 0x3FC0,
          f"BF16 enc(1.5) = 0x{bf16_enc(1.5):04X}, expected 0x3FC0")
    for v in [-1.0, 3.14159, 100.0, 0.0625, -255.0]:
        cw = bf16_enc(v)
        rt = bf16_dec(cw)
        if v != 0:
            check(abs(rt - v) / abs(v) < 0.01,
                  f"BF16 round-trip {v}: cw=0x{cw:04X}, got {rt}")

    # ── INT8 ─────────────────────────────────────────────────────────────────
    scale = 1.0
    check(int8_enc(63.5, scale) == 64,
          f"INT8 enc(63.5,1.0) = {int8_enc(63.5, scale)}, expected 64")
    check(int8_enc(-127.0, scale) == -127,
          f"INT8 enc(-127.0,1.0) = {int8_enc(-127.0, scale)}, expected -127")
    check(int8_enc(200.0, scale) == 127,     # clamp
          f"INT8 enc(200.0,1.0) = {int8_enc(200.0, scale)}, expected 127")
    scale2 = int8_calibrate(np.array([1.0, -2.54, 0.0, 0.5]))
    check(abs(scale2 - 2.54/127) < 1e-9,
          f"INT8 calibrate: scale={scale2}, expected {2.54/127}")

    if failures:
        print("UNIT TEST FAILURES:")
        for f in failures:
            print(f"  FAIL: {f}")
        sys.exit(1)
    print("All unit tests PASSED  (NFE-13, FP8-E4M3, FP8-E5M2, BF16, INT8)")


# ─────────────────────────────────────────────────────────────────────────────
# PART 3 — ARENA A: Single-pass 8×8 matvec accuracy
# Methodology mirrors second_source_validator.py.
# For each format: encode A and x, compute matvec with per-product quantization
# (decode product and accumulate in FP64), decode output, compare to FP64.
# ─────────────────────────────────────────────────────────────────────────────

N = 8
_SEED_A = 0xA3E4_9F01    # arena A seed; not tuned toward any format


def _make_matvec_instance(rng, n=N):
    """Random 8×8 matrix and 8-vector, entries in roughly [0.5, 1.5]."""
    A = [[0.5 + rng.random() for _ in range(n)] for _ in range(n)]
    x = [0.5 + rng.random() for _ in range(n)]
    return A, x


def _fp64_matvec(A, x):
    n = len(x)
    return [sum(A[i][j] * x[j] for j in range(n)) for i in range(n)]


def _vec_mre(got, ref):
    """Mean relative error (%)."""
    errs = []
    for g, r in zip(got, ref):
        if r != 0.0 and math.isfinite(r) and math.isfinite(g):
            errs.append(abs(g - r) / abs(r) * 100.0)
    return sum(errs) / len(errs) if errs else float('inf')


# Per-format matvec: encode A and x, per-product quantize, FP64 accumulate.

def _matvec_nfe(A, x):
    """NFE-13 matvec with per-product 6-bit truncation (mirrors step_nfe)."""
    n = len(x)
    A_enc = [[nfe_enc(A[i][j]) for j in range(n)] for i in range(n)]
    x_enc = [nfe_enc(v) for v in x]
    out = []
    for i in range(n):
        acc = 0.0
        for j in range(n):
            sa, ea, fa = A_enc[i][j]
            sx, ex, fx = x_enc[j]
            sp, ep, fp = nfe_mul_fields(sa, ea, fa, sx, ex, fx)
            acc += nfe_dec(sp, ep, fp)
        out.append(acc)
    return out


def _matvec_fp8_e4m3(A, x):
    n = len(x)
    A_enc = [[fp8_e4m3_enc(A[i][j]) for j in range(n)] for i in range(n)]
    x_enc = [fp8_e4m3_enc(v) for v in x]
    out = []
    for i in range(n):
        acc = 0.0
        for j in range(n):
            p = fp8_e4m3_mul(A_enc[i][j], x_enc[j])
            acc += fp8_e4m3_dec(p)
        out.append(acc)
    return out


def _matvec_fp8_e5m2(A, x):
    n = len(x)
    A_enc = [[fp8_e5m2_enc(A[i][j]) for j in range(n)] for i in range(n)]
    x_enc = [fp8_e5m2_enc(v) for v in x]
    out = []
    for i in range(n):
        acc = 0.0
        for j in range(n):
            p = fp8_e5m2_mul(A_enc[i][j], x_enc[j])
            v = fp8_e5m2_dec(p)
            if math.isfinite(v):
                acc += v
            else:
                acc = v    # propagate Inf/NaN
                break
        out.append(acc)
    return out


def _matvec_bf16(A, x):
    n = len(x)
    A_enc = [[bf16_enc(A[i][j]) for j in range(n)] for i in range(n)]
    x_enc = [bf16_enc(v) for v in x]
    out = []
    for i in range(n):
        acc = 0.0
        for j in range(n):
            p = bf16_mul(A_enc[i][j], x_enc[j])
            acc += bf16_dec(p)
        out.append(acc)
    return out


def _matvec_int8(A, x):
    """INT8 matvec: calibrate per-matrix and per-vector scales, accumulate in FP64."""
    n = len(x)
    flat_A = [A[i][j] for i in range(n) for j in range(n)]
    scale_A = int8_calibrate(flat_A)
    scale_x = int8_calibrate(x)
    q_A = [[int8_enc(A[i][j], scale_A) for j in range(n)] for i in range(n)]
    q_x = [int8_enc(v, scale_x) for v in x]
    combined_scale = scale_A * scale_x
    out = []
    for i in range(n):
        acc = sum(float(q_A[i][j] * q_x[j]) * combined_scale for j in range(n))
        out.append(acc)
    return out


def run_arena_a(n_trials=100, verbose=False):
    """Arena A: single-pass 8×8 matvec accuracy vs FP64 golden."""
    rng = random.Random(_SEED_A)
    fmt_fns = {
        "NFE-13":   _matvec_nfe,
        "FP8-E4M3": _matvec_fp8_e4m3,
        "FP8-E5M2": _matvec_fp8_e5m2,
        "BF16":     _matvec_bf16,
        "INT8":     _matvec_int8,
    }
    results = {k: [] for k in fmt_fns}
    for _ in range(n_trials):
        A, x = _make_matvec_instance(rng)
        ref = _fp64_matvec(A, x)
        for fmt, fn in fmt_fns.items():
            out = fn(A, x)
            mre = _vec_mre(out, ref)
            results[fmt].append(mre)

    summary = {}
    for fmt, mres in results.items():
        finite = [e for e in mres if math.isfinite(e)]
        summary[fmt] = {
            "mean_mre_pct": sum(finite) / len(finite) if finite else float('inf'),
            "p95_mre_pct":  sorted(finite)[int(0.95 * len(finite))] if finite else float('inf'),
            "n_trials":     n_trials,
        }
    return summary


# ─────────────────────────────────────────────────────────────────────────────
# PART 4 — ARENA B: 256-cycle feedback chains
# Methodology mirrors second_source_chain.py and norm_interval_sweep.py.
# Two regimes: neutral (row sums ≈1.0) and expansive (row sums ≈1.1).
# Two normalization schedules: k=None (unnormalized) and k=8 (every 8 steps).
# Per-format: saturation/Inf events and floor/zero events counted.
# ─────────────────────────────────────────────────────────────────────────────

_SEED_B      = 0xCAFEF00D   # matches second_source_chain.py SEED_SSC_BASE
_CHAIN_DEPTH = 256
_N_CHAINS    = 100
_CHAIN_TOL   = 1.0          # divergence cut: mean rel err %


def _make_chain_instance_b(rng, regime):
    target = {"neutral": 1.0, "expansive": 1.1}[regime]
    A_fp = [[rng.random() for _ in range(N)] for _ in range(N)]
    for i in range(N):
        rs = sum(A_fp[i])
        A_fp[i] = [a / rs * target for a in A_fp[i]]
    x_fp = [(1.0 + rng.random()) * math.ldexp(1.0, rng.randint(28, 35) - 32)
            for _ in range(N)]
    return A_fp, x_fp


def _chain_step_nfe(A_enc, y_enc_list):
    """NFE chain step with per-product 6-bit truncation."""
    sat = floor_ = 0
    out = []
    for i in range(N):
        acc = 0.0
        for j in range(N):
            sa, ea, fa = A_enc[i][j]
            sy, ey, fy = y_enc_list[j]
            sp, ep, fp_ = nfe_mul_fields(sa, ea, fa, sy, ey, fy)
            acc += nfe_dec(sp, ep, fp_)
        s, e, f = nfe_enc(acc)
        out.append((s, e, f))
        if nfe_is_sat(e, f):
            sat += 1
        if nfe_is_floor(e, f):
            floor_ += 1
    return out, sat, floor_


def _decode_nfe_vec(y_enc_list):
    return [nfe_dec(s, e, f) for s, e, f in y_enc_list]


def _chain_step_fp8_e4m3(A_enc, y_enc):
    sat = floor_ = 0
    out = []
    for i in range(N):
        acc = 0.0
        for j in range(N):
            p = fp8_e4m3_mul(A_enc[i][j], y_enc[j])
            acc += fp8_e4m3_dec(p)
        cw = fp8_e4m3_enc(acc)
        out.append(cw)
        if fp8_e4m3_is_overflow(cw):
            sat += 1
        if fp8_e4m3_is_floor(cw):
            floor_ += 1
    return out, sat, floor_


def _chain_step_fp8_e5m2(A_enc, y_enc):
    sat = floor_ = nan = 0
    out = []
    for i in range(N):
        acc = 0.0
        propagated = False
        for j in range(N):
            p = fp8_e5m2_mul(A_enc[i][j], y_enc[j])
            v = fp8_e5m2_dec(p)
            if math.isnan(v):
                acc = float('nan')
                propagated = True
                break
            elif math.isinf(v):
                acc = v
                propagated = True
            elif not propagated:
                acc += v
        cw = fp8_e5m2_enc(acc)
        out.append(cw)
        if fp8_e5m2_is_overflow(cw):
            sat += 1
        if fp8_e5m2_is_nan(cw):
            nan += 1
        if fp8_e5m2_is_floor(cw):
            floor_ += 1
    return out, sat + nan, floor_


def _chain_step_bf16(A_enc, y_enc):
    sat = floor_ = 0
    out = []
    for i in range(N):
        acc = 0.0
        for j in range(N):
            p = bf16_mul(A_enc[i][j], y_enc[j])
            v = bf16_dec(p)
            if math.isfinite(v):
                acc += v
            else:
                acc = v
                break
        cw = bf16_enc(acc)
        out.append(cw)
        if bf16_is_overflow(cw) or bf16_is_nan(cw):
            sat += 1
        if bf16_is_floor(cw):
            floor_ += 1
    return out, sat, floor_


def _chain_step_int8(A_q, scale_A, y_q, scale_y):
    """INT8 chain step: accumulate integer products in FP64, return new (q, scale)."""
    combined = scale_A * scale_y
    sat = floor_ = 0
    new_fp = []
    for i in range(N):
        acc = sum(float(A_q[i][j] * int(y_q[j])) * combined for j in range(N))
        new_fp.append(acc)
    max_abs = max(abs(v) for v in new_fp)
    new_scale = max_abs / 127.0 if max_abs > 0.0 else 1.0
    new_q = []
    for v in new_fp:
        q = int8_enc(v, new_scale)
        new_q.append(q)
        if int8_is_saturated(q):
            sat += 1
        if q == 0:
            floor_ += 1
    return new_q, new_scale, sat, floor_


def _normalize_nfe(y_enc_list):
    """Rescale NFE state so max decoded abs = 1.0, then re-encode."""
    decoded = _decode_nfe_vec(y_enc_list)
    ma = max(abs(v) for v in decoded)
    if ma == 0.0:
        return y_enc_list
    return [nfe_enc(v / ma) for v in decoded]


def _normalize_fp8_e4m3(y_enc):
    decoded = [fp8_e4m3_dec(c) for c in y_enc]
    ma = max(abs(v) for v in decoded if math.isfinite(v))
    if ma == 0.0:
        return y_enc
    return [fp8_e4m3_enc(v / ma) for v in decoded]


def _normalize_fp8_e5m2(y_enc):
    decoded = [fp8_e5m2_dec(c) for c in y_enc]
    finite = [abs(v) for v in decoded if math.isfinite(v) and v != 0.0]
    if not finite:
        return y_enc
    ma = max(finite)
    return [fp8_e5m2_enc(v / ma if math.isfinite(v) else v) for v in decoded]


def _normalize_bf16(y_enc):
    decoded = [bf16_dec(c) for c in y_enc]
    finite = [abs(v) for v in decoded if math.isfinite(v) and v != 0.0]
    if not finite:
        return y_enc
    ma = max(finite)
    return [bf16_enc(v / ma if math.isfinite(v) else v) for v in decoded]


def _normalize_int8(y_q, scale_y):
    """For k-norm INT8: decode, normalize to max_abs=1, recalibrate scale."""
    decoded = [int8_dec(q, scale_y) for q in y_q]
    ma = max(abs(v) for v in decoded)
    if ma == 0.0:
        return y_q, scale_y
    normed = [v / ma for v in decoded]
    new_scale = 1.0 / 127.0
    new_q = [int8_enc(v, new_scale) for v in normed]
    return new_q, new_scale


def _chain_mre(y_encoded, fmt, scale, y_ref):
    """Mean relative error of decoded format state vs FP64 reference."""
    if fmt == "NFE-13":
        decoded = _decode_nfe_vec(y_encoded)
    elif fmt == "FP8-E4M3":
        decoded = [fp8_e4m3_dec(c) for c in y_encoded]
    elif fmt == "FP8-E5M2":
        decoded = [fp8_e5m2_dec(c) for c in y_encoded]
    elif fmt == "BF16":
        decoded = [bf16_dec(c) for c in y_encoded]
    elif fmt == "INT8":
        decoded = [int8_dec(q, scale) for q in y_encoded]
    errs = []
    for g, r in zip(decoded, y_ref):
        if r != 0.0 and math.isfinite(r) and math.isfinite(g):
            errs.append(abs(g - r) / abs(r) * 100.0)
    return sum(errs) / len(errs) if errs else float('inf')


def _run_single_chain(A_fp, x_fp, fmt, k_norm, depth=_CHAIN_DEPTH, tol=_CHAIN_TOL):
    """Run one feedback chain for the given format and normalization interval."""
    # Precompute FP64 golden chain
    y_g = list(x_fp)
    A_np = np.array(A_fp)

    # Encode A once
    if fmt == "NFE-13":
        A_enc = [[nfe_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]
        y_enc = [nfe_enc(v) for v in x_fp]
        scale  = None
    elif fmt == "FP8-E4M3":
        A_enc = [[fp8_e4m3_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]
        y_enc = [fp8_e4m3_enc(v) for v in x_fp]
        scale = None
    elif fmt == "FP8-E5M2":
        A_enc = [[fp8_e5m2_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]
        y_enc = [fp8_e5m2_enc(v) for v in x_fp]
        scale = None
    elif fmt == "BF16":
        A_enc = [[bf16_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]
        y_enc = [bf16_enc(v) for v in x_fp]
        scale = None
    elif fmt == "INT8":
        flat_A = [A_fp[i][j] for i in range(N) for j in range(N)]
        scale_A = int8_calibrate(flat_A)
        A_enc = [[int8_enc(A_fp[i][j], scale_A) for j in range(N)] for i in range(N)]
        scale_x = int8_calibrate(x_fp)
        y_enc = [int8_enc(v, scale_x) for v in x_fp]
        scale = scale_x

    tot_sat = tot_floor = 0
    onset = depth + 1
    err = 0.0
    golden_ovf = False

    for t in range(1, depth + 1):
        # Golden step
        y_g = list(A_np @ np.array(y_g))
        if any(not math.isfinite(v) or abs(v) > 1e300 for v in y_g):
            golden_ovf = True
            break

        # Format step
        if fmt == "NFE-13":
            y_enc, sat, fl = _chain_step_nfe(A_enc, y_enc)
        elif fmt == "FP8-E4M3":
            y_enc, sat, fl = _chain_step_fp8_e4m3(A_enc, y_enc)
        elif fmt == "FP8-E5M2":
            y_enc, sat, fl = _chain_step_fp8_e5m2(A_enc, y_enc)
        elif fmt == "BF16":
            y_enc, sat, fl = _chain_step_bf16(A_enc, y_enc)
        elif fmt == "INT8":
            y_enc, scale, sat, fl = _chain_step_int8(A_enc, scale_A, y_enc, scale)
        tot_sat  += sat
        tot_floor += fl

        # k-normalization
        if k_norm is not None and t % k_norm == 0:
            if fmt == "NFE-13":
                y_enc = _normalize_nfe(y_enc)
            elif fmt == "FP8-E4M3":
                y_enc = _normalize_fp8_e4m3(y_enc)
            elif fmt == "FP8-E5M2":
                y_enc = _normalize_fp8_e5m2(y_enc)
            elif fmt == "BF16":
                y_enc = _normalize_bf16(y_enc)
            elif fmt == "INT8":
                y_enc, scale = _normalize_int8(y_enc, scale)

        err = _chain_mre(y_enc, fmt, scale, y_g)
        if onset > depth and err > tol:
            onset = t

    return {
        "onset":        onset,
        "final_mre":    err,
        "sat_events":   tot_sat,
        "floor_events": tot_floor,
        "golden_ovf":   golden_ovf,
    }


def run_arena_b(n_chains=_N_CHAINS, depth=_CHAIN_DEPTH, verbose=False):
    """Arena B: feedback chains, neutral and expansive, k=∞ and k=8."""
    regimes  = ["neutral", "expansive"]
    k_values = [None, 8]      # None = unnormalized
    formats  = ["NFE-13", "FP8-E4M3", "FP8-E5M2", "BF16", "INT8"]

    all_results = {}
    for regime in regimes:
        for k_norm in k_values:
            rng = random.Random(_SEED_B ^ (hash(regime) & 0xFFFFFFFF)
                                ^ ((k_norm or 0) * 0x01010101))
            key = (regime, "unnorm" if k_norm is None else f"k={k_norm}")
            all_results[key] = {}
            for fmt in formats:
                chain_results = []
                rng2 = random.Random(_SEED_B ^ (hash(regime) & 0xFFFFFFFF)
                                     ^ ((k_norm or 0) * 0x01010101))
                for _ in range(n_chains):
                    A_fp, x_fp = _make_chain_instance_b(rng2, regime)
                    r = _run_single_chain(A_fp, x_fp, fmt, k_norm, depth)
                    chain_results.append(r)

                valid = [r for r in chain_results if not r["golden_ovf"]]
                n_v = len(valid)
                if n_v == 0:
                    all_results[key][fmt] = {
                        "onset_mean":    float('nan'),
                        "never_diverg":  0,
                        "final_mre":     float('nan'),
                        "sat_per_chain": float('nan'),
                        "floor_per_chain": float('nan'),
                        "n_valid":       0,
                    }
                    continue

                onsets    = [r["onset"] for r in valid]
                final_mre = [r["final_mre"] for r in valid if math.isfinite(r["final_mre"])]
                sat_ev    = [r["sat_events"] for r in valid]
                fl_ev     = [r["floor_events"] for r in valid]

                all_results[key][fmt] = {
                    "onset_mean":      sum(onsets) / n_v,
                    "never_diverg":    sum(o > depth for o in onsets),
                    "final_mre":       sum(final_mre) / len(final_mre) if final_mre else float('inf'),
                    "sat_per_chain":   sum(sat_ev) / n_v,
                    "floor_per_chain": sum(fl_ev) / n_v,
                    "n_valid":         n_v,
                }

    return all_results


# ─────────────────────────────────────────────────────────────────────────────
# PART 5 — ARENA C: MLP digit inference
# Methodology mirrors mlp_infer_nfe.py pipeline (c).
# Loads FP64 weights from MLP_FP64.npz, re-encodes in each format.
# NFE uses shared-offset expnorm between layers (mlp_infer_nfe.py lines 118-137).
# Other formats: encode activations in format after ReLU, no special regrounding.
# INT8: per-tensor scale recalibration between layers.
# ─────────────────────────────────────────────────────────────────────────────

_E_TARGET = 32    # NFE expnorm anchor, matches mlp_infer_nfe.py E_TARGET


def _nfe_shared_offset_expnorm(block_a, block_b, e_target=_E_TARGET):
    """Two-pass shared-offset expnorm. Mirrors mlp_infer_nfe.py lines 118-137."""
    e_max_a = max(e for _, e, _ in block_a)
    e_max_b = max(e for _, e, _ in block_b)
    shared_e_max = max(e_max_a, e_max_b)
    if shared_e_max == 0:
        return list(block_a), list(block_b)
    offset = e_target - shared_e_max
    def apply(block):
        out = []
        for s, e, f in block:
            ne = e + offset
            if ne < 0:
                out.append((s, 0, 0))
            elif ne > _NFE_EMAX:
                out.append((s, _NFE_EMAX, 63))
            else:
                out.append((s, ne, f))
        return out
    return apply(block_a), apply(block_b)


def _mlp_forward_nfe(W1, b1, W2, b2, x):
    """NFE inference: per-product multiply, FP64 accumulate, shared-offset expnorm."""
    n_h = len(b1)   # 16
    n_i = len(x)    # 64
    n_o = len(b2)   # 10

    W1_enc = [[nfe_enc(W1[i][j]) for j in range(n_i)] for i in range(n_h)]
    b1_enc = [nfe_enc(b) for b in b1]
    W2_enc = [[nfe_enc(W2[k][i]) for i in range(n_h)] for k in range(n_o)]
    b2_enc = [nfe_enc(b) for b in b2]
    x_enc  = [nfe_enc(v) for v in x]

    # Layer 1 MAC
    h1_raw = []
    for i in range(n_h):
        acc = nfe_dec(*b1_enc[i])
        for j in range(n_i):
            sp, ep, fp = nfe_mul_fields(*W1_enc[i][j], *x_enc[j])
            acc += nfe_dec(sp, ep, fp)
        h1_raw.append(nfe_enc(max(0.0, acc)))

    # Shared-offset expnorm (two 8-element blocks)
    b0_norm, b1_norm = _nfe_shared_offset_expnorm(h1_raw[:8], h1_raw[8:])
    h1_enc = b0_norm + b1_norm

    # Layer 2
    z2 = []
    for k in range(n_o):
        acc = nfe_dec(*b2_enc[k])
        for i in range(n_h):
            sp, ep, fp = nfe_mul_fields(*W2_enc[k][i], *h1_enc[i])
            acc += nfe_dec(sp, ep, fp)
        z2.append(acc)
    return int(np.argmax(z2))


def _mlp_forward_fp8_e4m3(W1, b1, W2, b2, x):
    n_h, n_i, n_o = len(b1), len(x), len(b2)
    W1e = [[fp8_e4m3_enc(W1[i][j]) for j in range(n_i)] for i in range(n_h)]
    b1e = [fp8_e4m3_enc(b) for b in b1]
    W2e = [[fp8_e4m3_enc(W2[k][i]) for i in range(n_h)] for k in range(n_o)]
    b2e = [fp8_e4m3_enc(b) for b in b2]
    xe  = [fp8_e4m3_enc(v) for v in x]

    h1 = []
    for i in range(n_h):
        acc = fp8_e4m3_dec(b1e[i])
        for j in range(n_i):
            acc += fp8_e4m3_dec(fp8_e4m3_mul(W1e[i][j], xe[j]))
        h1.append(fp8_e4m3_enc(max(0.0, acc)))

    z2 = []
    for k in range(n_o):
        acc = fp8_e4m3_dec(b2e[k])
        for i in range(n_h):
            acc += fp8_e4m3_dec(fp8_e4m3_mul(W2e[k][i], h1[i]))
        z2.append(acc)
    return int(np.argmax(z2))


def _mlp_forward_fp8_e5m2(W1, b1, W2, b2, x):
    n_h, n_i, n_o = len(b1), len(x), len(b2)
    W1e = [[fp8_e5m2_enc(W1[i][j]) for j in range(n_i)] for i in range(n_h)]
    b1e = [fp8_e5m2_enc(b) for b in b1]
    W2e = [[fp8_e5m2_enc(W2[k][i]) for i in range(n_h)] for k in range(n_o)]
    b2e = [fp8_e5m2_enc(b) for b in b2]
    xe  = [fp8_e5m2_enc(v) for v in x]

    h1 = []
    for i in range(n_h):
        acc = fp8_e5m2_dec(b1e[i])
        if not math.isfinite(acc):
            acc = 0.0
        for j in range(n_i):
            p = fp8_e5m2_mul(W1e[i][j], xe[j])
            v = fp8_e5m2_dec(p)
            if math.isfinite(v):
                acc += v
        h1.append(fp8_e5m2_enc(max(0.0, acc) if math.isfinite(acc) else 0.0))

    z2 = []
    for k in range(n_o):
        acc = fp8_e5m2_dec(b2e[k])
        if not math.isfinite(acc):
            acc = 0.0
        for i in range(n_h):
            p = fp8_e5m2_mul(W2e[k][i], h1[i])
            v = fp8_e5m2_dec(p)
            if math.isfinite(v):
                acc += v
        z2.append(acc if math.isfinite(acc) else 0.0)
    return int(np.argmax(z2))


def _mlp_forward_bf16(W1, b1, W2, b2, x):
    n_h, n_i, n_o = len(b1), len(x), len(b2)
    W1e = [[bf16_enc(W1[i][j]) for j in range(n_i)] for i in range(n_h)]
    b1e = [bf16_enc(b) for b in b1]
    W2e = [[bf16_enc(W2[k][i]) for i in range(n_h)] for k in range(n_o)]
    b2e = [bf16_enc(b) for b in b2]
    xe  = [bf16_enc(v) for v in x]

    h1 = []
    for i in range(n_h):
        acc = bf16_dec(b1e[i])
        for j in range(n_i):
            acc += bf16_dec(bf16_mul(W1e[i][j], xe[j]))
        h1.append(bf16_enc(max(0.0, acc) if math.isfinite(acc) else 0.0))

    z2 = []
    for k in range(n_o):
        acc = bf16_dec(b2e[k])
        for i in range(n_h):
            acc += bf16_dec(bf16_mul(W2e[k][i], h1[i]))
        z2.append(acc if math.isfinite(acc) else 0.0)
    return int(np.argmax(z2))


def _mlp_forward_int8(W1, b1, W2, b2, x,
                      scale_W1, scale_b1, scale_W2, scale_b2, scale_x):
    """INT8 inference: per-layer INT8 quantization, INT32 accumulate, FP64 argmax."""
    n_h, n_i, n_o = len(b1), len(x), len(b2)

    q_W1 = [[int8_enc(W1[i][j], scale_W1) for j in range(n_i)] for i in range(n_h)]
    q_b1 = [int8_enc(b, scale_b1) for b in b1]
    q_W2 = [[int8_enc(W2[k][i], scale_W2) for i in range(n_h)] for k in range(n_o)]
    q_b2 = [int8_enc(b, scale_b2) for b in b2]
    q_x  = [int8_enc(v, scale_x) for v in x]

    comb1 = scale_W1 * scale_x
    # Layer 1
    h1_fp = []
    for i in range(n_h):
        acc = float(q_b1[i]) * scale_b1
        acc += sum(float(q_W1[i][j] * q_x[j]) * comb1 for j in range(n_i))
        h1_fp.append(max(0.0, acc))   # ReLU

    # Recalibrate activation scale after layer 1
    scale_h1 = int8_calibrate(h1_fp)
    q_h1 = [int8_enc(v, scale_h1) for v in h1_fp]

    comb2 = scale_W2 * scale_h1
    # Layer 2
    z2 = []
    for k in range(n_o):
        acc = float(q_b2[k]) * scale_b2
        acc += sum(float(q_W2[k][i] * q_h1[i]) * comb2 for i in range(n_h))
        z2.append(acc)
    return int(np.argmax(z2))


def run_arena_c(verbose=False):
    """Arena C: MLP 64→16→10 digit inference on 360 test images."""
    npz_path = os.path.join(DIR, "MLP_FP64.npz")
    if not os.path.exists(npz_path):
        return {"error": f"MLP_FP64.npz not found at {npz_path}"}

    d   = np.load(npz_path)
    W1  = d["W1"].tolist()        # 16×64
    b1  = d["b1"].tolist()        # 16
    W2  = d["W2"].tolist()        # 10×16
    b2  = d["b2"].tolist()        # 10
    X   = d["X_te"]               # 360×64
    y   = d["y_te"]               # 360

    # Calibrate INT8 scales once from the weight tensors
    W1_flat = [W1[i][j] for i in range(len(W1)) for j in range(len(W1[0]))]
    W2_flat = [W2[k][i] for k in range(len(W2)) for i in range(len(W2[0]))]
    scale_W1 = int8_calibrate(W1_flat)
    scale_W2 = int8_calibrate(W2_flat)
    scale_b1 = int8_calibrate(b1)
    scale_b2 = int8_calibrate(b2)
    scale_x  = 1.0 / 127.0    # pixels in [0, 1]

    formats = ["NFE-13", "FP8-E4M3", "FP8-E5M2", "BF16", "INT8"]
    preds = {fmt: [] for fmt in formats}

    for idx in range(len(y)):
        x = list(X[idx])
        for fmt in formats:
            if fmt == "NFE-13":
                p = _mlp_forward_nfe(W1, b1, W2, b2, x)
            elif fmt == "FP8-E4M3":
                p = _mlp_forward_fp8_e4m3(W1, b1, W2, b2, x)
            elif fmt == "FP8-E5M2":
                p = _mlp_forward_fp8_e5m2(W1, b1, W2, b2, x)
            elif fmt == "BF16":
                p = _mlp_forward_bf16(W1, b1, W2, b2, x)
            elif fmt == "INT8":
                p = _mlp_forward_int8(W1, b1, W2, b2, x,
                                      scale_W1, scale_b1, scale_W2, scale_b2, scale_x)
            preds[fmt].append(p)

    results = {}
    for fmt in formats:
        correct = sum(int(preds[fmt][i]) == int(y[i]) for i in range(len(y)))
        results[fmt] = {
            "correct": correct,
            "total":   len(y),
            "accuracy_pct": 100.0 * correct / len(y),
        }
    return results


# ─────────────────────────────────────────────────────────────────────────────
# PART 6 — MASTER TABLE OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

def _fmt_f(v, places=2):
    if not math.isfinite(v):
        return "N/A"
    return f"{v:.{places}f}"


def print_master_table(res_a, res_b, res_c):
    hdr = f"{'Format':<12} {'Bits':>4} | " \
          f"{'A: mean MRE%':>13} {'A: p95 MRE%':>12} | " \
          f"{'B(n,k=∞) onset':>16} {'B(n,k=∞) MRE%':>14} {'sat/ch':>7} | " \
          f"{'B(n,k=8) onset':>16} {'B(n,k=8) MRE%':>14} | " \
          f"{'B(e,k=∞) onset':>16} {'B(e,k=∞) MRE%':>14} {'sat/ch':>7} | " \
          f"{'B(e,k=8) onset':>16} {'B(e,k=8) MRE%':>14} | " \
          f"{'C: accuracy%':>13}"
    print()
    print("=" * len(hdr))
    print("MASTER TABLE  —  format × arena × metric   (bits always shown)")
    print("=" * len(hdr))
    print(hdr)
    print("-" * len(hdr))

    formats = ["NFE-13", "FP8-E4M3", "FP8-E5M2", "BF16", "INT8"]
    for fmt in formats:
        bits = BITS[fmt]
        a = res_a.get(fmt, {})
        a_mre   = _fmt_f(a.get("mean_mre_pct", float('nan')), 3)
        a_p95   = _fmt_f(a.get("p95_mre_pct",  float('nan')), 3)

        def bget(regime, k_label):
            key = (regime, k_label)
            return res_b.get(key, {}).get(fmt, {})

        bn_u = bget("neutral",   "unnorm")
        bn_k = bget("neutral",   "k=8")
        be_u = bget("expansive", "unnorm")
        be_k = bget("expansive", "k=8")

        c = res_c.get(fmt, {})
        c_acc = _fmt_f(c.get("accuracy_pct", float('nan')), 2)

        row = (f"{fmt:<12} {bits:>4} | "
               f"{a_mre:>13} {a_p95:>12} | "
               f"{_fmt_f(bn_u.get('onset_mean', float('nan')),1):>16} "
               f"{_fmt_f(bn_u.get('final_mre',  float('nan')),2):>14} "
               f"{_fmt_f(bn_u.get('sat_per_chain', float('nan')),1):>7} | "
               f"{_fmt_f(bn_k.get('onset_mean', float('nan')),1):>16} "
               f"{_fmt_f(bn_k.get('final_mre',  float('nan')),2):>14} | "
               f"{_fmt_f(be_u.get('onset_mean', float('nan')),1):>16} "
               f"{_fmt_f(be_u.get('final_mre',  float('nan')),2):>14} "
               f"{_fmt_f(be_u.get('sat_per_chain', float('nan')),1):>7} | "
               f"{_fmt_f(be_k.get('onset_mean', float('nan')),1):>16} "
               f"{_fmt_f(be_k.get('final_mre',  float('nan')),2):>14} | "
               f"{c_acc:>13}")
        print(row)

    print("=" * len(hdr))
    print()
    print("Column legend:")
    print("  A: mean MRE%    = mean relative error % over 100 single-pass 8×8 matvec trials")
    print("  A: p95 MRE%     = 95th percentile MRE%")
    print("  B(n,k=∞) onset  = mean first cycle > 1% MRE, neutral regime, unnormalized (1=first step)")
    print("  B(n,k=8) onset  = same but with k=8 normalization injection")
    print("  B(e,…)          = same columns for expansive regime (row sums ≈1.1)")
    print("  sat/ch          = overflow/Inf/NaN sentinel events per chain (unnormalized only)")
    print("  C: accuracy%    = top-1 digit classification accuracy on 360 test images")
    print()
    print("  NFE-13: floor sentinel=E=0; sat sentinel=E=63.")
    print("  FP8-E5M2 / BF16: sat events = Inf or NaN produced by overflow.")
    print("  FP8-E4M3: sat events = clamped to ±448 (no Inf representation).")
    print("  INT8: sat events = element clamped to ±127 during re-quantization.")
    print()
    # Quick finder for NFE floor events in chains
    for key_label, key_tuple in [
        ("neutral/unnorm", ("neutral", "unnorm")),
        ("neutral/k=8",    ("neutral", "k=8")),
        ("expansive/unnorm", ("expansive", "unnorm")),
        ("expansive/k=8",    ("expansive", "k=8")),
    ]:
        n13 = res_b.get(key_tuple, {}).get("NFE-13", {})
        e52 = res_b.get(key_tuple, {}).get("FP8-E5M2", {})
        fl_nfe = n13.get("floor_per_chain", float('nan'))
        fl_e52 = e52.get("floor_per_chain", float('nan'))
        onset_nfe = n13.get("onset_mean", float('nan'))
        onset_e52 = e52.get("onset_mean", float('nan'))
        print(f"  Chain {key_label:20s}: NFE-13 floor/ch={_fmt_f(fl_nfe,1)}  "
              f"E5M2 floor/ch={_fmt_f(fl_e52,1)}  |  "
              f"onset NFE={_fmt_f(onset_nfe,1)}  E5M2={_fmt_f(onset_e52,1)}")
    print()


def save_csv(res_a, res_b, res_c, path):
    rows = []
    formats = ["NFE-13", "FP8-E4M3", "FP8-E5M2", "BF16", "INT8"]

    for fmt in formats:
        bits = BITS[fmt]
        a = res_a.get(fmt, {})

        def bget(regime, k_label):
            return res_b.get((regime, k_label), {}).get(fmt, {})

        c = res_c.get(fmt, {})

        rows.append({
            "format":        fmt,
            "bits":          bits,
            "arena":         "A",
            "metric":        "mean_mre_pct",
            "value":         a.get("mean_mre_pct", ""),
        })
        rows.append({
            "format":        fmt,
            "bits":          bits,
            "arena":         "A",
            "metric":        "p95_mre_pct",
            "value":         a.get("p95_mre_pct", ""),
        })
        for (regime, k_label) in [("neutral","unnorm"),("neutral","k=8"),
                                   ("expansive","unnorm"),("expansive","k=8")]:
            b = bget(regime, k_label)
            for metric, val in b.items():
                rows.append({
                    "format":  fmt,
                    "bits":    bits,
                    "arena":   f"B_{regime}_{k_label}",
                    "metric":  metric,
                    "value":   val,
                })
        rows.append({
            "format":  fmt,
            "bits":    bits,
            "arena":   "C",
            "metric":  "accuracy_pct",
            "value":   c.get("accuracy_pct", ""),
        })

    os.makedirs(os.path.dirname(path) if os.path.dirname(path) else ".", exist_ok=True)
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["format", "bits", "arena", "metric", "value"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"Raw data saved → {path}")


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Format-zoo head-to-head comparison")
    ap.add_argument("--arena", choices=["A", "B", "C", "all"], default="all")
    ap.add_argument("--chains", type=int, default=_N_CHAINS,
                    help=f"Chains per regime for Arena B (default {_N_CHAINS})")
    ap.add_argument("--depth",  type=int, default=_CHAIN_DEPTH)
    ap.add_argument("--out", default=os.path.join(DIR, "FORMAT_COMPARISON_RAW.csv"))
    ap.add_argument("--skip-tests", action="store_true")
    args = ap.parse_args()

    if not args.skip_tests:
        run_unit_tests()

    res_a = res_b = res_c = {}

    if args.arena in ("A", "all"):
        print("Running Arena A (8×8 matvec accuracy)…", flush=True)
        res_a = run_arena_a()
        print("  Arena A complete.")

    if args.arena in ("B", "all"):
        print(f"Running Arena B ({args.chains} chains × 2 regimes × 2 k-values × "
              f"5 formats, depth={args.depth})…", flush=True)
        res_b = run_arena_b(n_chains=args.chains, depth=args.depth)
        print("  Arena B complete.")

    if args.arena in ("C", "all"):
        print("Running Arena C (MLP inference)…", flush=True)
        res_c = run_arena_c()
        print("  Arena C complete.")

    print_master_table(res_a, res_b, res_c)

    if args.out:
        save_csv(res_a, res_b, res_c, args.out)


if __name__ == "__main__":
    main()

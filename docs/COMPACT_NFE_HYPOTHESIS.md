# COMPACT NFE HYPOTHESIS — Pre-registered Criteria

**Repository**: Horus-Geometry-Fabric  
**Written**: 2026-07-05, before any experiment code is run.  
**Status**: Pre-registration; criteria binding on `docs/COMPACT_NFE_VERDICT.md`.

---

## Motivation

`docs/GRADIENT_NICHE_FINAL.md` confirmed Claim (a): NFE-13 (1s 6e 6f, 13 bits/element)
matches BF16 gradient-accumulation quality at 0.59× BF16 multiplier area. The niche is
per-element mantissa precision; the 6-bit mantissa is the load-bearing component.

NFE-13's 6-bit per-element exponent (bias 32, range [2.4×10⁻⁹, 4.3×10⁹]) was never
stressed: in `sim/gradient_range_v2.py`, bare = norm for all conditions, meaning the
running-sum magnitudes at depth=256 stayed well within the per-element range and the
overflow-triggered re-grounding never fired. The exponent bits are partially redundant
given the range required — but only if the missing dynamic range is provided by another
mechanism.

**Hypothesis**: replace the per-element 6-bit exponent with a shorter one (2–5 bits),
delegate the missing dynamic range to a shared block exponent (one per 8 elements per
step, chosen by max magnitude, exactly the horus_norm_v2 mechanism). Keep the 6-bit
mantissa unchanged. Test whether the gradient niche and MLP accuracy survive.

---

## Format Family

EnM6 (n-bit exponent, 6-bit mantissa):

- **Encoding**: (sign[1], e_stored[n], fraction[6])  
- **Value (normal)**: (−1)^s × 2^(e_stored − bias) × (1 + f/64), for e_stored ∈ [1, 2ⁿ−1]  
- **Bias**: 2^(n−1) (NFE-13 convention)  
- **Subnormal**: e_stored=0, value = 2^(1−bias) × (f/64)  
- **Saturation**: no Inf/NaN; clamp to max-finite at ±(2^(2ⁿ−1 − bias) × 127/64)

Representable ranges:

| Format | Bits | Bias | Min normal | Max finite | vs NFE-13 max |
|--------|------|------|-----------|-----------|---------------|
| E2M6 | 9 | 2 | 0.500 | ≈ 3.97 | 1.1×10⁻⁹ × |
| E3M6 | 10 | 4 | 0.125 | ≈ 15.9 | 3.7×10⁻⁷ × |
| E4M6 | 11 | 8 | ≈ 0.0078 | ≈ 254 | 6×10⁻⁵ × |
| E5M6 | 12 | 16 | ≈ 3×10⁻⁵ | ≈ 65032 | 0.015× |
| E6M6 = NFE-13 | 13 | 32 | ≈ 4.7×10⁻¹⁰ | ≈ 4.3×10⁹ | 1× |

All formats have identical ULP at any given value scale: ULP(v) = |v| / 64. The mantissa
precision is identical across the family. The exponent bits determine representable range,
not per-step precision at a given accumulator scale.

---

## Block-Scale Mechanism

One signed 6-bit integer ("block exponent", b) shared per 8-element block per step:

1. Decode: effective\_value[i] = enm6\_dec(cw[i], n) × 2^b  
2. Operate (add gradient): new\_v[i] = effective\_value[i] + grad[i]  
3. Re-encode: find new b such that max |new\_v[i]| maps to the upper-normal e_stored  
   (exactly horus\_norm\_v2: b = floor(log₂(max|v|)) − (max\_e\_stored − 1 − bias))  
4. Encode: cw[i] = enm6\_enc(new\_v[i] / 2^b, n)  
5. Store (cw[0..7], b)

This is lossless when max|v[i]| is in normal range after step 3. Information loss
occurs when a small v[i] / 2^b underflows the per-element format's subnormal floor —
which is the pre-registered risk below.

---

## Storage Accounting (K3)

Block exponent size: 6 bits (same as NFE-13 per-element exponent, for fair comparison).
Block size: 8 elements.

| Format | Per-element bits | Block exp (amortised) | Effective bits/elem | vs NFE-13 |
|--------|------------------|-----------------------|---------------------|-----------|
| E2M6+block | 9 | 6/8 = 0.75 | **9.75** | −3.25 |
| E3M6+block | 10 | 0.75 | **10.75** | −2.25 |
| E4M6+block | 11 | 0.75 | **11.75** | −1.25 |
| E5M6+block | 12 | 0.75 | **12.75** | −0.25 |
| E6M6+block (NFE-13) | 13 | 0.75 | **13.75** | +0.75 |
| FP8-E4M3 (no block) | 8 | — | 8.00 | −5.00 |
| BF16 (no block) | 16 | — | 16.00 | +3.00 |

K3 is informational: the table above is the deliverable.

---

## Gradient Accumulation Test Design

**Workload**: 8-element block accumulation. Each trial = 8 concurrent i.i.d. gradient
streams, all sharing one block exponent per step. Log-uniform magnitudes in [1/R, 1],
random signs, 256 steps.

**Comparison**: sign-flip fraction per element, averaged across the 8 streams and over
1000 block-trials (= 8000 per-element observations; 10 batches × 100 block-trials × 8
elements). Error bars: mean ± std across 10 batches.

**Reference columns carried from `sim/gradient_range_v2.py`** (same SEED\_GRAD):
- NFE-13 bare scalar (single-element accumulator, no block exp)  
- E4M3+FP32acc (industry pattern, single-element)

**New reference condition**: E6M6+block (= NFE-13 with 8-element block mechanism applied).
If E6M6+block ≈ NFE-13 bare scalar: block sharing itself introduces no measurable
degradation, and any compact-format deficit is purely from per-element range reduction.

---

## Pre-registered Success Criteria

**K1** (gradient niche survives):  
> For a candidate format, the per-element sign-flip rate does not significantly exceed
> NFE-13 bare scalar at any R ∈ {10², 10⁴, 10⁶, 10⁸, 10¹⁰} at depth=256.
>
> Operationally: candidate mean\_flip ≤ NFE-13 mean\_flip + 2 × std\_pool at each R,
> where std\_pool = sqrt((std\_NFE)² + (std\_cand)²). This is a one-sided two-sample
> z-test at α ≈ 0.025.
>
> Threshold at R=10² (most discriminating): NFE-13 mean=0.0010, std=0.0030.
> K1 threshold = 0.0010 + 2 × sqrt(0.0030² + std\_cand²) ≈ 0.007 for typical std\_cand.
>
> K1 also requires: Clopper–Pearson 95% upper bound < 0.01 for all zero-rate cells.

**K2** (MLP accuracy within 1pp):  
> Block-quantised MLP accuracy ≥ 95.39% on the standard 360-image test set.
> (FP64 baseline 96.67%; NFE-13 pipeline (c) 96.39%; threshold = 96.39% − 1.00pp.)

**K3** (storage accounting stated):  
> Effective bits/element table above is included verbatim in the verdict doc.
> This criterion is not pass/fail; the table is the deliverable.

---

## Pre-registered Predictions and Mechanism Reasoning

**Risk (stated before data)**: In `sim/gradient_range_v2.py`, NFE-13's bare = norm
at all R and depth=256 because the single-element running sum (std ≈ 3–5) stays well
within NFE-13's per-element range (max ≈ 4.3×10⁹). The 6-bit exponent absorbed the
heavy-tailed spread without any re-grounding. Cutting to n=2 (max ≈ 4) means the
running sum frequently exceeds the per-element range and must be re-grounded via the
block exponent — and that re-grounding is shared across 8 elements, potentially forcing
small-magnitude streams to be encoded at a coarse scale dictated by the largest stream.

**Block contamination mechanism** (per-element, one of 8):  
When element j has running sum ≫ element i, the block exponent b is set by j:  
b = floor(log₂(|v_j|)) − (max\_e\_stored − 1 − bias\_n).  
Element i is encoded at scale 2^b. If |v_i| / 2^b falls below the per-element
subnormal floor (≈ 2^(1−bias) / 64), it is flushed to zero, losing its sign contribution.

For E2M6 (max ≈ 4, bias=2):  
- Per-element subnormal floor ≈ 2^(1−2) / 64 = 0.0078.  
- If stream j = 4.0 → b ≈ 1 (scale = 2). Stream i at 0.02 → 0.02/2 = 0.01 > subnormal floor. OK.  
- If stream j = 8.0 (after block reground the next step) → b ≈ 2. Stream i at 0.02 → 0.005 < subnormal floor. LOST.

For E3M6 (max ≈ 16, bias=4):  
- Per-element subnormal floor ≈ 2^(1−4) / 64 ≈ 0.002.  
- Block exp rarely exceeds 2 for typical running sums (max block ≈ 5×std ≈ 25 → b ≈ 1).  
- Stream i at 0.02 → 0.02/2 = 0.01 > 0.002. Representable. Less contamination.

**Pre-registered boundary prediction** (before seeing data):  
- **E5M6, E4M6**: PASS K1 (max >> typical running sum; block exp rarely fires)  
- **E3M6**: LIKELY PASS K1 at R=10² (max≈16 ≈ 3σ of running sum; marginal cases)  
- **E2M6**: LIKELY FAIL K1 at R=10² (max≈4 < 1σ; block exp fires constantly; contamination severe)  
- **K2 boundary**: likely same — E3M6 likely passes MLP (weights fit in range with occasional block shift); E2M6 may degrade  

If E2M6 passes K1: the block-contamination mechanism is less severe than predicted,
and the finding is that even 2-bit per-element exponents suffice with 8-element shared
block exponent.  
If E3M6 fails K1: the niche requires at least 4 per-element exponent bits, and the
minimum compact format is E4M6+block (11.75 effective bits).

---

## Fallback Deliverable

If K1 fails for all compact candidates, the finding is stated as:

> **The gradient niche requires n\_exp ≥ M bits of per-element exponent with 8-element
> block sharing, where M is the smallest n that passes K1.** The boundary curve (sign-flip
> rate vs n\_exp at R=10²) is the primary result, regardless of pass/fail.

This finding is a good one: it quantifies the minimum per-element exponent depth needed
to preserve the gradient niche under block scaling, which is directly relevant to any
compact-NFE hardware design.

---

*Pre-registration complete. Code and data collection to follow.*  
*Cross-reference: `sim/compact_nfe.py`, `docs/COMPACT_NFE_VERDICT.md`.*

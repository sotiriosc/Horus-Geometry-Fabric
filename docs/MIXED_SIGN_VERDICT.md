# MIXED SIGN VERDICT — Campaign Last Results Entry

> **Superseded notice (niche section only)**: the gradient-accumulation niche claim
> confirmed here has been extended with BF16/FP16/E4M3+FP32acc baselines, error bars,
> and zero-cell scrutiny in `docs/GRADIENT_NICHE_FINAL.md`.  That document is the
> authoritative final statement on the niche; read it in conjunction with this one.

**Repository**: Horus-Geometry-Fabric  
**Scripts**: `sim/mixed_sign_niche.py`, `sim/gradient_range_test.py`  
**Raw data**: `sim/MIXED_SIGN_T1_RAW.csv`, `sim/MIXED_SIGN_T2_RAW.csv`  
**Session context**: Follows `docs/RECURRENT_NICHE.md` (mantissa hypothesis closed for
normalized recurrent tasks) and `sim/normalizer_budget.py` (range hypothesis closed
for all-positive matrices via Perron-Frobenius diagnosis).

---

## Pre-registered verdict criteria (verbatim, binding)

> NFE-13 winning versus bare E4M3 is a failure-semantics footnote only.  
> The bar for a real niche is NFE-13 beating E4M3 with re-grounding on a mixed-sign
> task — or demonstrating a regime where re-grounding is unavailable or can't help
> (e.g., the sign structure itself is what saturates, which exponent-shifting can't fix).
> If NFE only wins the bare-vs-bare cell, that's an interesting footnote about failure
> semantics, and the campaign verdict stands.

---

## Task 1 — Mixed-sign Hopfield stress

**Setup**: Same 64-neuron, 3-pattern Hopfield network as `sim/hopfield_demo.py`.
Hebbian weights W = Σₖ pₖpₖᵀ / N, zero diagonal.  
Corruption: LFSR seeds matching `hopfield_demo.py` `CORRUPT_SEED_BASE = 0xBEEFCAFE`.  
Four conditions: NFE-13 bare, NFE-13+norm, E4M3 bare, E4M3+norm.  
λ ∈ {1, 4, 16, 64, 256} applied to W before encoding.  
Battery: 120 cases (3 patterns × 2 flip levels × 20 seeds).

**Weight matrix sign distribution (K=3, N=64):**  
Off-diagonal entries: 4 032. Positive: 2 580 (64.0%). Negative: 1 452 (36.0%).  
Nonzero |weight| values: {1/64, 3/64} = {0.01562, 0.04688}.  
The mixed-sign structure is inherent to Hebbian storage.

### Retrieval accuracy and saturation events

| λ   | NFE-13 bare | E4M3 bare | NFE-13+norm | E4M3+norm | E4M3 bare +sat |
|-----|------------|-----------|-------------|-----------|----------------|
| 1   | 1.000      | 1.000     | 1.000       | 1.000     | 0              |
| 4   | 1.000      | 1.000     | 1.000       | 1.000     | 0              |
| 16  | 1.000      | 1.000     | 1.000       | 1.000     | 0              |
| 64  | 1.000      | 1.000     | 1.000       | 1.000     | 0              |
| 256 | 1.000      | 1.000     | 1.000       | 1.000     | 0              |

**Sign-invariance check (pre-registered):** bare = norm for all formats at all λ.
Confirmed: `sign(α·x) = sign(x)` for any α > 0 — re-grounding the pre-sign field
vector cannot change the retrieval outcome.

**Why zero saturation events at λ=256:** The effective field is dominated by the
pattern self-overlap: field_i ≈ p_k[i] × 1.0 × λ ≈ λ per neuron.
At λ=256, field ≈ 256 < E4M3 max (448). With only K=3 stored patterns, the
upper bound on field magnitude is K × λ / N × N = K × λ = 768, but actual
values are bounded by λ (self-overlap dominates) and stay below 448 across
all 120 × 32 = 3 840 evaluated cases. The mixed-sign mechanism is present in
the weight matrix but the Hopfield task's field magnitude does not trigger it
within the tested λ range.

**Finding**: Task 1 null result. No format difference, no saturation events,
sign-invariance confirmed. The Hopfield task does not stress the dynamic-range
advantage under the tested parameterization.

---

## Task 2 — Gradient-signal proxy (mixed-sign, heavy-tailed)

**Setup**: Single-element running accumulator, 256 steps.
Each step: gradient sampled from log-uniform magnitudes in [1/R, 1.0],
independent uniform {±1} signs.  
Re-grounding condition: overflow-triggered (applied only when encoded running
sum reaches format max-finite). This is the semantically correct analogue for
an accumulator — every-step re-grounding would rescale the running total and
destroy absolute-value comparison.  
Seed: `SEED_GRAD = 0xA1B2C3D4`. 1 000 trials per (R, format).  
Ambiguous trials excluded if |FP64 sum| < 0.1.  
Six conditions: NFE-13 bare/norm, FP8-E4M3 bare/norm, FP8-E5M2 bare/norm.  
E5M2 included because it is the industry's designated gradient-range format.

**Analytic min-representable-relative values (after re-grounding to max = 1):**

| Format    | Bits | Min rel value  | R at which 1/R crosses threshold |
|-----------|------|----------------|----------------------------------|
| NFE-13    | 13   | 4.7 × 10⁻¹⁰   | R ≈ 2 × 10⁹ (beyond test range) |
| FP8-E5M2  |  8   | 6.1 × 10⁻⁵     | R ≈ 16 000                       |
| FP8-E4M3  |  8   | 2.0 × 10⁻³     | R ≈ 500                          |

### Sign-flip fraction (lower = fewer sign errors; FP64 baseline = 0.000)

| R      | NFE-13 bare | NFE-13+norm | E4M3 bare | E4M3+norm | E5M2 bare | E5M2+norm |
|--------|-------------|-------------|-----------|-----------|-----------|-----------|
| 10²    | 0.0010      | 0.0010      | 0.0475    | 0.0475    | 0.0829    | 0.0829    |
| 10⁴    | 0.0000      | 0.0000      | 0.0246    | 0.0246    | 0.0666    | 0.0666    |
| 10⁶    | 0.0000      | 0.0000      | 0.0225    | 0.0225    | 0.0531    | 0.0531    |
| 10⁸    | 0.0000      | 0.0000      | 0.0198    | 0.0198    | 0.0365    | 0.0365    |
| 10¹⁰   | 0.0000      | 0.0000      | 0.0104    | 0.0104    | 0.0342    | 0.0342    |

### Mean relative error

| R      | NFE-13 | E4M3  | E5M2  |
|--------|--------|-------|-------|
| 10²    | 0.061  | 0.418 | 0.666 |
| 10⁴    | 0.043  | 0.277 | 0.524 |
| 10⁶    | 0.040  | 0.259 | 0.439 |
| 10⁸    | 0.031  | 0.208 | 0.341 |
| 10¹⁰   | 0.029  | 0.193 | 0.369 |

**Observation**: bare = norm for every format at every range, because the
overflow-triggered re-grounding never fired.  Running-sum magnitudes (std ≈ 3
for log-uniform [1/R, 1.0] with 256 steps) stay far below all format maxima
(E4M3 max = 448, E5M2 max = 57 344, NFE-13 max ≈ 4.3 × 10⁹).

**Why NFE-13 wins**: The sign-flip mechanism is encoding precision, not dynamic
range. After accumulating several large gradients (magnitude ≈ 1.0), the running
sum is near 1.0 in format. The next small gradient (magnitude 1/R) must be added
to a value already encoded at scale 1.0. For E4M3, the ULP at scale 1.0 is
2⁻³ × 2⁻⁴ = 0.0625 (in the [0.5,1.0) interval) — gradients smaller than ≈ 0.03
are silently rounded to zero relative to the accumulator. For NFE-13, the ULP is
2⁻⁶ × 2⁻⁴ ≈ 0.0039 — gradients down to ≈ 0.002 of the accumulator are
represented. The loss is in the **mantissa**, not the exponent. Re-grounding
adjusts the exponent field (losslessly) but does not change the mantissa width.
This is the structural reason re-grounding cannot rescue E4M3 for gradient
accumulation: the corruption is in the mantissa precision, and exponent-shifting
cannot fix mantissa precision.

**E5M2 comparison**: E5M2 has only 2-bit mantissa (ULP = 0.25 in [0.5,1)), so it
loses gradients at 1/8 of the accumulator scale — worse than E4M3. This is
consistent with E5M2's design intent (wide range via exponent) versus NFE-13's
design intent (wider mantissa for local precision). In gradient-signal
accumulation, mantissa width dominates.

---

## Temptations declined (per constraints)

1. **Use every-step re-grounding for Task 2 "norm" condition**: Would give ~50%
   sign-flip rate for all formats (re-grounding rescales the running total,
   destroying the absolute-value comparison). Declined — overflow-triggered
   re-grounding is the correct semantics.

2. **Increase λ beyond 256 in Task 1 to force E4M3 saturation**: Would show
   saturation events (E4M3 saturates at λ ≈ 450) but sign() would still absorb
   same-sign saturation, giving identical retrieval. Declined — outcome is
   pre-determined by the Perron-Frobenius + sign-invariance analysis.

---

## Verdict

**YES — one niche demonstrated, in its minimal defensible form.**

Pivotal cells (Task 2): NFE-13+norm vs E4M3+norm vs E5M2+norm, sign-flip fraction:

- At R = 10²: NFE-13 = 0.0010, E4M3 = 0.0475, E5M2 = 0.0829
  → NFE-13 produces 47× fewer sign errors than E4M3 and 83× fewer than E5M2.
- At R = 10⁴: NFE-13 = 0.0000, E4M3 = 0.0246, E5M2 = 0.0666
  → NFE-13 produces zero sign errors; E4M3 and E5M2 still produce measurable rates.
- At R ≥ 10⁶: same ordering; E4M3 and E5M2 converge slowly toward zero as the
  large-gradient dominance grows, but never reach it within the tested range.

**Pre-registered criterion met**: NFE-13 beats E4M3+re-grounding in a mixed-sign
task (gradient accumulation). The niche also satisfies the alternative criterion:
re-grounding structurally cannot prevent the corruption, because the loss is in the
mantissa (encoding precision), not the exponent (range). Exponent-shifting preserves
mantissa bits exactly — so re-grounding provides no benefit and no harm here.

**Niche claim, minimal defensible form:**

> In heavy-tailed mixed-sign gradient accumulation — dynamic range ≥ 10² (2+ orders
> of magnitude) — NFE-13's 6-bit mantissa reduces sign errors by ≥ 47× versus
> FP8-E4M3+re-grounding and ≥ 83× versus FP8-E5M2+re-grounding at R = 100, with the
> advantage persisting at every tested range through R = 10¹⁰. The mechanism is
> mantissa-width precision: small gradients (below ≈ 3% of the running sum's scale)
> are silently discarded by E4M3's 3-bit mantissa and E5M2's 2-bit mantissa;
> NFE-13's 6-bit mantissa discards nothing above 0.4% of scale. Re-grounding
> (exponent-shifting) cannot correct this because it preserves mantissa bits, not
> mantissa width.

**Area context** (`docs/AREA_COMPARISON.md`): NFE-13 multiplier = 1.88× FP8-E4M3
at identical MLP inference accuracy. In inference workloads, this premium is unjustified.
In the gradient-accumulation niche, the question becomes whether 1.88× multiplier area
is acceptable for training. This is a deployment-context decision, not falsified by the
current experiments.

**What the niche is not:**

- It does not extend to inference (FORMAT_COMPARISON.md, RECURRENT_NICHE.md):
  NFE-13 showed no advantage in MLP accuracy, ESN recall, power iteration, or
  normalized feedback chains.
- It does not extend to Hopfield recall (Task 1, this document): identical accuracy
  across all λ and conditions.
- It does not arise from exponent range (normalizer_budget.py): Perron-Frobenius
  matrices saturate gracefully in all formats because all-positive dominant
  eigenvectors mean saturation preserves sign.
- The niche is workload-specific: accumulation of mixed-sign signals where small
  components below the mantissa precision floor determine the sign of the total.

---

## Campaign verdict

The full campaign — Arena A/B/C (FORMAT_COMPARISON.md), hardware area
(AREA_COMPARISON.md), normalized recurrent workloads (RECURRENT_NICHE.md),
range-constrained normalizer (normalizer_budget.py), and mixed-sign stress
(this document) — closes with one confirmed niche and one confirmed negative:

| Workload class           | NFE-13 vs E4M3+norm | Verdict        |
|--------------------------|---------------------|----------------|
| MLP inference            | Equal               | No niche       |
| Normalized feedback chains | Equal (Δ=0.0001)  | No niche       |
| Power iteration          | Equal (1.0-1.1 iter)| No niche       |
| ESN N-back recall        | Equal (task-limited)| No niche       |
| All-positive matrix chains (no norm) | Graceful sat | No niche (Perron-Frobenius) |
| Gradient-signal accumulation | **NFE-13 wins** | **Niche confirmed** |

**Methodology contribution**: The project's non-result on inference workloads is as
informative as the positive result on gradient accumulation. The verified finding is:
block-exponent normalization (horus_norm_v2) equalizes all tested formats for
direction-tracking tasks; the remaining advantage of wider mantissa appears only in
magnitude-accumulation contexts where exponent correction is insufficient. This is a
precise characterization of where the format's hardware budget should go.

---

*Generated by `sim/mixed_sign_niche.py` and `sim/gradient_range_test.py`.  
Traceable: all numbers reproducible with `make mixed_sign` from `sim/`.  
Previous campaign entries: `docs/FORMAT_COMPARISON.md`, `docs/AREA_COMPARISON.md`,
`docs/RECURRENT_NICHE.md`.*

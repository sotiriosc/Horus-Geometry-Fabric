# Horus-Geometry-Fabric — Validation Campaign Overview

**Date:** 2026-07-05  
**Status:** Complete  
**Audience:** engineers reading the repo for the first time

---

## Summary Table

| Claim | Measured result | Evidence |
|---|---|---|
| Baseline PATH_NFE feedback error in neutral regime | 23.95% at depth 256; stalls at attractor 1.25 vs Perron eigenvector 1.6436 | `docs/SSC_RTL_VALIDATION.md` P2 CONFIRMED |
| PATH_FAST feedback mode exists in `horus_nfe.v` | NOT CONFIRMED — 14-bit product is immediately truncated; no output port exposes it | `docs/SSC_RTL_VALIDATION.md` P1 |
| PF-W18 accumulator fixes deep-chain error | 0.18% neutral-regime error; +39.6% system area | `docs/ADR_001_PF18_ADOPTION.md` |
| PF-W18 meets ≥ 0.99 alignment on PI workload | FAILS at k ≥ 2; alignment 0.9892 < threshold; W=18 saturates for row sums > 2.0 | `docs/NORM_VS_PF18.md` Table 2 |
| Baseline + normalisation every k=8 meets PI threshold | 1.0000 alignment (RTL CONFIRMED); outperforms PF-W18 | `docs/NORM_VS_PF18.md` Cell 3, `docs/ADR_002_NORMALIZATION_ARCHITECTURE.md` |
| On-chip normalizer area | +2.84% system area (vs estimated +0.3–1.3%); 565 cells, 5,352.6 µm² | `docs/EXPNORM_RESULTS.md` |
| Normalizer cost vs PF-W18 | **14× cheaper** (+2.84% vs +39.6%) | `docs/EXPNORM_RESULTS.md` Task 4 |
| Hopfield recall, 120 pattern+corruption trials | 120/120 (100%); RTL and Python model agree 0/360 divergent iterations | `docs/HOPFIELD_DEMO.md` |
| MLP digit inference RTL accuracy | 96.39% (347/360) vs FP64 96.67% ceiling; predictions 360/360 bit-exact vs Python | `docs/MLP_INFERENCE_DEMO.md` |
| NFE-13 vs E4M3 on inference (format war) | E4M3 wins: identical 96.39% accuracy at 0.53× NFE-13 multiplier area | `docs/FORMAT_COMPARISON.md`, `docs/AREA_COMPARISON.md` |
| NFE-13 niche in gradient accumulation | BF16-class sign-error rate (0.0010) at 0.59× BF16 area; 3× fewer errors than E4M3+FP32acc at R=10²; ≥1.70× more area-efficient than FP16 | `docs/GRADIENT_NICHE_FINAL.md` |

---

## 1. What NFE Is

NFE v3 is a 13-bit floating-point format: 1 sign bit, 6-bit stored exponent (bias 32,
range [−32, +31]), 6-bit mantissa fraction.  A value encodes as
`(−1)^s × (1 + f/64) × 2^(E−32)`.  The representable range is roughly
[2.4×10⁻⁹, 4.3×10⁹]; the NORM band (E ∈ [16..47]) is where products land
without saturation for well-conditioned inputs.

The format is documented in `docs/HORUS_V3_FINAL_SPEC.md`.  The RTL module is
`rtl/horus_nfe.v`.  13 bits × 16 cores per `horus_top` = 208 bits of state —
the compact footprint is the design goal.

---

## 2. Second-Source Discipline: Why Two Agreeing Software Models Were Not Independent

The campaign began with a feedback-chain validation task: how well does the baseline
`horus_nfe` RTL sustain a matrix–vector recurrence `y ← A·y` over 256 iterations?

Two software models both predicted ≤ 0.38% error for a hypothetical PATH_FAST mode
that preserves the full 14-bit hidden-bit product through row accumulation before
re-encoding.  The C model (`nfe_matvec2.c`) and the Python second-source chain
(`sim/second_source_chain.py`) agreed on this number.  That agreement is not
confirmation.

Both models implemented the same software decision: accumulate the full integer
product P = `(64 + f_a) × (64 + f_b)` without truncation.  The RTL is the only
true second source.  Reading `horus_nfe.v` lines 502 and 530–532:

```
scale_reg = {1'b1, m_a} * {1'b1, m_b};          // 14-bit product
...
computed = {res_sign, exp_sum[EXP_W-1:0],
            scale_reg[13] ? scale_reg[12:7]       // 6-bit f_result
                          : scale_reg[11:6]};
```

`scale_reg` is immediately truncated to 6 bits; it is a local register with no
output port.  No `op_sel` value exposes it.  **PATH_FAST does not exist in the
hardware.**  (`docs/SSC_RTL_VALIDATION.md`, P1 NOT CONFIRMED.)

The actual RTL behavior — PATH_NFE, 6-bit quantization of every product — was also
predicted and confirmed: divergence past 1% at cycle 2, final error 23.95% at depth
256, DUT stalled at the NFE codeword for 1.25 while the FP64 golden converged to the
Perron eigenvector 1.6436.  (`docs/SSC_RTL_VALIDATION.md`, P2 CONFIRMED.)

---

## 3. The PF Campaign, Its Cost, and Its Falsification Within the Same Day

P1 NOT CONFIRMED converted the PATH_FAST question from a software modeling question
into a hardware design question.  The first response was to build a fused-MAC
accumulator variant: `rtl/horus_nfe_pf.v` (W=32), then `rtl/horus_nfe_pf18.v`
(W=18).

**PF-W32:** 0.18% neutral-regime error at +58.9% core area / +53.4% system area.
(`docs/PF_SYNTHESIS_COMPARISON.md`.)

**PF-W18:** Python model at W=18 predicts 0.35% error; RTL achieves 0.18%.
Synthesis: +45.9% core area / **+39.6% system area** (measured, Sky130 HD TT 025C 1v80).
ADR-001 adopted PF-W18.  (`docs/ADR_001_PF18_ADOPTION.md`.)

The same day, a normalization-interval sweep (`sim/norm_interval_sweep.py`) asked a
simpler question: if the harness renormalises the state vector every k steps using
block-exponent rescaling, does baseline PATH_NFE match PF-W18?

For the SSC workload: yes — baseline holds ≤ 0.55% mean relative error for all
k ≤ 128, within 0.22 pp of PF-W18's 0.33%.

For the power-iteration (PI) workload, the result was harder to predict.  PF-W18
saturates for row sums > ~2.0 (W=18 ceiling); the peak row sum in the PI test is
2.12.  At k=2..8, **PF-W18 fails the ≥ 0.99 alignment threshold** (alignment
0.9892); baseline achieves **1.0000**.  (`docs/NORM_VS_PF18.md`, Table 2,
RTL Cell 3 CONFIRMED.)

Three RTL-confirmed cells:

| Cell | Workload | k | Result |
|---|---|---|---|
| 1 | SSC | 128 | 0.5524% mre (**CONFIRMED**) |
| 2 | SSC | ∞ | 24.6959% mre (**CONFIRMED** — baseline without normalization) |
| 3 | PI | 8 | 0.999994 alignment (**CONFIRMED**) |

ADR-001 was superseded by ADR-002 on the same day it was accepted.  This is the
process working as designed, not a misstep: a prediction was made, a falsifying
measurement was taken, and the decision was revised.  The full evidence trail
(both ADRs, synthesis logs, sweep CSVs) is preserved exactly as found.

---

## 4. The Architecture That Won

ADR-002 (`docs/ADR_002_NORMALIZATION_ARCHITECTURE.md`): **baseline `horus_nfe`
(PATH_NFE, no datapath modification) plus periodic normalisation every ≤ k steps.**

The open item in ADR-002 was the cost of an on-chip normalizer.  Building it:

`rtl/horus_norm.v` — 8-element block-exponent normalizer.  Combinational max-exponent
tree (3-level, 7 comparators), 7-bit signed offset computation, 8 per-element exponent
adders with UF/OVF clamping, 1-cycle registered output.

**Synthesis (Sky130 HD TT 025C 1v80):** 565 cells, 105 DFFs, 5,352.6 µm².
System-level delta: **+2.84%** (vs estimated +0.3–1.3%; discrepancy traced to
unaccounted 104-bit output register bank, 39% of module area).

The estimate was wrong by approximately 2–9× on its upper bound.  The conclusion
is unchanged: **+2.84% vs PF-W18 +39.6% — 14× cheaper for equal or better accuracy
on tested workloads.**  (`docs/EXPNORM_RESULTS.md`.)

Unit tests: 11/11 PASS.  Random-vector regression: 0 mismatches in 1000 vectors vs
Python golden.  (`docs/EXPNORM_RESULTS.md`, Task 3.)

`rtl/horus_norm_v2.v` extends v1 with an `e_max_out` output and external-offset mode,
enabling composition across N > 8 elements.  Mode-0 regression: 1000/1000 against
EXPNORM_GOLDEN.dat.  Two-block composition: 200/200 against EXPNORM_V2_GOLDEN.dat.
This module is required by the MLP application (see §6).

---

## 5. Two Applications

### Hopfield Associative Memory (`docs/HOPFIELD_DEMO.md`)

Network: 64 neurons, Hebbian weights, 3 stored binary letter glyphs (H, T, X).
120 corruption recall trials (20 seeds × 2 corruption levels × 3 patterns).
`horus_nfe` (PATH_NFE, no modification) executes every 8×8 block matvec; the harness
applies sign(·) after each full matvec step.

**Recall: 120/120 (100%).  Python model and RTL agree 0/360 divergent iterations.**

The network is loaded at K/N = 3/64 ≈ 0.047, well below the 0.138 capacity limit,
so 100% recall is the correct outcome — reported plainly rather than as a headline.
Seven of eight random-state trials converge to spurious attractors, as expected for
inputs equidistant from all stored patterns; these are reported without softening.

The sign re-grounding at each step prevents quantisation error from compounding —
the same mechanism identified in the normalization study.

### MLP Digit Inference (`docs/MLP_INFERENCE_DEMO.md`)

Network: 64→16→10 MLP, ReLU hidden layer, argmax output.  Dataset: sklearn
`load_digits` (1797 images, 8×8 grayscale, 10 classes), 80/20 split, seed 42.

Weight quantization is verified lossless: pipeline (b) (NFE weights, FP64 activations)
= 96.67% — identical to FP64 reference.

Between-layer re-grounding uses `horus_norm_v2` in two-pass shared-offset composition.
The demo includes a documented negative result: the first attempt used per-block
normalization (independent offsets on two 8-element halves of the 16-neuron hidden
layer), which destroyed inter-block relative magnitudes and degraded accuracy to
84.72% — triggering the 5 pp gate.  `horus_norm_v2`'s external-offset mode resolves
this by applying a single shared offset across both blocks.

**RTL accuracy: 96.39% (347/360).  RTL vs Python predictions: 360/360 exact.
One activation divergence: 1-bit mantissa LSB in one hidden neuron on one image,
FP64 accumulation order; zero impact on classification.**

Full four-way accuracy table:

| Pipeline | Accuracy | Δ vs FP64 |
|---|---|---|
| (a) FP64 reference | 96.67% (348/360) | — |
| (b) NFE weights + FP64 activations | 96.67% (348/360) | 0.00 pp |
| (c) Full NFE + shared-offset expnorm | **96.39% (347/360)** | −0.28 pp |
| (d) Full NFE, no expnorm | 96.67% (348/360) | 0.00 pp |

The gate is measured at −0.28 pp against a 5 pp threshold.

---

## 6. Method

**Python model first.** Every claim is first a Python simulation that produces a
falsifiable prediction — a specific number, with stated tolerance and metric.  The
RTL testbench confirms or denies that prediction.  When the prediction is not
confirmed, the gap is explained (`docs/SSC_RTL_VALIDATION.md` §Implication) or
the discrepancy is diagnosed and traced (`docs/HOPFIELD_DEMO.md` §Agreement).

**Gates stop broken pipelines.** The MLP inference script exits 1 if pipeline (c)
accuracy drops more than 5 pp below FP64.  The first attempt triggered the gate
(−11.94 pp).  RTL work on that version was not started.  The root cause (per-block
normalization scope) was diagnosed in Python before returning to RTL.

**Negative results are documented.** The PATH_FAST gap, the PF-W18 PI saturation
failure, the initial per-block expnorm failure, the MLP gate trigger, the spurious
Hopfield attractors — each is in a doc with the numbers stated plainly.  The
normalization-sweep result that reversed ADR-001 is preserved alongside ADR-001;
both docs are in the repo.

**Timing is not measured.** OpenSTA is not available in this environment.  Area
numbers are from Yosys synthesis under Sky130 HD TT 025C 1v80.  No frequency claim
appears anywhere in this repo.

---

## 7. Format Comparison and Gradient-Accumulation Niche

After the RTL applications were verified, the campaign ran a final phase to answer the
hardware question directly: does NFE-13 have a defensible position against established
floating-point formats in any workload?

### Format zoo (`sim/format_zoo.py`, `docs/FORMAT_COMPARISON.md`)

Five formats tested: NFE-13 (13b), FP8-E4M3 (8b), FP8-E5M2 (8b), BF16 (16b), INT8 (8b).
Three arenas: 8×8 matvec accuracy (A), 256-cycle feedback chains (B), MLP digit
inference (C).  Result: NFE-13 wins no arena outright.  On Arena C (MLP), NFE-13 and
E4M3 both reach 96.39% — identical at 1.88× the E4M3 multiplier area.  That is a
**negative result for NFE-13 on inference**, stated plainly.

### Hardware area (`docs/AREA_COMPARISON.md`)

Three multipliers synthesised (Yosys, Sky130 HD PDK, combinational-only):
FP8-E4M3 = 857.1 µm²; NFE-13 = 1 611.5 µm²; BF16 = 2 740.1 µm².
NFE-13 costs 1.88× E4M3 for identical MLP accuracy (negative) and 0.59× BF16 for a
0.28 pp accuracy gap (a potential but narrow positive).

### Recurrent niche falsification (`sim/recurrent_niche.py`, `docs/RECURRENT_NICHE.md`)

Normalized-chain rematch, power iteration, ESN recall — all with lossless block-exponent
re-grounding.  Result: **NO niche**. Lossless exponent-shift re-grounding makes all formats
equivalent on these tasks; the mantissa-precision hypothesis was dead under normalization.

### Range/normalizer budget (`sim/normalizer_budget.py`)

Expansive chains with infrequent or absent normalization. Hypothesis: NFE-13's wider range
would help when normalizer is unavailable.  Result: null — all-positive matrices saturate
gracefully for all formats because the Perron-Frobenius theorem guarantees the dominant
eigenvector lies in the positive orthant, so the frozen (saturated) direction is nearly
correct.  Dynamic range matters only where saturation can destroy direction — which requires
mixed signs.

### Gradient-accumulation niche (`sim/gradient_range_v2.py`, `docs/GRADIENT_NICHE_FINAL.md`)

Final experiment: mixed-sign heavy-tailed gradient accumulation (log-uniform magnitudes,
random signs, 256 steps). Eleven format conditions including BF16, FP16, and the
industry FP32-accumulator pattern (E4M3 inputs + float32 running sum).

**Selected: Claim (a).**  
At all tested dynamic ranges (R = 10² to 10¹⁰) and depth = 256:
- NFE-13 and BF16 produce **statistically identical** sign-flip rates (0.0010 at R=10², 0
  at R≥10⁴; difference within batch standard deviation).
- NFE-13 achieves this at **0.59× BF16 multiplier area** — **1.70× more area-efficient**
  than BF16 at the same quality level.
- NFE-13 outperforms E4M3+FP32acc by **3× at R=10²** (0.0010 vs 0.0030 sign errors).
  The FP32 accumulator does not close this gap because the loss happens at *encoding*,
  before the accumulator sees the value — a better accumulator cannot recover a gradient
  rounded away on arrival.
- FP16 (10-bit mantissa) produces zero sign errors everywhere. Audit confirmed this is
  genuine: ~40% of gradients flush below FP16's subnormal floor but their total signed
  contribution is at most 2.1×10⁻⁶ per 4096-step trial — physically incapable of
  flipping any sign the test calls valid. NFE-13 is ≥ 1.70× more area-efficient than FP16
  (BF16 as lower bound; analytical estimate puts the central ratio at ≈ 3.8×).
- At depth=4096 and R=10¹², BF16 (0.24%) outperforms NFE-13 (0.75%); FP16 remains zero.
  This limitation is in the doc.

### MX/block-floating-point positioning

NFE-13 is a *per-element* floating-point format with individual exponents. MX (microscaling)
formats and block-floating-point share one exponent across a group of values, reducing
per-element overhead but requiring all elements in a group to share the same scale.
NFE-13's per-element exponent is what gives it dynamic range for individual gradient
contributions; in the gradient-accumulation workload, individual contributions differ by
many orders of magnitude and cannot share a scale without losing the small ones.
The niche sits exactly where grouped exponents cannot fully substitute: per-element
contribution retention in heavy-tailed mixed-sign accumulation.

---

## Final verdict

> **For single-pass inference, FP8-E4M3 with block-exponent normalization is the correct
> choice: it matches NFE-13 accuracy at 0.53× the multiplier area, and no tested workload
> justifies NFE-13's inference premium (`docs/FORMAT_COMPARISON.md`, `docs/AREA_COMPARISON.md`).**
>
> **For heavy-tailed mixed-sign gradient accumulation at standard depth (≤ 256 steps),
> NFE-13 delivers BF16-class sign-error rates at 0.59× BF16 multiplier area and beats
> the industry FP32-accumulator pattern (E4M3+FP32acc) by 3× at R=10², because the
> per-gradient encoding loss precedes accumulation and no accumulator can recover it
> (`sim/gradient_range_v2.py`, `docs/GRADIENT_NICHE_FINAL.md`).**

---

## Updated Cross-Reference Map

| Topic | Primary doc |
|---|---|
| NFE format | `docs/HORUS_V3_FINAL_SPEC.md` |
| RTL baseline | `rtl/horus_nfe.v` |
| Feedback-chain RTL validation | `docs/SSC_RTL_VALIDATION.md` |
| PF-W32 synthesis | `docs/PF_SYNTHESIS_COMPARISON.md` |
| PF-W18 adoption + costs | `docs/ADR_001_PF18_ADOPTION.md` |
| Normalization sweep + PF-W18 falsification | `docs/NORM_VS_PF18.md` |
| Normalization architecture decision | `docs/ADR_002_NORMALIZATION_ARCHITECTURE.md` |
| On-chip normalizer (build + synthesis) | `docs/EXPNORM_RESULTS.md` |
| Hopfield associative recall | `docs/HOPFIELD_DEMO.md` |
| MLP digit inference | `docs/MLP_INFERENCE_DEMO.md` |
| Format zoo comparison (5 formats, 3 arenas) | `docs/FORMAT_COMPARISON.md` |
| Multiplier area synthesis | `docs/AREA_COMPARISON.md` |
| Recurrent niche (closed — no niche found) | `docs/RECURRENT_NICHE.md` |
| Mixed-sign workloads (Hopfield + gradient) | `docs/MIXED_SIGN_VERDICT.md` |
| Gradient niche final verdict | `docs/GRADIENT_NICHE_FINAL.md` |
| FPGA deployment guide | `docs/FPGA_GUIDE.md` |
| License | `docs/NOTICE.md` |

---

*Horus-Geometry-Fabric · CAMPAIGN_OVERVIEW · 2026-07-05*

# BLOCKFP_HYPOTHESIS.md — The Paradigm Question, Pre-Registered

**Repository**: Horus-Geometry-Fabric  
**Campaign**: Block floating point — the E0 endpoint of the compact-NFE sweep  
**Extends**: `docs/COMPACT_NFE_VERDICT.md`, `docs/GRADIENT_NICHE_FINAL.md`  
**Date pre-registered**: 2026-07-05  
**Status**: Pre-registered — criteria binding before any arena code runs.

---

## The Question

`docs/COMPACT_NFE_VERDICT.md` established that the gradient niche survives
shrinking the per-element exponent from 6 bits down to 2 bits when paired
with a shared 6-bit block exponent per 8 elements, and concluded: *"the
encoding-loss mechanism … is carried entirely by the 6-bit mantissa, not
by the 6-bit per-element exponent."* The sweep stopped at n_exp = 2.

The paradigm question is the endpoint that sweep never tested: **is the
gradient niche's true home mantissa-only elements with a shared block
exponent — classic block floating point — rather than any per-element
float at all?** If E0 formats match E3M6+block, the per-element exponent
was residual and the float paradigm is not load-bearing for this niche.
If E0 dies, the mechanism that kills it identifies exactly what the
per-element exponent buys.

---

## Candidates

| Format | Bits/element | Layout | Eff bits (+6÷8 block) | Rationale |
|--------|-------------|--------|----------------------|-----------|
| **E0M6** | 7 | 1 sign + 6 mantissa | **7.75** | Keeps the proven 6-bit mantissa; cheapest possible carrier of the mechanism claim |
| **E0M9** | 10 | 1 sign + 9 mantissa | **10.75** | Equal-storage reallocation vs E3M6 (1+3+6 = 10 bits): spends E3M6's 3 exponent bits on 3 more mantissa bits |

**Element semantics (block floating point):** within a block of 8, one
shared signed block exponent `b`; element value = (−1)^s × q × 2^b with
integer q ∈ [0, 2^M − 1]. No hidden bit (no per-element exponent to anchor
one). Block encoding chooses `b = floor(log2(max|v|)) − (M − 1)` so the
max-magnitude element occupies the full mantissa width, then rounds every
element to nearest-even at that shared scale.

**Reference conditions (carried columns, same seeds):** E3M6+block
(re-run with the identical `SEED_BLOCK` derivation from
`sim/compact_nfe.py`, reproducing the `COMPACT_NFE_RESULTS.csv` column)
and E4M3+FP32acc scalar (the industry pattern, re-run with the identical
`SEED_GRAD` derivation from `sim/gradient_range_v2.py`). The E0 candidates
consume the **same gradient streams as the E3M6+block column** (same seed
per R), making the comparison paired.

---

## Pre-Registered Risks

These two risks are stated before any measurement, as required:

### Risk 1 — Intra-block dynamic-range flush under a max-set block scale

The block scale is set by the max-magnitude element. An element whose
magnitude is more than 2^M below the block max quantizes to zero; an
element within 2^k of the max retains only M − k mantissa bits. A
per-element float re-normalizes each element to its own exponent, so its
relative precision is constant across ~2^(2^n_exp) of magnitude; block FP's
precision is **absolute**, anchored to the block max.

In the gradient arena the accumulators' running sums within a block spread
over roughly two orders of magnitude (final |sums| ≈ 0.1–10 with the
AMBIG_ABS = 0.1 validity floor); 100× ≈ 2^6.6 **exceeds E0M6's entire
mantissa range (2^6)**. The pre-registered prediction is therefore:

- **E0M6 fails K1** at R = 10² (and likely all R), killed by intra-block
  flush of small-magnitude accumulators, and K4's instrumentation will show
  a large per-block fraction of elements losing > 50% of mantissa bits.
- **E0M9 is genuinely uncertain**: 2^9 = 512 of intra-block range covers
  the expected spread with ~2 bits to spare. If the niche is truly
  mantissa-carried, E0M9 should pass K1 at equal storage to E3M6.

The prediction is falsifiable in both directions and the campaign is
losable end to end: if E0M6 survives, the flush mechanism was overrated;
if E0M9 dies too, the per-element exponent is load-bearing and the float
paradigm wins outright.

### Risk 2 — Quadratic multiplier growth for wider mantissas

A mantissa multiplier's array grows quadratically with mantissa width.
E0M9's 3 extra mantissa bits are not free silicon: a 10×10 signed
multiplier against E3M6's effective 7×7 (hidden + 6) array is a
(10/7)² ≈ 2.04× array-growth risk. Any E0M9 quality win must be priced
against this. K3 makes the pricing mandatory: both mantissa multipliers
are synthesized under the identical flow before any verdict language is
written.

---

## Pre-Registered Kill Criteria

### K1 — Gradient niche (binding)

> Sign-flip rate within error bars of E3M6+block across R ∈ {10², 10⁴,
> 10⁶, 10⁸, 10¹⁰} at depth 256: candidate mean ≤ E3M6+block mean +
> 2×√(std_E3M6² + std_cand²) at every R (one-sided z-test, α ≈ 0.025,
> same construction as `docs/COMPACT_NFE_HYPOTHESIS.md`). Zero cells are
> never reported bare: every zero cell carries a Clopper–Pearson 95% upper
> bound from the main sweep (N ≈ 8000 per-element observations), and any
> candidate that passes K1 at the boundary is escalated with targeted
> trials at R = 10¹⁰/10¹², depth 256/1024 (200 block trials each), exactly
> the two-tier protocol of `sim/compact_nfe.py`.

### K2 — MLP inference (binding)

> Weight-only block-quantized MLP accuracy within 1pp of 96.39%:
> **accuracy ≥ 95.39%** on the 360-image test set (same `MLP_FP64.npz`,
> same 64→16→10 network, same weight-only quantization scope as Arena C
> of `sim/compact_nfe.py`).

### K3 — Iso-silicon accounting (binding, priced not assumed)

> Synthesize the 7×7 signed mantissa multiplier (E0M6: sign + 6 mantissa
> as 7-bit signed operand) and the 10×10 signed mantissa multiplier
> (E0M9) under the identical Sky130 HD TT/025C/1v80 Yosys flow used for
> every other area number in this repo. Report both areas alongside
> `horus_e3m6_core` (1,675.357 µm², the E3M6 full core) so any E0M9
> quality win is priced against its quadratic-growth cost. No energy
> claim; area proxies only.

### K4 — Flush mechanism instrumented, not assumed (binding)

> During every block encoding in the gradient sweep, instrument the
> intra-block alignment loss: report, per R, the mean per-block fraction
> of nonzero elements that lose more than 50% of their mantissa bits to
> scale alignment (element magnitude more than 2^⌈M/2⌉ below the block
> max: > 2³ for E0M6, > 2⁵ for E0M9), and separately the fraction flushed
> fully to zero. These numbers appear in the verdict whether or not K1
> passes — if E0 dies, the flush instrumentation is the mechanism finding
> that closes the paradigm question.

---

## Falsification Protocol

- If **both candidates fail K1**: the per-element exponent is load-bearing.
  The verdict states how many exponent bits the niche requires, citing the
  E2 marginal result from `docs/COMPACT_NFE_VERDICT.md` (E2M6 passed by
  0.0018 margin at the standard envelope and failed escalated at CP95 UB
  0.014): the answer is n_exp ≥ 2 marginal, n_exp ≥ 3 conservative.
- If **E0M9 passes and E0M6 fails**: the mechanism is mantissa-width ×
  intra-block range, and the paradigm question splits — block FP works iff
  the mantissa is wide enough to absorb the block's dynamic range. The
  K3 pricing then decides whether E0M9 is worth its multiplier.
- If **both pass**: the per-element exponent was residual; block FP is the
  niche's true home, and E0M6 at 7.75 effective bits is the new floor.
- Codecs are unit-tested against hand tables before any arena runs
  (constraint: Python gates arenas). Every number is traceable to
  `sim/blockfp_test.py` and `sim/BLOCKFP_RESULTS.csv`.

---

*Horus-Geometry-Fabric · BLOCKFP_HYPOTHESIS · 2026-07-05*

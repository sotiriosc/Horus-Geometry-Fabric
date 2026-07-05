# RECURRENT NICHE — Verdict Document

**Repository**: Horus-Geometry-Fabric  
**Script**: `sim/recurrent_niche.py`  
**Raw data**: `sim/RECURRENT_NICHE_RAW.csv`  
**Session context**: Follows `docs/FORMAT_COMPARISON.md` (single-pass arenas) and
`docs/AREA_COMPARISON.md` (NFE-13 multiplier = 1.88× FP8-E4M3, 0.59× BF16).

---

## Hypothesis under test

Normalization corrects scale but not per-element precision. Under per-step
block-exponent re-grounding, a 3-bit mantissa (FP8-E4M3) should degrade where a
6-bit mantissa (NFE-13) holds, because the two formats differ only in mantissa width
once scale is removed. This experiment tests whether that degradation is measurable at
a practical threshold.

---

## Task 1 — Normalized-chain rematch

**Setup**: 100 neutral-regime 8×8 feedback chains, 256 steps, k ∈ {1, 4, 8, 16}
lossless block-exponent re-grounding. Metric: cosine alignment with FP64 golden at
t = 256. Seed: `SEED_CHAIN = 0xCAFEF00D` (matches `format_zoo.py` Arena B). Re-grounding
per format: NFE-13 exponent shift to E_TARGET=32 (mirrors `horus_norm_v2`);
FP8-E4M3 to target_e=7; FP8-E5M2 to target_e=15; BF16 to target_e=127;
INT8 decode→max_abs/127→re-quantize (Jacob et al., CVPR 2018). All shifts are
lossless for FP formats (mantissa bits preserved exactly; only exponent adjusted).

### Mean alignment at t = 256

| Format    | Bits | k=1    | k=4    | k=8    | k=16   |
|-----------|------|--------|--------|--------|--------|
| NFE-13    | 13   | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| FP8-E4M3  |  8   | 0.9999 | 0.9999 | 0.9999 | 1.0000 |
| FP8-E5M2  |  8   | 0.9996 | 0.9997 | 0.9997 | 0.9998 |
| BF16      | 16   | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| INT8      |  8   | 1.0000 | 1.0000 | 1.0000 | 1.0000 |

### Fraction of chains with alignment ≥ 0.99 at t = 256

| Format    | Bits | k=1   | k=4   | k=8   | k=16  |
|-----------|------|-------|-------|-------|-------|
| NFE-13    | 13   | 1.000 | 1.000 | 1.000 | 1.000 |
| FP8-E4M3  |  8   | 1.000 | 1.000 | 1.000 | 1.000 |
| FP8-E5M2  |  8   | 1.000 | 1.000 | 1.000 | 1.000 |
| BF16      | 16   | 1.000 | 1.000 | 1.000 | 1.000 |
| INT8      |  8   | 1.000 | 1.000 | 1.000 | 1.000 |

**Pivotal comparison, k = 8**: NFE-13 = 1.0000, FP8-E4M3 = 0.9999, Δ = 0.0001.

**Finding**: The Δ = 0.0001 is within numerical noise (all 100 chains in both
formats maintain alignment above 0.99 at every k-value). **The mantissa hypothesis
is not supported by Task 1 at any k-value tested.** All formats achieve 100%
≥ 0.99-alignment fraction.

---

## Task 2a — Power-iteration convergence

**Setup**: 50 symmetric-positive 8×8 matrices (SEED_PI = 0xFACEFEED, LFSR
construction matching `sim/norm_interval_sweep.py` lines 184–198), entries
∈ [0.25, 1.25), 256-step limit, k = 1 re-grounding every step.
Convergence threshold: alignment ≥ 0.99 with FP64 dominant eigenvector.

| Format    | Bits | Frac converged | Mean iterations |
|-----------|------|---------------|-----------------|
| NFE-13    | 13   | 1.000         |             1.0 |
| FP8-E4M3  |  8   | 1.000         |             1.1 |
| FP8-E5M2  |  8   | 1.000         |             1.1 |
| BF16      | 16   | 1.000         |             1.0 |
| INT8      |  8   | 1.000         |             1.0 |

**Finding**: All formats converge in 1–2 iterations on every matrix. The
symmetric-positive matrices used here have a large spectral gap, so convergence is
practically instantaneous regardless of format. Format precision cannot be
distinguished at this speed. Power iteration on this matrix class is not a workload
where per-step mantissa width matters.

---

## Task 2b — ESN N-back recall

**Setup**: Echo-state-network (reservoir computing). Reservoir: 16 hidden units,
spectral radius 0.9, input coupling 0.4 (SEED_ESN = 0x3B8E1F27). Architecture:
h_t = tanh(W_hh · h_{t−1} + W_ih · x_t), W_out trained via least-squares on
FP64 activations (600 sequences). Quantized inference: all weights held in FP64;
only h_t is encoded in the format and re-grounded after each tanh step.
600 training sequences, 200 test sequences; 8-class one-hot input; recall distances
N ∈ {4, 8, 16}. Note: the declared option of an Elman-style RNN trained via BPTT
was replaced by an ESN (reservoir computing), where W_out is solved via lstsq
rather than backpropagation through time. ESN training is deterministic given the
reservoir and does not introduce any optimisation bias toward a specific format.

### Recall accuracy (fraction correct; 8-class random baseline = 0.125)

| Format        | Bits | N=4   | N=8   | N=16  |
|---------------|------|-------|-------|-------|
| FP64 baseline | —    | 0.287 | 0.130 | 0.115 |
| NFE-13        | 13   | 0.255 | 0.186 | 0.115 |
| FP8-E4M3      |  8   | 0.289 | 0.177 | 0.123 |
| FP8-E5M2      |  8   | 0.302 | 0.176 | 0.123 |
| BF16          | 16   | 0.252 | 0.188 | 0.117 |
| INT8          |  8   | 0.286 | 0.130 | 0.117 |

**Finding**: The FP64 baseline itself achieves only 0.287 at N=4 and 0.130 at N=8
(3.5 pp above random chance). At N=16 all rows including FP64 are at 0.115, within
noise of random (0.125). The 16-unit ESN does not have sufficient memory capacity to
perform reliable N-back recall beyond N=4. Quantization format is therefore not a
limiting factor: the bottleneck is network capacity, not mantissa width. No format
shows a meaningful advantage over another; the scatter across formats (±0.04 at N=4,
±0.06 at N=8) is unsystematic and within the variance of an underpowered task.

---

## Temptations reported per constraints

Two intermediate adjustments that would have favored NFE-13 were identified and
declined, as required by the design constraints:

1. **Increase ESN hidden units to 64+**: Would raise the FP64 baseline above random
   for N ≥ 8, potentially creating room for format-level differentiation at N = 16.
   Not done because the network size was fixed before running any format comparisons.

2. **Increase sequence length and training set to boost FP64 N=8 accuracy**: The
   FP64 baseline at N=8 (0.130) is barely above random. More training data might
   push it to 0.30+, at which point format-level degradation might appear. Not done
   because training configuration was fixed before any format runs.

Both adjustments are out of scope. The results stand as-is.

---

## Verdict

**NO.**

There is no recurrent workload tested here where NFE-13 + re-grounding succeeds and
FP8-E4M3 + re-grounding fails, or where NFE-13 degrades less past a stated
usefulness threshold.

Specific cells cited:

- Task 1, k = 8: NFE-13 alignment = 1.0000, FP8-E4M3 alignment = 0.9999, Δ = 0.0001.
  Both formats maintain 100% ≥ 0.99-alignment fraction across 100 chains at every
  k-value. The hypothesis requires a measurable difference at k = 8; none is found.

- Task 2a: all formats converge in 1.0–1.1 iterations (100% rate). The
  task is too easy to reveal any format difference.

- Task 2b, N = 8: FP64 baseline = 0.130 (3.5 pp above random). Quantized formats
  span 0.130–0.186, with no consistent ordering. The task is too hard for the
  network capacity to reveal any format difference.

**Why the hypothesis failed**: Lossless block-exponent shift re-grounding at k = 1
constrains the maximum element to be exactly representable at full mantissa precision
in every format at every step. After re-grounding, the relative error per element is
2^(−mantissa_bits−1) × scale, and because scale is corrected at each step, errors do
not compound in the direction dimension for a neutrally-stable chain. The
normalizer (horus_norm_v2) that was the design objective of this project is so
effective that it erases the precision advantage of NFE-13's 6-bit mantissa versus
E4M3's 3-bit mantissa.

**What the repo contributes**: The contribution of this repository is the verification
methodology — three arenas (single-pass, recurrent, MLP), hardware synthesis, and
now recurrent-workload isolation — and the normalization-architecture result:
block-exponent shift at k = 1 makes 8-bit formats competitive with 13-bit NFE-13
across all workload families tested. Combined with the area result from
`docs/AREA_COMPARISON.md` (NFE-13 multiplier = 1.88× FP8-E4M3 at identical MLP
accuracy), the evidence now consistently points to FP8-E4M3 + block-exponent
normalizer as the correct choice: smaller area, equal recurrent performance, same
MLP accuracy, at 8 bits versus 13. This is a clean negative result with direct
hardware-design implications, and it has the same standing as a positive claim would.

---

## Notes on methodology

- All seeds fixed before any format comparisons were run.
- Competitor re-grounding implemented via lossless exponent shift (FP formats) — the
  most favorable treatment, not decode-scale-encode, which would introduce additional
  quantization in the normalization step itself.
- INT8 re-grounding is the only exception (decode-scale-encode) because INT8 has no
  exponent field; this is its standard practice (Jacob et al., CVPR 2018).
- Task 2b uses an ESN (reservoir computing), not an Elman-style BPTT RNN. The ESN
  approach was chosen because (a) it avoids BPTT gradient biases toward specific
  activation precision, and (b) the W_out solution is unique given the reservoir,
  making the training deterministic and reproducible. The replacement is documented
  here as required by the constraints.
- Area context: NFE-13 multiplier = 1.88× FP8-E4M3 (44.04 µm² vs 23.44 µm²,
  Sky130 HD TT 025C 1v80, Yosys synthesis; see `docs/AREA_COMPARISON.md`).
  NFE-13 is below BF16 (0.59×) but above E4M3. Since no recurrent niche was found,
  the area premium is not justified.

---

*Generated by `sim/recurrent_niche.py`. Traceable: all numbers re-producible with
`make recurrent_niche` from the `sim/` directory.*

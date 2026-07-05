# Area Comparison: NFE-13 vs FP8-E4M3 vs BF16 Multipliers

**Date:** 2026-07-05  
**Status:** Complete  
**Library:** Sky130 HD TT 025C 1v80  
**Tool:** Yosys (`/usr/bin/yosys`)  
**Synthesis scripts:** `sim/synth_nfe13_mul.ys`, `sim/synth_fp8_e4m3_mul.ys`, `sim/synth_bf16_mul.ys`  
**RTL sources:** `rtl/nfe13_mul.v`, `rtl/fp8_e4m3_mul.v`, `rtl/bf16_mul.v`

---

## What Was Synthesized

Three **purely combinational multiplier modules**, one per format.  No pipeline
registers, no accumulator, no control logic — just the multiply operation that
is unique to each format.  This isolates the format-specific hardware cost.

| Module | Inputs | Output | Operation |
|--------|--------|--------|-----------|
| `nfe13_mul` | two 13-bit NFE-13 | 13-bit NFE-13 | A × B with 6-bit mantissa truncation |
| `fp8_e4m3_mul` | two 8-bit E4M3FN | 8-bit E4M3FN | A × B, round-to-nearest-even, NaN/overflow |
| `bf16_mul` | two 16-bit BF16 | 16-bit BF16 | A × B, round-to-nearest-even, Inf/NaN/overflow |

---

## Results

Sky130 HD standard-cell synthesis.  "Cells" = post-`abc` optimised cell count
(the first count in each log is pre-optimisation).

| Format   | Bits | Cells (post-opt) | Area (µm²) | vs FP8-E4M3 | vs BF16 |
|----------|------|-----------------|------------|-------------|---------|
| FP8-E4M3 |    8 |             121 |      857.1 |      1.00×  |   0.31× |
| NFE-13   |   13 |             221 |     1611.5 |  **1.88×**  |   0.59× |
| BF16     |   16 |             385 |     2740.1 |      3.20×  |   1.00× |

---

## Interpretation

**NFE-13 vs FP8-E4M3:**  
NFE-13 multiply costs **1.88× the area** of FP8-E4M3 multiply (1612 µm² vs 857 µm²).
The format uses 5 more bits (13 vs 8) and a 7-bit × 7-bit mantissa product
(vs 4-bit × 4-bit for E4M3), which accounts for the larger multiplier.  On the
MLP inference task (Arena C, `docs/FORMAT_COMPARISON.md`), both formats achieve
**identical accuracy: 96.39%**.  This means NFE-13 pays 1.88× the multiplier
area to achieve the same accuracy as FP8-E4M3 on this task.  That is a
**negative result for NFE-13 vs FP8-E4M3 at iso-accuracy** on the MLP workload.

**NFE-13 vs BF16:**  
NFE-13 multiply costs **0.59× BF16** (41% cheaper).  BF16 achieves 96.67%
accuracy (FP64 ceiling), NFE-13 achieves 96.39% (0.28 pp lower) at 41% lower
multiplier area.  This is the closest thing to a positive result: **NFE-13
approaches BF16 accuracy at substantially lower hardware cost** (3 fewer bits,
0.59× area).  Whether that 41% area saving justifies the 0.28 pp accuracy gap
is a system-level decision.

**The core tension:**  
NFE-13 sits between FP8-E4M3 and BF16 in both area and accuracy, but closer to
FP8-E4M3 in accuracy (tied) and closer to BF16 in area-per-bit (5 extra bits
over FP8 produce 1.88× area, not the 1.625× you'd expect from bit count alone).
The extra cost comes from the 7×7-bit mantissa multiply vs 4×4-bit for E4M3 —
the 3 extra mantissa bits cost disproportionately because multiplier area scales
as O(n²).

---

## Context: Full MAC Unit

The full `horus_nfe` module (multiply + add/subtract + 32-bit accumulator +
pipeline registers + overflow/underflow flags) synthesises to **1382 cells,
10422 µm²** (`sim/SYNTH_NFE_BASELINE.log`).  The pure multiplier (`nfe13_mul`)
is **221 cells, 1612 µm²** — about **16% of the total MAC area**.  The
remaining 84% is accumulator, control, and pipeline logic that is largely
format-independent.  A complete FP8-E4M3 MAC (with, say, BF16 accumulation
as is standard for FP8 inference hardware) would also need a format-conversion
step and a BF16 or FP32 adder tree, making the total MAC comparison closer than
the multiplier-only numbers suggest.

---

## What This Does Not Answer

1. **Timing.**  Synthesis closed without timing constraints.  A faster clock
   would require retiming and pipelining; the relative area ordering may change
   at higher frequencies.

2. **Full MAC iso-comparison.**  The correct comparison for a deployed system
   is: NFE-13 MAC (multiply + accumulate) vs FP8-E4M3 MAC (multiply + BF16
   accumulate + converter) at the same throughput.  That synthesis has not been
   run.

3. **Normaliser cost.**  NFE-13 needs `horus_norm_v2` for multi-layer inference
   (+2.84% system area, `docs/EXPNORM_RESULTS.md`).  FP8/BF16 do not require
   an equivalent block.  At the system level this partially offsets NFE-13's
   per-multiplier advantage over BF16.

4. **Larger networks.**  Results from a 64→16→10 MLP.  A deeper network with
   more layers may favour BF16's better per-product precision and render the
   0.28 pp gap larger.

---

## Cross-Reference Map

| Evidence | Location |
|----------|----------|
| NFE-13 multiplier RTL | `rtl/nfe13_mul.v` |
| FP8-E4M3 multiplier RTL | `rtl/fp8_e4m3_mul.v` |
| BF16 multiplier RTL | `rtl/bf16_mul.v` |
| NFE-13 synthesis log | `sim/SYNTH_NFE13_MUL.log` |
| FP8-E4M3 synthesis log | `sim/SYNTH_FP8_E4M3_MUL.log` |
| BF16 synthesis log | `sim/SYNTH_BF16_MUL.log` |
| Full `horus_nfe` MAC area | `sim/SYNTH_NFE_BASELINE.log` |
| Accuracy comparison | `docs/FORMAT_COMPARISON.md` |
| Normaliser area cost | `docs/EXPNORM_RESULTS.md` |

# MLP_INFERENCE_DEMO — Handwritten Digit Classification via Horus NFE RTL

**Date:** 2026-07-05
**Status:** NEGATIVE RESULT — Task 2 gate triggered; Task 3 (RTL testbench) skipped.
**Related:** `docs/ADR_002_NORMALIZATION_ARCHITECTURE.md`, `docs/EXPNORM_RESULTS.md`,
             `sim/mlp_train.py`, `sim/mlp_infer_nfe.py`, `rtl/horus_nfe.v`,
             `rtl/horus_norm.v`

---

## Goal

Run handwritten digit classification through the actual Horus RTL — `horus_nfe` for
block matrix–vector products, `horus_norm` for between-layer activation re-grounding —
on the sklearn `load_digits` dataset (8×8 grayscale, 10 classes, 1797 images).

Architecture: 64→16→10 MLP, ReLU hidden, argmax output.
64 inputs tile exactly as 8×8 blocks; 16 hidden neurons = 2 blocks of 8;
10 outputs padded to 16 = 2 blocks of 8 (rows 10–15 are dead padding).

---

## Method

**Dataset:** `sklearn.datasets.load_digits` (available in this environment; not a
fallback).  Pixels 0–16 normalised to [0, 1] by ÷16.  80/20 split, `random_state=42`.

**Training:** Pure-numpy Adam (lr=0.003, β₁=0.9, β₂=0.999, 300 epochs, batch 32).
Seed=42 throughout.  FP64 test accuracy after one training run: **96.67% (348/360)**.

**Quantization:** NFE v3 (13-bit, bias-32, 6-bit mantissa).
Scale factors chosen to land all weights in NORM band E ∈ [16..47] (HBS-12A;
`nfe_matvec2.c` lines 65–66).  Both layers: scale 2^0 = 1.0 (no scaling needed).
Distribution:

| Array    | In NORM | Floor sentinels | Note                              |
|----------|---------|-----------------|-----------------------------------|
| W1 16×64 | 1024/1024 | 0             | E ∈ [18..33]; all actual weights  |
| b1 16    |   14/16   | 2             | 2 near-zero biases                |
| W2 16×16 |  160/256  | 96            | 96 = 6 zero-padded rows (expected)|
| b2 16    |   10/16   | 6             | 6 zero-padded entries (expected)  |

All actual (non-padding) weights and biases are in the NORM band.

**Division of labour:**
- DUT (`horus_nfe`): all 8×8-block multiply–accumulate arithmetic.
- DUT (`horus_norm`): between-layer block-exponent re-grounding.
- Harness (Python): block sequencing, bias add, ReLU, NFE encode/decode, argmax.

---

## Three-Way Accuracy Table

| Pipeline                           | Accuracy    | Correct  |
|------------------------------------|-------------|----------|
| (a) FP64 reference                 | **96.67%**  | 348/360  |
| (b) NFE weights + FP64 activations | **96.67%**  | 348/360  |
| (c) Full NFE + per-block expnorm   | **84.72%**  | 305/360  |

Source: `sim/MLP_PY_TRACE.csv` (360 rows, produced by `sim/mlp_infer_nfe.py`).

Pipeline (b) matches (a) exactly.  Weight quantisation alone introduces no accuracy
loss at this layer size: all W1 E values are well within NORM, and NFE round-trip
error is negligible for single-pass inference.

Pipeline (c) drops **11.94 pp** below FP64.  This exceeds the 5 pp task gate.

---

## Gate Condition Triggered

Per task specification: *if pipeline (c) accuracy drops more than 5 percentage points
below FP64, stop after this task, report the finding with the confusion analysis, and
skip to Task 4 as a negative result — do not proceed to RTL on a broken pipeline.*

**Task 3 (RTL testbench `tb/tb_mlp_inference.v`) is therefore SKIPPED.**

---

## Root Cause Analysis

### Diagnostic pipelines

| Configuration                             | Accuracy    |
|-------------------------------------------|-------------|
| FP64 reference                            | 96.67%      |
| NFE weights + FP64 activations            | 96.67%      |
| NFE encode only, no expnorm               | **96.67%**  |
| NFE + global expnorm (16-element vector)  | **96.39%**  |
| NFE + per-block expnorm, N=8 (spec)       | **84.72%**  |

Source: inline diagnostic in `sim/mlp_infer_nfe.py` (gate-fail branch).

### Finding

The 11.94 pp degradation is **entirely caused by per-block expnorm** — not by NFE
weight quantisation (pipeline b = 96.67%) and not by NFE activation encoding
(no-expnorm variant = 96.67%).

`horus_norm` operates on exactly 8 elements and internally computes:

    E_max = max exponent across its 8 inputs
    offset = E_TARGET(32) − E_max
    new_E[i] = E[i] + offset      (mantissas untouched)

When applied **independently** to block 0 (neurons 0–7) and block 1 (neurons 8–15)
of the hidden layer, each block receives a **different offset**, determined by that
block's own E_max.  Typical E_max values from five representative images:

| Image | E_max block 0 | offset 0 | E_max block 1 | offset 1 | |offset₀ − offset₁| |
|-------|---------------|----------|---------------|----------|----------------------|
| img=0 | 34            | −2       | 35            | −3       | 1 (factor 2×)        |
| img=1 | 34            | −2       | 35            | −3       | 1 (factor 2×)        |
| img=2 | 35            | −3       | 34            | −2       | 1 (factor 2×)        |
| img=3 | 35            | −3       | 34            | −2       | 1 (factor 2×)        |
| img=4 | 33            | −1       | 35            | −3       | 2 (factor 4×)        |

Because the two blocks are rescaled by **different powers of 2**, the ratio of
(block-1 magnitude) to (block-0 magnitude) as seen by the layer-2 weights differs
from the ratio during FP64 training by a per-image factor of 2–4×.  Layer 2 was
trained on the true ratio; the independent rescaling makes those weights incorrect.

### What works

- **No expnorm between layers:** 96.67%.  Single-pass inference does not require
  iterative re-grounding; activations stay in representable range for one pass.
- **Global expnorm (16-element):** 96.39%.  One shared offset preserves the
  inter-block relative magnitudes and loses only 1/360 images.

---

## Per-Class Breakdown — Pipeline (c)

| Class | NFE corr. | NFE acc% | FP64 acc% | Delta  |
|-------|-----------|----------|-----------|--------|
| 0     | 31/36     |  86.1%   |  97.2%    | −11.1% |
| 1     | 23/36     |  63.9%   |  91.7%    | **−27.8%** |
| 2     | 35/35     | 100.0%   | 100.0%    |  0.0%  |
| 3     | 29/37     |  78.4%   | 100.0%    | **−21.6%** |
| 4     | 35/36     |  97.2%   |  97.2%    |  0.0%  |
| 5     | 25/37     |  67.6%   | 100.0%    | **−32.4%** |
| 6     | 29/36     |  80.6%   |  94.4%    | −13.9% |
| 7     | 34/36     |  94.4%   | 100.0%    |  −5.6% |
| 8     | 32/35     |  91.4%   |  91.4%    |  0.0%  |
| 9     | 32/36     |  88.9%   |  94.4%    |  −5.6% |

Source: `sim/MLP_PY_TRACE.csv`.  Classes 1, 3, 5 are hardest hit.

---

## RTL Agreement

Task 3 was skipped; `sim/MLP_RTL_TRACE.csv` was not produced.
`sim/analyze_mlp.py` reports the absence and exits 1.

---

## Limitations

- ReLU, bias add, and argmax are computed in the Python harness, not through RTL.
- Dataset is 8×8 (sklearn `load_digits`), not MNIST (28×28); different difficulty.
- Single-image inference latency was not measured (Task 3 skipped).
- FP64 accuracy of 96.67% is for a 64→16→10 MLP; capacity-limited vs. deeper
  networks.  It is what it is after one training run; no retraining was done.

---

## What This Demonstrates

**NFE weight quantisation alone (pipeline b)** introduces no accuracy loss for the
64→16→10 architecture at this dataset scale: the 13-bit NFE format with NORM-band
weights round-trips to FP64 accuracy.

**Per-block `horus_norm` (N=8) is incompatible with a 16-neuron hidden layer** when
applied independently to each 8-element block.  The architectural fix is one of:

1. Apply `horus_norm` twice with the same externally computed E_max (shared offset),
   preserving inter-block relative magnitudes — requires exposing E_max or running
   a pre-pass to determine the global maximum.
2. Reduce the hidden layer to 8 neurons (one block), so a single `horus_norm` call
   is both correct and complete.
3. Omit expnorm between layers entirely; single-pass inference does not compound
   quantisation error and does not need re-grounding.

The falsification principle applied here: the task gate correctly caught the
pipeline failure and prevented a broken pipeline from reaching RTL simulation.

---

## File Index

| File                        | Description                                      |
|-----------------------------|--------------------------------------------------|
| `sim/mlp_train.py`          | Training, quantisation, hex file export          |
| `sim/mlp_infer_nfe.py`      | Three-pipeline inference; gate check; diagnostic |
| `sim/analyze_mlp.py`        | RTL vs Python cross-check (RTL trace absent)     |
| `sim/MLP_W1.hex`            | W1 NFE codewords (1024 entries)                  |
| `sim/MLP_B1.hex`            | b1 NFE codewords (16 entries)                    |
| `sim/MLP_W2.hex`            | W2 NFE codewords, 16×16 padded (256 entries)     |
| `sim/MLP_B2.hex`            | b2 NFE codewords, 16 padded (16 entries)         |
| `sim/MLP_TEST_IMAGES.hex`   | Test images NFE-encoded (360×64 entries)         |
| `sim/MLP_TEST_LABELS.dat`   | Test labels, one per line (360 entries)          |
| `sim/MLP_FP64.npz`          | FP64 weights + test set (numpy archive)          |
| `sim/MLP_PY_TRACE.csv`      | Pipeline (c) per-image trace (360 rows)          |
| `docs/MLP_INFERENCE_DEMO.md`| This document                                    |

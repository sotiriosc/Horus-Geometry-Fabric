# MLP_INFERENCE_DEMO — Handwritten Digit Classification via Horus NFE RTL

**Date:** 2026-07-05
**Status:** COMPLETE — all four tasks passed; RTL accuracy 96.39% (347/360).
**Related:** `rtl/horus_nfe.v`, `rtl/horus_norm.v`, `rtl/horus_norm_v2.v`,
             `sim/mlp_train.py`, `sim/mlp_infer_nfe.py`,
             `tb/tb_horus_norm_v2.v`, `tb/tb_mlp_inference.v`,
             `sim/analyze_mlp.py`, `docs/EXPNORM_RESULTS.md`

---

## Goal

Run handwritten digit classification through the actual Horus RTL — `horus_nfe`
for block matrix–vector products, `horus_norm_v2` for between-layer activation
re-grounding — on the sklearn `load_digits` dataset (8×8 grayscale, 10 classes,
1797 images).

Architecture: 64→16→10 MLP, ReLU hidden, argmax output.
64 inputs tile exactly as 8×8 blocks; 16 hidden neurons = 2 blocks of 8;
10 outputs padded to 16 = 2 blocks of 8 (rows 10–15 are dead padding).

---

## Method

**Dataset:** `sklearn.datasets.load_digits`.  Pixels 0–16 normalised to [0, 1]
by ÷16.  80/20 split, `random_state=42`.

**Training:** Pure-numpy Adam (lr=0.003, β₁=0.9, β₂=0.999, 300 epochs, batch 32).
Seed=42 throughout.  FP64 test accuracy after one training run: **96.67% (348/360)**.

**NFE quantisation:** Weights encoded to NFE v3 (13-bit, bias-32) via `nfe_enc`.
Block-scaling (`choose_scale`) prefers k=0 to avoid unnecessary magnitude reduction.
Biases scaled by the same layer factor as weights.  Verified lossless: pipeline (b)
accuracy = 96.67%, identical to FP64.

**Between-layer re-grounding:** `horus_norm_v2` in two-pass shared-offset composition
(see [Gate failure → fix](#gate-failure--root-cause--fix) for why shared offset is
required):
- Pass 1 (mode=0): query `e_max_out` from each 8-element hidden-layer block.
- Harness: `shared_offset = E_TARGET − max(e_max_A, e_max_B)`.
- Pass 2 (mode=1): apply `shared_offset` to both blocks.

---

## Gate Failure → Root Cause → Fix

### First Attempt (prior session): per-block expnorm — GATE FAIL

The original `horus_norm` applies an independent offset to each 8-element block.
For the 16-neuron hidden layer (2 blocks), blocks 0 and 1 were normalised separately,
producing offsets that differed by 2–4× for many images.  This destroyed the
relative magnitudes that layer 2 was trained to expect.

| Pipeline | Accuracy | Δ vs FP64 |
|---|---|---|
| (a) FP64 reference | 96.67% (348/360) | — |
| (c) Full NFE + **per-block** expnorm | **84.72% (305/360)** | **−11.94 pp** |

Gate threshold: 5 pp.  **Gate triggered.  RTL testbench skipped.**

Root cause confirmed by diagnostic variants:

| Variant | Accuracy | Implication |
|---|---|---|
| NFE encode only, no expnorm | 96.67% | NFE quantisation is lossless |
| Global (16-element) expnorm | 96.39% | Single shared offset is fine |
| Per-block (2×8) expnorm | 84.72% | Independent offsets break Layer 2 |

### Fix: `horus_norm_v2` with external-offset mode

`rtl/horus_norm_v2.v` adds two ports to `horus_norm`:
- `e_max_out[5:0]` — exposes the internal max-tree result (registered).
- `offset_mode` / `offset_in[6:0]` — mode 0: internal (v1 behaviour);
  mode 1: apply externally supplied offset.

Mode-0 regression: **1000/1000 against `EXPNORM_GOLDEN.dat`** — byte-for-byte
identical to v1.  Composition test: **200/200 two-block trials** against
`EXPNORM_V2_GOLDEN.dat`.

---

## Four-Way Accuracy Table

| Pipeline | Accuracy | Correct/Total | Δ vs FP64 |
|---|---|---|---|
| (a) FP64 reference | 96.67% | 348/360 | — |
| (b) NFE weights + FP64 activations | 96.67% | 348/360 | 0.00 pp |
| **(c) Full NFE + shared-offset expnorm** | **96.39%** | **347/360** | **−0.28 pp** |
| (d) Full NFE, no expnorm [for record] | 96.67% | 348/360 | 0.00 pp |

Gate check: pipeline (c) delta = **0.28 pp ≤ 5 pp threshold** — **PASS**.

---

## RTL Inference Results

**RTL accuracy: 96.39% (347/360)**  — exact match with Python pipeline (c).

Cross-check (`sim/analyze_mlp.py`):
- Prediction agreement: **360/360 (100.0%)**
- Hidden-activation agreement: **359/360** (1 image, 1-bit mantissa LSB rounding difference;
  no effect on classification — see [Divergences](#known-divergences)).

### Per-Class Breakdown (pipeline c / RTL)

| Class | Correct | Total | Acc% | FP64 acc% | Note |
|---|---|---|---|---|---|
| 0 | 35 | 36 | 97.2% | 97.2% | |
| 1 | 32 | 36 | 88.9% | 91.7% | 1 new error vs FP64 |
| 2 | 35 | 35 | 100.0% | 100.0% | |
| 3 | 36 | 37 | 97.3% | 100.0% | 1 new error vs FP64 |
| 4 | 36 | 36 | 100.0% | 97.2% | |
| 5 | 37 | 37 | 100.0% | 100.0% | |
| 6 | 34 | 36 | 94.4% | 94.4% | |
| 7 | 36 | 36 | 100.0% | 100.0% | |
| 8 | 33 | 35 | 94.3% | 91.4% | |
| 9 | 33 | 36 | 91.7% | 94.4% | 1 new error vs FP64 |

New errors introduced by shared-offset NFE pipeline vs FP64 (3 images):

| img | true | pred | FP64 margin |
|---|---|---|---|
| 80 | 9 | 5 | 0.097 (close call even in FP64) |
| 89 | 1 | 8 | 0.246 |
| 128 | 3 | 2 | 0.250 |

---

## ASCII Showcase Inference

**img=0 (class 5) — easy correct:**
```
  +--------+
  |..+###:.|
  |..#+.:..|
  |..@::...|
  |.:@##@:.|
  |..:..++.|
  |.....*+.|
  |.+#.:@..|
  |..+#@:..|
  +--------+
  Scores: [0]-0.685 [1]-4.422 [2]-5.196 [3]-2.151 [4]-2.967
           [5]+2.968 [6]-2.039 [7]-2.657 [8]-0.339 [9]+0.479
  Verdict: CORRECT (predicted=5)
```

**img=231 (class 9) — close-flip (margin=0.009):**
```
  +--------+
  |...:*@@:|
  |..*@###:|
  |.+@@@@#.|
  |..*++@*.|
  |.....@:.|
  |....**..|
  |....@+..|
  |...:@:..|
  +--------+
  Scores: [7]+0.944 [9]+0.953  — margin 0.009
  Verdict: CORRECT (predicted=9)
```

**img=36 (class 6) — misclassified (FP64 also fails here):**
```
  +--------+
  |...*@#..|
  |..+@*@:.|
  |.:@*.+..|
  |.+@*....|
  |.+@@*...|
  |.:@*@+..|
  |..*@@+..|
  |...+#...|
  +--------+
  Scores: [0]+0.553 [6]+0.266 [8]+1.112
  Verdict: WRONG (predicted=8, true=6)
  Note: FP64 also predicts 8 on this image.
```

---

## Known Divergences

**1-bit mantissa LSB rounding (img=340, block=1, neuron=0):**
- Python: `h1_b1_0 = 0x0770` (E=30, f=48, value ≈ 0.4375)
- RTL:    `h1_b1_0 = 0x0771` (E=30, f=49, value ≈ 0.4414)
- Cause: FP64 accumulation-order difference between Python `float` and Verilog
  `real` in the 64-term dot product for one hidden neuron.  Exponent field
  is identical; the difference is ±1 in the 6-bit mantissa fraction.
  Prediction is unaffected (both produce pred=correct label on img=340).

---

## Limitations and Lessons

**Scope of the anchor:** Normalization scope must span the entire activation
vector — single-pass shallow inference does not require re-grounding at all,
and re-grounding pays off only in iterative and deep regimes where exponent
drift accumulates across layers.

---

## Files

| File | Role |
|---|---|
| `rtl/horus_nfe.v` | MAC DUT (unchanged) |
| `rtl/horus_norm.v` | 8-element normalizer v1 (unchanged) |
| `rtl/horus_norm_v2.v` | Normalizer v2: `e_max_out` + external-offset mode |
| `sim/mlp_train.py` | MLP training + NFE weight export |
| `sim/mlp_infer_nfe.py` | Python inference, four pipelines, gate check |
| `sim/expnorm_sweep.py` | Sweep + v2 golden generator (`--v2-golden`) |
| `sim/EXPNORM_V2_GOLDEN.dat` | 200 two-block composition trials |
| `tb/tb_horus_norm_v2.v` | Unit tests: mode-0 regression + composition |
| `tb/tb_mlp_inference.v` | Full 360-image RTL inference testbench |
| `sim/MLP_PY_TRACE.csv` | Python pipeline (c) per-image trace |
| `sim/MLP_RTL_TRACE.csv` | RTL per-image trace |
| `sim/analyze_mlp.py` | RTL vs Python cross-check |

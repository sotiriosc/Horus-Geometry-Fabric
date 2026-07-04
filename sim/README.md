# NFE C-Model Workloads & Deployment Review Tests

This directory contains the golden C model (`horus_sim.c`), HBS analysis scripts, and a
suite of **targeted C simulators** built during the July 2026 NFE deployment review. The
review asked a single practical question: *what actually matters for real CLASS_A workloads
(GEMM, conv, attention) on the documented hardware path?*

The full narrative, findings, and conclusions live in
[docs/NFE_DEPLOYMENT_REVIEW.md](../docs/NFE_DEPLOYMENT_REVIEW.md). This file covers how to
build and run the new tests.

---

## Quick run

```bash
cd sim

# Baseline 8×8 matvec (single-path NFE)
make nfe_matvec && ./nfe_matvec

# Dual-path routed matvec (fast path for E ∈ [28..35])
make nfe_matvec2 && ./nfe_matvec2

# ABMP epoch snapshot vs true sum (off-by-one isolation)
make abmp_epoch_test && ./abmp_epoch_test

# ABMP blast radius (K=8, trigger characterization)
make abmp_blast_radius && ./abmp_blast_radius

# HBS-1 scale K=128 reduction (7 epoch boundaries)
make abmp_k128_test && ./abmp_k128_test

# Forced normalization at epoch boundary (cancellation operands)
make abmp_norm_fires && ./abmp_norm_fires
```

Or run everything at once:

```bash
make deployment_review
```

---

## Test programs

| Program | Purpose | Key result |
|---------|---------|------------|
| `nfe_matvec.c` | 8×8 NFE matvec baseline; arith/dmov op counts and weighted-cost table | 0.383% mean / 0.794% max rel error vs FP64 |
| `nfe_matvec2.c` | Dual-path matvec: `PATH_FAST` (double accum) for anchor zone E∈[28..35], `PATH_NFE` elsewhere | Weighted cost moved vs baseline (see program output) |
| `abmp_epoch_test.c` | One full epoch (depth=16 from C4 HC-5); compare true sum vs `accum_out` snapshot | Snapshot misses last MAC by 1 cycle — consistent with 1/16 drop |
| `abmp_blast_radius.c` | Which real ops trigger ABMP; K=8 matvec through ABMP path | Fixed `depth > 16` counter; K=8 never fires; 0% accuracy delta |
| `abmp_k128_test.c` | HBS-1 K=128 dot product; operands uniform in [0.1, 1.0] | 7 boundaries at depth=17; normalization never fires (E≥20); 0% delta |
| `abmp_norm_fires.c` | Adversarial alternating-sign epoch forcing E<20 at boundary | Normalization fires (4× MUL×TWO); operand from `op_a` not `accum_out`; 0% delta |

---

## What these tests model (and what they do not)

All ABMP tests use a **minimal hardware accumulator model** layered on top of
`horus_sim.c` NFE primitives:

- `accum_reg` — 32-bit sum of 13-bit integer codewords (same cycle)
- `accum_out` — registered copy, **1 cycle behind** (`horus_nfe.v` L596–598)
- `depth` — caller-maintained counter since last `accum_clr` (C4 §1.2)
- `INSERT_EPOCH_BOUNDARY` — fires when `depth > 16` (C4 HC-5)

They do **not** modify RTL. They mirror documented action semantics from
`HORUS_C1_COMPILER_SPEC.md` §1.8 and `HORUS_C4_COMPILER_KERNEL_SPEC.md` §1.4.

**Critical architectural distinction:**

| Path | Register | Role | ABMP off-by-one affects? |
|------|----------|------|--------------------------|
| Compute | `result` (13-bit NFE) | Running partial sum / dot product | **No** |
| Monitor | `accum_out` (32-bit) | Integer codeword accumulator for snapshot | **Yes** (when read) |

Real GEMM accuracy is determined by the `result` chain. The off-by-one corrupts
`accum_out` only when that register is used as a computation input — not on the
standard dot-product path.

---

## Related analysis (not separate binaries)

Several investigations were run as one-off Python scripts during the review (gate-level
GE breakdowns, block-scaling cost tables, saturation reachability for 16-step epochs,
fidelity LFSR replay). Those results are summarized in
[docs/NFE_DEPLOYMENT_REVIEW.md](../docs/NFE_DEPLOYMENT_REVIEW.md).

The 1024-cycle fidelity benchmark logic is replicated in `analyze_fidelity.py` (requires
`fidelity_benchmark.csv` from `make fidelity`) and was also reproduced inline for
compensated-accumulation and block-scaling comparisons documented in the review.

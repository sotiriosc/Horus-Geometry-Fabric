# PF18 Power Iteration: Three-Way Convergence Comparison

**Date:** 2026-07-05  
**Status:** COMPLETE  
**Artifacts:** `tb/tb_pf18_power_iteration.v` · `tb/tb_baseline_power_iteration.v`
· `sim/analyze_power_iteration.py` · `sim/PF18_POWER_ITER.csv`
· `sim/BASELINE_POWER_ITER.csv` · `sim/PI_THREE_WAY.csv`

---

## Method

### Workload

Power iteration: **y ← A·y / ‖y‖**, 256 iterations, 8-element state vector,
8×8 matrix A.

### Matrix

8×8 symmetric positive matrix constructed from LFSR upper triangle (seed
`SEED_PI = 32'hFACE_FEED`, values in [0.25, 1.25) per entry); lower triangle
mirrored from upper.  All entries > 0, so Perron-Frobenius guarantees a unique
positive dominant eigenvalue λ_max and corresponding positive eigenvector.
Golden value: λ_max = **7.1635** (FP64 power iteration, t=256).

### Division of labour

**DUT** — computes the matrix-vector product A·y.  
**Harness** — decodes the DUT outputs, computes ‖z‖ = ‖Ay‖ in FP64 real
arithmetic, divides each component by ‖z‖, and re-encodes the normalised
vector to NFE for the next DUT step.  The golden path is entirely independent
of the DUT at every step.

This division of labour is identical across all three runs so the comparison
isolates the datapath, not the normalisation algorithm.

### Eigenvalue estimate

**‖Ay‖** (norm of the unnormalised output before renormalisation).  Since
‖y‖ = 1 after each step, ‖Ay‖ = ‖y_{t+1}‖/‖y_t‖ and converges to λ_max
as the eigenvector is approached.

### Three paths under comparison

| Path | DUT module | Protocol |
|------|-----------|----------|
| (a) RTL Baseline | `horus_nfe` | 8 MUL ops per row (standard mode); each product re-quantised to 6-bit NFE (lines 530–532 of `horus_nfe.v`); 8 decoded products summed in harness FP64 |
| (b) RTL PF18 | `horus_nfe_pf18` | 8 MUL ops accumulate into 18-bit `pf_accum`; 1 NOP readout gives NFE(pf_accum) per row |
| (c) Python W=18 | `sim/analyze_power_iteration.py` | RTL-faithful model using `pf_accum_add_w18` / `pf_readout_w18`; same LFSR, same matrix, same NFE round-trip for initial vector |

---

## Results

### Summary table (t = 256)

| Path | λ_final | λ error | Alignment | First t ≥ 0.99 |
|------|---------|---------|-----------|----------------|
| Golden (FP64) | 7.1635 | — | — | — |
| RTL Baseline | 7.1346 | 0.40% | **0.9993** | t = 1 |
| RTL PF18 | 5.6139 | **21.63%** | 0.9909 | t = 2 |
| Python W=18 | 5.6139 | 21.63% | 0.9909 | t = 2 |

Source: `sim/PI_THREE_WAY.csv`; Verilog summary blocks from `vvp sim_pf18_pi`
and `vvp sim_baseline_pi`.

### Convergence trajectories (selected iterations)

| t | PF18 λ | Base λ | Gold λ | PF18 align | Base align | Py align |
|---|--------|--------|--------|------------|------------|----------|
| 1 | 5.4842 | 6.5244 | 6.5525 | 0.9879 | 1.0004 | 0.9879 |
| 2 | 5.6191 | 7.1214 | 7.1525 | **0.9917** | 0.9998 | 0.9917 |
| 3 | 5.6139 | 7.1250 | 7.1632 | 0.9907 | 0.9996 | 0.9907 |
| 8 | 5.6139 | 7.1346 | 7.1635 | 0.9909 | 0.9993 | 0.9909 |
| 256 | 5.6139 | 7.1346 | 7.1635 | 0.9909 | 0.9993 | 0.9909 |

Source: `sim/PI_THREE_WAY.csv`, rows t=1,2,3,8,256.

All three paths stabilise by t=8; the remaining 248 iterations hold the
same fixed-point values within NFE resolution.

### RTL PF18 vs Python W=18 model

No alignment divergence > 2× detected across all 256 iterations.  Both paths
produce identical λ_final (5.6139) and alignment (0.9909).  The Python model
faithfully replicates the RTL PF18 saturation behaviour.  Source:
`sim/analyze_power_iteration.py`, divergence check section.

---

## Finding: PF18 accumulator saturation in this workload

The W=18 pf_accum ceiling is MAX18 = 131 071 (= 2^17 − 1), corresponding to a
decoded row-sum value of 131 071 × 2^(−16) ≈ **2.00**.

At convergence, the dominant eigenvector is a unit vector with components of
magnitude ~1/√8 ≈ 0.354.  With matrix entries averaging ~0.75, each row sum
z_i ≈ 8 × 0.75 × 0.354 ≈ 2.12; the accumulator representation of 2.12 is
≈ 2.12 × 2^16 ≈ 139 000 > MAX18.  Saturation fires on most rows in steady
state.

The saturation guard (clamp rather than wrap, `horus_nfe_pf18.v` lines
579–583) clips each row magnitude to approximately the same fraction of its
true value.  Because the clipping is approximately uniform across rows, the
vector *direction* is approximately preserved, giving the 0.9909 alignment.
The *magnitude* (λ estimate) is underestimated by −21.6%.

For the SSC-style workload (row-stochastic A, row sums ≤ 1.0, y ∈ [1.0, 2.0))
the peak pf_accum is ≈ 1.5 × 2^16 ≈ 98 304 < MAX18: no saturation, hence the
0.18% neutral-regime error documented in `docs/PF_DECISION_INPUTS.md`.  The
W=18 accumulator is sized for that workload, not for matrices with larger row
sums.

---

## Finding: baseline unexpectedly converges in normalised power iteration

The baseline (PATH_NFE) achieves 0.9993 vector alignment and 0.40% eigenvalue
error.  This contradicts the "baseline stalls" expectation from the SSC
validation.

The SSC test is an **un-normalised** feedback chain: y ← A·y with no rescaling
between steps.  Per-product 6-bit NFE re-quantisation accumulates without
correction, driving the DUT to a wrong attractor (23.95% final error,
`docs/SSC_RTL_VALIDATION.md`, P2 CONFIRMED).

Normalised power iteration applies an explicit rescale **every step**:
y ← z / ‖z‖.  This per-step direction correction absorbs the re-quantisation
error before it can accumulate, allowing the baseline to converge directionally
even though each product is truncated to 6-bit NFE.

The SSC result stands.  The power iteration result is a separate finding about
a separate workload.

---

## What this demonstrates

The data shows three things, no more:

1. **RTL PF18 and the Python W=18 model agree exactly** across all 256
   iterations (identical λ_final, identical alignment trajectory, zero cycles
   diverging by > 2×).  The Python model faithfully captures the RTL behaviour,
   including the saturation regime.

2. **Both paths converge directionally** in normalised power iteration, but
   PF18's eigenvalue estimate is biased −21.6% because the W=18 accumulator
   saturates for this matrix (peak row sum ≈ 2.12 > W=18 ceiling ≈ 2.00).
   The saturation guard prevents wrap; direction is approximately preserved.

3. **The practical PF18 advantage is in un-normalised feedback chains**
   (the chip's attractor workload, characterised in `docs/SSC_RTL_VALIDATION.md`
   and `docs/ADR_001_PF18_ADOPTION.md`): there, baseline reaches 23.95% error
   and PF18 reaches 0.18%.  Normalised power iteration with per-step rescaling
   is a different regime where both paths converge, and where the PF18
   accumulator saturates if the matrix row sums exceed the W=18 ceiling.

---

*Horus-Geometry-Fabric · PF18 Power Iteration · 2026-07-05*

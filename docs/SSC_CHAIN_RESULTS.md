# Second-Source Chain RTL Confirmation — Results

**Investigation:** SSC-Chain — deep y ← A·y feedback chain through `horus_nfe.v`  
**System:** HORUS NFE v3 (13-bit, Bias-32, 6-bit mantissa)  
**Date:** 2026-07-05  
**Artifacts:** `tb/tb_second_source_chain.v` · `sim/second_source_chain.py` · `sim/SSC_CHAIN_TRACE.csv`  
**Analysis script:** `sim/analyze_second_source_chain.py`  
**Run:** `cd sim && make ssc_chain`

---

## Context

`sim/second_source_chain.py` makes three predictions about how NFE arithmetic behaves under
256-step y ← A·y feedback chains on an 8×8 random row-stochastic matrix. This investigation
runs those chains through the **actual `horus_nfe.v` RTL datapath** (not a behavioral re-model)
to confirm or falsify each prediction.

Three spectral regimes, 256 cycles each, 64 MUL operations per cycle (8 rows × 8 columns):

| Regime | Row sum | Expected spectral radius |
|--------|---------|--------------------------|
| Contractive | 0.90 | < 1 → vector shrinks |
| Neutral | 1.00 | ≈ 1 → vector converges to eigenvector |
| Expansive | 1.10 | > 1 → vector inflates toward saturation |

The FP64 golden reference is computed independently inside the testbench (pure `real`
arithmetic, no NFE re-encoding) and never touches the RTL path. LFSR seed and matrix
construction match `second_source_chain.py`.

---

## RTL Architecture Constraint

`horus_nfe.v` provides one multiply opcode: `op_sel = 2'b10` (MUL, lines 494–536).

The MUL path computes the hidden-bit product `scale_reg = {1,m_a} × {1,m_b}` (line 502) and
immediately quantizes the result to a 6-bit mantissa field (lines 530–532):

```
f_result = scale_reg[12:7]   // P[13]=1 path
         = scale_reg[11:6]   // P[13]=0 path
```

This is exactly the `PATH_NFE` model in `second_source_chain.py` — 6-bit quantization of every
intermediate product before the product enters the FP64 accumulator.

`PATH_FAST` (keep full 14-bit `scale_reg` product, re-encode state only once per matvec step)
is **not accessible from the RTL interface**. `scale_reg` is a local register (line 502); no
`op_sel` value exposes the pre-quantized product. Prediction 1 is untestable from this RTL
without modification.

---

## Predictions and Verdicts

### P1 — PATH_FAST, neutral regime, ≤ 1% error through 256 cycles

**Predicted:** full-mantissa MAC path holds ≤ 1% mean relative error vs FP64 through 256
feedback cycles; predicted final error 0.3838% (matching the single-pass figure from
`sim/nfe_matvec.c`).

**RTL result:** untestable — no PATH_FAST datapath in `horus_nfe.v`.

**VERDICT: NOT CONFIRMED (ARCHITECTURAL GAP)**  
The RTL does not falsify this prediction; it simply cannot exercise the path. Confirmation
requires exposing `scale_reg` (line 502) on an output port or adding a new opcode.

---

### P2 — PATH_NFE, neutral regime, onset ≤ 10 cycles, final ≈ 20%

**Predicted:** 6-bit intermediate quantization causes divergence past 1% mean relative error
within ~5 feedback cycles, ending near 20% error at depth 256.

**RTL result:**

| Metric | Predicted | RTL measured |
|--------|-----------|--------------|
| Divergence onset (> 1%) | ≤ 5 cycles (tolerance ≤ 10) | cycle 2 |
| Final mean rel err | ≈ 20% | 23.95% |
| Cumulative sat events | — | 0 |

**VERDICT: CONFIRMED** (onset 2 ≤ tolerance 10)

The golden path converges to the dominant eigenvector of A at 1.6436 by cycle ≈ 10 and holds
there through cycle 256. The RTL path drifts downward due to quantization rounding loss per
multiply (6 bits retained vs 14 available in `scale_reg`) and stalls at 1.25 by cycle ≈ 130.
The 23.95% gap is stable from cycle 130 to cycle 256.

---

### P3 — Both paths, expansive regime, final error ≈ 95%

**Predicted:** both paths converge to ~95% error at depth 256, dominated by saturation events
— divergence at the OVF cliff is format-level, not path-level.

**RTL result:**

| Metric | Predicted | RTL measured |
|--------|-----------|--------------|
| Final mean rel err | ≈ 95% (tolerance [47.5%, 190%]) | 93.50% |
| Cumulative sat events | > 0 | 136 |

**VERDICT: CONFIRMED** (47.5% ≤ 93.50% ≤ 190%)

136 saturation events confirm the OVF cliff was reached. The RTL-measured 93.50% is within
1.5% absolute of the Python prediction.

---

## Additional Observations

### Eigenvector convergence (neutral golden path)

The FP64 golden chain for the neutral regime converges to 1.6436 (all 8 components identical
to six significant figures) by approximately cycle 10 and remains there through cycle 256.
This is the Perron–Frobenius dominant eigenvector of the row-stochastic A — a deterministic
consequence of the matrix spectrum, not a property of the NFE format. The RTL DUT cannot
track this convergence; it stalls at 1.25 (NFE codeword `E=32, f=16`) due to the
quantization rounding loss compounding over ≈ 130 steps.

The 1.25 stall is an NFE fixed point, not an artifact: `A × [1.25, …, 1.25]` with
row sums = 1.0 and A quantized to 6-bit mantissas accumulates a sum that re-encodes to the
same codeword. The golden eigenvector (1.6436) lies above the NFE-quantized fixed point (1.25).

### Contractive floor stall

In the contractive regime (row sums = 0.90), both DUT and golden shrink toward zero. The
golden reaches ≈ 2.5 × 10⁻¹² by cycle 256. The DUT stalls at ≈ 2.4 × 10⁻⁹ (components
span E = 3, f ∈ {0..18}). Below this scale, `exp_sum = e_y + e_A − 32` wraps negative
(`exp_sum[7] = 1`, `horus_nfe.v` lines 516–520), triggering UNDERFLOW on every product;
the sum of 8 UNDERFLOW floor values re-encodes to the same scale, creating a stable loop.
The divergence-onset counter fires at cycle 2 (mean relative error immediately > 1%) but
the physical mechanism is NFE resolution, not saturation. `cum_sat` and `cum_floor` (using
the E=63,f=63 / E=0,f=0 sentinels) both remain 0 because the stall happens inside the
representable range, not at the format extremes.

The contractive regime is not covered by any of the three predictions above; this observation
is informational.

---

## Testbench implementation notes

**Icarus Verilog `$pow` integer promotion bug.** The standard `$pow(2.0, e - EXP_BIAS)`
expression, where `e` and `EXP_BIAS` are both `integer`, passes the result as an *unsigned*
32-bit value when the mathematical result is negative (e.g., `e = 28`, `e − 32 = −4` is
promoted to 4,294,967,292). This produces `Inf` from `$pow`. The fix is
`$pow(2.0, $itor(e) − $itor(EXP_BIAS))`. All NFE decode calls in
`tb_second_source_chain.v` use this form. This does not affect `horus_nfe.v` (RTL uses
integer arithmetic for the exponent, not `$pow`).

**DUT timing.** MUL is single-cycle (`result <=` at posedge, `horus_nfe.v` line 536).
Inputs are applied at negedge; result is sampled at the following posedge + 1 ns NBA settle,
matching the pattern in `tb_fidelity_benchmark.v`.

---

## Summary table

| Regime | Onset cycle (> 1%) | Final mean rel err | cum_sat | cum_floor |
|--------|--------------------|--------------------|---------|-----------|
| Contractive (0.90) | 2 | 98,043% (floor-stall) | 0 | 0 |
| Neutral (1.00) | 2 | 23.95% | 0 | 0 |
| Expansive (1.10) | 2 | 93.50% | 136 | 0 |

| Prediction | Verdict |
|------------|---------|
| P1 — PATH_FAST neutral ≤ 1% | NOT CONFIRMED (architectural gap — RTL has no PATH_FAST datapath) |
| P2 — PATH_NFE neutral onset ≤ 10 | CONFIRMED (onset = cycle 2; final = 23.95%) |
| P3 — expansive ≈ 95% | CONFIRMED (93.50%; 136 saturation events) |

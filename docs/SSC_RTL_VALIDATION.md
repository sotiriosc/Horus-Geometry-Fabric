# Second-Source Chain RTL Validation

**Date:** 2026-07-05  
**Status:** COMPLETE  
**Artifacts:** `tb/tb_second_source_chain.v` · `sim/second_source_chain.py` ·
`sim/analyze_second_source_chain.py` · `sim/SSC_CHAIN_TRACE.csv`  
**Run:** `cd sim && make ssc_chain`

---

## Method

The second-source discipline requires that the golden reference be computed by a path
entirely independent of the path under test. Here:

- **DUT path** — `op_sel = 2'b10` (MUL) applied 64 times per cycle (8 rows × 8 columns)
  through the actual `horus_nfe.v` datapath. Decoded products accumulate in FP64; the
  accumulated sum is re-encoded to NFE and fed back as the state for the next cycle.
- **Golden path** — pure FP64 matrix–vector multiply (`A_fp × y_g`), computed entirely in
  `real` arithmetic inside the testbench, never touching `horus_nfe.v` and never re-encoded.

Three spectral regimes, 256 feedback cycles each, 8×8 row-stochastic matrix A:

| Regime | Row sum | Spectral behavior |
|--------|---------|-------------------|
| Contractive | 0.90 | State shrinks toward zero |
| Neutral | 1.00 | State bounded, converges to Perron eigenvector |
| Expansive | 1.10 | State inflates toward OVF cliff |

Divergence cut: 1.0% mean relative error. Matrix A and initial state y generated
deterministically from a 32-bit Galois LFSR (seed `CAFE_F00D`, taps 32/22/2/1),
independent of the seed used in `tb_fidelity_benchmark.v`.

---

## P1 — PATH_FAST, neutral regime, ≤ 1% error through 256 cycles

**Prediction (second_source_chain.py, `step_fast`, lines 120–132):** a path that accumulates
the full 14-bit hidden-bit product per multiply — `P = (64+f_a)×(64+f_b)` kept at full
precision through the row accumulate — and re-encodes state once per matvec step holds
≤ 1% mean relative error versus FP64 through 256 feedback cycles. The Python model reports
a final error of 0.3838% for the neutral regime. The C model (`nfe_matvec.c`) reports
0.383% mean error on a single-pass 8×8 matvec.

**RTL finding:** `horus_nfe.v` provides no PATH_FAST datapath. The MUL opcode
(`op_sel = 2'b10`, lines 494–536) computes the hidden-bit product at line 502:

```
scale_reg = {1'b1, m_a} * {1'b1, m_b};          // 14-bit product
```

and immediately truncates to a 6-bit mantissa field (lines 530–532):

```
computed = {res_sign, exp_sum[EXP_W-1:0],
            scale_reg[13] ? scale_reg[12:7]       // 6-bit f_result
                          : scale_reg[11:6]};
```

`scale_reg` is a local register. No `op_sel` value exposes it on any output port.

**VERDICT: NOT CONFIRMED — ARCHITECTURAL GAP**

The 0.3838% figure cannot be confirmed or falsified by this RTL because the path it
describes does not exist in hardware.

**The C and Python model agreement is not independent confirmation.** Both
`nfe_matvec2.c` (PATH_FAST branch) and `second_source_chain.py` lines 109–112
(`nfe_fast_mac`) implement the same software decision: use the full integer product P
without truncation. They agree because they share the unverified assumption that this
full-mantissa product is available to the accumulator. The RTL is the only true second
source, and it shows that assumption is not met. Confirming P1 requires either exposing
`scale_reg` on an output port or adding a fused-MAC accumulate opcode to `horus_nfe.v`.

---

## P2 — PATH_NFE / RTL, neutral regime, onset ≤ 10 cycles, final ≈ 20%

**Prediction (second_source_chain.py, `step_nfe`, lines 135–148):** intermediate 6-bit
quantization of every product before the row accumulate causes divergence past 1% mean
relative error within approximately 5 cycles, with a final error near 20% at depth 256.

**RTL result** (SSC_CHAIN_TRACE.csv, neutral regime):

| Metric | Predicted | Measured |
|--------|-----------|----------|
| Divergence onset (first cycle > 1%) | ≤ 5 cycles (tolerance ≤ 10) | cycle 2 (err = 1.2621%) |
| Final mean rel err (cycle 256) | ≈ 20% | 23.9465% |
| Cumulative sat events | — | 0 |
| Cumulative floor events | — | 0 |

**VERDICT: CONFIRMED** (onset 2 ≤ tolerance 10; final 23.9% consistent with ~20% prediction)

**Attractor observation.** The golden path converges to a single value — 1.6436 for all
8 components — by cycle 11 (component spread drops to 0.00 at cycle 11,
SSC_CHAIN_TRACE.csv). This is the Perron–Frobenius dominant eigenvector of A; all
components converge because A is row-stochastic with positive entries. The value 1.6436
is a property of this specific random matrix and is not a format constant.

The RTL DUT drifts in the opposite direction. It reaches the NFE codeword for 1.25
(E=32, f=16) at cycle 52 (SSC_CHAIN_TRACE.csv) and remains there through cycle 256.
The 23.9465% gap at cycle 256 is the distance between the NFE-quantized fixed point
(1.25) and the FP64 eigenvector (1.6436).

**Open question — why cycle 2 rather than ~5.** The RTL onset is earlier than the
Python PATH_NFE model's typical onset for this regime. A plausible cause is that the
RTL quantizes the fractional product at the bit positions described by lines 530–532,
which may differ from the Python model's rounding behavior at `round((m − 1.0) * 64)`
(`second_source_chain.py` line 76). This difference has not been characterized further
and is flagged as an open question, not a conclusion.

---

## P3 — Both paths, expansive regime, final error ≈ 95%

**Prediction (second_source_chain.py):** once the expansive chain reaches the OVF cliff,
both PATH_FAST and PATH_NFE converge to approximately 95% mean relative error, dominated
by saturation events — the cliff behavior is format-level, not path-level.

**RTL result** (SSC_CHAIN_TRACE.csv, expansive regime):

| Metric | Predicted | Measured |
|--------|-----------|----------|
| Final mean rel err (cycle 256) | ≈ 95% (tolerance [47.5%, 190%]) | 93.5011% |
| Cumulative sat events | > 0 | 136 (first at cycle 240) |
| DUT state at cycle 256 | saturation | 4,261,412,864 = NFE(E=63, f=63) = 4.26×10⁹ |

**VERDICT: CONFIRMED** (93.50% within the [47.5%, 190%] band; 136 saturation events
confirm the OVF cliff was reached)

---

## Contractive Regime — Informational

Not covered by any of the three predictions above. The contractive chain
(row sums = 0.90) shows a secondary NFE resolution effect.

The DUT state stabilizes at ≈ 2.39×10⁻⁹ beginning at cycle 194
(SSC_CHAIN_TRACE.csv). The mechanism: once state exponent E_y reaches
approximately 3, the product exponent `exp_sum = E_y + E_A − 32` wraps below zero
(`exp_sum[7] = 1`, `horus_nfe.v` lines 516–520), triggering UNDERFLOW on every
product. The row accumulate then sums 8 UNDERFLOW floor values, re-encodes to the
same scale, and the state is trapped.

The golden path continues decaying and reaches 2.48×10⁻¹² at cycle 256 (same row of
SSC_CHAIN_TRACE.csv), giving a final mean relative error of 98,043%. This large number
reflects NFE resolution, not saturation: `cum_sat = 0` and `cum_floor = 0` throughout
(the stall occurs inside the representable range, above the E=0, f=0 floor sentinel).

---

## Tooling Note

Icarus Verilog passes the integer expression `e - EXP_BIAS` to `$pow` as an unsigned
32-bit value when the result is negative (e.g. E=28: `28−32 = −4` is promoted to
4,294,967,292, giving `$pow(2.0, 4294967292) = Inf`). The fix is
`$pow(2.0, $itor(e) − $itor(EXP_BIAS))`; all NFE decode calls in
`tb_second_source_chain.v` use this form. This does not affect `horus_nfe.v`, which
uses integer exponent arithmetic throughout.

---

## Implication

P1 converts the matvec-breakeven question — whether a PATH_FAST mode (bypassing the
6-bit product quantization in lines 530–532) is worth its gate cost against the
reduction in deep-chain error — from a software modeling question into a hardware
design question. The answer requires synthesizing a fused-MAC accumulate path (keeping
`scale_reg` at 14 bits through the row summation before re-encoding) against a real
standard-cell library and comparing GE cost against the 0.383% → ~24% error gap
identified here. That synthesis is deferred to a follow-up investigation.

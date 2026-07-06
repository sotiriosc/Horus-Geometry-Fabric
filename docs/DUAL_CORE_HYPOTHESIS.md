# DUAL-CORE HYPOTHESIS

**Repository**: Horus-Geometry-Fabric  
**Campaign**: Dual-mode E4M3/E3M6+block compact core  
**Extends**: `docs/COMPACT_NFE_VERDICT.md`, `docs/AREA_COMPARISON.md`  
**Date pre-registered**: 2026-07-05  
**Status**: Pre-registered — criteria binding before any RTL or synthesis.

---

## Background

Standing verdicts:
- E4M3 + block-exponent normalization wins inference
  (`docs/CAMPAIGN_OVERVIEW.md §7`; `docs/FORMAT_COMPARISON.md` Arena C).
- E3M6 + shared block exponent is the conservative compact accumulation format at
  10.75 effective bits (`docs/COMPACT_NFE_VERDICT.md` K1/K2/K3 PASS).

The compact result makes fusion more plausible than the original NFE-13 pairing:
per-element exponent fields are now 4-bit (E4M3) vs 3-bit (E3M6), and the mantissa
array is 7×7 (E3M6 hidden+6) with a natural 4×4 subarray (E4M3 hidden+3)
that is active in inference mode while the outer partial products are gated.

**Known risk, pre-registered**: fused dual-mode datapaths often exceed the sum
of their parts once mode-muxing, dual rounding/sentinel semantics, and control
overhead land. This experiment is intentionally losable.

---

## Format Definitions

### E3M6 (accumulation mode, mode=0)

Format: 1 sign + 3 exponent + 6 fraction = **10 bits** per element.

```
[9]   Sign S     0=positive, 1=negative
[8:6] Exp  E     3-bit biased exponent, bias = 4  (= 2^(3−1))
                 Stored range 0..7, actual E = stored − 4.
[5:0] Frac f     6-bit fraction; value = (1 + f/64) × 2^(stored_E − 4)
```

Special values:
- `e=0, f=0`: zero (architectural floor sentinel)
- `e=0, f≠0`: subnormal — value = 2^(1−4) × f/64 = f/(64×8); RTL multiplier
  flushes subnormal operands to zero (consistent with NFE-13 convention).
- `e=7, f=63`: saturation sentinel (max finite ≈ 15.875)
- No NaN, no Inf.

Representable range: ≈[0.125, 15.875]. Extended via shared block exponent.

Per-element exponent bias convention: `bias = 2^(n_exp − 1)` (matches NFE-13,
matches `compact_nfe.py` `enm6_enc`/`enm6_dec` with n=3).

Used with **horus_norm_v2** shared block exponent: one 6-bit signed block
exponent per 8 elements, chosen by max magnitude.
Effective bits per element: 10 + 6/8 = **10.75**.

### E4M3 (inference mode, mode=1)

Format: 1 sign + 4 exponent + 3 fraction = **8 bits** per element.

```
[7]   Sign S     0=positive, 1=negative
[6:3] Exp  E     4-bit biased exponent, bias = 7
                 Stored range 0..15
[2:0] Frac f     3-bit fraction
```

Special values (OCP 8-Bit FP Spec v1.0, E4M3FN variant):
- Subnormal: `e=0`, value = (f/8) × 2^(1−7)
- Normal: `e=1..15`, value = (1 + f/8) × 2^(e−7)
- NaN: `s.1111.111` (all-ones exp and frac). No Inf.
- Max finite: `0.1111.110` = 1.75 × 2^8 = 448.

RTL source of truth: `rtl/fp8_e4m3_mul.v`; Python reference: `format_zoo.py
fp8_e4m3_enc`/`fp8_e4m3_dec`.

---

## Exponent-Path Unification

The design challenge: E3M6 has a 3-bit per-element exponent (bias=4) and E4M3
has a 4-bit per-element exponent (bias=7). A single shared adder must handle both.

**Unified representation**: In the dual core, both operands use a 5-bit effective
exponent field. For E3M6, the 3-bit stored exponent is zero-extended to 5 bits
(max value 7). For E4M3, the 4-bit stored exponent is zero-extended (max value
14 for normal, 15 for NaN-exponent). A mode-selected bias (4 vs 7) is subtracted.

**Bias subtraction**: A single 5-bit subtractor with mode-selected constant.
```
e_r = (ae_a + ae_b + P_msb [+ rnd_carry_e4m3]) − bias_sel
bias_sel = 4 (E3M6 mode) or 7 (E4M3 mode)
```
Both biases fit in 5 bits; the result fits in a signed 7-bit register.

**Where fusion lives or dies**: The exponent mux adds ~4 LUT levels. The rounding
logic (RNE for E4M3, truncation for E3M6) adds ~3 LUT levels. The sentinel logic
adds ~3 LUT levels. Total mode-overhead estimate: ~10 LUT levels beyond the
mantissa array. If synthesis correctly gate-optimizes the 7×7 array in E4M3 mode,
the overhead is bounded.

---

## Mantissa Array Architecture

The shared 7×7 mantissa array is the key fusion element.

**E3M6 mode** (mode=0): both operands use the full 7-bit mantissa `{1, f[5:0]}`.  
Product P ∈ [4096, 16129], 14 bits. Normalization at P[13]. Mantissa result is
P[12:7] (P_msb=1) or P[11:6] (P_msb=0). No rounding (truncation, matching
NFE-13 convention in `nfe13_mul.v`).

**E4M3 mode** (mode=1): operands use 7-bit representation `{0,0,0, H, f[2:0]}`
where H=0 for zero/subnormal, H=1 for normal. Bits [6:4] are **explicitly gated
to 0** via AND with `hi_en = ~mode_r`. Product active range P[7:0] ∈ [0, 225].
Normalization at P[7]. Mantissa result is P[6:4] (P_msb=1) or P[5:3] (P_msb=0),
with round-to-nearest-even on the 3-bit result (matching `fp8_e4m3_mul.v`).

**Gating boundary**: The explicit gating uses:
```verilog
wire hi_en      = ~mode_r;                  // registered mode
wire mant_a6    = hi_en;                    // E3M6 hidden=1; E4M3=0 (gated)
wire [1:0] ma54 = {f_a_6[5] & hi_en,       // E3M6 f[5], E4M3=0 (gated)
                   f_a_e3m6[4] & hi_en};   // E3M6 f[4], E4M3=0 (gated)
```

Synthesis **cannot flatten** these AND gates because `hi_en` is a non-constant
primary input to each cell. The gating boundary is synthesis-visible and will
produce distinct gated cells in the netlist.

**Why bit[3] is a mux, not a gate**: In E3M6 mode, mant[3] = f[3] (a fraction
bit). In E4M3 mode, mant[3] = H_e4m3 (the E4M3 hidden bit). These carry
structurally different signals; a mux is required and synthesis will implement it
as a 2:1 MUX cell (not a power gate). Bits [2:0] are naturally shared (E3M6
f[2:0] and E4M3 f[2:0] both occupy the same positions in the codeword).

---

## Pre-registered Kill Criteria

> **K1** (area benefit): dual-core area < 85% of the summed area of a standalone
> E4M3 core and a standalone E3M6 core.
>
> `dual_area < 0.85 × (E4M3_area + E3M6_area)`
>
> E4M3 standalone area: **857.1 µm²** (fp8_e4m3_mul, 121 cells; from
> `docs/AREA_COMPARISON.md`, Sky130 HD TT 025C 1v80, reproduced identically).
> E3M6 standalone area: synthesized fresh as `rtl/horus_e3m6_core.v` in Task 4
> (do not substitute NFE-13's 1611.5 µm² — E3M6 has 3-bit exponent, materially
> cheaper exponent adder).
>
> K1 **FAILS** if the dual core costs ≥ 85% of the sum. In that case the fallback
> architecture (two separate cores with a shared normalizer) is the deliverable.

> **K2** (mode overhead bounded): dual-core area ≤ 1.30× the standalone E3M6
> core area.
>
> `dual_area ≤ 1.30 × E3M6_area`
>
> Rationale: E3M6 is the larger format (6-bit mantissa, 7×7 array). Adding E4M3
> inference mode should not cost more than 30% overhead over the larger format.
> If K2 fails, the dual core is area-pathological even in absolute terms.

> **K3** (inference-mode gated fraction ≥ 25%): when synthesis applies the
> hi_en gating structure, the gated cells — those driven by hi_en and gated to 0
> in E4M3/inference mode — must account for ≥ 25% of the total dual-core area.
>
> Measured as: `gated_area / dual_core_area ≥ 0.25`
>
> gated_area is estimated by synthesizing the dual core with `hi_en` forced to 1
> (always E3M6) vs the default and taking the area difference. This is the area
> proxy for dynamic power reduction in inference mode — labeled explicitly as
> an area proxy; no dynamic power claim is made.

**Fallback finding**: if K1 or K2 fails, the finding is:
- Quantified cost of fusion: dual_area − E3M6_area (absolute overhead)
- Quantified cost ratio: dual_area / (E4M3_area + E3M6_area)
- Proposed fallback: separate E4M3 core (existing `rtl/fp8_e4m3_mul.v`) +
  standalone E3M6 core (`rtl/horus_e3m6_core.v`) + shared `horus_norm_v2` —
  area = E4M3_area + E3M6_area (no sharing), normalizer cost unchanged.

**Power claims**: none. Sky130 synthesis does not produce dynamic power estimates.
All power-related reporting uses "area proxy" language only.

---

## Pre-registered Predictions

1. **E3M6 standalone area** will be materially less than NFE-13 (1611.5 µm²).
   Prediction: 1300–1500 µm² (shorter exponent adder saves ~100–300 µm²).
   If E3M6 ≈ 1400 µm²: K1 threshold = 0.85×(857+1400) = 0.85×2257 = 1918 µm².

2. **K1 pass probability**: moderate (~50%). The 7×7 mantissa array is the
   dominant area element and is shared. The mode overhead (mux trees, dual
   rounding, dual sentinel logic) may consume 10–20% of the E3M6 core area.

3. **K2 pass probability**: moderate-high (~65%). The E4M3 mode should not
   add more than 30% overhead if the mantissa array is truly shared.

4. **K3 pass probability**: high (~85%). The gated outer partial products
   correspond to roughly (49−16)/49 = 67% of the partial product count, and
   partial products are a substantial fraction of multiplier area.

5. **Chain of failure**: fusion most likely fails K1 via mode-overhead, not via
   mantissa cost. If mode-overhead (muxes + dual rounding + dual sentinels) is
   > 15% of E3M6 area, K1 may fail even with correct gating.

---

## What This Does Not Claim

- **No energy measurement**: power proxy via gated area fraction only.
- **No timing**: synthesis closed without timing constraints; relative area
  ordering may change under clock constraints.
- **No multiplier savings vs NFE-13**: the multiplier is unchanged from NFE-13.
  The 0.59× BF16 area ratio (`docs/AREA_COMPARISON.md`) applies to E3M6 core
  identically (same 7×7 mantissa array). The dual core does not improve this.
- **No MX-spec compliance**: block size (8), mantissa width (6 bits for E3M6),
  and block-exponent encoding differ from OCP MX formats.
- **Stated relationship to MX**: the E3M6+block format structurally resembles
  MXFP8 (shared block exponent per N elements) but is not spec-compliant.
  The E4M3 mode is OCP-compliant for the multiply operation.

---

## Files

| File | Role |
|------|------|
| `docs/DUAL_CORE_HYPOTHESIS.md` | This document (pre-registration, binding) |
| `sim/dual_core_model.py` | Python bit-exact model; gates RTL |
| `rtl/horus_e3m6_core.v` | Standalone E3M6 multiplier (K1/K2 baseline) |
| `rtl/horus_dual_core.v` | Dual-mode core under test |
| `tb/tb_horus_e3m6_core.v` | Testbench: 1000/1000 golden vectors + edges |
| `tb/tb_horus_dual_core.v` | Testbench: 1000/1000 per mode + mode-switch |
| `sim/synth_e3m6_core.ys` | Synthesis script for E3M6 standalone |
| `sim/synth_dual_core.ys` | Synthesis script for dual core |
| `docs/DUAL_CORE_RESULTS.md` | Results, four-way table, K1/K2/K3 verdict |

---

*Pre-registration complete. Criteria binding. Experiment begins.*

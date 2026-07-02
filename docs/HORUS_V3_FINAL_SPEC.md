# HORUS v3 Final Specification

**Document type:** Gold Master Architectural Specification  
**Status:** FINAL — all claims validated by HBS-11 through HBS-14  
**Authority:** Measured simulation results only. No speculative claims.  
**Version:** 1.0 · 2026-07-02  

---

## 3.1 System Overview

### 3.1.1 Native Fractional Engine — 13-bit Format

HORUS v3 operates on 13-bit NFE codewords with the following fixed-point encoding:

```
Bit layout:
  [12]   [11:6]           [5:0]
   S    E[5:0] (stored)   f[5:0] (fraction)

Value semantics:
  V = (−1)^S  ×  2^(stored_E − 32)  ×  (1 + f/64)

Bias: 32  (stored_E = 32 → actual exponent = 0, value ≈ 1.0)
Hidden bit: always 1 (no denormals; no NaN; no ±Inf)
Exponent range: stored_E = 0..63 → actual = −32..+31
Fraction range: f = 0..63 → mantissa = 1.000..1.984375
```

**Canonical constants (RTL-verified):**

| Symbol | Codeword | Value | stored_E | f |
|---|---|---|---|---|
| NFE_FLOOR | `0x000` | 0 (sentinel) | 0 | 0 |
| NFE_HALF | `0x7C0` | 0.5 | 31 | 0 |
| NFE_ONE | `0x800` | 1.0 | 32 | 0 |
| NFE_TWO | `0x840` | 2.0 | 33 | 0 |
| NFE_MAXPOS | `0x1FFF` | ≈ 4.26×10⁹ | 63 | 63 |

### 3.1.2 Arithmetic Envelope (HBS-12/13 Validated)

The 64-value exponent field is partitioned into four discrete execution phases:

```
stored_E:  0         15 | 16              47 | 48        63
           [  COLLAPSE  ][    STABLE (50%)   ][  SATURATION ]
                        ↑                   ↑
                   Collapse cliff      Saturation cliff
                   (E=15↔16)           (E=47↔48)
```

| Phase | Range | UF rate (self-MUL) | OVF rate (self-MUL) | Information |
|---|---|---|---|---|
| Stable | 16–47 | 0% | 0% | Preserved |
| Collapse | 0–15 | 100% at E=15 | 0% | Discarded (MUL) |
| Saturation | 48–63 | 0% | 100% at E=48 | Bounded cap |

**Boundary geometry:** Both cliffs are abrupt (CLIFF geometry, no gradual zone). Confirmed HBS-13F. One exponent step crosses from stable to terminal behavior in both directions.

**Natural anchor:** stored_E = 32 (actual_E = 0, value ≈ 1.0). Equidistant from both cliffs: 32 scale-down steps to collapse, 32 scale-up steps to saturation.

**True safe self-MUL floor:** stored_E = 24. Self-MUL at E=24 produces E_result = 16 (minimum stable), confirmed HBS-13.

### 3.1.3 Policy Layer Behavior (HBS-11 Validated)

The 3-bit `mode_tag` field selects the accumulator policy applied after each arithmetic operation. Policy is applied to `accum_reg` only — it does not modify the `result` output.

| mode_tag | Name | Effect on accum_reg | Effect on result |
|---|---|---|---|
| `3'b000` | Standard | `accum_reg += computed` | None (= computed) |
| `3'b001` | Bias-Corrected | `accum_reg += computed + BIAS_LUT[e_a]` | None |
| `3'b010` | Pre-Scaled | `accum_reg += {sign, E−1, frac}` if E>0 | None |
| `3'b011` | Safe-Accumulation | `accum_reg = min(accum_reg + computed, 0xFFFFFFFF)` | None |
| `3'b1xx` | Reserved | Treated as Standard | None |

**Default state:** BIAS_LUT is initialized to all-zero. With default LUT, MODE_001 is identical to MODE_000 for both `result` and `accum_out`.

### 3.1.4 System Integration Behavior (HBS-14 Validated)

Results across 2,643 simulation events, 4 policy modes, 6 test configurations:

- **Result invariance:** 0 mismatches across 384 cross-mode tests. `result` is MODE-INVARIANT.
- **Flag invariance:** `underflow_flag` and `exp_ovf_flag` are identical across all modes for identical inputs.
- **Boundary confirmation:** E=15↔16 and E=47↔48 cliffs confirmed policy-invariant.
- **Long-horizon stability:** No drift or entropy decay over 2,000-cycle sustained operation. Stable-phase entropy: 5.990 bits (≈ max 6.0 bits).
- **Consistency score:** 5/5 system-level checks CONSISTENT.

---

## 3.2 Layered Architecture Model

HORUS v3 has three architecturally distinct layers. Each layer has a defined scope of operation, a defined set of invariants, and a defined interface to adjacent layers.

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 3 — Execution Controller                             │
│  pgate_ctrl depth gating · host_tile_depth budget           │
│  Execution horizon: 1..63 MACs per tile                     │
├─────────────────────────────────────────────────────────────┤
│  Layer 2 — Accumulation System                              │
│  mode_tag policy decoder · accum_reg (32-bit)               │
│  4 policies: STD / BIAS / PRSC / SAFE                       │
├─────────────────────────────────────────────────────────────┤
│  Layer 1 — Arithmetic Core                                  │
│  horus_nfe · 13-bit NFE · MUL / ADD / SUB / NOP             │
│  Exponent physics · UF/OVF · Thoth Rollover                 │
└─────────────────────────────────────────────────────────────┘
```

### Layer 1 — Arithmetic Core

**Module:** `horus_nfe`  
**Width:** 13-bit input/output operands; 20-bit intermediate product; 7-bit mantissa adder  
**Operations:** MUL (hidden-bit multiply + normalize), ADD_FRAC (fraction add + Thoth Rollover), SUB_FRAC (fraction subtract + Guard-B normalize), NOP

**Exponent physics (all claims RTL-verified and HBS-validated):**

| Event | Condition | Result | Flag |
|---|---|---|---|
| MUL normal | 16 ≤ E_a+E_b−32 ≤ 63 | Valid codeword | None |
| MUL underflow | E_a + E_b − 32 < 0 | NFE_FLOOR (0x000) | `underflow_flag` |
| MUL overflow | E_a + E_b − 32 > 63 | NFE_MAXPOS (0x1FFF) | `exp_ovf_flag` |
| ADD Thoth Rollover | f_a + Δ ≥ 64 | E+1, f=mant_sum[5:0] | `rollover_flag` |
| ADD OVF | E=63 and rollover | NFE_MAXPOS | `exp_ovf_flag` |
| SUB Guard-A | f_a ≥ Δ | E unchanged, f decremented | None |
| SUB Guard-B | f_a < Δ, E > 0 | E−1, f renormalized (2-cycle) | None |
| SUB floor | E=0, f_a < Δ | NFE_FLOOR | `underflow_flag` |

**Boundary cliff physics (HBS-12/13):**
- Collapse cliff: stored_E 16 → 15 is a single-step discontinuous transition. At E=15, self-MUL produces E_result = 15+15−32 = −2 (UF). At E=16: E_result = 0 (valid).
- Saturation cliff: stored_E 47 → 48 is a single-step discontinuous transition. At E=48, self-MUL produces E_result = 64 (OVF). At E=47: E_result = 62 (valid stable).
- Both cliffs have CLIFF geometry (no gradual zone, HBS-13F).

**SUB Guard-B pipeline note:** Guard-B requires a 2-cycle latency. Consumer must insert one NOP bubble between Guard-B issue and the first read of `result`.

### Layer 2 — Accumulation System

**Module:** `horus_nfe` (policy decoder inline), `horus_system` (wrapper)  
**Accumulator:** 32-bit `accum_reg`, cleared by `accum_clr`, readable as `accum_out` (one-cycle latency)  
**Policy decoder:** Inline in `horus_nfe` sequential always block; applies per-cycle before NBA update

**Policy semantics:**

```
// Applied each cycle when accum_en=1 and accum_clr=0
case (mode_tag)
  000 STD:  accum_word = computed
  001 BIAS: accum_word = computed + BIAS_LUT[e_a]
  010 PRSC: accum_word = (E > 0) ? {sign, E−1, frac} : computed
  011 SAFE: accum_reg ← saturate33(accum_reg + computed)
  default:  accum_word = computed
endcase

accum_reg ← accum_reg + accum_word   (NBA, except for SAFE path)
accum_out ← accum_reg                (one-cycle latency registered output)
```

**Policy applicability boundary (HBS-11/14 confirmed):**
The policy decoder path is entered AFTER `result <= computed` is assigned. There is no feedback from the policy path to `result`. The accumulator policy is strictly post-arithmetic.

**Accumulator sampling:** One NOP cycle required after final accum operation before sampling `accum_out` (accum_out mirrors accum_reg with one-cycle latency, RTL comment §596).

### Layer 3 — Execution Controller

**Module:** `horus_pgate_ctrl` (power-proportional memory gating controller)  
**Function:** Compares running MAC count (`op_count_reg`) against host-specified tile budget (`host_tile_depth`). Issues combinational `accum_en_gated` signal to Layer 2.

**Gate rule:**
```
accum_en_gated = (op_count_reg < {10'd0, host_tile_depth})

host_tile_depth = 0:      gate CLOSED  (unsigned 0 < 0 is false — power-off state)
host_tile_depth = N (1–63): gate open for exactly N MACs, then closes
```

**Important:** `host_tile_depth = 0` closes the gate. "Unlimited" operation is NOT supported; the maximum tile budget is 63 MACs. To run longer sequences, the host must periodically issue `accum_clr` to reset `op_count_reg` and reopen the gate.

**Counter:** `op_count_reg` increments on each gated MAC (non-NOP operation with `accum_en=1`). Reset by `accum_clr`. Exposed as `op_count` output port.

**Thoth Rollover interaction:** The `rollover_flag` is a one-cycle pulse from Layer 1 that the execution controller may observe to detect ADD-induced exponent increments. The controller does not modify its gating behavior in response to rollover — that is a compiler/scheduler responsibility.

**`accum_full` signal:** Asserted on the same cycle as the last valid MAC when `op_count_reg >= host_tile_depth − 1`. Used by host to detect tile completion without polling `op_count`.

---

## 3.3 Integrity Proof

### 3.3.1 HBS-14 Consistency Result

HBS-14 achieved a **5/5 contradiction-free classification** across all system layers and all four policy modes. The test corpus comprised:

- 384 direct cross-mode result comparisons (subtests 14A, 14E)
- 500 random-mode cycles with 444 unique operands observed in multiple modes (14B)
- 4 cross-boundary sequences with mid-chain mode switches (14C)
- 1,500 long-horizon observations over 2,000 simulation cycles (14D)
- 5 systolic array validation tests (14G)

### 3.3.2 No Inter-Layer Contradictions

**Layer 1 ↔ Layer 2:** The policy decoder in Layer 2 operates strictly on the accumulator path. The `result` output is assigned unconditionally from `computed` before the policy case statement. No feedback path exists. Verified: 0 result mismatches across 384 tests.

**Layer 1 ↔ Layer 3:** The execution controller in Layer 3 gates `accum_en` but does not modify any signal on the arithmetic compute path. MUL, ADD, and SUB operations proceed identically regardless of gate state; only the accumulation of their results is affected. The `result` output is valid on every clock regardless of gate state.

**Layer 2 ↔ Layer 3:** The controller increments `op_count_reg` on every gated accumulation (when `gated_accum_en = accum_en && accum_en_gated` and `op_sel != NOP`). The counter and accumulator clear simultaneously on `accum_clr`. Atomicity is guaranteed by shared clock-edge update.

### 3.3.3 No Mode Interference

Verified in HBS-14B: 444 operands observed under multiple modes, 0 result interference events. HORUS v3 has no per-mode state register and no cross-cycle mode dependency. Mode takes effect for exactly one cycle and leaves no residue.

### 3.3.4 No Hidden State Coupling

The complete state of HORUS v3 at any clock edge is fully described by:

```
State = {
  result_reg      [12:0]  — last computed result
  accum_reg       [31:0]  — running accumulator
  accum_out       [31:0]  — registered mirror of accum_reg (1-cycle latency)
  op_count_reg    [15:0]  — MAC counter
  accum_full_reg  [1:0]   — tile budget exhaustion flag
  sub_p1_*        [24:0]  — SUB Guard-B pipeline registers (frac + e_pre + shift + flags)
  BIAS_LUT        [64×13] — bias correction table (read-only during operation)
}
```

No hidden state. No undocumented registers. The system is fully observable through the defined output ports and fully reproducible given identical inputs and initial state.

---

## 3.4 System Invariants

The following invariants hold unconditionally for HORUS v3 as implemented and validated. They are not design goals — they are proven properties of the measured system.

**Invariant I-1: Arithmetic Boundaries Are Deterministic**
The collapse boundary (E=15↔16) and saturation boundary (E=47↔48) are fixed properties of the exponent arithmetic `E_result = E_a + E_b − 32`. They cannot be changed by software, policy configuration, tile depth, or any external control signal. They are invariant under all operating conditions.

**Invariant I-2: Policy Layer Does Not Modify Arithmetic Correctness**
For any input pair (op_a, op_b, op_sel), the `result` output is identical for all values of `mode_tag`. The policy multiplexer is entered after `result` is assigned. Verified across 384 direct comparisons with zero exceptions.

**Invariant I-3: Hardware Flags Are Policy-Invariant**
`underflow_flag` and `exp_ovf_flag` are set by the arithmetic core unconditionally, before the policy decoder path. They pass through all policy modes unchanged. Verified: UF events STD=8, SAFE=8 for identical stimuli; OVF events STD=5, SAFE=5.

**Invariant I-4: Depth Gating Does Not Alter Exponent Physics**
The `host_tile_depth` parameter and `op_count_reg` counter affect only whether MAC results are accumulated into `accum_reg`. The arithmetic result `result` is computed identically regardless of gate state. Exponent boundaries are invariant under depth gating.

**Invariant I-5: System Behavior Is Fully Reproducible**
Given identical (rst_n, op_a, op_b, op_sel, mode_tag, accum_en, accum_clr, host_tile_depth) sequences, HORUS v3 produces identical (result, accum_out, rollover_flag, underflow_flag, exp_ovf_flag, op_count, accum_full) sequences without exception. No stochastic elements exist in the RTL.

**Invariant I-6: Failure Modes Are Boundary-Localized**
UF events occur exclusively when E_a + E_b < 32. OVF events occur exclusively when E_a + E_b > 95 (for MUL). No failure mode spreads, propagates, or accumulates across arithmetic boundaries. Sustained operation in the stable band (E=16..47) produces zero UF/OVF events regardless of duration. Confirmed: stable-phase UF=0%, OVF=0% over 500 consecutive observations (HBS-14D).

**Invariant I-7: Mode State Does Not Persist**
`mode_tag` is sampled per-cycle with no memory. Changing `mode_tag` on cycle N does not affect the arithmetic outcome of any cycle before N or the `result` of cycle N. It affects only the accumulator contribution of cycle N.

---

## 3.5 Known Limitations and v4 Directions

### Documented Limitations

| Limitation | Source | Impact |
|---|---|---|
| Tile budget maximum = 63 MACs | pgate_ctrl 6-bit counter | Long sequences require periodic accum_clr |
| host_tile_depth=0 closes gate | pgate_ctrl unsigned arithmetic | "Unlimited" mode not available; gate closed at 0 |
| BIAS_LUT uncalibrated | Initial 13'd0 LUT | MODE_001 has null effect until QAT calibration |
| ADD Thoth Rollover non-reversible | HBS-12F: 0% reversibility | E+1 operations are one-way within a tile window |
| SUB Guard-B 2-cycle latency | Pipeline register insertion | Consumer must insert NOP bubble |
| No denormals, NaN, or Inf | Design intent | Floor (0x000) and MaxPos (0x1FFF) are sentinels, not IEEE-754 special values |

### v4 Directions (HBS-13/14 Identified)

| Direction | Motivation |
|---|---|
| Tile budget expansion (>6 bits) | Support longer inference windows without periodic clr |
| Saturating right-shift normalization stage | Prevent accum_reg growth in deep GEMM tiles |
| BIAS_LUT population from QAT calibration pass | Enable MODE_001 cancellation drift mitigation |
| pgate_ctrl comment fix (tile_depth=0 semantics) | Eliminate interface confusion; document as power-off |
| Encoding extension for collapse rescue | Reduce information loss at E=15 ADD boundaries |

---

## Appendix: Validated HBS Benchmark Summary

| Suite | DUT | Key Finding |
|---|---|---|
| HBS-11 | horus_system (all modes) | Policy layer validated; applicability boundary defined |
| HBS-12 | horus_nfe (mode_tag=000) | Arithmetic envelope mapped; E=15↔16, E=47↔48 cliffs found |
| HBS-13 | horus_nfe (mode_tag=000) | Cliff geometry confirmed (CLIFF, not gradual); ADD rescue at E=15,f≥32 |
| HBS-14 | horus_system + systolic_array (all modes) | End-to-end consistency: 5/5 checks consistent, 0 result mismatches |
| Total observations | — | > 10,000 simulation events across HBS-11..14 |

---

## Related Documents

| Document | Content |
|---|---|
| `docs/EXECUTION_MAPPING.md` | Formal execution contract; phase-space semantics table |
| `docs/HORUS_SYSTEM_UTILIZATION_BLUEPRINT.md` | Runtime strategy; mode selection guide |
| `docs/HORUS_ARITHMETIC_ENVELOPE.md` | Full envelope; compiler/QAT constraints |
| `docs/HORUS_BOUNDARY_GAP_ANALYSIS.md` | Boundary geometry; recovery characterization |
| `docs/HORUS_END_TO_END_SYSTEM_REPORT.md` | HBS-14 principal report |
| `docs/EXECUTION_POLICY.md` | Policy mode specification; HBS-11 results |
| `docs/ARCHITECTURE_PHILOSOPHY.md` | Design philosophy; layered model context |
| `rtl/horus_nfe.v` | Arithmetic core (Layer 1) |
| `rtl/horus_pgate_ctrl.v` | Execution controller (Layer 3) |
| `rtl/horus_system.v` | Integration wrapper |

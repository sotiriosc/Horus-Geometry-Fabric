# HORUS v3 System Utilization Blueprint

**Document type:** Operational Deployment Guide  
**Authority:** HBS-11 through HBS-14 validated results  
**Version:** 1.0 · 2026-07-02  
**Status:** GOLD — derived from measured system behavior only  

---

## Preamble

This blueprint defines how the 3-bit `mode_tag` system is deployed in real inference execution, how a scheduler selects modes based on workload region, and how the four arithmetic execution phases (Stable, Transition, Collapse, Saturation) map to runtime strategy decisions.

The central architectural insight:

> **The 3-bit mode system enables distributed execution control without central bottlenecking by embedding computation policy directly into arithmetic flow.**

`mode_tag` travels in-band with each operand. There is no separate control bus, no mode register, no synchronization protocol, and no pipeline stall for mode switches. The policy decoder operates in a single cycle inline with the arithmetic result. This makes mode-based computation policy zero-overhead at the hardware level.

---

## 1. Mode Function Map

| mode_tag | Name | RTL Constant | Primary Function | Calibration Required |
|---|---|---|---|---|
| `3'b000` | Standard | `MODE_STANDARD` | Default arithmetic accumulation. Baseline MAC operation. `accum_reg += computed`. | No |
| `3'b001` | Bias-Corrected | `MODE_BIAS_CORR` | Bias-space correction of cancellation residuals. Adds per-exponent-band offset from BIAS_LUT before accumulation. `accum_reg += computed + BIAS_LUT[e_a]`. | **Yes** — requires QAT pass to populate BIAS_LUT |
| `3'b010` | Pre-Scaled | `MODE_PRE_SCALED` | Exponent preconditioning / accumulator range management. Decrements stored_E by 1 before accumulation (effective ÷2 in magnitude), preventing `accum_reg` saturation under large-operand deep chains. | No |
| `3'b011` | Safe-Accumulation | `MODE_SAFE_ACCUM` | Saturation protection / bounded accumulation. 33-bit unsigned add with clamp at `0xFFFFFFFF`. Prevents modular wrap-around artifacts from outlier MAC results in long-running accumulators. | No |

### 1.1 Mode Equivalences Under Default Hardware State

With `BIAS_LUT` initialized to all-zero (default RTL initial block):
- `MODE_001 ≡ MODE_000` — both produce identical `result` and `accum_out`
- This is a verified property (HBS-14: STD final accum 57,100 = BIAS final accum 57,100)

The bias-correction capability is dormant until activated by a QAT calibration pass that populates the LUT with measured per-exponent residuals from Test 9 (cancellation drift manifold).

### 1.2 Mode Effects on accum_out (Measured, HBS-14A)

| Mode | Final accum_out (32 mixed-zone ops) | Δ vs STD |
|---|---|---|
| STD | 57,100 | — |
| BIAS | 57,100 | 0% (LUT=0) |
| PRSC | 55,692 | −2.5% |
| SAFE | 57,100 | 0% (no 32-bit overflow) |

MODE_PRSC reduction of ~2.5% reflects the per-codeword E−1 transformation applied to each accumulated value. The exact ratio depends on the exponent distribution of the workload.

---

## 2. Runtime Strategy

### 2.1 How the Scheduler Selects Modes Per Workload Region

The scheduler maps workload characteristics to `mode_tag` using the following decision tree. All decisions are based on the operand's current exponent band and chain depth.

```
SCHEDULER DECISION TREE:

  Given: current operand exponent E, current chain depth D, workload type W

  IF E ∈ [16..47] (STABLE BAND):
    IF W == CANCELLATION_HEAVY and BIAS_LUT is populated:
      → mode_tag = 001  (BIAS)    // Correct cancellation drift
    ELSE IF D > 8 or operand magnitude > 2^12:
      → mode_tag = 010  (PRSC)    // Pre-scale to contain accum growth
    ELSE IF accumulator will exceed 500K MACs without reset:
      → mode_tag = 011  (SAFE)    // Prevent 32-bit wrap-around
    ELSE:
      → mode_tag = 000  (STD)     // Baseline — lowest overhead

  IF E ∈ [14..15] (COLLAPSE APPROACH):
    → mode_tag = 000  (STD)       // Policy cannot help; normalize operand
    ACTION: Insert MUL(x, TWO) to raise E before proceeding

  IF E ∈ [48..49] (SATURATION APPROACH):
    → mode_tag = 011  (SAFE)      // Bound accumulator before clamping
    ACTION: Insert MUL(x, HALF) to lower E or use OVF as ceiling signal

  IF E ∉ [16..47] (COLLAPSE or SATURATION BAND):
    POLICY HAS NO ARITHMETIC EFFECT — `result` is floor or maxpos regardless
    → mode_tag = 000  (STD)       // Minimal overhead; policy irrelevant
    ACTION: Issue accum_clr if UF observed; discard computation window
```

### 2.2 How the Transition Band Triggers Scaling Behavior

The transition band (E = 14..15 approaching collapse, E = 48..49 approaching saturation) is the early-warning zone that should trigger explicit normalization in compiler-generated code.

**Collapse approach (E=14..15):**
```
DETECTION: E_operand ≤ 19  (conservative 4-step margin from cliff)
ACTION:
  MUL(x, NFE_TWO)    → E += 1  (scale up; one-step cost)
  MUL(x, NFE_TWO×TWO) → E += 2 (if further distance needed)
  REPEAT until E ≥ 20 (conservative safe zone)

NOTE: If E=15 and f ≥ 32:
  ADD_FRAC(x, x) produces Thoth Rollover → E=16 (rescue into stable)
  This is the ADD-rescue mechanism from HBS-13A.
  Fraction channel is partially transformed; exponent channel is recovered.
```

**Saturation approach (E=44..47):**
```
DETECTION: E_operand ≥ 44  (conservative 4-step margin from cliff)
ACTION:
  MUL(x, NFE_HALF) → E -= 1  (scale down; one-step cost)
  REPEAT until E ≤ 43 (conservative safe zone)

NOTE: If E=47 and ADD is required with f ≥ 32:
  Result will cross to E=48 (saturation entry — no rescue)
  Either gate the ADD or pre-scale the operand first
```

### 2.3 How the Collapse Band Is Used as a Sentinel System

The collapse band (E < 16) has a secondary use beyond being an error condition: it can serve as a **sentinel system** for computation boundaries.

**NFE_FLOOR (0x000) as a computation boundary marker:**
When a chain produces NFE_FLOOR via UF, the accumulator contribution is zero. This can be exploited:

```
USE CASE: Depth-limited computation window
  1. Issue operations up to max useful depth
  2. Beyond depth, allow further MUL to drive toward UF naturally
  3. UF events are signaled by underflow_flag (observable in hardware)
  4. accum_reg contains only the pre-UF contributions
  5. Issue accum_clr to reset for next window

ADVANTAGE: No explicit depth counter needed at the operand level;
           the arithmetic itself terminates the window via UF.
CONSTRAINT: Only valid if the desired computation terminates before
            the floor attractor fires.
```

**Floor attractor schedule (from HBS-12D, HALF-scaling):**
```
Starting E:  Steps to UF via MUL(x, HALF) chain:
  E=16 →  1 step
  E=20 →  5 steps
  E=24 → 25 steps   ← recommended minimum for inference chains
  E=28 → 29 steps
  E=32 → 33 steps   ← natural anchor; longest stable chain
  E=40 → 41 steps
  E=44 → 29 steps
  E=47 → 32 steps   ← symmetric with E=32 toward saturation
```

### 2.4 How the Saturation Band Is Used for Clipping or Gating

The saturation band (E ≥ 48) has a defined use as a **ceiling gate**:

**NFE_MAXPOS (0x1FFF) as a ceiling signal:**
```
USE CASE: Outlier detection / dynamic range gating
  1. Set threshold operand T at E=47 (maximum stable)
  2. MUL(input, T): if input > threshold, E_result > 63 → OVF
  3. Observe exp_ovf_flag: 1 = input exceeded ceiling
  4. exp_ovf_flag is policy-invariant (fires regardless of mode_tag)
  5. Use as one-bit "above ceiling" signal for dynamic routing

USE CASE: Saturation accumulation (MODE_SAFE)
  1. Set mode_tag = 011 (SAFE_ACCUM)
  2. Accumulate without clearing; large values clamp at 0xFFFFFFFF
  3. Final accum_out ≤ 0xFFFFFFFF (no modular wrap-around)
  4. Effective for streaming inference with occasional outlier MACs
```

---

## 3. System-Level Insight

### 3.1 Distributed Execution Control via In-Band Policy

```
INSIGHT: The 3-bit mode system enables distributed execution control
without central bottlenecking by embedding computation policy directly
into arithmetic flow.
```

**What this means architecturally:**

In conventional computing systems, policy decisions (e.g., "use saturating arithmetic for this computation") require either:
- A separate control register (overhead: read-modify-write cycle)
- A separate control bus (overhead: bus arbitration, synchronization)
- Encoded in the instruction opcode (overhead: wider instruction word)

HORUS v3 embeds policy in-band within the NFE operand stream as `mode_tag[2:0]`. Because operands already travel on the data path, adding 3 bits to the sidecar costs zero additional control cycles. A scheduler can change computation policy every clock cycle at zero latency penalty.

**Verification (HBS-14B):** 500 cycles of cycle-by-cycle mode switching with random mode selection produced **zero result interference** and **deterministic mixed-mode accumulation**. No setup time, hold time, or mode-transition latency was observed.

**Practical implication:** A systolic array deployment can assign different `mode_tag` values to different operand rows in the same tile window. Row 0 may use MODE_PRSC (scale-controlled accumulation), Row 1 may use MODE_SAFE (outlier protection), Row 2 may use MODE_STD (baseline). All four modes execute simultaneously on different MACs within the same `horus_systolic_array` tile without interaction.

### 3.2 Execution Horizon as Computational Envelope

The `host_tile_depth` parameter defines the **execution horizon** — the maximum number of MACs that may accumulate before the computation window closes. This horizon has two roles:

1. **Power budget:** pgate_ctrl prevents accumulation beyond the specified MAC count, enabling predictable energy consumption per tile.
2. **Information quality:** In the collapse band, depth determines when the floor attractor fires. Controlling depth controls information survival.

**Execution horizon vs. collapse schedule:**
```
CONSTRAINT: host_tile_depth ≤ (stored_E − 16) for HALF-scaling chains
            to guarantee the computation terminates before UF fires.

EXAMPLE:
  E=24, HALF-chain: UF fires at depth 9 (E=24 → 23 → ... → 15)
  Set host_tile_depth ≤ 8 to ensure all MACs are valid before gate closes.
```

### 3.3 Mode Selection as Workload Classification

The four modes classify workloads along two axes:

```
                  ACCUMULATOR PRECISION
                  High ────────────────── Low
         ┌────────────────┬────────────────┐
    High │  000 STD       │  010 PRSC      │
    CHAIN│  Default MAC   │  Deep chains   │
    DEPTH├────────────────┼────────────────┤
    Low  │  001 BIAS      │  011 SAFE      │
         │  Cancellation  │  Outlier       │
         │  correction    │  protection    │
         └────────────────┴────────────────┘
```

- **STD (000):** Default. Both dimensions nominal. No known failure mode active.
- **BIAS (001):** Precision-critical, cancellation-heavy. Requires QAT calibration.
- **PRSC (010):** Deep chains where accumulator growth is a concern. Accepts lower accum magnitude.
- **SAFE (011):** High-variance workloads with occasional outlier MACs. Accepts saturation ceiling.

---

## 4. Deployment Configuration Summary

### 4.1 Minimal Deployment (Single Mode)

For workloads operating exclusively in the stable band (E=16..47) with depth ≤ 8:

```
mode_tag        = 3'b000  (STD — all other modes zero-gain at defaults)
host_tile_depth = N       (1..63, sized to workload; 8 is conservative safe)
accum_clr       = pulse   (once per tile window)
```

This configuration requires no calibration and produces correct results for all in-band operations.

### 4.2 Deep Inference Configuration (PRSC + Depth Budget)

For multi-layer inference chains with depth > 8 or operand magnitudes > 2^12:

```
mode_tag        = 3'b010  (PRSC — contains accum_reg growth)
host_tile_depth = 4       (recommended: pair with max_depth ≤ 4, EXECUTION_POLICY §6)
accum_clr       = pulse   (after each tile; accumulate across tiles externally)
Compiler constraint: stored_E ∈ [20..44]  (8-step margins both sides)
```

### 4.3 Safe-Streaming Configuration (SAFE + Extended Depth)

For long-running streaming accumulators (multi-tile, many-layer):

```
mode_tag        = 3'b011  (SAFE — prevents 32-bit wrap)
host_tile_depth = 63      (maximum; reset with periodic accum_clr)
Monitor:        accum_full output — asserts when budget exhausted
Strategy:       Read accum_out, issue accum_clr, continue
```

### 4.4 Cancellation-Corrected Configuration (BIAS + QAT)

For inference on graphs with structured cancellation patterns (HBS-9 identified residuals):

```
PREREQUISITE: QAT calibration pass completed; BIAS_LUT[0:63] populated
mode_tag        = 3'b001  (BIAS — adds per-band correction offset)
host_tile_depth = 4..8    (moderate depth to bound cancellation accumulation)
Note:           Without LUT calibration, MODE_001 ≡ MODE_000
```

---

## 5. Cross-Reference to Failure Mode Mitigations

| Failure Mode | Source | Mode Mitigation | Effectiveness |
|---|---|---|---|
| W01 Cancellation Drift | HBS-9 (Test 9) | MODE_001 (BIAS) | 0% until LUT calibrated |
| W03 Underflow Collapse | HBS-12 (E<16) | None — arithmetic layer | MODE_010 can delay via lower accum growth |
| W04 Spike Saturation | HBS-12 (E>47) | MODE_011 (SAFE) | Prevents 32-bit wrap; OVF still fires |
| W06 Dynamic Range Exhaustion | HBS-12 (depth) | MODE_010 (PRSC) | −2.5% per tile; effective for deep chains |
| Mode interference | HBS-14B | N/A | Not observed — zero interference events |

---

## 6. Related Documents

| Document | Content |
|---|---|
| `docs/EXECUTION_MAPPING.md` | Formal execution contract; region semantics table |
| `docs/HORUS_V3_FINAL_SPEC.md` | Gold master specification; layered model |
| `docs/EXECUTION_POLICY.md` | Policy mode full specification; HBS-11 results |
| `docs/HORUS_ARITHMETIC_ENVELOPE.md` | Compiler constraints; QAT constraints |
| `docs/HORUS_END_TO_END_SYSTEM_REPORT.md` | HBS-14 system integration report |

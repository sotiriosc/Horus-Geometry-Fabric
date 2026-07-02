# HORUS v3 Arithmetic Envelope

**Document type:** Principal Architecture Reference  
**System:** HORUS v3 Native Fractional Engine (NFE)  
**Encoding:** 13-bit, Bias-32, hidden-bit (V = (−1)^S × 2^(E−32) × (1 + f/64))  
**Status:** Verified by HBS-12 (2026-07-02)  
**Source data:** `sim/HBS12_ARITHMETIC_BOUNDARY.csv`, `sim/HBS12_SUMMARY.log`

---

## Executive Summary

HORUS v3 operates inside a **precisely bounded arithmetic envelope**.  Every failure mode — underflow, overflow, floor attractor collapse, and information loss — is **deterministic and algebraically derivable**.  There is no stochastic failure.

The key constraint set is:

| Constraint | Boundary | Consequence if violated |
|-----------|----------|------------------------|
| `stored_E` per operand | 16 ≤ E ≤ 47 | UF (E<16) or OVF (E>47) on MUL |
| Chain depth per epoch | depth ≤ 16 | Information cliff at depth 32 |
| ADD/SUB delta | delta ≤ 63 − f | Thoth Rollover destroys f bits |
| Operand sum exponent | E_a + E_b ∈ [32, 95] | MUL UF or OVF |

Compilers and QAT frameworks should treat these as **hard constraints**, not soft recommendations.

---

## Architectural Invariant

HORUS v3 is a **bounded arithmetic system**.

Within `stored_E = 16–47`:
- arithmetic is **stable**.

Below `stored_E = 16`:
- multiplication **underflows deterministically**.

Above `stored_E = 47`:
- multiplication **overflows deterministically**.

Depth-induced collapse arises from **migration into these boundary regions** rather than from stochastic numerical instability.

---

## 1. Encoding Reference

```
 12  11 10  9  8  7  6   5  4  3  2  1  0
  S  |   E[5:0] (stored, Bias-32)   | f[5:0]
```

| Field | Width | Interpretation |
|-------|-------|---------------|
| S | 1 bit | Sign: 0 = positive, 1 = negative |
| E | 6 bits | Stored exponent.  actual_E = E − 32.  Range: stored 0..63 → actual −32..+31 |
| f | 6 bits | Fraction.  V = 2^(E−32) × (1 + f/64).  f=0 → mantissa 1.0, f=63 → mantissa ≈ 1.984 |

**Special codewords:**

| Codeword | Value | Meaning |
|---------|-------|---------|
| `13'h000` | 0 | Architectural minimum / Underflow Floor |
| `13'h800` | 1.0 | NFE_ONE (E=32, f=0) |
| `13'h7C0` | 0.5 | NFE_HALF (E=31, f=0) |
| `13'h1FFF` | ≈ 4.26 × 10⁹ | Maximum positive |

---

## 2. Stable Operating Region

**Verified by HBS-12A and HBS-12E.**

The stable region is defined as the set of operand pairs (A, B) for which `MUL(A, B)` produces neither `underflow_flag` nor `exp_ovf_flag`.

### 2.1 Exponent Stability Window

```
stored_E:   0           15 | 16                  47 | 48            63
            ──────────────|──────────────────────── |────────────────
            COLLAPSE ZONE │      STABLE ZONE        │  SATURATION ZONE
```

| Zone | E range | Fraction of E space |
|------|---------|---------------------|
| **Stable** | 16 – 47 | **50 %** (32 of 64 values) |
| Collapse (UF) | 0 – 15 | 25 % |
| Saturation (OVF) | 48 – 63 | 25 % |

Phase transitions at E=15→16 and E=47→48 are **instantaneous** (no mixed rows in HBS-12A sweep).

### 2.2 Fraction Stability

- At E=32: all 64 fraction values produce **64 distinct MUL outputs** (0 collisions, HBS-12B Pass 2).
- Within the stable band, fraction utilisation is 100 %: no two distinct inputs produce the same output.
- Fraction resolution does not degrade with E within the stable zone.

### 2.3 MUL Identity Property

`MUL(x, NFE_ONE) = x` for all x tested (21/21 at E=32, f=0..63). HBS-12B Pass 3.

This identity holds algebraically:

```
scale_reg = {1, f} × {1, 0} = 64 × (64 + f) = 4096 + 64f
P[13] = 0  (always, since 4096 + 64×63 = 8128 < 8192)
f_result = (4096 + 64f)[11:6] = f   [exact]
exp_sum  = E + 32 − 32 = E          [exact]
```

### 2.4 Reversibility in the Stable Zone

- ADD→SUB round-trip: **100 % reversible** when delta ≤ 63 − f (21/21, HBS-12F Test 1).
- Thoth Rollover path: **0 % reversible** (7/7 failures, HBS-12F Test 2).
- Overall reversibility score: 85.7 % (42/49).

---

## 3. Transition Region

The transition region comprises operand pairs at the boundary of stable and non-stable zones.

| Transition | Condition | Behavior |
|-----------|----------|----------|
| UF boundary | E = 15 or E = 16 in a mixed-E MUL | Result may be NORM or UF depending on partner E |
| OVF boundary | E = 47 or E = 48 in a mixed-E MUL | Result may be NORM or OVF depending on partner E |
| ADD rollover | f + delta ≥ 64 | E incremented, f truncated — deterministic, non-reversible |
| SUB Guard-B | f_a < delta, E > 0 | 2-cycle pipeline. FTZ if E < norm_shift |

### 3.1 Asymmetric Pair Safety

HBS-12E Pass 3 demonstrates that for any E_a ∈ [0..31]:

```
MUL({0, E_a, 0}, {0, 63−E_a, 0})  →  exp_sum = E_a + (63−E_a) − 32 = 31
```

All 32 complementary pairs produce NORM results (UF=0, OVF=0).  **Complementary exponent pairs are always safe.**

---

## 4. Collapse Region

**Verified by HBS-12A (E scan) and HBS-12D (depth chain).**

Two distinct collapse mechanisms exist:

### 4.1 Static Collapse — Exponent Underflow

When `stored_E < 16`, any `MUL(x, x)` immediately produces `NFE_FLOOR (0x000)`.  
Algebraic trigger: `2E − 32 < 0` → `exp_sum[7] = 1`.

This is a **single-operation collapse** — no depth required.

### 4.2 Dynamic Collapse — Floor Attractor (Chain Depth)

Chain MUL operations with `CHAIN_Y = NFE_HALF (E=31)` decrement `stored_E` by 1 per step.  Observed collapse curve:

| Depth | Floor Rate | Unique Outputs | Entropy |
|-------|-----------|----------------|---------|
| 1–16  | 0 %       | 29/32          | 4.81 bits |
| 32    | **56 %**  | 14/32          | 2.59 bits |
| 64    | **100 %** | 1/32           | 0.00 bits |

**Hard cliff:** Full fidelity at depth 16, majority collapse at depth 32.  No graceful degradation window.

The floor attractor is an **absorbing state** — once a computation chain reaches `NFE_FLOOR`, all subsequent MUL operations stay there.

---

## 5. Saturation Region

**Verified by HBS-12A (E ≥ 48) and HBS-12C (E=62, E=63).**

When `stored_E ≥ 48`, `MUL(x, x)` produces `NFE_MAXPOS (0x1FFF)`.  
Algebraic trigger: `2E − 32 > 63` → `exp_sum[6] = 1`.

ADD at E=63 with rollover produces the same saturation output via `exp_ovf_flag`.

The saturation codeword `0x1FFF` is non-absorbing: subsequent operations on it behave normally (it represents the maximum representable value, not infinity).  However, all precision is lost in the OVF zone.

---

## 6. Recommended Compiler Constraints

These constraints are derived directly from HBS-12 measurements and must be enforced by the Horus compiler or QAT pre-processing stage.

### 6.1 Operand Range Constraints

```
# Hard constraint: MUL safety
ASSERT 16 ≤ stored_E_A ≤ 47 AND 16 ≤ stored_E_B ≤ 47
    FOR ALL MUL(A, B) in compute graph

# Derived: E sum constraint
ASSERT 32 ≤ E_A + E_B ≤ 95  (implied by 16 ≤ E ≤ 47)
```

**Conservative constraint** (recommended for production):

```
PREFER stored_E ∈ [20..44]   # 4-step margin from UF/OVF boundaries
```

### 6.2 Depth Constraints

```
# Hard constraint: information survival
ASSERT chain_depth ≤ 16  FOR operations using E_seed ∈ [28..35]
    (or equivalently: chain_depth ≤ E_seed − 16)

# If depth > 16 is required:
APPLY mode_tag = 3'b010 (Pre-Scaled) AND epoch_depth ≤ 32
    WITH depth_reset via horus_controller MAX_DEPTH register
```

The depth constraint is **seed-dependent**: higher-E seeds tolerate deeper chains.

### 6.3 ADD/SUB Delta Constraints

```
# Hard constraint: reversible addition
ASSERT f + delta < 64  FOR reversible ADD→SUB compute graphs

# If rollover is permitted (non-reversible operation):
ASSERT E < 63  (to prevent ADD OVF)
```

### 6.4 Encoding Constraints

```
# Compiler-side operand preparation
CLIP operand_value TO [min_reliable, max_reliable]
    BEFORE encoding to 13-bit NFE codeword

min_reliable = 2^(16−32) × 1.0 = 2^−16 ≈ 1.526 × 10^−5
max_reliable = 2^(47−32) × 1.984375 = 2^15 × 1.984375 ≈ 65,063
```

---

## 7. Recommended QAT Constraints

QAT (Quantization-Aware Training) frameworks should apply these constraints during weight quantisation and calibration.

### 7.1 Weight Quantisation Range

| Parameter | Constraint | Rationale |
|-----------|-----------|-----------|
| Weight exponent | `stored_E ∈ [20..44]` | Conservative safe window |
| Activation exponent | `stored_E ∈ [16..47]` | Full stable zone |
| Max weight value | ≤ 2^12 × 1.984 ≈ 8,126 | E=44 max with f=63 |
| Min weight value | ≥ 2^−12 × 1.0 ≈ 2.44 × 10^−4 | E=20, f=0 |

### 7.2 Depth-Aware Calibration

The floor attractor means that QAT calibration with deep chain simulations will underestimate real network accuracy.  Calibration should:

1. Use chain depths ≤ 16 in the main calibration pass.
2. Apply a separate "depth stress" calibration for layers expected to chain beyond depth 16.
3. Flag any quantised weight that, when self-multiplied, falls outside the stable zone.

### 7.3 Rollover Awareness

Non-reversible QAT operations (ADD with large fraction deltas) should be flagged as lossy.  Where exact round-trip computation is required, restrict `delta ≤ 63 − f`.

### 7.4 Identity Operations

MUL by 1.0 (NFE_ONE = `0x800`) is exact and zero-cost in QAT graphs.  It may be used freely as a pass-through or type-cast operation.

---

## 8. Known Arithmetic Boundaries (Summary)

| Boundary | Condition | Flag |
|----------|----------|------|
| MUL underflow | `E_a + E_b < 32` (stored) | `underflow_flag` |
| MUL overflow | `E_a + E_b > 95` (stored) | `exp_ovf_flag` |
| MUL self-UF | `E < 16` | `underflow_flag` |
| MUL self-OVF | `E > 47` | `exp_ovf_flag` |
| ADD Thoth Rollover | `f + delta ≥ 64` | `rollover_flag` |
| ADD OVF | E=63 and rollover | `exp_ovf_flag` |
| SUB Guard-B FTZ | `E < norm_shift` | `underflow_flag` |
| SUB E=0 Guard-B | E=0, f_a < delta | `underflow_flag`, immediate floor |
| Floor attractor | Chain depth ≥ E_seed | permanent `NFE_FLOOR` |
| Information cliff | MUL chain depth ≥ 32 (E_seed ∈ [28..35]) | entropy < 2.59 bits |

---

## 9. Phase Diagram

```
                    HORUS v3 ARITHMETIC PHASE DIAGRAM
                    (MUL operation, both operands equal)

Fraction f
  63 ┤         COLLAPSE │██████ STABLE ZONE ██████│ SATURATION
     │          (UF)    │                         │    (OVF)
  32 ┤                  │                         │
     │                  │     All f values safe    │
   0 ┤                  │     (100% utilisation)   │
     └──────────────────┼─────────────────────────┼──────────
     E: 0    8   15 | 16   24    32    40   47 | 48   56  63

     │◄── UF (16E) ───►│◄─── NORM (32E) ────►│◄── OVF (16E) ─►│

     MUL(x,x) boundary: UF @ E<16, OVF @ E>47
     Chain depth cliff:  fidelity @ d≤16, collapse @ d≥32
```

---

## 10. Relation to Execution Policy System

Execution policies (`mode_tag` bits) operate on the **accumulator path**, which receives the arithmetic result **after** it has been generated by the NFE core.  Therefore:

- Policies **cannot** prevent MUL underflow or overflow (these are core arithmetic events).
- Policies **cannot** extend the usable exponent window beyond E=16..47.
- Policies **cannot** prevent the floor attractor collapse (which occurs at the arithmetic result, not the accumulator).
- Policies **can** mitigate accumulator-level saturation (MODE_SAFE_ACCUM, mode_tag=011).
- Policies **can** apply depth-triggered epoch resets (Depth-Monitor in `horus_controller`).

See `docs/EXECUTION_POLICY.md` § "Policy Applicability Boundary" for the formal boundary statement.

---

## 11. Related Documents

| Document | Relationship |
|----------|-------------|
| `docs/HBS12_RESULTS.md` | Full HBS-12 test report (this document's source) |
| `docs/EXECUTION_POLICY.md` | Policy system; HBS-11 results; policy-arithmetic boundary |
| `docs/COMPOSITION_GEOMETRY.md` | Composition geometry; shallow vs deep chain analysis |
| `docs/ARCHITECTURE_PHILOSOPHY.md` | Full architectural context; HBS-12 findings summary |
| `sim/HBS12_ARITHMETIC_BOUNDARY.csv` | Raw measurement data (1255 rows) |
| `sim/HBS12_SUMMARY.log` | Full sub-test analysis log |

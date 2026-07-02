# HORUS v3 Boundary Gap Analysis

**Document type:** Principal Architecture Reference  
**System:** HORUS v3 NFE (13-bit, Bias-32, hidden-bit)  
**Status:** Verified by HBS-13 (2026-07-02)  
**Source data:** `sim/HBS13_BOUNDARY_GAP.csv`, `sim/HBS13_SUMMARY.log`

---

## Executive Summary

HORUS v3 has two arithmetic phase boundaries. Both are **instantaneous cliffs** — a single exponent step separates full stability from complete collapse or saturation. There is no transition gradient, no fraction dependence, and no hysteresis.

Key facts established by HBS-13:

| Property | Collapse (E=15→16) | Saturation (E=47→48) |
|----------|---------------------|----------------------|
| Geometry | CLIFF | CLIFF |
| Fraction-dependent? | No | No |
| Hysteresis? | No | No |
| ADD can cross? | Yes (50%, f≥32) | Yes (50%, f≥32) |
| Near-boundary reversible? | Yes (perfectly) | Yes (perfectly) |
| Through-boundary reversible? | Partial (+2 E, f=0) | Partial (f=63 corrupted) |
| Identity op safe? | Yes, all zones | Yes, all zones |

The boundaries are **algebraic consequences** of the Bias-32 exponent encoding and cannot be relocated without changing the encoding. They are not bugs — they are deterministic physics of the format.

---

## 1. The Boundaries

### 1.1 Collapse Boundary (E = 15 ↔ 16)

**Cause:** MUL(A, B) computes `stored_E_result = E_A + E_B − 32`. For self-multiplication (`E_A = E_B = E`): `E_result = 2E − 32`. This goes negative when `E < 16`, causing the 8-bit exponent field to wrap (`exp_sum[7] = 1`), triggering underflow.

**Physical meaning:** Multiplying a number with `actual_E < −16` (i.e., magnitude < 2⁻¹⁶) by itself produces a result below the minimum representable value (2⁻³²).

**Threshold:** `E < 16` → UF floor. `E ≥ 16` → NORM. Verified across all 64 fraction values in HBS-13A.

### 1.2 Saturation Boundary (E = 47 ↔ 48)

**Cause:** `E_result = 2E − 32`. Overflows the 6-bit exponent field when `E_result ≥ 64`, i.e., `E ≥ 48` (`exp_sum[6] = 1`).

**Physical meaning:** Squaring a number with `actual_E > +15` (i.e., magnitude > 2¹⁵) produces a result above the maximum representable value (2⁺³¹ × 1.984).

**Threshold:** `E ≤ 47` → NORM. `E ≥ 48` → OVF max. Verified across all 64 fraction values in HBS-13B.

---

## 2. Collapse Boundary

### 2.1 Cliff Geometry

```
MUL(x,x) UF rate vs stored_E:

  UF%
  100 │████████████████
      │                 ← E=16: cliff
    0 │                ░░░░░░░░░░░░░░░░░░░░░
      └─────────────────────────────────────
      E: 12  13  14  15 │ 16  17  18  19  20
                        │
                   COLLAPSE │ STABLE
                   BOUNDARY │
```

No intermediate values. No fraction dependence. The cliff is perfectly vertical.

### 2.2 MUL(x, ONE) is Safe in the Collapse Zone

`MUL(x, NFE_ONE)` preserves `x` exactly for all E values including E < 16. Identity failures: 0/576.

This means the **collapse zone is not completely dead** — non-self-product operations that keep the result exponent low can safely traverse it.

### 2.3 ADD Rescue Mechanism

ADD(x, x) with f ≥ 32 causes Thoth Rollover, incrementing E by 1. For E=15 with f ≥ 32: result has E=16. **50% of E=15 codewords can be rescued into the stable zone by a single ADD.**

```
E=15, f=31:  ADD(x,x) → E=15, f=62      (no rescue — stays in collapse zone)
E=15, f=32:  ADD(x,x) → E=16, f= 0  ←  RESCUED into stable zone
E=15, f=63:  ADD(x,x) → E=16, f=31 ←  RESCUED into stable zone
```

This is a one-way rescue only — there is no ADD operation that pushes from E=16 back to E=15 without explicitly targeting a lower-E result.

### 2.4 Scale-Down is Safe

`MUL(x, NFE_HALF)` across E=12..20: **0 UF events.** The scale-down operation traverses the collapse zone without triggering underflow because `exp_sum = E + 31 − 32 = E − 1`, which only underflows at E=0.

This property — that non-self-product operations can safely enter and exit the collapse zone — is critical for compiler strategies that scale weights before dispatch.

### 2.5 Information Recovery from Floor

| Recovery scenario | E recovery | f recovery |
|-----------------|------------|------------|
| Near-boundary descent (no floor) | Perfect | Perfect |
| Through-floor descent | +2 deterministic offset | f=0 permanently |

The +2 E offset arises because the floor is an **absorbing state for scale-down**: two descent steps into/through the floor produce no E decrement (both map to E=0 floor), but the corresponding scale-up steps each add +1 to E, resulting in a net +2 overshoot.

---

## 3. Saturation Boundary

### 3.1 Cliff Geometry

```
MUL(x,x) OVF rate vs stored_E:

  OVF%
  100 │                ████████████████
      │  ← E=48: cliff
    0 │░░░░░░░░░░░░░░░░
      └─────────────────────────────────────
      E: 44  45  46  47 │ 48  49  50  51  52
                        │
                 STABLE  │  SATURATION
                         │   BOUNDARY
```

Symmetric to the collapse boundary. Instantaneous, fraction-independent, no mixing.

### 3.2 ADD Push Mechanism

ADD(x, x) with f ≥ 32 at E=47 pushes the result to E=48 (OVF zone). This is the mirror of the ADD rescue at E=15:

```
E=47, f=31:  ADD(x,x) → E=47, f=62      (stays in stable zone)
E=47, f=32:  ADD(x,x) → E=48 → OVF ←  PUSHED into saturation
E=47, f=63:  ADD(x,x) → E=48 → OVF ←  PUSHED into saturation
```

The 50% crossing rate is universal: exactly f=32..63 cause rollover for any E value.

### 3.3 Scale-Up is Safe

`MUL(x, NFE_TWO)` across E=44..52: **0 OVF events** in this range (OVF occurs only when E+1 ≥ 64, i.e., E=63). Scale-up traverses the saturation edge safely.

### 3.4 Saturation Recovery

OVF fixes the result at `{0, 63, 63}` (NFE_MAXPOS). Scale-down from NFE_MAXPOS perfectly preserves f=63 (since MUL with HALF and f_b=0 preserves f_a). This means:

- Scale-down from saturated state: E decrements cleanly from 63, f stays 63.
- Recovery of original f: impossible — f=63 overwrites original fraction at saturation.

This is symmetric to the floor: **floor contaminates f=0, saturation contaminates f=63**.

---

## 4. Recovery Behavior

### 4.1 Near-Boundary Round-Trip (no floor/OVF crossing)

```
E=24, f=31
    ↓ 20× MUL(HALF)
E=4, f=31   ← in collapse zone, no UF
    ↓ 20× MUL(TWO)
E=24, f=31  ← PERFECTLY RECOVERED
```

Near-boundary descent and recovery is **lossless** because:
- Scale-down/up with f=0 multipliers (NFE_HALF, NFE_TWO) preserve f_a analytically.
- No UF or OVF fires in the round-trip.
- E arithmetic is exactly reversible (additive).

### 4.2 Through-Floor Round-Trip

```
E=24, f=31
    ↓ 26× MUL(HALF)   [floor reached at step 25]
E=0, f=0   ← FLOOR (f destroyed)
    ↓ 26× MUL(TWO)
E=26, f=0  ← PARTIAL RECOVERY (E overshoot +2, f=0 permanent)
```

| Loss type | Description |
|-----------|-------------|
| Fraction loss | f permanently set to 0 at floor |
| E overshoot | +2 deterministic offset (universal for all anchors) |
| Predictability | Both losses are **deterministic and measurable** |

### 4.3 Information Migration Summary

```
Scale-DOWN trajectory (seed E=24, MUL×HALF):
  Step:  1   2   3  ...  16  ...  24   25   26→32
  E:    23  22  21  ...   8  ...   0   UF   UF
  f:    31  31  31  ...  31  ...  31    0    0

Scale-UP trajectory (seed E=32, MUL×TWO):
  Step:  1   2  ...  16  ...  31   32
  E:    33  34  ...  48  ...  63   OVF
  f:     0   0  ...   0  ...   0   63
```

Migration is purely in the exponent channel. The fraction is **inert** until a boundary event forces it to 0 (floor) or 63 (saturation).

---

## 5. Fraction Survival

### 5.1 Effective Precision Near Boundaries

| E | MUL(x,x) eff.bits | MUL(x,ONE) eff.bits |
|---|-------------------|---------------------|
| 14 | 0.00 (floor) | 6.00 (identity) |
| 15 | 0.00 (floor) | 6.00 (identity) |
| **16** | **6.00 (but E_result=0)** | **6.00** |
| 17 | 6.00 (E_result=2) | 6.00 |
| 46 | 6.00 | 6.00 |
| **47** | **6.00 (E_result∈{62,63})** | **6.00** |
| 48 | 0.00 (OVF max) | 6.00 |
| 49 | 0.00 (OVF max) | 6.00 |

The fraction field carries full information (6.00 eff.bits) for all E values in the scan **when using identity operations**. Only self-multiplication destroys it below E=16 or above E=47.

### 5.2 Result-E Drift from MUL(x,x) Near Collapse

```
Input E:  16    17    18    19    20  ...  24
Exp_sum:   0     2     4     6     8  ...  16
```

Even in the "stable zone" (E=16..23), self-multiplication pushes `E_result` back toward the collapse zone. The result is **in the stable zone** only when `E_input ≥ 24` (gives `E_result ≥ 16`).

**This is the true self-multiplication safe floor: E ≥ 24 for MUL(x,x).**

---

## 6. Recommended v4 Directions

The following architectural observations from HBS-13 are offered as inputs to v4 design:

### 6.1 ADD Boundary Awareness

The ADD operation's 50% boundary-crossing rate (for f ≥ 32) is uncontrolled. A v4 enhancement could add a **boundary-guard mode** that clamps f to [0..30] before ADD when the operand is within one step of a phase boundary. This would prevent accidental saturation of E=47 values via routine ADD operations, at the cost of 2 fraction bits in the guard range.

### 6.2 Soft Floor with f-Preservation

The current floor enforces both E=0 and f=0. If instead the floor only set E=0 while preserving f (i.e., `{sign, 0, f_result}`), the +2 E offset would persist but f would survive. This requires adding one additional gate condition to the underflow path:

```
// Hypothetical v4 floor (E=0, f preserved):
computed = {res_sign, {EXP_W{1'b0}}, scale_reg[11:6]};  // f from product
```

This would make the floor a **soft attractor** (E-only collapse) rather than a hard erasure.

### 6.3 Wider Bias

Moving from Bias-32 to a wider bias (e.g., Bias-24) would shift both boundaries outward, increasing the stable exponent window from 32 to 48 values. The trade-off is a proportional reduction in the representable range.

### 6.4 Boundary-Aware Compiler Scheduling

The 50% ADD crossing rate provides a natural scheduling primitive: an optimizer can use ADD with f=0..31 as a **non-crossing operation** and avoid ADD with f≥32 for operands near phase boundaries. This requires no hardware change.

---

## 7. Related Documents

| Document | Content |
|----------|---------|
| `docs/HBS13_RESULTS.md` | Full HBS-13 sub-test report |
| `docs/HORUS_ARITHMETIC_ENVELOPE.md` | Full arithmetic envelope; phase diagram; compiler/QAT constraints |
| `docs/HBS12_RESULTS.md` | HBS-12 full results (initial boundary discovery) |
| `docs/EXECUTION_POLICY.md` | Policy system; policy-arithmetic boundary |
| `docs/COMPOSITION_GEOMETRY.md` | Deep-chain behavior; floor attractor; residual manifold |
| `docs/ARCHITECTURE_PHILOSOPHY.md` | Full architectural context |
| `sim/HBS13_BOUNDARY_GAP.csv` | Raw measurement data (6,092 rows) |
| `sim/HBS13_SUMMARY.log` | Full sub-test analysis log |

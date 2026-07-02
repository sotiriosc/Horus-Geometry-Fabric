# HBS-13 Results: Boundary Gap Characterization Suite

**Suite:** HBS-13 — Boundary Gap Characterization  
**System:** HORUS v3 NFE (13-bit, Bias-32, hidden-bit)  
**Policy:** `mode_tag = 3'b000` (Standard — no policy effects)  
**Date:** 2026-07-02  
**Output files:** `sim/HBS13_BOUNDARY_GAP.csv` · `sim/HBS13_SUMMARY.log`

---

## Overview

HBS-13 characterizes information behavior in the ±4-exponent bands around both arithmetic phase boundaries discovered by HBS-12:

| Boundary | Location | Type |
|----------|----------|------|
| Collapse | E = 15 ↔ 16 | Underflow floor |
| Saturation | E = 47 ↔ 48 | Overflow max |

Six sub-tests probe edge-scan sharpness, information migration trajectories, recovery round-trips, fraction survival, and boundary geometry classification. All 6,092 measurement rows used `mode_tag = 3'b000`.

---

## HBS-13A — Collapse Edge Scan

**Scope:** `E = 12..20`, `f = 0..63`. Four operations per (E, f) pair.

### MUL(x, x) — Self-product UF map

| E | UF% | NORM% | Unique results | Result-E range |
|---|-----|-------|---------------|----------------|
| 12 | 100% | 0% | 1 | 0 |
| 13 | 100% | 0% | 1 | 0 |
| 14 | 100% | 0% | 1 | 0 |
| **15** | **100%** | **0%** | **1** | **0** |
| **16** | **0%** | **100%** | **64** | **0..1** |
| 17 | 0% | 100% | 64 | 2..3 |
| 18 | 0% | 100% | 64 | 4..5 |
| 19 | 0% | 100% | 64 | 6..7 |
| 20 | 0% | 100% | 64 | 8..9 |

**Key finding:** The UF cliff at E=16 is **fraction-independent** — the same for all 64 f values. No mixing at either boundary E value.

**Novel finding — result-E drift:** MUL(x,x) at E=16..23 produces `E_result < 16` (in the collapse zone) with no UF flag. The UF flag only fires when `exp_sum[7]=1` (negative wrap). At E=16: `E_result = 2×16−32 = 0`. At E=20: `E_result = 8`. A result exponent of 16 requires `E_input ≥ 24`. **The self-multiplication stable floor for result-E is at E_input = 24**, not 16.

### MUL(x, ONE) — Identity test

- Identity failures: **0 / 576** across E=12..20.
- `MUL(x, ONE)` is safe even in the collapse zone (E<16). The identity holds because `exp_sum = E + 32 − 32 = E`, which never wraps.
- Compilers may use `MUL(x, ONE)` as a free pass-through even for out-of-range operands.

### ADD(x, x) — Fraction addition / boundary crossing

Every E value in the scan shows identical rollover behavior:

| E | Rollover% | f values crossing E boundary |
|---|-----------|------------------------------|
| 12–14 | 50% | f ≥ 32 (32/64) — E increments but stays in collapse zone |
| **15** | **50%** | **f ≥ 32 (32/64) — result E = 16 (crosses into stable!)** |
| 16–20 | 50% | f ≥ 32 (32/64) — stays in stable zone |

**Key finding:** ADD can **rescue** E=15 values into the stable zone. For f ≥ 32, the Thoth Rollover increments E from 15 to 16. Half of all E=15 codewords are one ADD operation away from stability.

### MUL(x, HALF) — Scale-down

- UF events in E=12..20: **0**.
- Fraction perfectly preserved at every step (f_b=0 → f_result=f_a analytically).
- Scale-down traversal through the collapse zone is completely safe for non-self operations.

---

## HBS-13B — Saturation Edge Scan

**Scope:** `E = 44..52`, `f = 0..63`. Four operations per (E, f) pair.

### MUL(x, x) — Self-product OVF map

| E | OVF% | NORM% | Unique results | Result-E range |
|---|------|-------|---------------|----------------|
| 44 | 0% | 100% | 64 | 56..57 |
| 45 | 0% | 100% | 64 | 58..59 |
| 46 | 0% | 100% | 64 | 60..61 |
| **47** | **0%** | **100%** | **64** | **62..63** |
| **48** | **100%** | **0%** | **1** | **63** |
| 49 | 100% | 0% | 1 | 63 |
| 50 | 100% | 0% | 1 | 63 |

The OVF cliff at E=48 is equally sharp: fraction-independent, single-E-step, no mixing.

**Note:** MUL(x,x) at E=44..47 produces `E_result ∈ [56..63]` — near or in the saturation boundary. Just as E=16 self-products fall back into the collapse zone, E=44..47 self-products push close to the saturation boundary.

### MUL(x, ONE) — Identity test

- Identity failures: **0 / 576** across E=44..52. Safe in OVF zone too.

### ADD(x, x) — Saturation boundary crossing

Symmetric to the collapse boundary:
- E=47: 50% of f values (f ≥ 32) cause rollover → E=48 → OVF zone.
- ADD can **push** E=47 values into saturation.

### MUL(x, TWO) — Scale-up

- OVF events in E=44..52: **0** (MUL(x, TWO) OVF occurs only when E+1 ≥ 64, i.e., E=63).
- Scale-up traversal is safe through the saturation edge scan range.

---

## HBS-13C — Information Migration Test

**Seeds:** E ∈ {24, 32, 40}, f=0. **32 steps** scale-down (×HALF) and scale-up (×TWO).

### Scale-Down Trajectories

| Seed E | Steps to floor | Final E (32 steps) | Notes |
|--------|---------------|-------------------|-------|
| 24 | **25** (E_seed + 1) | 0 (floored) | 8 UF events (steps 25–32) |
| 32 | none in 32 steps | 0 | No UF — arrives at E=0 exactly |
| 40 | none in 32 steps | 8 | Still alive at E=8 |

The floor arrival rule is: **steps to first UF = E_seed + 1**. For E=24: floor at step 25. For E=32: E=0 at step 32 (no UF since `exp_sum = 0+31−32 = −1` fires at the *next* step beyond 32).

### Scale-Up Trajectories

| Seed E | Steps to OVF | Final E (32 steps) | Notes |
|--------|-------------|-------------------|-------|
| 24 | none in 32 steps | 56 | 8 steps short of OVF |
| 32 | **32** | 63 (OVF at step 32) | Reaches saturation exactly |
| 40 | **24** | 63 (OVF + 8 absorbed) | 9 OVF events (steps 24–32) |

Steps to OVF = 63 − E_seed (= 64 − E_seed for strict: 63−E+1 = 64−E). OVF fires when `E_result = E + steps = 64`.

**Information migration is purely exponent-channel.** The fraction field is inert throughout both scale-down and scale-up chains (f_b=0 preserves f_a at every step). Entropy loss occurs only at boundary events (floor: f=0 forced; OVF: f=63 forced).

---

## HBS-13D — Recovery Test

**Anchors:** E ∈ {24, 32, 40}, f=31. Two scenarios per anchor.

### Scenario A — Near-Boundary (20 steps, no floor)

| Anchor E | Steps | Bottom E | Bottom f | Recovered E | Recovered f | E-match | f-match |
|----------|-------|----------|----------|-------------|-------------|---------|---------|
| 24 | 20 | 4 | 31 | 24 | 31 | YES | YES |
| 32 | 20 | 12 | 31 | 32 | 31 | YES | YES |
| 40 | 20 | 20 | 31 | 40 | 31 | YES | YES |

**100% perfect recovery.** Both E and f are identically restored. The chain traverses deep into the collapse zone (E=4 for the E=24 anchor) without any information loss because scale-down/scale-up with f=0 multipliers preserve the fraction field exactly.

### Scenario B — Through-Floor (floor_steps = anchor_E + 2)

| Anchor E | Steps | Bottom E | Bottom f | Recovered E | Recovered f | E offset | f-match |
|----------|-------|----------|----------|-------------|-------------|----------|---------|
| 24 | 26 | 0 | 0 | 26 | 0 | **+2** | NO (was 31) |
| 32 | 34 | 0 | 0 | 34 | 0 | **+2** | NO (was 31) |
| 40 | 42 | 0 | 0 | 42 | 0 | **+2** | NO (was 31) |

**The +2 E offset is deterministic and universal.** It arises because:
1. The floor absorbs 2 descent steps (one reaches E=0 without UF; the second fires UF and produces floor).
2. Scale-up from floor has no absorbing behavior — it climbs back up for all applied steps.
3. Net effect: 2 "wasted" down steps consume steps without corresponding up-steps.

**Fraction is irrecoverably 0** for all anchors after floor transit.

---

## HBS-13E — Fraction Survival Analysis

### Collapse Boundary Zone (E = 14..18)

| E | MUL(x,x) unique | Eff. bits | Identity OK | MUL(x,x) result-E |
|---|----------------|-----------|-------------|-------------------|
| 14 | 1 | 0.00 | 64/64 | 0 (floor) |
| 15 | 1 | 0.00 | 64/64 | 0 (floor) |
| **16** | **64** | **6.00** | **64/64** | **0..1** |
| 17 | 64 | 6.00 | 64/64 | 2..3 |
| 18 | 64 | 6.00 | 64/64 | 4..5 |

**Fraction cliff is absolute:** E=14 and E=15 have 0 effective fraction bits after MUL(x,x). E=16 immediately restores 6.00 effective bits (64 unique outputs) — but the result-E is 0..1, still in the collapse zone.

The identity operation preserves 6.00 effective bits at all five E values. The cliff exists only for self-multiplication.

### Saturation Boundary Zone (E = 46..50)

| E | MUL(x,x) unique | Eff. bits | Identity OK | MUL(x,x) result-E |
|---|----------------|-----------|-------------|-------------------|
| 46 | 64 | 6.00 | 64/64 | 60..61 |
| **47** | **64** | **6.00** | **64/64** | **62..63** |
| **48** | **1** | **0.00** | **64/64** | **63** |
| 49 | 1 | 0.00 | 64/64 | 63 |
| 50 | 1 | 0.00 | 64/64 | 63 |

Symmetric to the collapse side: 6.00 effective bits at E=47, 0 at E=48. The saturation cliff is equally sharp.

---

## HBS-13F — Boundary Geometry Classification

### Collapse Boundary (E=15 ↔ 16)

| E | UF rate | Row type |
|---|---------|----------|
| 15 | 100.0% | PURE |
| 16 | 0.0% | PURE |

No fraction dependence, no mixing. **CLIFF geometry confirmed.**

### Saturation Boundary (E=47 ↔ 48)

| E | OVF rate | Row type |
|---|---------|----------|
| 47 | 0.0% | PURE |
| 48 | 100.0% | PURE |

**CLIFF geometry confirmed.** Symmetric to the collapse boundary.

### Hysteresis

No state carries between operations. The transition is stateless — purely a function of current operand E values. **No hysteresis.**

### ADD-Induced Crossing

| Boundary | Crossing direction | f threshold | Fraction crossing |
|----------|-------------------|-------------|-------------------|
| E=15 → 16 | Upward (rescue) | f ≥ 32 | 32/64 (50%) |
| E=47 → 48 | Downward (push into OVF) | f ≥ 32 | 32/64 (50%) |

ADD Thoth Rollover is a **hidden phase-transport mechanism**. It applies only when f ≥ 32 (the upper half of the fraction range). This means the boundary is porous to ADD — 50% of boundary-zone codewords are one ADD operation away from crossing.

---

## Final Classification: HORUS v3 Gap Analysis

### Collapse Boundary (E = 15 ↔ 16)

| Property | Measurement |
|----------|-------------|
| Information loss type | Immediate floor — f=0 forced |
| Recoverability | Partial — E recovers with +2 deterministic offset; f irrecoverable |
| Fraction survival | 0 eff. bits below boundary (E<16) |
| Geometry | CLIFF — single-E-step, fraction-independent |
| ADD-induced crossing | 50% of E=15 inputs (f≥32) rescued by ADD rollover |

### Saturation Boundary (E = 47 ↔ 48)

| Property | Measurement |
|----------|-------------|
| Information loss type | Max codeword — f=63 forced |
| Recoverability | Partial — E direction recovers; f=63 contamination persists |
| Fraction survival | 0 eff. bits above boundary (E>47) |
| Geometry | CLIFF — single-E-step, fraction-independent |
| ADD-induced crossing | 50% of E=47 inputs (f≥32) pushed into OVF by ADD rollover |

### Global Assessment

| Category | Status |
|----------|--------|
| Recoverable by Scaling | PARTIAL — E only, not f |
| Recoverable by Scheduling | YES — depth monitor prevents descent into floor |
| Requires Encoding Change | NO — boundaries are algebraic properties of Bias-32 |
| Inherent Limitation | YES — 50% exponent utilisation is an architectural constant |

### Safe-Operations Summary Near Boundaries

| Operation | Behavior near E=15..16 | Behavior near E=47..48 |
|-----------|----------------------|----------------------|
| MUL(x, ONE) | Identity — fully safe | Identity — fully safe |
| MUL(x, HALF) | Safe, no UF | Safe, no OVF |
| MUL(x, TWO) | Safe, no UF | Safe, no OVF |
| MUL(x, x) | UF at E≤15 (cliff) | OVF at E≥48 (cliff) |
| ADD(x, x) with f≥32 | Crosses E=15→16 upward | Crosses E=47→48 downward |
| Round-trip (no floor) | Perfectly reversible | Perfectly reversible |
| Round-trip (through floor) | Irreversible (+2 E, f=0) | — |

---

*Generated by `tb/tb_hbs13_boundary_gap.v` + `sim/analyze_hbs13.py`*

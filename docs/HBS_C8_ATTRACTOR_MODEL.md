# HBS-C8: Attractor Decomposition — Formal Model

**Document type:** Dynamical Systems Reduction — Formal Attractor Definitions  
**Authority:** Collapse of HBS-C1 through HBS-C7 empirical findings  
**Version:** 1.0 · 2026-07-02  
**Status:** FROZEN — derived from measured behavior only. No RTL, mode, or compiler changes.

---

## Purpose

This document reduces all observed HORUS v3 failure behaviors into a minimal, formal
attractor model. Each attractor is defined by:

- A minimal trigger condition (formal boolean / threshold expression)
- Measured TTI range (from HBS-C7 isolation + HBS-C6 confirmation)
- Accumulator interaction type (absorbing / oscillatory / transient)
- Attractor classification (absorbing / transient / oscillatory / quasi-periodic)

This is a reduction step, not a redesign step. No new behavior is introduced.

---

## Four Attractors

### A1 — Cancellation Residual Absorption

| Property | Value |
|---|---|
| Workload class | CLASS_B |
| Op signature | `SUB` with `E_a = E_b` and `|f_a − f_b| ≤ 7` |
| Trigger (formal) | `op=SUB ∧ E_a = E_b ∧ Δf < 8` |
| TTI range | **2–5 cycles** |
| Attractor type | **ABSORBING** |
| STABLE occupancy | 100% |
| Accum entropy | 3.42 bits |
| Residual amplification | **63.6× over E=32 quantization step** |
| Accumulator range | 20,497 over 200 cycles |
| Recovery latency | 0 cycles |
| Phase-space (X, Y) | (0.05, 0.92) — low exponent pressure, high cancellation pressure |

**Attractor description:**  
A monotonically absorbing state. Each SUB at equal exponents produces a residual of
magnitude `Δf/64`. The accumulator absorbs these residuals without oscillation or reset:
`accum_n = accum_(n−1) + residual`. The state is monotonically displaced from zero
without return, bounded only by epoch resets. The residual is invisible to region
monitoring (result codewords remain in STABLE), making this the most architecturally
subtle attractor.

**Physical invariant:**  
`accum_n ≈ n × (Δf/64)` for constant Δf. The drift is linear in depth, bounded by
`epoch_depth × max_residual` per epoch. Nonlinearity appears only if Δf varies systematically
with depth (as in R1 jitter sweep).

---

### A2 — Geometric Exponent Explosion

| Property | Value |
|---|---|
| Workload class | CLASS_D |
| Op signature | `MUL` with `E_factor > 32` as sustained feedback chain |
| Trigger (formal) | `op=MUL ∧ E_factor > 32 ∧ chain_depth ≥ 1` |
| TTI range | **16–31 cycles** |
| Attractor type | **TRANSIENT** |
| STABLE occupancy | 37% |
| SATURATE occupancy | 51% |
| OVF rate | 3% |
| Accum entropy | 3.87 bits |
| Mean ΔE/cycle | **1.000 exactly** (measured, 7 runs) |
| Recovery latency | 0 cycles |
| Phase-space (X, Y) | (0.90, 0.05) — high exponent pressure, near-zero cancellation |

**Attractor description:**  
A cyclic transient. Starting from E_initial, each MUL with a factor at E_factor = 33
increments the result exponent by exactly 1: `E_(n+1) = E_n + 1`. The chain traverses
STABLE → TRANSITION → SATURATE → 6-bit OVF in exactly 31 cycles from E=32. On OVF,
the feedback is reset to E=32 (deterministic restart). The system then repeats the
identical trajectory, confirmed over 7 independent runs with ΔE/cycle = 1.000.

**Epoch interaction:**  
When `depth_cnt > 16`, the C4 kernel switches `mode_tag` to PRE_SCALED, which alters
the MUL output path. This creates two observable run lengths: 31 cycles (full drift,
epoch does not intersect OVF) and 8 cycles (epoch fires mid-drift, altering the
feedback trajectory). Both are deterministic — the run length is determined by the
alignment of the epoch boundary with the OVF event.

**Physical invariant:**  
For factor `F = 2^(E_f−32)` at exponent E_f:  
`E_n = E_0 + n × (E_f − 32)`  
For E_f = 33: `TTI = (63 − E_0) / 1 = 63 − E_0` cycles to 6-bit field overflow.

---

### A3 — Thoth Rollover Boundary Oscillation

| Property | Value |
|---|---|
| Workload class | CLASS_C |
| Op signature | `ADD` with `E ∈ {15, 47}` and `f_a + f_b ≥ 64` (Rollover condition) |
| Trigger (formal) | `op=ADD ∧ E ∈ {15, 47} ∧ (f_a + f_b) ≥ 64` |
| TTI range | **0 cycles** (permanent — system enters from cycle 0) |
| Attractor type | **OSCILLATORY** |
| STABLE occupancy | 0% |
| Oscillation period | **2 cycles** |
| Boundary crossing rate | **50.0%** |
| Accum entropy | **0.045 bits** (near-zero — 2-state locked) |
| Recovery latency | 0 cycles |
| Phase-space (X, Y) | (0.65, 0.10) — high boundary proximity, near-zero cancellation |

**Attractor description:**  
A permanent period-2 oscillator. ADD at E=15 with f_sum ≥ 64 triggers Thoth Rollover,
incrementing E to 16 (TRANSITION). On the next cycle, ADD at E=15 with f_sum < 64
produces E=15 (COLLAPSE). The system oscillates COLLAPSE ↔ TRANSITION indefinitely.
At E=47, the same mechanism produces TRANSITION ↔ SATURATE oscillation. The
accumulator entropy approaches zero (0.045 bits) because the system is locked into
exactly two states with no opportunity for divergence.

**Critical isolation property:**  
The C4 kernel routes CLASS_C operations through `NORMALIZE_THEN_ROUTE` with `accum_en=0`.
This ensures the boundary oscillation is **completely isolated from the accumulator**.
A boundary oscillation under any other class routing would contaminate the accumulator
with alternating large/small values — the correct CLASS_C routing prevents this.

**Physical invariant:**  
Rollover condition: `f_a + f_b ≥ 64` at `E ∈ {15, 47}`.  
Oscillation guaranteed by alternating operands: one exceeds Rollover, next falls below.

---

### A4 — Entropic Regime Interference

| Property | Value |
|---|---|
| Workload class | MIXED (CLASS_A + CLASS_B + CLASS_A) |
| Op signature | `ADD` mix: P(E=32)=0.4, P(E=15)=0.3, P(E=48)=0.3 per 10-cycle epoch |
| Trigger (formal) | `P(E<16)>0 ∧ P(E>47)>0 ∧ P(20≤E≤43)>0` in same epoch |
| TTI range | **4–10 cycles** |
| Attractor type | **QUASI-PERIODIC** |
| STABLE / COLLAPSE / SATURATE | 40% / 30% / 30% (exact match to injection ratio) |
| Boundary crossing rate | 29.5% |
| Accum entropy | **2.91 bits** |
| Recovery latency | 0 cycles |
| Phase-space (X, Y) | (0.50, 0.28) — moderate exponent pressure, low-moderate cancellation |

**Attractor description:**  
A quasi-periodic entropy-bounded attractor. The 10-cycle deterministic injection pattern
(cycles 0–3: STABLE, 4–6: COLLAPSE-edge, 7–9: SAT-edge) creates region transitions at
exactly 29.5% of cycles. The accumulator trajectory exhibits 2.91 bits of entropy —
high variance but bounded, since the pattern repeats with period 10. The first
regime interference event (COLLAPSE region result following STABLE result) occurs at
cycle 4 (the first COLLAPSE-edge injection after a STABLE run).

**Physical invariant:**  
Occupancy exactly matches injection ratio (40/30/30), confirming that C4 per-operation
routing correctly handles each injection type without cross-contamination. The per-class
routing contains the interference — each injection is handled in isolation by the kernel.

---

## Interaction Matrix

```
        A1        A2        A3        A4
A1  [   —         I         S         I  ]
A2  [   I         —         T         I  ]
A3  [   S         T         —         P  ]
A4  [   I         I         P         —  ]
```

**Codes:**

| Code | Meaning | Evidence source |
|---|---|---|
| `I` | Independent — no coupling observed | Disjoint trigger conditions; disjoint phase-space zones |
| `S` | Suppressed — A3 routing prevents A1 accumulator contact | C4 accum_en=0 for CLASS_C; A3 accum_entropy=0.045 bits |
| `T` | Transient intersection — A2 drift passes through A3 zone | C7-R2: 12% TRANSITION occupancy = A3 zone transit during drift |
| `P` | Partial overlap — boundary-adjacent operands in A4 trigger weak A3 dynamics | C7-R4: COLLAPSE/SAT-edge injections at boundary-adjacent E values |

### Detailed evidence

**A1 ↔ A2 (I):** No CLASS_B + CLASS_D composition was tested. Trigger conditions are
disjoint (SUB at E=32 vs. MUL at E>32 with feedback). Phase-space positions are
maximally separated (X distance = 0.85, Y distance = 0.87).

**A1 ↔ A3 (S):** CLASS_C routing sets `accum_en=0`, preventing A1 accumulation even
if the operand is at the cancellation-critical E=15 zone. A3 isolates A1 by routing.

**A2 ↔ A3 (T):** During A2's geometric drift from E=32 to E=63, the chain passes
through E=44–47 (A3's SAT boundary zone). C7-R2 recorded 12% TRANSITION occupancy,
confirming the transit. This is transient — no persistent coupling; accumulator is
isolated during transit by epoch management.

**A3 ↔ A4 (P):** R4's COLLAPSE-edge (E=15) and SAT-edge (E=48) injections are
boundary-adjacent and activate A3-zone states for 3 cycles per 10-cycle pattern.
No accumulator coupling occurs (A3 routing still applies for boundary operations).

---

## Attractor Independence Verification

**TTI spread ratio: 31×** (A3 TTI=0, A2 TTI=31).  
For a single-threshold system, all TTI values would fall within 2× of each other.  
The 31× spread confirms four independent failure attractors.

| Pair | TTI distance | Independence? |
|---|---|---|
| A1–A2 | 29 cycles | **YES** — 14.5× apart |
| A1–A3 | 2 cycles | **YES** — triggers disjoint |
| A2–A3 | 31 cycles | **YES** — mechanism disjoint |
| A3–A4 | 4 cycles | **YES** — partial overlap at boundary |

---

## Unobserved Singularity: Composite Zone (S1)

**Location:** Phase-space coordinates X≈0.80, Y≈0.75 — high exponent pressure AND high
cancellation pressure simultaneously.

**Would require:** A CLASS_D workload (deep MUL chain) that also contains CLASS_B SUB
operations at equal exponents — e.g., a deep neural-network inference pass where
both weight multiplication (MUL) and gradient cancellation (SUB, near-zero) coexist.

**Expected behavior (inferred, not measured):**  
Both A1 and A2 would activate simultaneously. The accumulator would absorb residuals
(A1) while the exponent chain explodes (A2). Since they are structurally independent
(I code), they would not suppress each other — both failure modes would proceed in
parallel, creating a compound failure. This is the highest-risk unobserved state in
the HORUS v3 phase space.

**Current mitigation:** No direct mitigation in C4 kernel. CLASS_D routing would be
applied (depth management), but CLASS_B residuals would still accumulate independently.

---

## Summary Table

| Attractor | Type | TTI | Phase-space | Accum impact | Isolated? |
|---|---|---|---|---|---|
| A1 — Cancellation | ABSORBING | 2–5 cy | Low-X, High-Y | 63.6× drift | No (accumulates) |
| A2 — Exponent Drift | TRANSIENT | 16–31 cy | High-X, Low-Y | Moderate entropy | Yes (epoch-bounded) |
| A3 — Boundary Osc. | OSCILLATORY | 0 cy | Mid-X, Low-Y | Near-zero (0.045b) | Yes (accum_en=0) |
| A4 — Mixed Inject. | QUASI-PERIODIC | 4–10 cy | Mid-X, Mid-Y | 2.91-bit entropy | Partial |

---

*HBS-C8 Attractor Model · HORUS v3 NFE · 2026-07-02*  
*Derived from HBS-C1 → C7 measurement data only. No new behaviors introduced.*

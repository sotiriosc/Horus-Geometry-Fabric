# HBS-C12: Adversarial Reality Collapse Suite — Results

## Overview

| Metric | Value |
|--------|-------|
| Total cycles | 14,600 |
| Suites | 5 (C12A–C12E) |
| Total epochs classified | 913 |
| **Attractor retention** | **100.00%** |
| Verified NEW regimes | **0** |
| Phase-space stability | 0.0372 (low = stable) |
| **Final verdict** | **PARTIALLY_ROBUST** |

---

## C12A — Noise Injection Collapse Test

**Setup**: SUB E=32 baseline (A1 workload) stressed under 6 noise levels (300 cycles each):

| Level | Description | A1 % | A2 % | OVF% | Dom | A1 Drop |
|-------|-------------|------|------|------|-----|---------|
| NL0 | Baseline (0% noise) | 100.0% | 0% | 0.00% | A1 | 0.0 pp |
| NL1 | 10% fraction scramble | 100.0% | 0% | 0.00% | A1 | 0.0 pp |
| NL2 | 30% fraction scramble | 100.0% | 0% | 0.00% | A1 | 0.0 pp |
| NL3 | 60% fraction scramble | 100.0% | 0% | 0.00% | A1 | 0.0 pp |
| NL4 | Exponent ±1 jitter | 100.0% | 0% | 0.00% | A1 | 0.0 pp |
| NL5 | 10% sign inversion | 100.0% | 0% | 0.00% | A1 | 0.0 pp |

**Finding**: **Zero noise sensitivity.** The A1 cancellation attractor is completely invariant
to fraction scrambling (up to 60%), exponent jitter (±1), and low-rate sign inversions.

**Explanation**: The epoch classifier determines A1 from the *structural statistics* of the
epoch (pct_stable, acc_delta, E_slope), not from operand-level precision. Even with 60%
of the fraction bits randomized:
- The result E remains near E=27–28 (STABLE region) because the E component dominates
- The STABLE region occupation stays > 70%
- Accumulator contamination still grows (accum_delta > 100)
- All three A1 conditions still hold → classification is noise-immune

**Implication**: The A1 attractor is *structurally stable*. Operand-level noise up to
60% does not push the system out of A1. This means the C4 classifier's region-based
routing is robust to moderate data corruption.

---

## C12B — Distribution Drift Over Long Horizon

**Setup**: 10,000-cycle continuous stream, **no epoch reset, no accum_clr**. E_in drifts
from 32 → 50 over 10,000 cycles (increment every ~526 cycles). Mixed ADD+SUB operations.

### Attractor Migration

| Drift Step | E_in | Window | Dominant |
|-----------|------|--------|----------|
| 0–13 | 32–43 (STABLE) | Cycles 0–6,999 | **A1** |
| 14–19 | 44–50 (TRANSITION/SAT) | Cycles 7,000–9,999 | **A3** |

**Migration path**: A1 → A3 (exactly two attractors, clean single transition)

**Finding**: The system transitions cleanly from A1 to A3 as E drifts through the
STABLE→TRANSITION boundary. The transition occurs at the C8-predicted boundary (E≈44,
entering TRANSITION zone). **This validates the C8 attractor model's boundary placement.**

The transition is not abrupt but gradual (the first A3-dominant window appears at drift
step 14 = cycle 7,000). No bifurcation, no lock-in, no hysteresis — the system migrates
smoothly as the input distribution drifts.

### Accumulator Unbounded Growth

With no `accum_clr`, the accumulator grows monotonically over 10,000 cycles. The final
accum value is large (orders of magnitude above normal operating range). This is the
primary PARTIALLY_ROBUST finding: **the epoch-reset mechanism is not optional for
sustained operation.** Without it, physical state diverges even though attractor
classification remains valid.

**The C4 compiler's `EPOCH_DEPTH=16` reset is the robustness boundary condition.**

---

## C12C — Adversarial Cancellation Chains

**Setup**: MUL-based cancellation chains — MUL(feed, +2) alternating with MUL(feed, −2)
should produce zero net accumulation. Five corruption patterns:

| Pattern | Description | Dom | Residual Amp | OVF% |
|---------|-------------|-----|-------------|------|
| P0 | Clean cancel | A2 | 1.1× | 3.0% |
| P1 | E±2 mismatch | A2 | **34,368×** | 6.5% |
| P2 | 30% fraction noise | A2 | 2.0× | 3.0% |
| P3 | 10% sign flip | A2 | **65,152×** | 3.5% |
| P4 | Full corruption | A2 | 3.5× | 5.5% |

**Key finding 1**: All patterns classify as **100% A2** (MUL-chain exponent drift). The
adversarial cancellation does NOT create a new attractor — it is fully explained as A2
dynamics because MUL is the dominant operation.

**Key finding 2**: **Catastrophic residual amplification from asymmetric corruption:**

- **P1 (E±2 mismatch)**: When the negative MUL operand has E=35 instead of E=33, the
  cancellation fails catastrophically — the ×(−4) step does not cancel ×2. Residual
  amplification = 34,368×. The accumulator fills with exponentially growing MUL products.

- **P3 (10% sign flip)**: When 10% of the intended negative MUL operands accidentally
  become positive (×2 instead of ×(−2)), the accum grows 65,152× from baseline. A small
  sign-bit error rate creates catastrophic cancellation failure.

**P2 and P4 are more robust**: Fraction-level noise (P2: 30%) produces only 2× amplification
because the MUL magnitude is dominated by the E component, not the fraction. Full
corruption (P4) also only 3.5×, because E jitter partially cancels with fraction noise.

**Implication**: The critical vulnerability in adversarial cancellation is **exponent
precision and sign integrity**, not fraction precision. The C4 compiler must protect
the E field and sign bit under adversarial inputs.

---

## C12D — Semantic Mismatch Stress Test

**Setup**: Same hardware, same RTL, four different "semantic interpretations":

| Mode | Design | Dom | A2% | Switch Rate |
|------|--------|-----|-----|-------------|
| INT-like | ADD E=32, F cycling 0..63 | A1 | 0% | 0.0% |
| PROB-like | ADD E=36..39, probability sim | A1 | 0% | 0.0% |
| ENERGY-like | MUL chain E=44..47 | A2 | 92.3% | 8.3% |
| MIXED | Rotate INT/PROB/ENERGY/INT every 50 cy | A1+A2+A4 | 15.4% | **25.0%** |

**Finding 1 — Semantic invariance of A1**: Both INT-like and PROB-like operations, despite
treating the bit patterns as representing fundamentally different physical quantities
(integers vs. probabilities), produce identical A1 dynamics. The attractor is determined
by the *operation structure* (ADD in STABLE band), not the semantic interpretation.

**Finding 2 — ENERGY-like = A2**: High-E MUL chains classify as A2 regardless of whether
the operands "mean" energy values or any other quantity. Physics doesn't care about
semantics — high-E MUL chains drift to OVF.

**Finding 3 — MIXED mode highest instability**: The 25% epoch-to-epoch switching rate
in MIXED mode is the highest observed in any suite. When semantic context switches every
50 cycles (< 4 epochs), the attractor changes frequently. However, all switches remain
within A1, A2, and A4 — no new regime emerges from semantic confusion.

**Implication**: HORUS v3 has no semantic awareness — the attractor is entirely determined
by operational parameters (op_sel, E, mode_tag). This is both a limitation and a strength:
the system is predictable regardless of what the operands "mean," but it provides no
protection against semantic misinterpretation.

---

## C12E — Failure Boundary Expansion Test

**Setup**: Deliberate boundary stress — push system into repeated SAT/COLLAPSE/oscillation:

| Pattern | Design | Dom | A3% | A2% | A4% |
|---------|--------|-----|-----|-----|-----|
| SAT chain | ADD at E=47 | **A3** | 100% | 0% | 0% |
| COLL chain | ADD at E=16 | **A3** | 100% | 0% | 0% |
| BOUNCE | Alternating E=47/E=15 | **A3** | 100% | 0% | 0% |
| DEEP_BOUNCE | MUL push + SUB cancel | A2+A4 | 0% | 38.5% | 38.5% |
| MAXIMAL | All regions cycling | A1+A4 | 0% | 0% | 38.5% |

**Finding 1 — A3 perfect boundary capture**: SAT chain, COLL chain, and BOUNCE all
classify as 100% A3. The boundary lock (Rollover at E=15/47) is perfectly stable and
perfectly classifiable. No OVF in any of these — the boundary is an absorbing attractor,
not a failure mode.

**Finding 2 — DEEP_BOUNCE creates A2/A4 mix**: The 30-cycle MUL push followed by
10-cycle SUB cancel creates a complex 38.5% A2 / 38.5% A4 / 23.1% A1 distribution.
The MUL phase (A2) and the mixed-region result of MUL+SUB (A4) share epochs. No new
attractor needed — DEEP_BOUNCE is fully explained as an A2/A4 composite.

**Finding 3 — MAXIMAL stays within A1/A4**: The most adversarial pattern (cycling through
SAT/COLL/MUL/SUB every 10 cycles) produces 61.5% A1 + 38.5% A4. The SUB cycles
produce A1, and the multi-region injection creates A4 episodes. Zero OVF events —
the epoch-depth management prevents accum from reaching saturation.

**Phase-space topology**: No new metastable regimes emerge under boundary expansion.
The A1–A4 topology is stable under all tested adversarial boundary conditions.

---

## Aggregate Results

### Attractor Distribution Across All 913 Epochs

```
A1: 586 epochs (64.2%)  — Cancellation / stable accumulation
A2:  83 epochs  (9.1%)  — Exponent drift / MUL chain
A3: 233 epochs (25.5%)  — Boundary oscillation
A4:  11 epochs  (1.2%)  — Multi-region entropy
NEW:  0 epochs  (0.0%)  — [NONE]
```

**100% attractor retention. Zero new regimes in 14,600 adversarial cycles.**

---

## Final Verdict

```
PARTIALLY_ROBUST
```

**Criteria assessment:**

| Criterion | Value | Threshold | Pass? |
|-----------|-------|-----------|-------|
| Attractor retention | 100.0% | ≥ 95% | ✅ |
| Verified new regimes | 0 | 0 | ✅ |
| Drift magnitude | 0.053 | ≤ 0.20 | ✅ |
| Phase stability | 0.037 | — | ✅ |
| Accum unbounded (no reset) | **True** | False | ❌ |

The single failing criterion: **without epoch resets (C12B), the accumulator grows
without bound.** This is not a model failure — the attractor classification remains
100% correct throughout — but it reveals that the C4 compiler's epoch-depth reset
mechanism is a **mandatory operational constraint**, not an optional optimization.

**With epoch resets (normal HORUS v3 operation): the system would be ROBUST.**

**Without epoch resets (pathological long-horizon mode): the system is PARTIALLY_ROBUST.**

---

## Critical Security Finding: Exponent Mismatch Amplification

From C12C:

| Attack | Mechanism | Amplification |
|--------|-----------|--------------|
| P1: E±2 mismatch | Cancel operand E_factor ≠ forward E_factor | **34,368×** |
| P3: 10% sign flip | Cancel sign not inverted 10% of the time | **65,152×** |

These represent **catastrophic failure modes for adversarial inputs** where an attacker
can corrupt the sign bit or exponent by a single step. Under the C4 compiler's normal
operation, the compiler routes based on `classify(E_in)` before operations are applied —
but if the operand generation itself is corrupted (adversarial input), the exponent
and sign fields must be validated before routing.

**Recommendation** (documentation only, no RTL change): The C4 compiler specification
should include an input validation layer for adversarial-input contexts, checking that
cancellation operand E_factor values are within ±1 of the expected cancel magnitude.

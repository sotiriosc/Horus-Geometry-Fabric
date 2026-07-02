# HORUS v3 Execution Mapping

**Specification Type:** Formal Execution Contract  
**Authority:** HBS-12, HBS-13, HBS-14 (validated simulation results)  
**Version:** 1.0 · 2026-07-02  
**Status:** GOLD — no further modification without new validated HBS results  

---

## Preamble

HORUS v3 is not a continuous-domain floating-point arithmetic system. It is a **phase-space arithmetic system** in which the 6-bit stored exponent field partitions the representable range into four discrete execution phases with distinct computational semantics, failure modes, and information-preservation contracts.

This document formalizes that partition as a compiler and scheduler contract. All claims are derived exclusively from validated HBS-11 through HBS-14 measurements. No speculative physics is included.

---

## 1. Region-to-Computation Mapping

### 1.1 Arithmetic Region Definitions

The four execution phases are defined by `stored_E` (the 6-bit exponent field of the 13-bit NFE codeword, Bias-32 encoded):

```
stored_E (decimal):  0        15 | 16              47 | 48       63
                     [  COLLAPSE  ][     STABLE        ][  SATURATION ]
                                 ↑                   ↑
                            Collapse              Saturation
                            Cliff (HBS-12/13)     Cliff (HBS-12/13)
```

Transition bands are the single-exponent rows immediately flanking each cliff. They are not independent regions but **cliff-adjacent positions** with asymmetric semantics (one side stable, one side terminal).

| Region | stored_E Range | Size | % of Exponent Space |
|---|---|---|---|
| Stable Band | 16 – 47 | 32 values | 50% |
| Collapse Band | 0 – 15 | 16 values | 25% |
| Saturation Band | 48 – 63 | 16 values | 25% |
| Collapse Cliff | 15 ↔ 16 | boundary | — |
| Saturation Cliff | 47 ↔ 48 | boundary | — |

---

### 1.2 Stable Band: stored_E = 16 – 47

**Computational role:** Primary inference computation domain. All arithmetic operations produce valid, information-preserving results with deterministic and fully characterized output distributions.

**Allowed operations:** MUL, ADD_FRAC, SUB_FRAC, NOP — all permitted.

**UF/OVF behavior:**
- `underflow_flag` = 0 for all in-band operations (both operands in stable band)
- `exp_ovf_flag` = 0 for all in-band operations (result E ∈ [0..63])
- Exception: ADD_FRAC at E=47 with f ≥ 32 triggers Thoth Rollover and increments E to 48, crossing the saturation cliff. Compiler MUST prevent this condition in safety-critical paths.

**Information contract:**
- MUL: **preserved** — result exponent deterministic; fraction reconstructed with full 6-bit fidelity; no collision (at E=32: 64 unique MUL inputs → 64 unique outputs, HBS-12B verified)
- ADD_FRAC without rollover: **preserved** — fraction incremented, exponent unchanged
- ADD_FRAC with Thoth Rollover: **transformed** — E incremented, fraction right-shifted; rollover is non-reversible (HBS-12F: 0% reversibility on rollover path)
- SUB_FRAC Guard-A (f_a ≥ Δ): **preserved** — fraction decremented, exponent unchanged
- SUB_FRAC Guard-B (f_a < Δ): **transformed** — 2-cycle pipeline; exponent decremented, fraction renormalized; reversibility regime-dependent
- Identity: `MUL(x, ONE)` = x for all x in stable band. Zero-cost identity operation.

**Thoth Rollover boundary (ADD):**
- Fires when `f_a + Δ ≥ 64` (fractional carry into mantissa bit[7])
- Effect: `E ← E + 1`, `f_result ← mant_sum[5:0]`
- At E=47: rollover transports operand into saturation band (E=48)
- Trigger threshold: f ≥ 32 for symmetric ADD(x,x)

**Validated statistics (HBS-12, HBS-14):**
- MUL UF rate at E=32: **0.0%**
- MUL OVF rate at E=32: **0.0%**
- Floor rate during sustained stable-phase operation: **0.0%**
- Result entropy at E=32: **5.990 bits** (≈ theoretical max 6.0 bits)

---

### 1.3 Collapse Band: stored_E = 0 – 15

**Computational role:** Sentinel domain. Codewords in this band are the arithmetic residue of exponent underflow cascades; they do not carry inference-relevant information in normal operation. They function as **terminal states** from the perspective of MUL-based computation.

**Allowed operations (with semantics):**

| Operation | Outcome | Notes |
|---|---|---|
| MUL(x, x) with both E < 16 | `UF → NFE_FLOOR (0x000)` | 100% UF rate; floor attractor |
| MUL(x, y) with E_x + E_y < 32 | `UF → NFE_FLOOR` | Boundary condition |
| ADD_FRAC(x, x) with f ≥ 32 | Result E = E_x + 1 | May rescue into stable if E_x = 15 |
| NOP | No-op; operand unchanged | Safe always |

**UF/OVF behavior:**
- `underflow_flag` fires unconditionally for MUL at E=15 (E_result = 15+15−32 = −2)
- ADD_FRAC can rescue: at E=15 with f ≥ 32, Thoth Rollover → E=16 (enters stable band)
- ADD rescue threshold: **f ≥ 32 required** (validated HBS-13B, symmetric ADD)

**Information contract:** **DISCARDED for MUL; partially recoverable via ADD rescue**
- MUL in collapse band: information is irreversibly lost. Result is NFE_FLOOR regardless of input fraction.
- ADD rescue: exponent channel is recoverable if E=15; fraction is partially preserved if ADD does not cause further rollover.
- Below E=14: no ADD rescue is possible without multiple upward steps.

**Collapse cliff (E=15↔16) geometry:** CLIFF — abrupt, single-exponent transition. No degradation zone (HBS-13F confirmed). At stored_E=16, self-MUL is stable (E_result=0, valid). At stored_E=15, self-MUL underflows (E_result=−2).

**True safe self-MUL floor:** **stored_E = 24** (HBS-13 validated). Self-MUL at E=24 produces E_result=16, the minimum stable exponent. E=24 is the closest stable point to the collapse cliff under self-multiplication.

---

### 1.4 Saturation Band: stored_E = 48 – 63

**Computational role:** Bounded-cap domain. Codewords in this band represent values that have exceeded the stable operating range via exponent overflow. They function as **bounded ceiling sentinels**: information above the stable ceiling is clamped, not destroyed, but is not faithfully representable.

**Allowed operations (with semantics):**

| Operation | Outcome | Notes |
|---|---|---|
| MUL(x, x) with both E ≥ 48 | `OVF → NFE_MAXPOS (0x1FFF)` | 100% OVF rate |
| MUL(x, y) with E_x + E_y > 63 | `OVF → NFE_MAXPOS` | Boundary condition |
| ADD_FRAC(x, x) with f ≥ 32 | Result E = E_x + 1 (further saturation) | Pushes deeper into saturation |
| NOP | No-op; operand unchanged | Safe always |

**UF/OVF behavior:**
- `exp_ovf_flag` fires unconditionally for MUL at E=48 (E_result = 48+48−32 = 64 > 63)
- No ADD-based rescue from saturation band exists (there is no higher band to rescue into)
- ADD at E=47 with f ≥ 32 PUSHES into saturation — this is the primary entry vector from stable band

**Information contract:** **BOUNDED CAP — partially preserved**
- Exponent information above E=47 is clamped to NFE_MAXPOS. The exact magnitude is lost.
- The sign bit (S) is preserved in OVF output.
- Fraction information is not preserved (NFE_MAXPOS has f=63 regardless of input).

**Saturation cliff (E=47↔48) geometry:** CLIFF — abrupt, single-exponent transition (HBS-13F confirmed). At E=47, self-MUL produces E_result=62 (stable). At E=48, self-MUL overflows unconditionally.

---

### 1.5 Cliff Transition Geometry

Both boundaries are **single-exponent cliffs** with no gradual degradation zone. Confirmed by HBS-13F:

| Boundary | Type | Geometry | Entry Condition | Exit Condition |
|---|---|---|---|---|
| E=15↔16 | Collapse | CLIFF | MUL with E_a + E_b < 32 | ADD rescue at E=15 with f≥32 |
| E=47↔48 | Saturation | CLIFF | ADD(x,x) at E=47 with f≥32 | Scale-down (MUL by HALF) from E=48 |

There are no hysteresis zones, gradual transition zones, or probabilistic transition behaviors. Phase membership is deterministic given the input exponent.

---

## 2. Operational Contract (FORMAL)

### 2.1 Core Axiom: Discrete Execution Phases

> **HORUS v3 MUST NOT be treated as a continuous numeric domain.**
> 
> The exponent field partitions computation into four discrete execution phases with distinct semantics. A compiler, scheduler, or runtime system operating on HORUS v3 MUST model these phases as separate semantic domains, not as points on a continuous number line.

This axiom has the following binding consequences:

---

### 2.2 Formal Rules

**Rule 1 — Boundary Non-Continuity:**
No operation may assume that results vary continuously across a region boundary. At E=15↔16 and E=47↔48, the arithmetic output changes discontinuously: a one-step exponent change transitions the system between qualitatively distinct behavior regimes.

```
FORBIDDEN:
  Treat MUL(E=15, x) and MUL(E=16, x) as "similar" operations.

REQUIRED:
  Treat them as distinct execution phases with independent contracts.
```

**Rule 2 — Mandatory Normalization at Cross-Region Operations:**
Any operation chain that may transport a codeword from the stable band toward a boundary MUST either:
  - Be statically bounded to prevent boundary crossing (preferred), OR
  - Include explicit normalization (rescaling via MUL by HALF or TWO) before the boundary is reached.

```
FORBIDDEN:
  Apply unlimited depth MUL(x, HALF) chains starting from E=20 without
  checking for E=16 approach.

REQUIRED:
  If chain depth > (stored_E − 16), insert normalization or truncate chain.
```

**Rule 3 — Collapse Is a Terminal Semantic State:**
Underflow (UF) and floor (NFE_FLOOR = 0x000) are not arithmetic errors to be corrected — they are **terminal semantic states** indicating that the computation has exhausted its representable dynamic range. The appropriate response is reset (accum_clr), not retry.

```
FORBIDDEN:
  Treat UF as a transient condition and continue accumulating into
  an accumulator that has received NFE_FLOOR contributions.

REQUIRED:
  When underflow_flag is observed, the computation window is terminated.
  The accumulator value at that point reflects only the pre-UF operations.
```

**Rule 4 — Saturation Is a Bounded-Cap, Not an Error:**
OVF and NFE_MAXPOS are not errors in the traditional sense — they indicate values that have exceeded the representable maximum and are bounded to the largest representable positive value. The sign bit is preserved. Saturated values MAY be valid outputs for clipping or gating workloads.

```
DISTINCTION:
  Collapse (UF) → information annihilation → reset required
  Saturation (OVF) → information bounding → result is usable as a ceiling

USE CASE:
  Saturation band may be deliberately used as a clipping layer:
  inject large values, observe NFE_MAXPOS, use as a one-bit "above ceiling"
  signal without reading the magnitude.
```

**Rule 5 — Policy Modes Do Not Alter Region Semantics:**
The `mode_tag` field modifies the accumulator contribution of each result but does NOT modify the arithmetic result, the UF flag, the OVF flag, or the region membership of any codeword. Region semantics are invariant under mode_tag changes.

This was verified in HBS-14 across 2,643 observations: **zero result mismatches, zero flag mismatches** across all four policy modes.

---

### 2.3 Compiler Constraints (From HBS-12 Validated Envelope)

```
HARD CONSTRAINTS:
  ASSERT 16 ≤ stored_E_A ≤ 47  (both operands in stable band for MUL)
  ASSERT 16 ≤ stored_E_B ≤ 47

RECOMMENDED CONSERVATIVE CONSTRAINTS:
  PREFER stored_E ∈ [20..44]   (4-step margin from both boundaries)
  WARN   stored_E ∈ [16..19]   (collapse approach zone)
  WARN   stored_E ∈ [44..47]   (saturation approach zone)
  REJECT stored_E ≤ 15          (collapse band — no MUL permitted)
  REJECT stored_E ≥ 48          (saturation band — no MUL permitted)

IDENTITY OPERATION:
  MUL(x, NFE_ONE) is exact and zero-cost for all x. Use freely.

ADD ROLLOVER GUARD:
  IF (stored_E == 47 AND f_a + delta ≥ 64):
      REJECT or normalize operand before ADD
```

---

## 3. Execution Semantics Table

Deterministic mapping of region × operation to output semantics:

| Region | Operation Class | Input State | Output Semantics | Information Status | Hardware Flags |
|---|---|---|---|---|---|
| **Stable** | MUL (both in-band) | E ∈ [16..47] | Deterministic valid result | **Preserved** | None |
| **Stable** | ADD without rollover | E ∈ [16..46] | Exact fraction increment | **Preserved** | None |
| **Stable** | ADD with Thoth Rollover | E ∈ [16..46], f_a+Δ≥64 | E+1, fraction shifted | **Transformed** (non-reversible) | `rollover_flag` |
| **Stable** | ADD at E=47, f≥32 | E=47, f≥32 | E=48 (exits to saturation) | **Transformed → SAT** | `rollover_flag`, `exp_ovf_flag` |
| **Stable** | MUL by ONE | any in-band | x (identity) | **Preserved exactly** | None |
| **Transition** | ADD rescue | E=15, f≥32 | E=16 (enters stable) | **Partially recovered** | `rollover_flag` |
| **Transition** | Scale-down approach | E=16..19 | E decremented toward 16 | **Transformed** (approaching cliff) | None until UF |
| **Transition** | Scale-up approach | E=44..47 | E incremented toward 48 | **Transformed** (approaching cliff) | None until OVF |
| **Collapse** | MUL (any) | E < 16 | NFE_FLOOR (0x000) | **Discarded** | `underflow_flag` |
| **Collapse** | ADD rescue | E=15, f≥32 | E=16 | **Partially recovered** | `rollover_flag` |
| **Collapse** | NOP | E < 16 | Operand unchanged | **Preserved in register** | None |
| **Saturation** | MUL (any) | E ≥ 48 | NFE_MAXPOS (0x1FFF) | **Bounded cap** | `exp_ovf_flag` |
| **Saturation** | NOP | E ≥ 48 | Operand unchanged | **Preserved in register** | None |
| **Any** | NOP | Any | Operand unchanged | **Preserved in register** | None |
| **Any** | Policy mode switch | Any | `result` unchanged | **Invariant** | Invariant |

**Information status key:**
- **Preserved:** Input information fully recoverable from output.
- **Transformed:** Input information partially encoded in output; some bits lost.
- **Discarded:** Input information is irretrievably lost.
- **Bounded cap:** Magnitude lost; sign and overflow condition preserved.
- **Partially recovered:** Exponent channel recoverable; fraction channel partially lost.

---

## 4. Phase-Boundary Transport Mechanisms

The following operations deliberately transport codewords across phase boundaries. They MUST be explicitly marked in any compiler IR and handled by the scheduler with full awareness of destination phase semantics.

| Transport | Source | Destination | Trigger | Reversible? |
|---|---|---|---|---|
| MUL scale-down | Stable (E=N) | Stable (E=N−1) or Collapse | MUL(x, HALF) | Yes (scale-up within stable) |
| MUL scale-up | Stable (E=N) | Stable (E=N+1) or Saturation | MUL(x, TWO) | Yes (scale-down within stable) |
| ADD rescue | Collapse (E=15) | Stable (E=16) | ADD with f≥32 | Partial — E yes, f partial |
| ADD push | Stable (E=47) | Saturation (E=48) | ADD with f≥32 | No — saturation is absorbing |
| MUL cascade | Stable | Collapse | Depth > (E−16) | No once UF fires |
| Normalization | Any stable | Any stable | Explicit MUL by power-of-2 | Yes within stable band |

---

## 5. Related Documents

| Document | Relationship |
|---|---|
| `docs/HORUS_V3_FINAL_SPEC.md` | Consolidated gold-master specification |
| `docs/HORUS_ARITHMETIC_ENVELOPE.md` | Full arithmetic envelope; compiler/QAT constraints |
| `docs/HORUS_BOUNDARY_GAP_ANALYSIS.md` | Detailed boundary geometry (HBS-13) |
| `docs/HBS14_RESULTS.md` | End-to-end consistency validation |
| `docs/ARCHITECTURE_PHILOSOPHY.md` | Philosophical context and layered model |
| `docs/EXECUTION_POLICY.md` | Policy mode specification (HBS-11) |

# HORUS C4 Compiler Kernel Specification

**Document type:** Compiler Kernel — Unified Decision Function  
**Supersedes:** HORUS_C1_COMPILER_SPEC.md · HORUS_C3_WORKLOAD_EMBEDDING.md  
**Authority:** HBS-11 through HBS-C3 validated hardware behavior (frozen)  
**Version:** 1.0 · 2026-07-02  
**Status:** GOLD — compression of C1 + C3 into a single deterministic kernel

---

## 1.1 Objective

Compress the C1 instruction-level routing and C3 workload-level scheduling into a single deterministic mapping function:

```
HORUS_KERNEL(workload_class, estimated_E, depth) → (mode_tag, action)
```

There are no sub-functions, no secondary layers, no phase embedding pipelines, and no runtime adaptation. The entire compiler decision is one function with three inputs and two outputs.

**Why a kernel?** C1 and C3 defined correct routing — C4 proves the entire routing logic collapses to a finite, enumerable truth table with 32 entries. If the compiler is correct, it is verifiable. If it is verifiable, it is a kernel.

---

## 1.2 Input Model

Exactly three inputs. No additional metadata, no historical state, no workload graph pre-processing.

| Input | Type | Range | Source |
|---|---|---|---|
| `workload_class` | enum | {A, B, C, D} | Static workload annotation |
| `estimated_E` | integer | [0..63] | `predict_exponent(op_a, op_b, op_sel)` from C1 §1.9 |
| `depth` | integer | [0..63] | Current epoch depth counter (maintained by caller) |

**`workload_class`** is the only semantic context the kernel accepts. It is assigned once per workload graph, not per operation. No per-cycle reclassification is permitted.

**`estimated_E`** is the predicted result exponent for the current operation, derived from the operand fields using the prediction function from C1 §1.9. For registered outputs, this is derived from `result[11:6]` of the previous cycle.

**`depth`** is the number of accumulated operations since the last `accum_clr` in the current epoch. It is maintained by the caller and passed to the kernel each cycle. The kernel does not track it internally — this is what makes the kernel stateless.

---

## 1.3 Region Function

The region classification function is unchanged from HBS-12, HBS-13, and C1. It is reproduced here in its final compressed form.

```
function classify(E):
    if   E ≤ 15:          return COLLAPSE
    elif E ∈ [16..19]:    return TRANSITION
    elif E ∈ [20..43]:    return STABLE
    elif E ∈ [44..47]:    return TRANSITION
    else (E ≥ 48):        return SATURATION
```

**These regions are NOT redefined by C4.** They are algebraic consequences of the Bias-32 encoding and were validated in HBS-12 (envelope scan), HBS-13 (boundary gap), and HBS-C2 (live occupancy). No compiler version may alter them.

---

## 1.4 Single Decision Function

This is the complete HORUS compiler.

```
function HORUS_KERNEL(workload, E, depth):

    region = classify(E)

    // ── Region dispatch ────────────────────────────────────────────

    if region == STABLE:
        mode   = 000
        action = EXECUTE

    elif region == TRANSITION:
        if workload in {CLASS_B, CLASS_D}:
            mode   = 010
            action = NORMALIZE_THEN_EXECUTE
        else:
            mode   = 000
            action = EXECUTE

    elif region == COLLAPSE:
        if workload == CLASS_A:
            mode   = 011
            action = SENTINEL_OR_SKIP
        else:   // CLASS_B, CLASS_C, CLASS_D
            mode   = 010
            action = NORMALIZE_THEN_ROUTE

    elif region == SATURATION:
        mode   = 011
        action = CLAMP

    // ── Depth override (applied after region dispatch) ─────────────
    //    Overrides action and mode when epoch depth is exceeded.
    //    This check is unconditional: depth > 16 always triggers,
    //    regardless of region or workload class.

    if depth > 16:
        action = INSERT_EPOCH_BOUNDARY
        mode   = 010

    return (mode, action)
```

### Action Semantics

Each action maps to a concrete hardware instruction sequence. The kernel outputs an action token; the instruction emitter resolves it.

| Action | Hardware sequence | accum_en | Notes |
|---|---|---|---|
| `EXECUTE` | emit(op_a, op_b, op_sel, mode, accum_en, tile_depth) | Per-class rule† | Normal operation |
| `NORMALIZE_THEN_EXECUTE` | MUL×k by TWO (mode=010, accum_en=0) until E≥20, then EXECUTE | 0 then 1 | Scale-up transit + execute |
| `NORMALIZE_THEN_ROUTE` | MUL×k by TWO (mode=010, accum_en=0); re-enter kernel at new E | 0 | Normalization only; caller loops |
| `SENTINEL_OR_SKIP` | NOP or accum_en=0 suppress | 0 | Floor gate; flag to host |
| `CLAMP` | emit with mode=011; flag exp_ovf to host; no inference accumulation | 0 | Ceiling gate |
| `INSERT_EPOCH_BOUNDARY` | accum_clr pulse; snapshot accum_out; MUL×k TWO until E≥20; reset depth | 0 during; 1 after | Epoch reset |

† `EXECUTE` accum_en rule by class:
- CLASS_A, CLASS_B, CLASS_D: `accum_en = 1`
- CLASS_C: `accum_en = 0` always (scaling is transport; never accumulate)

### Complete Truth Table

All 32 kernel outputs enumerated. `DG` = depth guard (depth > 16 override applied).

```
workload │ region     │ DG  ║ mode │ action
─────────┼────────────┼─────╫──────┼──────────────────────────
CLASS_A  │ STABLE     │ NO  ║ 000  │ EXECUTE
CLASS_A  │ STABLE     │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_A  │ TRANSITION │ NO  ║ 000  │ EXECUTE
CLASS_A  │ TRANSITION │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_A  │ COLLAPSE   │ NO  ║ 011  │ SENTINEL_OR_SKIP
CLASS_A  │ COLLAPSE   │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_A  │ SATURATION │ NO  ║ 011  │ CLAMP
CLASS_A  │ SATURATION │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
─────────┼────────────┼─────╫──────┼──────────────────────────
CLASS_B  │ STABLE     │ NO  ║ 000  │ EXECUTE
CLASS_B  │ STABLE     │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_B  │ TRANSITION │ NO  ║ 010  │ NORMALIZE_THEN_EXECUTE
CLASS_B  │ TRANSITION │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_B  │ COLLAPSE   │ NO  ║ 010  │ NORMALIZE_THEN_ROUTE
CLASS_B  │ COLLAPSE   │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_B  │ SATURATION │ NO  ║ 011  │ CLAMP
CLASS_B  │ SATURATION │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
─────────┼────────────┼─────╫──────┼──────────────────────────
CLASS_C  │ STABLE     │ NO  ║ 000  │ EXECUTE        [accum=0]
CLASS_C  │ STABLE     │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_C  │ TRANSITION │ NO  ║ 000  │ EXECUTE        [accum=0]
CLASS_C  │ TRANSITION │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_C  │ COLLAPSE   │ NO  ║ 010  │ NORMALIZE_THEN_ROUTE
CLASS_C  │ COLLAPSE   │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_C  │ SATURATION │ NO  ║ 011  │ CLAMP
CLASS_C  │ SATURATION │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
─────────┼────────────┼─────╫──────┼──────────────────────────
CLASS_D  │ STABLE     │ NO  ║ 000  │ EXECUTE
CLASS_D  │ STABLE     │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_D  │ TRANSITION │ NO  ║ 010  │ NORMALIZE_THEN_EXECUTE
CLASS_D  │ TRANSITION │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_D  │ COLLAPSE   │ NO  ║ 010  │ NORMALIZE_THEN_ROUTE
CLASS_D  │ COLLAPSE   │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
CLASS_D  │ SATURATION │ NO  ║ 011  │ CLAMP
CLASS_D  │ SATURATION │ YES ║ 010  │ INSERT_EPOCH_BOUNDARY
```

**Observations from the truth table:**

1. **Depth override is universal.** Any (class, region) combination with depth > 16 produces the same output: `(010, INSERT_EPOCH_BOUNDARY)`. The depth gate collapses all 16 DG=YES entries to a single action.

2. **Class only matters in TRANSITION and COLLAPSE.** In STABLE, SATURATION, and all DG=YES cases, workload class does not affect the output. Class differentiation is localized to the two boundary-adjacent regions.

3. **mode=010 is the transit policy.** It appears in every boundary-zone case: TRANSITION for B/D, COLLAPSE for non-A, depth override for all. It is the universal transit carrier — not a "special" mode.

4. **mode=011 is the ceiling/floor gate.** It appears only in SATURATION (all classes) and CLASS_A in COLLAPSE. It is the sentinel policy: accumulator saturation guard.

5. **mode=000 is the stable-zone only mode.** It appears exclusively in STABLE (all classes) and TRANSITION for A/C without depth override. It is the default inference mode.

---

## 1.5 Hard Constraints

These constraints are properties of the kernel, not guidelines. Any implementation that violates them is not implementing C4.

**HC-1: No secondary decision layers exist.**  
The kernel is one function. There is no pre-processing stage, no workload analyzer, no phase embedding pipeline, no multi-stage dispatch. The C1/C3 architectures that described such stages are superseded by this kernel. Their content remains as reference documentation; their multi-stage structure is deprecated.

**HC-2: No probabilistic routing exists.**  
Every output is fully determined by (workload, E, depth). There are no default fallbacks, random selections, or heuristic approximations.

**HC-3: No workload reclassification occurs at runtime.**  
`workload_class` is assigned once before the workload begins. The kernel does not observe results and adjust workload class. If the actual behavior diverges from the class prediction, that is a workload annotation error, not a kernel error.

**HC-4: Region classification is the ONLY gating function.**  
No other property of the operation (fraction value, operand magnitude, flag state, previous mode) gates the decision. The kernel sees only (workload, E, depth).

**HC-5: The depth threshold is exactly 16.**  
Not 14, not 18, not E_seed − 16. The kernel uses depth = 16 as the hard epoch boundary. This corresponds to the minimum safe epoch depth for E_seed=32 (the natural anchor). Finer-grained depth management (E_seed-dependent limits) belongs in the caller's depth counter configuration, not in the kernel.

---

## 1.6 Compiler Invariants (Compressed Form)

**CI-1 — Arithmetic physics is immutable.**  
UF fires when E_a + E_b < 32. OVF fires when E_a + E_b > 95. Thoth Rollover fires when f + f ≥ 64. These are hardware algebraic properties. The kernel is built on them; it cannot alter them.

**CI-2 — mode_tag affects accumulator only.**  
`result`, `underflow_flag`, and `exp_ovf_flag` are mode-invariant (HBS-14, 384 tests, 0 exceptions). The kernel's mode output controls the accumulator policy exclusively.

**CI-3 — Region boundaries are hardware-defined, not compiler-defined.**  
E=15↔16 and E=47↔48 are consequences of the Bias-32 encoding. The kernel's `classify()` function reads these boundaries; it does not own them. They cannot be relocated, widened, or parameterized by the compiler.

**CI-4 — Collapse is a routing state, not an error.**  
E≤15 results are valid codewords. Hardware UF requires E_a+E_b < 32, not E≤15. The kernel routes COLLAPSE to SENTINEL or NORMALIZE; it does not treat it as a failure condition.

**CI-5 — Depth is a hard execution constraint, not a heuristic.**  
depth > 16 always triggers INSERT_EPOCH_BOUNDARY. There is no "soft" depth warning, no gradual escalation, no depth-dependent probability. The kernel is binary on depth.

**CI-6 — The compiler cannot alter UF/OVF behavior.**  
No mode_tag selection, no action, and no normalization sequence can prevent the hardware from setting `underflow_flag` or `exp_ovf_flag` when the arithmetic condition is met. The kernel accepts this and routes accordingly.

---

## 1.7 Execution Contract

```
HORUS C4 compiler is a stateless deterministic routing function
mapping (workload_class, estimated_E, depth) into (mode_tag, action).

No historical state is used.
No runtime adaptation occurs.
No external data (flags, accum values, result history) is read.
The same inputs always produce the same outputs.
The function is total: defined for all valid inputs.
The function is finite: 32 output cases, fully enumerated in §1.4.
```

This contract means a C4 implementation can be verified by table lookup against the truth table in §1.4. A conforming implementation and the truth table must agree on all 32 entries. Any discrepancy is a spec violation.

---

## 1.8 Relationship to C1 and C3

C1 and C3 defined the correct routing logic in full generality, with supporting rationale, physics citations, ABMP protocols, and workload profiles. C4 does not invalidate that content — it shows that the decision logic distills to a 32-entry table.

```
C1 (HORUS_C1_COMPILER_SPEC.md):
  Defined instruction-level routing with prediction functions,
  region classification, mode assignment rules, ABMP, and
  depth management. [STATUS: SUPERSEDED by C4 for decision logic;
  retained as reference for action implementation details]

C3 (HORUS_C3_WORKLOAD_EMBEDDING.md):
  Defined workload-class profiles, phase embedding, scheduler
  rules S1–S4, and Phase Transport protocol. [STATUS: SUPERSEDED
  by C4 for decision logic; retained as reference for action
  implementation details and workload classification criteria]

C4 (this document):
  Compresses C1 + C3 decision logic into HORUS_KERNEL().
  Action implementation details are resolved by referencing
  C1/C3 as implementation guides, not as decision authorities.
```

The C1/C3 multi-stage compiler pipeline (workload classifier → phase embedding analyzer → scheduling policy generator → C1 instruction emitter) is replaced by the single kernel call:

```
// C1 + C3 pipeline (deprecated):
class    = classify_workload(graph)
profile  = embed_phases(class, E_seed, depth)
policy   = generate_schedule(profile)
inst     = emit_C1(policy, op)

// C4 kernel (current):
(mode, action) = HORUS_KERNEL(class, E_est, depth)
```

---

## Related Documents

| Document | Status | Relationship |
|---|---|---|
| `docs/HORUS_C1_COMPILER_SPEC.md` | SUPERSEDED (decision logic) | Action implementation reference |
| `docs/HORUS_C3_WORKLOAD_EMBEDDING.md` | SUPERSEDED (decision logic) | Action implementation + class criteria |
| `docs/HORUS_PHASE_SCHEDULER_MODEL.md` | SUPERSEDED (decision logic) | Visual reference; boundary physics |
| `docs/HORUS_SYSTEM_COMPILATION_MODEL.md` | RETAINED | Layer separation; interface contract |
| `docs/ARCHITECTURE_PHILOSOPHY.md` | RETAINED | C4 principle (§C4) |
| `docs/HORUS_V3_FINAL_SPEC.md` | RETAINED | Hardware spec; physics source |
| `docs/HORUS_C2_LIVE_SYSTEM_REPORT.md` | RETAINED | Measured occupancy baseline |

# Horus Geometry Fabric — Program Charter

**Status:** Initial fork from Horus-NFE-Research (2026-07-04)  
**Baseline commit:** HBS-C23 complete (observer-frame relativity established)

---

## 1. Why This Repository Exists

Horus-NFE-Research established that:

- The **arithmetic core** is causally closed and coordinate-invariant (HBS-C18–C22)
- The **attractor taxonomy** (A1–A4) is an observer-frame artifact of `result[11:6]` (HBS-C23)

That split — invariant computation vs frame-dependent observation — is the
foundation for a **geometry-based logic fabric**: logic that is defined by
geometric regions and coordinate transforms, not only by symbolic gate networks.

This repository preserves the full verified NFE substrate and dedicates new
work to fabric-level geometry exploration.

---

## 2. Core Concepts

### 2.1 Two-Layer Architecture (from C23)

| Layer | Object | Invariance |
|-------|--------|------------|
| **Computation** | `computed = f(op_a, op_b, op_sel)` | Frame-independent |
| **Observation** | A1–A4 via E-field extraction | Frame-dependent |

Fabric design must treat these as **separate, explicit layers**.

### 2.2 Geometry as Logic

In conventional digital logic, state is bits and transitions are gates.  
In geometry fabric:

- **State** = point in a quantized manifold (NFE codeword space)
- **Transition** = geometric transform (rotation, XOR mask, accumulation fold)
- **Decision** = region membership (attractor classification)
- **Routing** = coordinate projection (which bits define the active field)

### 2.3 What Must Survive Coordinate Change

From HBS-C23, only the **arithmetic output** survives arbitrary observer transforms.
Fabric invariants are therefore anchored on:

- Deterministic MAC results
- Accumulation policy boundaries (mode_tag, depth gates)
- Causal firewall at B0|B1 (HBS-C20)

Not on attractor labels alone.

---

## 3. Initial Research Tracks

### Track A — Coordinate Atlas

Map alternative E-field / manifold projections and document which
computational properties each projection preserves.

### Track B — Fabric Composition Operators

Extend beyond systolic MAC: geometric tile-to-tile transforms,
epoch-varying basis changes, and multi-projection observers.

### Track C — Invariant Core Extraction

Identify minimal coordinate-independent descriptors of NFE state
that can serve as fabric-level routing signals.

### Track D — Observer-Aware RTL Patterns

Testbench and RTL patterns that separate `computed` from
`computed_obs` explicitly — building on C21/C22/C23 methodology.

---

## 4. Inherited Verification Baseline

All HBS-C7 through HBS-C23 artifacts are included. Key entry points:

```bash
cd sim
make hbs_c23    # Observer decoupling — MODEL BREAKS (frame-dependent attractors)
make hbs_c22    # Exogenous injection — MI_arith = 0 (arithmetic closure)
make hbs_c20    # Firewall geometry — zero-thickness boundary
```

---

## 5. Next Steps

1. Define fabric coordinate atlas (Track A)
2. Prototype multi-projection observer module (external to RTL, as in C23)
3. Specify first fabric composition operator beyond 4×4 systolic
4. Establish pass/fail criteria for coordinate-invariant fabric routing

---

*Horus Geometry Fabric Program Charter · 2026-07-04*

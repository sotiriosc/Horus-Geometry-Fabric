# Horus Geometry Fabric

**Geometry-Based Logic Fabric — Exploration & Development**

This repository is the dedicated workspace for exploring and developing a
**geometry-based logic fabric** built on the Horus Native Fractional Engine (NFE)
foundation. It was forked from [Horus-NFE-Research](https://github.com/sotiriosc/Horus-NFE-Research)
to preserve the verified NFE substrate while pursuing a new architectural direction:
treating computation as **coordinate geometry** rather than conventional bit-level
logic alone.

**License:** [CERN-OHL-S-2.0](LICENSE)

---

## Mission

Horus Geometry Fabric investigates:

- **Geometric coordinate systems** for representing and transforming logic states
- **Observer-frame invariants** vs frame-dependent projections (see HBS-C23 findings)
- **Fabric-level composition** — how NFE tiles, attractor regions, and accumulation
  manifolds compose into larger inference structures
- **Logic-as-geometry** — encoding decision boundaries, routing, and state transitions
  as geometric regions rather than purely symbolic gates

The parent NFE research repo remains unchanged. This repo carries the full
verified RTL, simulation infrastructure, and HBS verification history as a
starting baseline.

---

## Relationship to Horus NFE Research

| Repository | Role |
|------------|------|
| [Horus-NFE-Research](https://github.com/sotiriosc/Horus-NFE-Research) | Original NFE engine, MAC mesh, HBS-C7–C23 verification |
| **Horus-Geometry-Fabric** (this repo) | Geometry-based logic fabric exploration & development |

**Inherited baseline (verified):**

| Layer | Status |
|-------|--------|
| Core MAC/NFE | Verified — ADD/SUB/MUL, C-model vs FP64 |
| Causal closure (C18–C22) | Proved — arithmetic frame-independent |
| Observer-frame relativity (C23) | Proved — attractors are frame-dependent labels |
| Composition geometry | Documented — [docs/COMPOSITION_GEOMETRY.md](docs/COMPOSITION_GEOMETRY.md) |

---

## Repository Layout

```
horus_geometry_fabric/
├── README.md           ← this file
├── LICENSE
├── Makefile            → delegates to sim/
├── rtl/                ← synthesizable Verilog (horus_nfe, mesh, systolic)
├── tb/                 ← Icarus Verilog testbenches
├── sim/                ← Makefile, C-model, analysis scripts, build artifacts
└── docs/               ← architecture, numerics, HBS verification, geometry notes
```

---

## Quick Start

```bash
# Full RTL regression
make test

# Composition geometry analysis
make composition_analysis

# HBS verification suites (C19–C23)
cd sim && make hbs_c19   # closure falsification
cd sim && make hbs_c20   # boundary geometry
cd sim && make hbs_c21   # feedback coupling
cd sim && make hbs_c22   # exogenous injection
cd sim && make hbs_c23   # observer decoupling
```

**Requirements:** Icarus Verilog ≥ 11, GCC, Python 3.8+

---

## Key Documentation

| Document | Description |
|----------|-------------|
| [docs/GEOMETRY_FABRIC.md](docs/GEOMETRY_FABRIC.md) | Program charter and research tracks |
| [docs/ARCHITECTURE_PHILOSOPHY.md](docs/ARCHITECTURE_PHILOSOPHY.md) | Digital Physics paradigm; C18–C23 principles |
| [docs/COMPOSITION_GEOMETRY.md](docs/COMPOSITION_GEOMETRY.md) | Deterministic residual manifold |
| [docs/HORUS_SYSTEM_CLOSURE_THEOR.md](docs/HORUS_SYSTEM_CLOSURE_THEOR.md) | Formal closure theorem (C18) |
| [docs/HBS_C23_RESULTS.md](docs/HBS_C23_RESULTS.md) | Observer-frame relativity (starting insight) |

---

## Development Direction

Starting from the C23 result — *attractors are real in the frame that defines them* —
this repo will explore:

1. **Fabric coordinate systems** — alternative E-field / manifold projections for logic routing
2. **Invariant cores** — what survives coordinate destruction (arithmetic closure)
3. **Geometric composition operators** — tile-to-tile transforms beyond systolic MAC
4. **Observer-aware design** — explicit separation of computation vs classification layers

---

*Horus Geometry Fabric · Geometry-Based Logic Fabric · v0.1 (forked from NFE v3)*

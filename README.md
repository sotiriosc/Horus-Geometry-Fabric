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

## NFE Deployment Review (July 2026)

A structured C-model review asked what actually affects **real CLASS_A workloads**
(GEMM, conv, attention) on the documented hardware path — as opposed to synthetic
long-chain stress tests.

**Full write-up:** [docs/NFE_DEPLOYMENT_REVIEW.md](docs/NFE_DEPLOYMENT_REVIEW.md)  
**Run the tests:** [sim/README.md](sim/README.md) → `cd sim && make deployment_review`

### Why we ran it

The NFE verification suite (HBS-C5–C23) proves kernel logic and causal closure. It does
not directly answer deployment questions: dual-path matvec cost, whether ABMP snapshots are
correct, whether the 1024-cycle fidelity benchmark models production, or whether block
scaling / compensated accumulation are worth the hardware.

### What we built

| Artifact | Role |
|----------|------|
| `sim/nfe_matvec.c` | 8×8 baseline — op counts, weighted cost, 0.383% mean error |
| `sim/nfe_matvec2.c` | Dual-path routed matvec (anchor zone E∈[28..35]) |
| `sim/abmp_epoch_test.c` | ABMP snapshot vs true sum at depth=16 |
| `sim/abmp_blast_radius.c` | Trigger characterization + K=8 accuracy |
| `sim/abmp_k128_test.c` | HBS-1 K=128 reduction (7 epoch boundaries) |
| `sim/abmp_norm_fires.c` | Forced normalization when E<20 at boundary |

### Headline findings

1. **ABMP off-by-one is real but isolated** — `accum_out` trails `accum_reg` by 1 cycle;
   snapshot at epoch close drops one MAC from the *integer codeword* sum. The NFE **`result`**
   dot-product path is unaffected (0.000% measured delta at K=8, K=128, and forced-norm cases).

2. **Epoch trigger is a fixed counter** — C4 HC-5: `depth > 16` → `INSERT_EPOCH_BOUNDARY`.
   K≤16 reductions never fire. K=128 fires 7 times at depth=17.

3. **1024-cycle fidelity benchmark is a stress test** — continuous accumulator with feedback;
   not epoch-reset CLASS_A. Divergence there does not predict real GEMM behavior.

4. **Saturation unreachable in 16-step epochs** — with documented operand ranges (E_export ≤ 36),
   Thoth rollover is correct renormalization, not a deployment risk.

5. **Block scaling / compensation** — no accuracy win on bounded epochs; no energy breakeven
   for matvec once E_block dmov is priced in.

**Bottom line for deployment:** The live accuracy budget is inherent NFE quantization
(~0.38% mean on the characterized 8×8 matvec). Fix the `accum_out` sampling contract if
any consumer treats the snapshot as a compute input — not because it affects standard GEMM
accuracy.

---

## Quick Start

```bash
# Full RTL regression
make test

# Composition geometry analysis
make composition_analysis

# NFE deployment review (C-model matvec + ABMP tests)
cd sim && make deployment_review

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
| [docs/NFE_DEPLOYMENT_REVIEW.md](docs/NFE_DEPLOYMENT_REVIEW.md) | July 2026 deployment review — ABMP, matvec, block scaling |
| [sim/README.md](sim/README.md) | C-model review tests — build & run |

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

# ADR-001 — PF-W18 Adopted for NFE Core

> **Status: SUPERSEDED by `docs/ADR_002_NORMALIZATION_ARCHITECTURE.md` (2026-07-05).**
> `docs/NORM_VS_PF18.md` shows baseline `horus_nfe` + periodic normalisation
> every ≤ 8 steps matches or exceeds PF-W18 accuracy on all tested workloads
> (RTL CONFIRMED, 3 cells) at an estimated 30–100× lower area cost.  PF-W18
> retains a residual advantage only for unnormalised SSC chains, which was
> the motivating scenario.  The decision body below is preserved as an
> evidence record; the superseding ADR documents the full revision rationale.

**Status:** ACCEPTED  
**Date:** 2026-07-05  
**Evidence trail:** `docs/SSC_RTL_VALIDATION.md` → `docs/PF_SYNTHESIS_COMPARISON.md`
→ `docs/PF_DECISION_INPUTS.md` (including PF18 Update section)

---

## Decision

`rtl/horus_nfe_pf18.v` — PATH_FAST accumulator at W=18 bits — is adopted as
the NFE core for feedback/attractor workloads.

---

## Evidence Chain

| Step | Finding | Source |
|------|---------|--------|
| RTL validation | Baseline `horus_nfe.v` always re-quantizes each multiply product to 6-bit NFE (lines 530–532). No PATH_FAST mode exists in the original RTL; the 0.38% deep-chain prediction described software-only behavior. | `docs/SSC_RTL_VALIDATION.md`, P1 NOT CONFIRMED |
| Baseline error | PATH_NFE neutral-regime deep chain diverges past 1% at cycle 2 and reaches **23.95%** final error; DUT stalls at an offset attractor (1.25) while the FP64 golden converges to the Perron eigenvector (1.6436). | `docs/SSC_RTL_VALIDATION.md`, P2 CONFIRMED |
| PF synthesis (W=32) | A PATH_FAST RTL variant (`horus_nfe_pf.v`, W=32 accumulator) achieves **0.18% neutral-regime error** at a core-level cost of +58.9% area / +67.9% cells. System-level (horus_top): +53.4% area. | `docs/PF_SYNTHESIS_COMPARISON.md`, `docs/PF_DECISION_INPUTS.md` Tasks 1–3 |
| Width sweep | Python model at W=18 achieves **0.35% error** (minimum viable ≤ 0.5%); W=16 overflows (66% error). The combinational overhead also scales with W — the assumption that only DFF count changes was wrong. | `docs/PF_DECISION_INPUTS.md` Task 2, `sim/pf_width_sweep.py` |
| PF18 synthesis | `horus_nfe_pf18.v` (W=18, saturation guard) achieves **0.18% neutral-regime error** — identical to W=32 — at reduced cost. Core: +45.9% area / 2075 cells / 118 DFFs. System: **+39.6% area** / 34 679 cells / 2316 DFFs. | `docs/PF_DECISION_INPUTS.md` PF18 Update section |
| Spot-check | Python RTL-faithful model at W=18 and RTL PATH_FAST both yield 0.1798% on the same seed — zero divergent cycles across 256 steps. | `docs/PF_DECISION_INPUTS.md` Task 3, `sim/pf_spotcheck.py` |
| Saturation guard | In expansive regime (row_sum=1.10), saturation guard fired 2039 times (clamp not wrap) — confirms clamping path is active without wrap artifacts. | `tb/tb_horus_nfe_pf18.v` simulation output |

---

## Accepted Cost

| Metric | Baseline | PF-W18 | Delta |
|--------|----------|--------|-------|
| System area (µm²) | 188 742 | 263 443 | **+39.6%** |
| System cells | 24 028 | 34 679 | +44.3% |
| System DFFs | 2 028 | 2 316 | +14.2% |
| Neutral-regime deep-chain error | 23.95% | **0.18%** | −23.77 pp |
| Timing (critical path) | not measured | not measured | — |

**Interpretation of area cost:** at fixed silicon budget, +39.6% area equates
to approximately 11 PF18 tiles vs 16 baseline tiles.  The feedback/attractor
workload is the chip's purpose; accepting 5 fewer tiles to reach the correct
attractor is in-scope.

---

## Rejected Alternatives

**Baseline `rtl/horus_nfe.v`** — 23.95% deep-chain feedback error is unusable
for spectral workloads.  The quantized DUT stalls at an offset attractor; it
does not reach the Perron eigenvector of the workload matrix.

**PF-W32 `rtl/horus_nfe_pf.v`** — strictly dominated by PF-W18.  Equal accuracy
(0.18% on matched seed) at higher area (+58.9% core / +53.4% system vs +45.9%
/ +39.6% for W=18).  The W=32 accumulator is retained in the repo as a
reference artifact; `docs/PF_SYNTHESIS_COMPARISON.md` is marked superseded.

---

## Open Items Carried Forward

1. **Timing unmeasured.** OpenSTA is not installed.  Critical-path analysis for
   `horus_nfe_pf18` on Sky130 HD TT 025C 1v80 is deferred.  All frequency
   claims must await STA.
2. **Contractive-regime floor stall unaddressed.** Under row_sum=0.90, the DUT
   stalls at the NFE resolution floor (~2.4 × 10⁻⁹) while the FP64 golden
   continues decaying (`docs/SSC_RTL_VALIDATION.md`, contractive note).  PF18
   uses the same NFE output format; the floor stall is unchanged.
3. **Multi-matrix / non-symmetric workloads not characterized.**  All
   validation used 8×8 row-stochastic or symmetric positive matrices.

---

*Horus-Geometry-Fabric · ADR-001 · 2026-07-05*

# ADR-002 — Normalization Architecture Adopted; PF-W18 Superseded

**Status:** ACCEPTED  
**Date:** 2026-07-05  
**Supersedes:** `docs/ADR_001_PF18_ADOPTION.md`  
**Evidence trail:** `docs/NORM_VS_PF18.md` ←
`docs/PF18_POWER_ITERATION.md` ← `docs/ADR_001_PF18_ADOPTION.md`

---

## Decision

**Option A** — baseline `horus_nfe` (PATH_NFE, no datapath modification) plus
periodic harness normalisation every ≤ k steps — is adopted as the operating
mode for feedback/attractor workloads.

`rtl/horus_nfe_pf18.v` and `rtl/horus_nfe_pf.v` are formally superseded and
retained only as reference artifacts (evidence trail preserved; see deprecation
notes below).

---

## Evidence

Two RTL-confirmed findings from the normalization-interval sweep
(`docs/NORM_VS_PF18.md`, run `make norm_vs_pf18`):

| Evidence cell | Workload | k | Baseline result | PF-W18 result | Delta |
|---------------|----------|----|----------------|---------------|-------|
| RTL Cell 3 (CONFIRMED) | PI symmetric-positive | 8 | **1.0000 alignment** | 0.9892 (< 0.99 threshold) | +0.0108 |
| RTL Cell 1 (CONFIRMED) | SSC neutral row-stochastic | 128 | **0.5524% mre** | 0.543% mre | +0.009 pp |
| RTL Cell 2 (CONFIRMED) | SSC k=∞ (reference) | ∞ | 24.6959% mre | 0.335% mre | PF18 wins without norm |

For the PI workload with k=2..8, baseline achieves **perfect alignment (1.0000)**
where PF-W18 is limited to **0.9892** (below the 0.99 threshold) due to W=18
accumulator saturation (peak row sum 2.12 > W=18 ceiling ~2.0,
`docs/PF18_POWER_ITERATION.md` Finding 1).

For the SSC workload at k=128, baseline (0.5524% RTL-confirmed) is within
0.01 pp of PF-W18's unnormalised result (0.335%), at an estimated 30–100×
lower area cost.

PF-W18 retains an advantage **only for unnormalised SSC chains** (k=∞:
baseline 24.7% vs PF-W18 0.33%), which was the original motivating scenario
in ADR-001.  With normalisation enabled, that advantage is eliminated.

---

## Accepted Architecture: Option A

| Parameter | Value |
|-----------|-------|
| RTL module | `horus_nfe` (unmodified baseline, no PF changes) |
| Datapath | PATH_NFE: 6-bit per-product quantisation, float accumulate |
| Normalisation interval k | ≤ 128 steps (SSC workloads); ≤ 8 steps (PI workloads) |
| Normalisation locus | harness / host — not yet on-chip |
| On-chip normaliser RTL | **`rtl/horus_norm.v` built, verified, synthesised** — 5,352.6 µm² / +2.84% system |
| Throughput overhead | ≤ 1.6% (k=8) to ≤ 0.1% (k=128) for exponent-only rescale |
| Area delta (on-chip normaliser) | **+2.84% system area measured** (1 normaliser/top; `docs/EXPNORM_RESULTS.md`) |
| Timing | Not measured |

---

## Rejected Alternatives (summary)

**PF-W18 (`rtl/horus_nfe_pf18.v`):** +39.6% system area (measured), workload
ceiling at row sum ~2.0 (W=18 saturation), fails ≥ 0.99 alignment criterion on
PI workload for k ≥ 2.  No advantage over Option A for normalised workloads.
See `docs/ADR_001_PF18_ADOPTION.md` (full evidence chain preserved).

**PF-W32 (`rtl/horus_nfe_pf.v`):** strictly dominated by PF-W18 on area
(+53.4% system vs +39.6%) with identical accuracy.  Superseded by both
ADR-001 and this ADR.

---

## Deprecated Artifacts

The following files are retained in the repo as an evidence record.  They
represent a well-documented road not taken:

| File | Status | Reason |
|------|--------|--------|
| `rtl/horus_nfe_pf18.v` | **SUPERSEDED** by ADR-002 | +39.6% area; PI workload ceiling |
| `rtl/horus_nfe_pf.v` | **SUPERSEDED** by ADR-001 and ADR-002 | Dominated by PF-W18 on area |
| `docs/ADR_001_PF18_ADOPTION.md` | **SUPERSEDED** by this ADR | Decision reversed |
| `docs/PF_DECISION_INPUTS.md` | Historical reference | Numbers still valid; decision superseded |
| `docs/PF_SYNTHESIS_COMPARISON.md` | Historical reference | Core-level synthesis numbers still valid |

---

## Open Items

1. **On-chip normaliser RTL — CLOSED WITH MEASUREMENT (2026-07-05).**
   `rtl/horus_norm.v` built and verified (`tb/tb_horus_norm.v`, 11/11 pass).
   Synthesised under Sky130 HD TT 025C 1v80 (`sim/synth_horus_norm.ys`):
   **5,352.6 µm² / 565 cells / +2.84% system area** (1 normaliser per `horus_top`).
   Above the +0.3–1.3% estimate; discrepancy traced to unaccounted output register
   bank (105 DFFs = 39% of module area).  Decision unaffected: +2.84% << PF-W18 +39.6%.
   See `docs/EXPNORM_RESULTS.md` for sweep table, RTL verdicts, and full stat block.

2. **Timing unmeasured.** OpenSTA not installed.  The normaliser rescale path
   may introduce a new critical path through the exponent adder; this has not
   been characterised.

3. **Contractive-regime floor stall unaddressed.** Under row_sum=0.90, the DUT
   stalls at the NFE resolution floor (~2.4 × 10⁻⁹).  Normalisation does not
   mitigate this because the floor stall reduces signal below NFE minimum
   before normalisation fires.  Remains an open architectural question.

4. **On-chip normalisation k-interval selection.** The break-even values
   (k ≤ 128 for SSC, k ≤ 8 for PI) were measured under the specific workload
   families in `norm_interval_sweep.py`.  Generalisation to other matrix
   families has not been characterised.

---

*Horus-Geometry-Fabric · ADR-002 · 2026-07-05*

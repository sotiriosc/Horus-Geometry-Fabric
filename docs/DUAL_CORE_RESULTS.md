# DUAL_CORE_RESULTS.md — Dual-Mode Core Synthesis Verdict

**Campaign**: Horus-Geometry-Fabric · Dual-Mode Compact Core  
**Flow**: Yosys 0.9 · Sky130 HD TT/025C/1v80  
**Date**: 2026-07-05  
**Sources of truth**: `sim/format_zoo.py` (E4M3), `sim/compact_nfe.py` (E3M6)

---

## 1. Four-Way Synthesis Table

All areas in µm² (Sky130 HD, Yosys `stat -liberty`).

| Core                        | Area (µm²) | Cells | DFFs | Notes                                   |
|-----------------------------|------------|-------|------|-----------------------------------------|
| E4M3 (`fp8_e4m3_mul`)       |    857.072 |   121 |    0 | Combinational; from `synth_fp8_e4m3_mul.ys`  |
| E3M6 (`horus_e3m6_core`)    |  1 675.357 |   232 |    0 | Combinational; synthesised fresh        |
| **Sum-of-two**              |  **2 532.429** | **353** | **0** | Arithmetic sum; no shared logic        |
| Dual core (`horus_dual_core`)| 3 304.419 |   456 |   11 | 10-bit result reg + 1-bit mode_r DFF   |
| Dual infer-only (K3 probe)  |  1 546.483 |   211 |    8 | `mode_r=1'b1`; E3M6 logic synthesised away |

**K3 methodology**: `horus_dual_core_infer_k3.v` is a structurally identical copy of
`horus_dual_core.v` with `mode_r` replaced by `wire mode_r = 1'b1`.  Yosys
constant-propagates `hi_en = ~mode_r = 1'b0` and removes all E3M6-only logic
(upper-mantissa AND gates, E3M6 normalizer, E3M6 output mux arm) during
synthesis.  Area difference `dual − infer_only` is the inference-mode gated
area proxy.

---

## 2. Kill-Criteria Evaluation

Kill criteria quoted verbatim from `docs/DUAL_CORE_HYPOTHESIS.md`.

### K1 — Dual-core area < 85 % of sum-of-two

> "(K1) dual-core area < 85% of the summed areas of a standalone E4M3 core and
> a standalone E3M6 core."

| Quantity                      | Value      |
|-------------------------------|------------|
| E4M3 area                     | 857.072 µm² |
| E3M6 area (fresh synthesis)   | 1 675.357 µm² |
| Sum-of-two                    | 2 532.429 µm² |
| K1 threshold (85 %)           | **2 152.565 µm²** |
| Dual-core area                | **3 304.419 µm²** |
| Actual ratio (dual / sum)     | **1.305×** (130.5 %) |

**K1: FAIL** — The dual core is 1.305× the sum-of-two, not < 0.85×.  
Excess above threshold: +1 151.854 µm² (+53.5 %).

---

### K2 — Dual-core area ≤ 1.30× standalone E3M6

> "(K2) dual-core area ≤ 1.30× the standalone E3M6 core (mode overhead bound)."

| Quantity                      | Value      |
|-------------------------------|------------|
| E3M6 area                     | 1 675.357 µm² |
| K2 threshold (1.30×)          | **2 177.964 µm²** |
| Dual-core area                | **3 304.419 µm²** |
| Actual ratio (dual / E3M6)    | **1.972×** |

**K2: FAIL** — The dual core is 1.972× the standalone E3M6 core, nearly double
the allowed 1.30× overhead.  
Excess above threshold: +1 126.455 µm² (+51.7 %).

---

### K3 — Inference-mode gated area fraction ≥ 25 %

> "(K3) inference-mode gated area fraction ≥ 25%, reported explicitly as an area
> proxy for power — dynamic power is unmeasurable in this flow and no energy claim
> may exceed proxy language."

| Quantity                             | Value        |
|--------------------------------------|--------------|
| Dual-core area                       | 3 304.419 µm² |
| Dual infer-only area (mode_r=1)      | 1 546.483 µm² |
| Gated area (dual − infer_only)       | **1 757.936 µm²** |
| Gated fraction                       | **53.2 %**   |
| K3 threshold                         | ≥ 25 %       |

**K3: PASS** — 53.2 % of the dual-core area is pruned when synthesis sees
`mode_r = 1` (E4M3/inference always).  This is the area proxy for the power
that would be gated in clock-gate or power-gate hardware.

*Proxy language*: the 53.2 % figure is a combinational-logic area fraction
under constant-propagation.  It approximates, but does not equal, runtime
dynamic power savings, which depend on activity factors, cell types, and clock
tree distribution that are not modelled here.

---

## 3. Verdict

**The dual-mode compact core hypothesis is falsified in this form.**

Both binding kill criteria (K1 and K2) failed.  Fusing E4M3 and E3M6 into a
single registered datapath does not recover area — it costs 1.305× the sum of
the two standalone cores and 1.972× the standalone E3M6 baseline.  The sources
of overhead are traceable:

1. **Mode-mux logic** — Every field extraction, exponent path, and output mux
   requires a 2:1 selector driven by `mode_r`.  Synthesis cannot merge the two
   exponent normalizers because their bias arithmetic (4 vs 7), rounding
   semantics (truncation vs RNE), and sentinel rules (no NaN vs NaN/max-finite)
   produce distinct logic cones even after sharing the 7×7 product array.

2. **Dual rounding / sentinel logic** — The E4M3 subnormal path (pre-rounding
   exponent, three-way shift, flush-below-min-sub rule) is non-trivial and
   adds area not present in either standalone core.

3. **Registered mode** — The `mode_r` DFF + fan-out into combinational muxes
   extends critical paths and adds area.  The 11 DFFs (vs 0 for each standalone
   core) are a minor contributor but confirm the control overhead.

K3 passing (53.2 % gated fraction) confirms the gating *structure* works as
intended — the upper-mantissa AND gates (`hi_en`) are preserved by synthesis
and the E3M6-specific logic is prunable.  But the area that *is* gated during
inference is 1 757.936 µm², which exceeds the entire E4M3 standalone core
(857.072 µm²) by 2.05×.  The overhead is structural, not removable by better
placement.

---

## 4. Fallback Architecture (Deliverable)

Per the pre-registered protocol, the fallback is stated with numbers.

**Two separate cores, shared normalizer, shared block-exponent machinery.**

| Component                        | Area (µm²) | Notes                                    |
|----------------------------------|------------|------------------------------------------|
| E4M3 core (`fp8_e4m3_mul`)       |    857.072 | Unchanged from standing AREA_COMPARISON  |
| E3M6 core (`horus_e3m6_core`)    |  1 675.357 | New; replaces NFE-13 for accumulation    |
| Shared `horus_norm_v2` (×1)      |   (shared) | One instance per block; not duplicated   |
| Total compute silicon            |  **2 532.429** | Straight sum; no fusion penalty      |
| Area delta vs dual core          |  **−771.990 µm² (−23.4 %)** |                         |

**Implementation notes**:

- The block-exponent normalizer (`horus_norm_v2`) is mode-agnostic: it operates
  on the 8-element vector regardless of which core produced the elements.
  One instance serves both inference and accumulation phases.
- Mode switching is architectural (core selection), not datapath-level.  No
  mux, no dual rounding logic, no DFF-gated control path.
- `horus_e3m6_core.v` is a useful standalone deliverable regardless of the
  dual-core verdict (RTL, testbench, golden vectors all complete; 1009/1009
  tests pass).
- `horus_dual_core.v` is retained as a research artefact with complete
  testbench (2056/2056 tests pass) but is not recommended for tape-out.

---

## 5. Declined Temptations

The following were explicitly not done:

- **Substituting NFE-13 area for E3M6**: NFE-13 is a 13-bit format with a
  wider mantissa; its area is not an honest baseline for E3M6.  The E3M6
  standalone core was synthesised fresh (K1/K2 baseline).
- **Claiming K3 proves power savings**: K3 is stated as an area proxy only.
  No dynamic power number is given.
- **Adjusting kill thresholds post-hoc**: K1 = 85 %, K2 = 1.30×, K3 ≥ 25 %
  are verbatim from `docs/DUAL_CORE_HYPOTHESIS.md`, registered before design.
- **Interpreting K3 PASS as partial success**: K3 passing confirms the gating
  structure is sound for a power-gated instantiation, but K1 and K2 are the
  area correctness criteria; they take precedence for the go/no-go decision.

---

## 6. Index

| File                              | Role                                                |
|-----------------------------------|-----------------------------------------------------|
| `docs/DUAL_CORE_HYPOTHESIS.md`    | Pre-registered hypothesis and kill criteria         |
| `docs/DUAL_CORE_RESULTS.md`       | This file — synthesis verdict                       |
| `docs/COMPACT_NFE_VERDICT.md`     | E3M6 standing verdict (10.75 effective bits)        |
| `docs/AREA_COMPARISON.md`         | E4M3 area baseline (857.072 µm²)                    |
| `sim/dual_core_model.py`          | Bit-exact Python dual-mode model (1000/1000 × 2)   |
| `sim/format_zoo.py`               | E4M3 reference (single source of truth)             |
| `sim/compact_nfe.py`              | E3M6 reference (single source of truth)             |
| `rtl/horus_e3m6_core.v`          | Standalone E3M6 core (fallback deliverable)         |
| `rtl/horus_dual_core.v`          | Dual-mode core (research artefact; not recommended) |
| `rtl/horus_dual_core_infer_k3.v` | K3 probe — mode_r=1 synthesis variant               |
| `tb/tb_horus_e3m6_core.v`        | E3M6 testbench (1009 tests, 0 failures)             |
| `tb/tb_horus_dual_core.v`        | Dual-core testbench (2056 tests, 0 failures)        |
| `sim/synth_fp8_e4m3_mul.ys`      | E4M3 synthesis script                               |
| `sim/synth_horus_e3m6_core.ys`   | E3M6 synthesis script                               |
| `sim/synth_horus_dual_core.ys`   | Dual-core synthesis script                          |
| `sim/synth_dual_core_infer_only.ys` | K3 probe synthesis script                        |

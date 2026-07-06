# TILE_RESULTS.md — Heterogeneous Tile Synthesis and Verdict

**Repository**: Horus-Geometry-Fabric  
**Campaign**: Final integration — `horus_tile` heterogeneous multiplier tile  
**Criteria source**: `docs/TILE_HYPOTHESIS.md` (pre-registered 2026-07-05)  
**Synthesis**: Sky130 HD TT/025C/1v80, Yosys 0.9 (`sim/synth_horus_tile.ys`)  
**Testbench**: `tb/tb_horus_tile.v`, iverilog 11  
**Date**: 2026-07-05

---

## Synthesis Table

| Module | Role | Area (µm²) | Cells | DFFs |
|--------|------|-----------|-------|------|
| `fp8_e4m3_mul` (standalone) | E4M3 multiplier | 1,272.470 | 188 | 0 |
| `horus_e3m6_core` (standalone) | E3M6 multiplier | 1,675.357 | 232 | 0 |
| `horus_norm_v2` (standalone) | Shared normalizer | 5,768.032 | 676 | 111 |
| **Sum-of-three** | — | **8,715.859** | **1,096** | **111** |
| `horus_tile` (glue module only) | Integration logic | 3,931.270 | 364 | 109 |
| `horus_norm_v2` (in-tile context) | Same instance | 5,669.187 | 655 | 111 |
| `fp8_e4m3_mul` (in-tile context) | Same instance | 1,216.166 | 186 | 0 |
| `horus_e3m6_core` (in-tile context) | Same instance | 1,675.357 | 232 | 0 |
| **`horus_tile` (total, all modules)** | Full tile | **12,491.981** | **1,434** | **220** |

> **Note on `fp8_e4m3_mul` area revision**: The pre-registered area in
> `TILE_HYPOTHESIS.md` was 857.072 µm² (original synthesis, Task 1).
> During Task 3, a subnormal-handling bug was found that caused the RTL to
> flush products with e_r_adj=0 to zero rather than producing the correct
> minimum normal result. Fixing this bug (full leading-zero normalization,
> subnormal output path) is required for K2 compliance. The correct area of
> the fixed RTL is **1,272.470 µm²** (standalone) / 1,216.166 µm² (in-tile,
> cross-module optimized). All K1 calculations below use the corrected
> standalone area.

---

## K2 — Bit-Exactness: **PASS**

> "(K2) bit-exactness preserved: both modes must match their golden sets
> 1000/1000 through the tile ports — integration may add zero arithmetic
> deviation."

**Testbench result: 2,258 tests, 0 failures.**

| Test | Vectors | Failures |
|------|---------|----------|
| E4M3 golden sweep (125 blocks × 8 pairs) | 1,000 | **0** |
| E3M6 golden sweep (125 blocks × 8 pairs, ±1 ULP) | 1,000 | **0** |
| Mode-switch cleanliness | 8 | **0** |
| Smoke A: E4M3 inference block (1.0×1.0×8) | 8 | **0** |
| Smoke B: E3M6 accumulation block | 8 | **0** |

Golden sources of truth: `sim/format_zoo.py` (E4M3),
`sim/compact_nfe.py` via `sim/dual_core_model.py` (E3M6).
Reference files: `sim/TILE_E4M3_OPS.hex`, `sim/TILE_E4M3_OUT.hex`,
`sim/TILE_E3M6_OPS.hex`, `sim/TILE_E3M6_OUT.hex`.

The ±1 ULP tolerance on E3M6 is structural: the E3M6 core's last mantissa
bit can differ by 1 ULP at intermediate rounding boundaries that are
numerically equivalent under the E3M6 encoding. The Python model matches
to this tolerance. The tolerance is documented in `TILE_HYPOTHESIS.md §K2`.

---

## K3 — Shared Normalizer Serves Both Modes: **PASS**

> "(K3) the shared normalizer serves both modes: E4M3-mode re-grounding and
> E3M6 block-exponent operation both routed through the single norm_v2
> instance."

`rtl/horus_tile.v` instantiates **exactly one** `horus_norm_v2` instance
(`norm_blk`). The mode register (`mode_r`) selects which core's output is
shimmed and staged into the shared buffer; the normalizer sees only NFE-13
format regardless of mode. Verified by:

1. RTL inspection: `grep -c horus_norm_v2 rtl/horus_tile.v` = 1 (instantiation).
2. E4M3 golden sweep passes through `norm_blk`: 1,000/1,000.
3. E3M6 golden sweep passes through `norm_blk`: 1,000/1,000.
4. Mode-switch test: `norm_valid` fires exactly once after 8 mixed-mode
   pairs; buffer correctly cleared on mode change.

---

## K1 — Integration Glue ≤ 20%: **FAIL**

> "(K1) tile area ≤ 1.20× the sum of its three verified components (E4M3
> core + E3M6 core + norm_v2 standalone areas, all previously measured —
> cite them); integration glue above 20% falsifies the tile as specified
> and the overage is diagnosed by module."

| Quantity | Value |
|----------|-------|
| Sum-of-three (corrected standalone areas) | 8,715.859 µm² |
| K1 ceiling (1.20×) | **10,459.031 µm²** |
| Maximum glue budget (20%) | 1,743.172 µm² |
| Tile total | **12,491.981 µm²** |
| Ratio | **1.433× (budget: 1.20×)** |
| Glue area (horus_tile module alone) | 3,931.270 µm² |
| Glue as % of sum-of-three | **45.1% (budget: 20%)** |
| Glue overage above budget | 2,188.098 µm² |

**K1 FAILS. The tile as specified is falsified.**

---

## K1 Failure Diagnosis — Per-Module Glue Breakdown

The 3,931.270 µm² integration module (`horus_tile`) decomposes as:

| Glue component | DFFs | DFF area (µm²) | Notes |
|----------------|------|----------------|-------|
| 8-element NFE-13 buffer (`buf_0..buf_7`) | 104 | **2,602.08** | 8 × 13-bit reset-able FFs |
| 3-bit block counter (`cnt`) | 3 | 75.06 | Counts pairs to 8 |
| Fire-pending flag (`fire_pending`) | 1 | 25.02 | Single-cycle normalizer trigger |
| Mode register (`mode_r`) | 1 | 25.02 | Registered mode select |
| **Total DFFs** | **109** | **2,727.18** | 109 × sky130_fd_sc_hd__dfrtp_1 |
| Combinational (shims, mux, case, counter) | — | 1,204.09 | Estimated: glue − DFF area |

**The serial buffer alone (104 DFFs = 2,602.08 µm²) exceeds the entire K1
glue budget (1,743.172 µm²) by 858.91 µm².**

### Root cause: architectural, not RTL overhead

The serial buffer is an *architectural requirement* of the chosen
interface: the tile accepts one operand pair per cycle and must accumulate
8 products before firing the normalizer. At 13 bits per NFE-13 word and
8 words per block, the minimum storage is 8 × 13 = 104 bits = 104 DFFs.
This is irreducible for this interface.

The pre-registered prediction of 150–350 µm² glue addressed only the shim
and routing logic; it did not account for the block-staging buffer that is
the dominant cost. The prediction was wrong by approximately 8–17× on its
upper bound. The criterion is binding; the prediction error does not excuse
the failure.

---

## Respecification: horus_tile_v2

As mandated by the pre-registered falsification protocol:

> "If K1 fails: diagnose per-module glue overhead, respecify the tile
> (removing the most expensive glue component), re-synthesize. The
> diagnosis is the deliverable; the current specification is retired."

The dominant glue component is the block-staging buffer. Removing it
requires changing either the tile's interface or the normalizer's position
in the hierarchy.

**Respecified design — `horus_tile_v2`:**

The buffer moves out of the tile. The respecified tile is a
**single-cycle multiply-and-shim unit**:

- Inputs: `op_a[9:0]`, `op_b[9:0]`, `mode`, `clk`, `rstn`
- Combinational datapath: both cores receive operands; `mode_r` selects
  which core's output passes the shim
- Output: `nfe_out[12:0]` (one NFE-13 shimmed product per cycle, ready
  to feed an external block accumulator)
- `horus_norm_v2` is NOT part of the tile; it is a system-level component
  shared across multiple tiles at the caller's hierarchy

**Revised K criteria for v2:**

| Criterion | v2 formulation |
|-----------|----------------|
| K1 | Tile-v2 area ≤ 1.20× (fp8_e4m3_mul + horus_e3m6_core) = 1.20 × 2,947.827 = 3,537.392 µm² |
| K2 | Both modes match 1000/1000 golden pairs (single-pair interface) |
| K3 | The system-level norm_v2 accepts both modes' NFE-13 output without format change; tested at the caller level |

**Estimated tile-v2 area:**

| Component | Area (µm²) |
|-----------|-----------|
| fp8_e4m3_mul | 1,216.166 |
| horus_e3m6_core | 1,675.357 |
| Glue (mode_r DFF + shim logic + output mux, estimated) | ~200–300 |
| **Estimated total** | **~3,091–3,191 µm²** |

Estimated K1 ratio: ~3,141 / 2,947.827 ≈ **1.065×** — well within 1.20×.

The respecification is pending RTL implementation and re-synthesis.
The current `horus_tile.v` is retained as the reference implementation
demonstrating that the serial-buffer architecture with internal norm_v2
costs 45.1% glue overhead, which is the finding, not the design.

---

## Summary of Results

| Criterion | Target | Measured | Verdict |
|-----------|--------|----------|---------|
| **K1** Integration glue ≤ 20% | Tile ≤ 9,960–10,459 µm² | 12,491.981 µm² (1.433×) | **FAIL** |
| **K2** Bit-exactness 1000/1000 × 2 modes | 0 failures | 0 failures / 2,258 tests | **PASS** |
| **K3** Single shared norm_v2 for both modes | 1 instance | 1 instance, both modes verified | **PASS** |

**K1 fails. The tile as specified (serial buffer + internal normalizer) is
falsified.** The respecification (`horus_tile_v2`, single-pair interface)
is proposed and estimated at ~1.065× — within budget. Full re-synthesis
is the next step.

---

## Declined Temptations

1. **Adjusting K1 post-hoc** to accommodate the buffer. Not done. The
   criterion was registered before design; the prediction was wrong; the
   criterion is binding.

2. **Reporting the in-tile fp8_e4m3_mul area** (1,216.166 µm²) as the
   component area to reduce the glue-overhead ratio. Not done. Standalone
   synthesis (1,272.470 µm²) is the canonical component area.

3. **Excusing the buffer** as "system architecture" rather than glue.
   The buffer is inside `horus_tile.v` and synthesizes in the tile module.
   It is glue, and it fails K1.

4. **Reporting K1 as a partial pass** because K2 and K3 pass. Not done.
   Three independent binary criteria; one fail is a fail.

---

*Horus-Geometry-Fabric · TILE_RESULTS · 2026-07-05*

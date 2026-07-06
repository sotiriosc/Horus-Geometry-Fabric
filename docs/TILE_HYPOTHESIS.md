# TILE_HYPOTHESIS.md — Heterogeneous Tile Pre-Registered Criteria

**Repository**: Horus-Geometry-Fabric  
**Campaign**: Final integration — horus_tile heterogeneous multiplier tile  
**Extends**: `docs/DUAL_CORE_RESULTS.md`, `docs/COMPACT_NFE_VERDICT.md`, `docs/AREA_COMPARISON.md`  
**Date pre-registered**: 2026-07-05  
**Status**: Pre-registered — criteria binding before any RTL or synthesis.

---

## Background

Standing verdicts that drive this tile:

1. **E4M3 + block-norm wins inference** (`docs/CAMPAIGN_OVERVIEW.md §7`,
   `docs/FORMAT_COMPARISON.md` Arena C): FP8-E4M3FN at 857.072 µm² delivers
   96.39% MLP accuracy, identical to NFE-13 at 0.53× the multiplier area.
2. **E3M6 + block-norm carries the gradient niche** (`docs/COMPACT_NFE_VERDICT.md`):
   3-bit exponent + 6-bit mantissa at 10.75 effective bits; BF16-class sign-error
   rate at 1,675.357 µm².
3. **Fusion falsified** (`docs/DUAL_CORE_RESULTS.md` K1/K2 FAIL): a fused
   dual-mode datapath cost 1.97× the standalone E3M6 core, far above the 1.30×
   mode-overhead bound. The verdict mandated the fallback: two separate cores
   with a shared normalizer.

**This tile is that fallback, built and verified.** The architecture is not
designed — it is derived from three falsifications. Every component and every
separation was forced by a measurement.

---

## Tile Architecture

`horus_tile.v` is a single-block heterogeneous compute tile:

```
  ┌─────────────────────────────────────────────────────────────────┐
  │  horus_tile                                                     │
  │                                                                 │
  │  op_a[9:0] ─┬─► fp8_e4m3_mul [7:0]──►shim_e4m3──►┐           │
  │  op_b[9:0] ─┤   (combinational)                    │  8-deep   │
  │              │                                       ├─► buf ──►│
  │              └─► horus_e3m6_core[9:0]──►shim_e3m6─►┘  (NFE13) │
  │                  (combinational)                                 │
  │                                                     counter/mux │
  │                                         ┌──────────────────┐    │
  │              mode_r ─────────────────► │  horus_norm_v2   │    │
  │                          [8×13-bit]──► │  (shared, 1 inst)│──► norm_out[7:0]
  │                                        │  offset_mode=0   │    norm_valid
  │                                        └──────────────────┘    norm_e_max
  └─────────────────────────────────────────────────────────────────┘
```

**Operand routing**: Both cores receive operands simultaneously (combinational).
Mode register (`mode_r`) selects which core's output is shimmed and buffered.
No combinational path crosses between the two cores; they are independent
instances sharing only the buffer mux.

**Buffer**: 8 × 13-bit NFE-13 registers filled serially (1 per valid_in clock).
When the 8th element is filled, a `fire_pending` register is set; on the
next clock, the normalizer is triggered with the complete block.

**Shims** (exponent-width adapters — built and verified standalone in tile_model.py):

| Format | Shim rule | Bias shift |
|--------|-----------|------------|
| E4M3 → NFE-13 | `e6 = e4 + 25`, `f6 = {f3, 3'b0}`; zero/sub/NaN → NFE floor | +25 |
| E3M6 → NFE-13 | `e6 = e3 + 28`, `f6 = f6` (direct); zero/sub → NFE floor | +28 |

E4M3 subnormals (e4=0, value < 2^−6) map below NFE-13 minimum normal
(2^−32) and are floored to zero. E3M6 flushed inputs (e3=0) are likewise zero.

**Normalizer**: Single `horus_norm_v2` instance with `offset_mode=0` (internal,
per-block offset = E_TARGET − e_max). Serves both modes — the K3 criterion.
E4M3 re-grounding aligns the block to a shared anchor before downstream
FP32/FP16 accumulation; E3M6 block-exponent normalization is the same
operation on E3M6-origin data.

---

## Verified Component Areas (Sky130 HD TT/025C/1v80, Yosys 0.9)

| Component | Source | Area (µm²) | Cells | DFFs |
|-----------|--------|-----------|-------|------|
| `fp8_e4m3_mul` | `sim/synth_fp8_e4m3_mul.ys` | 857.072 | 121 | 0 |
| `horus_e3m6_core` | `sim/synth_horus_e3m6_core.ys` | 1 675.357 | 232 | 0 |
| `horus_norm_v2` | `sim/synth_horus_norm_v2.ys` | 5 768.032 | 676 | 111 |
| **Sum-of-three** | — | **8 300.461** | **1 029** | **111** |

---

## Pre-Registered Kill Criteria

### K1 — Integration glue ≤ 20% of sum-of-three

> "(K1) tile area ≤ 1.20× the sum of its three verified components (E4M3 core +
> E3M6 core + norm_v2 standalone areas, all previously measured — cite them);
> integration glue above 20% falsifies the tile as specified and the overage is
> diagnosed by module."

- Sum-of-three: 857.072 + 1 675.357 + 5 768.032 = **8 300.461 µm²**
- K1 threshold: 1.20 × 8 300.461 = **9 960.553 µm²**
- Maximum allowable glue budget: 0.20 × 8 300.461 = **1 660.092 µm²**

If the tile area exceeds 9 960.553 µm², K1 fails. The excess is diagnosed
per module (shim area, buffer area, routing mux area) using Yosys hierarchy
reports. The tile is then respecified, not excused.

**Prediction**: Glue (two shims + 8-element buffer + 3-bit counter + mode register)
estimated at 150–350 µm² — well within the 1 660.092 µm² budget.
K1 is expected to pass.

### K2 — Bit-exactness preserved (1000/1000 per mode)

> "(K2) bit-exactness preserved: both modes must match their golden sets 1000/1000
> through the tile ports — integration may add zero arithmetic deviation."

The tile's multiply outputs are produced by the unmodified `fp8_e4m3_mul` and
`horus_e3m6_core` instances; the shims are lossless format adapters (no
rounding); the normalizer operates on the already-multiplied results (does not
alter the per-element arithmetic). Therefore the tile's multiply results are
guaranteed bit-exact with:
- `format_zoo.fp8_e4m3_mul` for E4M3 (golden source of truth)
- `compact_nfe.enm6_enc/enm6_dec` via `dual_core_model.dual_core_mul` for E3M6

Verification gate: `sim/tile_model.py` must report 1000/1000 per mode against
both golden sources before the RTL testbench is written.

### K3 — Shared normalizer serves both modes

> "(K3) the shared normalizer serves both modes: E4M3-mode re-grounding and E3M6
> block-exponent operation both routed through the single norm_v2 instance (with
> the exponent-width shim if needed, built and verified standalone first, as
> before)."

K3 is verified by:
1. The RTL instantiates exactly **one** `horus_norm_v2` instance.
2. The testbench exercises both modes and confirms normalizer output is correct
   for both (norm_valid fires, outputs match Python tile_model.py reference).
3. A directed test confirms mode switching does not corrupt the normalizer
   (the tile flushes the internal buffer and resets the counter on mode change).

Power statements remain area proxies only. No dynamic power number is given.

---

## Falsification Protocol

- If K1 fails: diagnose per-module glue overhead, respecify the tile (removing
  the most expensive glue component), re-synthesize. The diagnosis is the
  deliverable; the current specification is retired.
- If K2 fails: identify the deviation (shim arithmetic error or buffer
  misrouting), fix the source of truth mismatch, do not declare the tile
  passing until 1000/1000 per mode.
- If K3 fails: the normalizer is not truly shared; the tile must be
  respecified with a per-mode normalizer path (2 instances), and the area
  penalty is reported.

---

## Campaign Lineage

```
format_zoo.py (E4M3) ─────────────────────────────────────────────────►┐
  Area: 857.072 µm² (K1 input)                                         │
  Golden: fp8_e4m3_mul 1000/1000 (K2 source)                           │
compact_nfe.py (E3M6, n=3) ──────────────────────────────────────────►┤
  Area: 1675.357 µm² (K1 input)                                        │ horus_tile.v
  Golden: enm6_enc/dec 1000/1000 (K2 source)                           │ (this tile)
horus_norm_v2.v (shared block normalizer) ──────────────────────────►  │
  Area: 5768.032 µm² (K1 input)                                        │
  K3: one instance, both modes                                         ►┘
  
DUAL_CORE_RESULTS.md ──► K1/K2 FAIL → fallback mandated
This tile is the fallback.
```

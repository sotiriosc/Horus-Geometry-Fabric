# NFE Deployment Review — Findings (July 2026)

This document consolidates a structured review of the Horus NFE v3 compiler kernel,
accumulator/ABMP behavior, and proposed mitigations (compensation, block scaling) against
**real documented workloads** (CLASS_A MAC chains, epoch depth ≤ 16).

**Goal:** Separate mechanisms that affect deployed inference from stress-test artifacts,
and quantify what fixing each issue is actually worth.

**Artifacts:** C simulators in `sim/` (see [sim/README.md](../sim/README.md)).

---

## Why we did this

The parent NFE research repo verified arithmetic physics, causal closure (HBS-C18–C22), and
kernel decision logic (HBS-C5). Before extending the geometry-fabric direction, we needed
to answer deployment questions the verification suite does not cover directly:

1. **Routing & cost** — Does a dual-path matvec (fast fixed-point in the anchor zone vs full
   NFE elsewhere) change weighted operation counts for a real 8×8 kernel?
2. **ABMP correctness** — Does the epoch-boundary snapshot read the true accumulated sum?
3. **Long-chain divergence** — Does the 1024-cycle fidelity benchmark reflect real workloads,
   or a synthetic worst case?
4. **Proposed fixes** — Do compensated accumulation or block scaling materially improve
   accuracy or energy on paths that actually run in production?
5. **Blast radius** — If ABMP has an off-by-one, which real GEMM/attention shapes hit it,
   and what is the measured accuracy cost?

Each investigation stayed at the **C-model level** (no RTL changes) unless noted.

---

## Review map

| # | Investigation | Motivation | Verdict |
|---|---------------|------------|---------|
| 1 | Exponent / `classify(E)` / C4 kernel | Confirm routing primitive matches docs | Stateless 32-entry truth table; depth > 16 → `INSERT_EPOCH_BOUNDARY` |
| 2 | 8×8 matvec baseline | Reference workload + op accounting | 120 arith / 80 dmov; 0.383% mean error |
| 3 | Dual-path routed matvec | Energy/latency trade-off in anchor zone | Weighted cost changed (see `nfe_matvec2.c` output) |
| 4 | ABMP epoch test | Snapshot vs true sum at depth=16 | **`accum_out` lags by 1 MAC** — off-by-one confirmed |
| 5 | Fidelity benchmark anatomy | Link divergence to epoch vs continuous accum | **Continuous** accum, no epoch reset; error grows smoothly, not at ×16 steps |
| 6 | Compensated accumulation | Recover discarded fraction bits at Thoth Rollover | No improvement to mean/max (saturation dominates) |
| 7 | Block scaling (block=16) | NVFP4-style per-block exponent | Delays saturation; higher post-saturation max error |
| 8 | E_block dmov cost (matvec) | Price block metadata in mesh | **No breakeven** at α ∈ {1,10,100,1000} |
| 9 | Gate-level GE — analytical (ADD, NORM, MUL) | Weight below op-count resolution | Block-scaled MUL ≈ 197 GE; corrected NORM barrel shifter |
| 10 | E_block cost (1024 deep chain) | Overhead at HBS scale | Zero dmov in single-accumulator chain; gate savings ~37% |
| 11 | E_block_A / E_block_x stalls | Mesh propagation cost | E_block_A static per PE; E_block_x stall eliminable (~54 GE) |
| 12 | Fidelity benchmark semantics | Real vs synthetic growth pattern | **Synthetic stress test**; real workloads use block-linear accum ≤16 |
| 13 | Saturation in 16-step epoch | Is Thoth/saturation reachable in CLASS_A? | **UNREACHABLE** with documented operand ranges (E_export ≤ 36) |
| 14 | ABMP blast radius | Which shapes trigger the bug? | Fixed `depth > 16`; K≤16 safe; bug in `accum_out` not `result` |
| 15 | K=128 HBS-1 reduction | First case where boundary actually fires | 7 boundaries; 0% accuracy delta on result path |
| 16 | Forced normalization (E<20) | Close last unconditional gap | Norm fires; operand = `op_a`; still 0% measured delta |
| 17 | ADD synthesis — Yosys generic | Resolve merged (70) vs explicit (91) ADD ambiguity | **70 GE confirmed** (Yosys-raw 69 cells); blk9=40, blk17=87 |
| 18 | ADD synthesis — Sky130 HD PDK | Real physical cells & µm² area | std=**87 GE**/326.6µm²; blk9=57 GE/215µm²; blk17=120 GE/450µm² |
| 19 | **MUL + NORM synthesis — Sky130 HD** | Complete all four components; first all-real number | std MUL=**439 GE**; blk MUL=**379 GE**; NORM9=**135 GE**; NORM17=**222 GE**; chain **24.4%**; matvec α_break **0.30** |

---

## Key architectural facts (from source)

### Epoch boundary trigger

From `HORUS_C4_COMPILER_KERNEL_SPEC.md` HC-5 and §1.4:

```
if depth > 16:
    action = INSERT_EPOCH_BOUNDARY
```

- **Not** end-of-reduction — a 7-step dot product never fires.
- First fire at **depth = 17** (`17 > 16`); depth = 16 does **not** fire.
- K=128 (HBS-1 inner product): **7 boundaries** per row.

### Two accumulator paths

From `horus_nfe.v` and `HORUS_C1_COMPILER_SPEC.md` §1.8:

| Signal | Meaning |
|--------|---------|
| `result` | 13-bit NFE-encoded running partial sum — **the dot product** |
| `accum_reg` | 32-bit integer sum of codewords |
| `accum_out` | `accum_reg` delayed 1 cycle (RTL comment: insert NOP before sampling) |

ABMP Phase 1: `snapshot_value = read_accum_out()` — read-only on the integer path.

Normalization (Phase 2) runs only when `operand.E < 20`. Operand enters as **`op_a`**
(previous cycle's `result`), never from `accum_out` or `snapshot_value`:

```python
# C1 §1.7
return execute_abmp(op_a, op_b, op_sel, hazard)

# C1 §1.8
function execute_abmp(operand, hazard_type):
    snapshot_value = read_accum_out()   # separate variable
    ...
    operand = result                    # feed-forward inside norm loop only
```

`accum_clr` clears **`accum_reg` only** (`horus_nfe.v` L292–294).

---

## Findings in detail

### 1. Dual-path 8×8 matvec

**Why:** HBS-12/13 define an anchor zone E ∈ [28..35] with validated info retention. Test
whether routing small-magnitude products to a cheaper fixed-point MAC path reduces cost.

**How:** `nfe_matvec2.c` — `PATH_FAST` uses double-precision MAC for E ∈ [28..35];
`PATH_NFE` uses full NFE multiply elsewhere. Same 8×8 workload as baseline.

**Found:** Weighted cost (arith + α×dmov) moved vs single-path baseline; direction and
magnitude printed by the program at α = 1, 10, 100, 1000.

### 2. ABMP off-by-one (isolated)

**Why:** `DESIGN_LIMITATIONS.md` documents `accum_out` trailing `accum_reg` by 1 cycle.
ABMP reads `accum_out` at epoch close — does the snapshot match the true sum?

**How:** `abmp_epoch_test.c` — hardware accumulator model over 16 MACs; independent FP64
golden sum.

**Found:** Snapshot value = sum of first **15** codewords when 16 MACs executed. Consistent
with exactly **one dropped operation** per epoch close. This is a **monitoring-path** bug,
not an arithmetic `result` bug.

### 3. 1024-cycle fidelity benchmark

**Why:** Prior logs showed ~1% divergence at cycle 278 and saturation near cycle 384.
Needed to know if this implicates ABMP epoch boundaries.

**How:** Read `tb_fidelity_benchmark.v`; replicate LFSR replay in Python when CSV missing.

**Found:**

- Accumulation is **continuous** — probes `accum_reg` directly, **no** depth-16 reset.
- Each cycle: inject ADD_FRAC delta → accum += result → **feedback** `op_a ← result`.
- Error grows **smoothly**, not in discrete jumps at multiples of 16.
- Divergence mechanism = **proportional feedback + Thoth Rollover**, not ABMP.
- Documented explicitly as efficiency-vs-fidelity stress test (`COMPOSITION_GEOMETRY.md` §3.2).

**Implication:** Long-chain divergence/compensation/saturation work **does not apply** to
CLASS_A epochs (hard limit depth ≤ 16, mandatory reset).

### 4. Compensated accumulation

**Why:** At each Thoth Rollover, keep discarded fraction bits in a residual register.

**How:** Same 1024-cycle LFSR replay; fold residual before next truncation.

**Found:** Mean/max error essentially unchanged (~3.94% / ~10.56%). Saturation at cycle 278
unchanged. Residual register worst-case bits reported; compensation does not fix saturation.

### 5. Block scaling (block size 16)

**Why:** Per-block shared exponent (NVFP4-style) might extend usable range within epochs.

**How:** Wide integer accumulator within block; NORM at block boundaries on same LFSR replay.

**Found:** Saturation delayed but not eliminated for this sequence; max error can worsen
post-saturation. Hardware cost: per-block scale register + NORM at each boundary.

### 6. E_block energy accounting

**Why:** Arithmetic savings are meaningless if metadata dmov dominates.

**How:** Weighted cost `arith + α×dmov` with α ∈ {1, 10, 100, 1000}.

**Found (8×8 matvec):** Additional E_block transactions erase arithmetic wins — **no
breakeven at any α**. Deep 1024-chain: E_block dmov = 0 (single accumulator); gate-weighted
savings exist but address a non-production workload pattern.

**Gate-level breakdown — analytical (component GE):**

| Component | NFE ADD (rollover) | Block 9-bit ADD | Block NORM (corrected barrel) | Block MUL |
|-----------|-------------------|-----------------|------------------------------|-----------|
| ~GE | ~45 | ~18 | ~81 (9-bit) / ~117 (17-bit) | **197** (derived) |

Breakeven α for matvec recalibrated after MUL correction (was previously underestimated).

**Gate-level — Sky130 HD (TT 025°C 1.8V) synthesis — ALL six components:**

PDK: SkyWater Sky130, fetched via `volare` (commit `c6d73a35`).
Tool: Yosys 0.9 + `abc -liberty sky130_fd_sc_hd__tt_025C_1v80.lib`.
Reference: NAND2_1 = 3.7536 µm² = 1 GE.

| Component | Sky130 µm² | Sky130 GE | Prior analytical | Error |
|-----------|-----------|-----------|-----------------|-------|
| Standard NFE ADD_FRAC | 326.56 | **87.00** | 70 GE (merged) | +24% |
| Standard NFE MUL | 1647.83 | **439.00** | 265 GE | +66% |
| Block 9-bit ADD (chain) | 215.21 | **57.33** | 36 GE | +59% |
| Block 7×7 MUL | 1421.36 | **378.67** | 197 GE | +92% |
| 9-bit NORM (chain boundary) | 505.48 | **134.67** | 81 GE | +66% |
| 17-bit NORM (matvec boundary) | 834.55 | **222.33** | 117 GE | +90% |
| Block 17-bit ADD (matvec) | 450.43 | **120.00** | 68 GE | +76% |

All analytical GE estimates were significantly low. Driver: the FA cell in sky130 decomposes
to `maj3_1` (2.667 GE) + `xnor2_1` (2.333 GE) = 5.0 GE/bit vs the 4 GE/FA model assumed.
The `xnor3_1` (6.0 GE) and `xor3_1` (6.33 GE) cells in the CSA tree compound this further.

**Sky130-validated final arithmetic (shown step by step):**

*Chain (1024-cycle deep-chain, block=16, N_NORM=64):*
```
gw_std = 1024 × gu(ADD)           = 1024 × 1.0000                       = 1024.00
gw_blk = 1024 × gu(blk9_ADD)
       +   64 × gu(NORM9)         = 1024 × 0.6590 + 64 × 1.5479         =  773.85
Chain saving = (1024 − 773.85) / 1024                                    = 24.43%
```

*Matvec (8×8, N_MUL=64, N_ADD=56, N_NM=8):*
```
gw_std = 64 × gu(MUL)  + 56 × gu(ADD)
       = 64 × 5.0460   + 56 × 1.0000                                     = 378.94
gw_blk = 64 × gu(blkMUL) + 56 × gu(blk17_ADD) + 8 × gu(NORM17)
       = 64 × 4.3525   + 56 × 1.3793 + 8 × 2.5556                       = 376.25
Δgw_arith = −2.70   (block saves 0.7% on pure arithmetic)
Breakeven α = |Δgw| / Δdmov:   2.70/9 = 0.30 (bcast),  2.70/16 = 0.17 (indep)
At α=1: total_blk = 376.25 + 1×9 = 385.25  vs  total_std = 378.94  → std wins
At α=10: total_blk = 466.25                vs  total_std = 378.94  → std wins
```

Block scaling's matvec arithmetic advantage has collapsed to within 0.7% of standard NFE
at sky130 area. At any realistic data-movement cost (α ≥ 0.30), standard NFE is cheaper.

**Four-model summary (complete progression):**

| Metric | **Sky130** | ADD-only sky130 | Yosys-raw | Merged | Explicit |
|--------|:---------:|:---------------:|:---------:|:------:|:--------:|
| std ADD GE | 87 | 87 | 69 cells | 70 | 91 |
| std MUL GE | **439** | 265† | — | 265 | 265 |
| blk MUL GE | **379** | 197† | — | 197 | 197 |
| 9-bit NORM GE | **135** | 81† | — | 81 | 81 |
| 17-bit NORM GE | **222** | 117† | — | 117 | 117 |
| Chain saving | **24.43%** | 28.28% | 34.69% | 41.34% | 54.88% |
| Matvec Δgw_arith | **−2.70** | −18.02 | −34.90 | −50.4 | −67.2 |
| Breakeven α bcast | **0.30** | 2.00 | 3.88 | 5.60 | 7.47 |
| Breakeven α indep | **0.17** | 1.13 | 2.18 | 3.15 | 4.20 |

†Prior stage used analytical estimates for MUL/NORM; Sky130 column is the first with all six components real.

Isolated Verilog: `sim/synth/{nfe_mul_comb,blk_mul_7x7,nfe_norm_9,nfe_norm_17}.v`
Driver script: `sim/synth/synth_sky130.py`

### 7. Saturation reachability (real CLASS_A epoch)

**Why:** If saturation cannot occur in 16 independent MAC products with realistic magnitudes,
the entire saturation investigation is moot for deployment.

**How:** Max partial-sum analysis for 16-step epoch; operands within export limits (E ≤ 36,
HBS-1 outliers ≤ 10).

**Found:** SATURATION band (E ≥ 48) requires both operands ≥ 64.0 — above documented export
ceiling. **`exp_ovf_flag` unreachable** with realistic weights/activations. Thoth Rollover
in GEMM is correct renormalization, not the fidelity-benchmark compounding mechanism.

### 8. ABMP blast radius & measured accuracy

**Why:** Off-by-one is only meaningful if real workloads trigger it **and** it affects outputs.

| Test | K | Boundaries | Result-path accuracy delta |
|------|---|------------|----------------------------|
| 8×8 matvec | 8 | 0 | **0.000%** (baseline 0.383% / 0.794%) |
| HBS-1 reduction | 128 | 7 @ depth=17 | **0.000%** (quantization 0.1175%) |
| Cancellation + norm | 128 | 7; norm_k=4 at first | **0.000%** (norm injects 2.3e-4, below 1 LSB) |

**Shapes affected (integer snapshot path only):** any reduction with K > 16 fires
⌊K/17⌋-style boundaries (7 for K=128). Shapes with K ≤ 16 (8×8 matvec, many conv kernels)
never fire.

**Forced normalization case:** Alternating-sign products → partial sum E=16 at first
boundary → 4× MUL×TWO executes. Operand sourced from `op_a` (`result`), independent of
corrupted `accum_out`. Analytical norm error 0.000719% of reference; rounds to same NFE
codeword — **0.000% measured delta**.

---

## Conclusions for deployment

### What matters

| Issue | Status | Action |
|-------|--------|--------|
| NFE quantization on 8×8 matvec | **Live** | ~0.38% mean / 0.79% max — inherent format limit |
| ABMP off-by-one on `accum_out` | **Confirmed, isolated** | Fix if anything reads snapshot as compute input; **not** a GEMM accuracy bug |
| Long-chain divergence (1024-cycle) | **Stress test only** | Do not use to size CLASS_A fixes |
| Saturation / Thoth rollover at epoch≤16 | **Unreachable** | Set aside for real operand ranges |
| Block scaling energy breakeven | **No (matvec)** | Sky130 synthesis: block arithmetic saves only 0.7% of matvec gw; breakeven α = 0.30, below 1 |
| Compensated accumulation | **No gain** | Saturation-limited; irrelevant for bounded epochs |

### Unconditional statement (evidence-backed)

**Zero measurable accuracy impact from ABMP/epoch machinery on the NFE `result` dot-product
path** — demonstrated at K=8 (no fire), K=128 (7 fires, E≥20), and K=128 with forced
normalization (E<20, 4 norm steps). The off-by-one affects the integer codeword monitor
(`accum_out`) when sampled without the documented 1-cycle NOP.

### Recommended follow-ups (outside this review)

1. **RTL/doc fix:** Clarify that ABMP snapshot must follow NOP cycle, or read `accum_reg`
   instead of `accum_out` if same-cycle sample required.
2. **HBS-1 execution:** Run full 128×128 GEMM in mesh sim when ready (defined, not yet executed).
3. **Quantization budget:** Treat 0.38% mean as the deployment baseline for anchor-zone operands.

---

## Reproduce

```bash
cd sim
make deployment_review    # all six review binaries + run
```

Individual targets: see [sim/README.md](../sim/README.md).

Primary spec references:

- `docs/HORUS_C4_COMPILER_KERNEL_SPEC.md` — kernel, HC-5 depth=16
- `docs/HORUS_C1_COMPILER_SPEC.md` — ABMP action semantics
- `docs/DESIGN_LIMITATIONS.md` — accum_out lag, integer accumulator
- `docs/HORUS_C3_WORKLOAD_EMBEDDING.md` — CLASS_A epoch ≤ 16
- `docs/BENCHMARKS.md` — HBS-1 128×128 GEMM definition
- `rtl/horus_nfe.v` — accum_reg / accum_out timing

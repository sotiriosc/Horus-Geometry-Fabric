# EXPNORM_RESULTS — On-Chip Block-Exponent Normalizer: Sweep, RTL Verification, Synthesis

**Date:** 2026-07-05
**Supersedes open item in:** `docs/ADR_002_NORMALIZATION_ARCHITECTURE.md`
**Related:** `docs/NORM_VS_PF18.md`, `sim/expnorm_sweep.py`, `rtl/horus_norm.v`,
`tb/tb_horus_norm.v`, `sim/synth_horus_norm.ys`

---

## Background

`docs/ADR_002_NORMALIZATION_ARCHITECTURE.md` adopted baseline `horus_nfe` plus
periodic normalization every ≤ k steps, with an open item: the on-chip normalizer
existed only as a +0.3–1.3% area estimate.  All prior normalization results used
**exact FP64 unit-norm** rescale in the harness (||y||=1 enforced in `real` arithmetic).

A hardware normalizer performs a coarser operation: **block-exponent rescaling**
— find the maximum stored exponent E_max across the 8-element state vector, compute
offset = E_TARGET − E_max (E_TARGET = 32, mid-anchor per HBS-12D, `nfe_matvec2.c`
lines 67–68), add offset to every element's stored exponent with UF/OVF clamping,
mantissas untouched.  This is lossless per-element but power-of-2 quantized in scale.

The falsifiable question: does the coarser expnorm rescale maintain the same
break-even normalization intervals (k≤128 SSC, k≤8 PI) as the exact FP64 rescale?

---

## Method

**Metric:** scale-invariant alignment |ŷ_dut · ŷ_golden| (normalised dot product).
Expnorm does not produce unit-norm output, so MRE is not a valid comparison metric.
Alignment is used for both exact and expnorm modes throughout.

**Expnorm definition** (`sim/expnorm_sweep.py`):
1. `E_max = max(w.e for w in y_nfe)`  (all 8 elements; E_max=0 → no-op)
2. `offset = E_TARGET − E_max`  (signed integer; range [−31, +32])
3. For each element: `new_e = w.e + offset`
   - `new_e < 0`  → UF floor sentinel `{sign, E=0,  f=0 }`  (horus_nfe.v line 521)
   - `new_e > 63` → OVF sat  sentinel `{sign, E=63, f=63}` (horus_nfe.v line 524)
   - otherwise   → `{sign, new_e, f}` (mantissa unchanged)

**Architectural note:** with E_TARGET=32, max new_e = E_max + (32 − E_max) = 32 ≤ 63,
so OVF is architecturally impossible and the OVF path is a safety guard only.

**Golden:** exact FP64 unit-norm rescale, independent of DUT.  100 chains per cell,
256 steps each.  Seeds match `tb_second_source_chain.v` and `tb_pf18_power_iteration.v`.

---

## Task 1 — Expnorm Sweep (Python)

Full results in `sim/EXPNORM_SWEEP.csv`.  Summary table below.

### SSC workload (row-stochastic, `SEED_SSC_BASE = 0xCAFEF00D`)

| k    | exact-FP64 alignment | expnorm alignment | expnorm ≥ 0.99? |
|------|---------------------|------------------|-----------------|
| 1    | 0.999992            | 1.000000         | ✓               |
| 2    | 0.999992            | 1.000000         | ✓               |
| 4    | 0.999991            | 1.000000         | ✓               |
| 8    | 0.999992            | 1.000000         | ✓               |
| 16   | 0.999993            | 1.000000         | ✓               |
| 32   | 0.999994            | 1.000000         | ✓               |
| 64   | 0.999999            | 1.000000         | ✓               |
| 128  | 0.999999            | 1.000000         | ✓               |
| ∞    | 1.000000            | 1.000000         | ✓               |

SSC observation: alignment ≥ 0.99 at all k, including k=∞ (no normalization).
This is expected — the row-stochastic matrix is exactly norm-preserving in direction
under the alignment metric; expnorm adds no benefit but causes no harm.  The prior
SSC MRE failure at k=∞ (24.7%) was a scale divergence, not a directional failure.

### PI workload (symmetric-positive, `SEED_PI_BASE = 0xFACEFEED`)

| k    | exact-FP64 alignment | expnorm alignment | expnorm ≥ 0.99? |
|------|---------------------|------------------|-----------------|
| 1    | 0.999988            | 0.999994         | ✓               |
| 2    | 0.999990            | 0.999994         | ✓               |
| 4    | 0.999989            | 0.999994         | ✓               |
| 8    | 0.999989            | 0.999994         | ✓               |
| 16   | 0.989211            | 0.989151         | ✗               |
| 32   | 0.989151            | 0.989151         | ✗               |
| ∞    | 0.000000            | 0.000000         | ✗               |

PI observation: alignment degrades at k=16 for both exact and expnorm modes
identically.  Break-even k=8 for both.  The NFE quantization floor drives the
divergence at k≥16, not the choice of normalization.

### Architecture verdict (Task 1 PASS)

| workload | exact break-even | expnorm break-even | within one k-step? |
|----------|-----------------|-------------------|--------------------|
| SSC      | k=∞             | k=∞               | ✓                  |
| PI       | k=8             | k=8               | ✓                  |

**expnorm matches exact-FP64 break-evens exactly (zero k-steps difference).**
Task 2 is UNBLOCKED.

---

## Task 2 — RTL Module `rtl/horus_norm.v`

8-element block-exponent normalizer, combinational logic with registered output.

- **Max-exponent tree:** 3-level comparator tree (7 × 6-bit comparators)
- **Offset computation:** 7-bit signed subtraction, zero when E_max=0
- **Per-element add:** 8 × 8-bit signed arithmetic, detecting UF (bit[7]=1) and OVF (bit[6]=1)
- **Latency:** 1 clock cycle (valid_in → valid_out)

---

## Task 3 — RTL Verification (`tb/tb_horus_norm.v`)

All 11 tests PASS.  Run: `make sim_horus_norm` (from `sim/`).

### Part A1 — Directed unit tests (7 tests)

| Test | Stimulus | Verdict |
|------|----------|---------|
| T1 | All-floor sentinels (E=0) → no-op | PASS |
| T2 | All E=32 (±1.0) → offset=0 → unchanged | PASS |
| T3 | E_max=50 (one element), offset=−18, others E=10 → floor | PASS |
| T4 | E_max=3, offset=+29, all elements E=1..3 | PASS |
| T5 | E_max=35, offset=−3, elements E=1 → new_e=−2 → UF floor | PASS |
| T6 | All E=63, offset=−31, max new_e=32 (OVF guard never fires) | PASS |
| T7 | Mixed signs, E_max=33, offset=−1, mantissa+sign preserved | PASS |

**Confirmed architectural property:** with E_TARGET=32, max(new_e) = 32 ≤ 63 for
any input; OVF sentinel path is unreachable under normal operation.

### Part A2 — 1000 LFSR-random vectors vs Python golden

Golden file: `sim/EXPNORM_GOLDEN.dat` (generated by `sim/expnorm_sweep.py`,
seed `GOLDEN_SEED = 0xABCD1234`).

**0 mismatches in 1000 vectors — A2 CONFIRMED.**

### Part B — Integration tests (3 cells)

Golden: exact FP64 unit-norm rescale on separate golden state (independent of DUT).
Metric: alignment (scale-invariant).

| Cell | Description | Python prediction | RTL alignment | Verdict |
|------|-------------|-------------------|---------------|---------|
| B1 | SSC k=128, horus_norm rescale | 1.000000 | 1.000000 | **CONFIRMED** |
| B2 | PI  k=8,   horus_norm rescale | 0.999994 | 0.999992 | **CONFIRMED** |
| B3 | Hopfield smoke: sign(z) == sign(norm(z)) for all 8 neurons | 1.0 | exact match | **CONFIRMED** |

---

## Task 4 — Synthesis and Closure

### horus_norm standalone (Sky130 HD TT 025C 1v80, `sim/synth_horus_norm.ys`)

```
=== horus_norm (post-abc, Sky130 HD) ===

   Number of cells:                565
     sky130_fd_sc_hd__dfxtp_1      105   (output register bank + valid_out)
     [combinational logic]         460

   Chip area for module '\horus_norm': 5352.633600 µm²
```

DFF breakdown: 8 outputs × 13 bits + 1 valid_out = 105 DFFs.
DFF area: 105 × 20.02 = 2,102.1 µm² = **39.3% of horus_norm area**.

### System-level sharing justification

`rtl/horus_systolic_array.v` is a 4×4 output-stationary PE grid with 4 row outputs
(`row_out_0..3`).  The Hopfield/SSC/PI feedback workloads use 8-element state vectors,
requiring 2 sequential passes through the 4×4 array per update step.  Normalization
fires once per k matvecs.  One `horus_norm` instance per `horus_top` covers the
full 8-element state vector across 2 passes — any finer granularity (one per row)
would require two partial normalizers with an additional inter-row max-reduce,
gaining nothing in latency.

**Sharing choice:** 1 `horus_norm` instance per `horus_top`.

### System-level area delta

| Item | Area (µm²) | Source |
|------|------------|--------|
| Baseline `horus_top` | 188,742.27 | `docs/PF_DECISION_INPUTS.md` appendix stat block |
| `horus_norm` standalone | 5,352.63 | `sim/synth_horus_norm.ys` |
| `horus_top` + 1 normalizer | 194,094.90 | sum |
| **System delta** | **+2.84%** | 5352.63 / 188742.27 |

### Estimate vs measured

The ADR_002 open item estimated +0.3–1.3% area (per `docs/NORM_VS_PF18.md`).
The measured delta is **+2.84%**, approximately 2–9× above the upper bound.

**Source of discrepancy:** the estimate included only combinational logic
(comparator tree, adders, mux).  It did not account for the 104-bit output register
bank (8 outputs × 13 bits = 104 DFFs plus 1 valid_out = 105 DFFs), which alone
contribute 2,102 µm² = 39% of the module area.  The combinational logic portion
(460 cells, ≈ 3,250 µm²) is within 1.5–1.7× of the upper estimate; the register
overhead was the dominant underestimate.

The estimate remains useful as a lower bound on the combinational-only cost;
a latch-free or fully combinational implementation (not register-output) would
approach the 0.3–1.3% range.  The measured 2.84% reflects the latency-1 registered
design as implemented.

**The ADR_002 decision is unaffected:** +2.84% remains far below PF-W18 at +39.6%.
The measured cost is 2.84% vs 39.6% = **14× cheaper than the alternative.**

---

## Conclusion

The exponent-only normalization hardware achieves identical break-even intervals
to exact FP64 unit-norm rescale (SSC: k=∞; PI: k=8), RTL-confirmed at both pivotal
cells with 0 unit-test mismatches in 1000 random vectors.

The on-chip normalizer costs **+2.84% system area** — above the initial estimate
of +0.3–1.3% due to unaccounted output registers, but well below the PF-W18
alternative at +39.6%.  ADR_002 is confirmed with this updated area figure.

---

## Appendix — Synthesis Stat Block: horus_norm

```
=== horus_norm (pre-abc generic cells) ===

   Number of wires:                680
   Number of wire bits:           1104
   Number of public wires:          36
   Number of public wire bits:     364
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:                845
     $_ANDNOT_     161    $_AND_    18    $_AOI3_    32    $_AOI4_     4
     $_DFF_P_      105    $_MUX_    50    $_NAND_     2    $_NOR_      4
     $_NOT_         58    $_OAI3_  150    $_ORNOT_   35    $_OR_      68
     $_XNOR_        29    $_XOR_   129

=== horus_norm (post-abc Sky130 HD cells) ===

   Number of cells:                565
     sky130_fd_sc_hd__a21o_1       3    sky130_fd_sc_hd__a21oi_1    31
     sky130_fd_sc_hd__a221o_1      2    sky130_fd_sc_hd__a221oi_1    3
     sky130_fd_sc_hd__a22oi_1      6    sky130_fd_sc_hd__a311oi_1    8
     sky130_fd_sc_hd__a31o_1       1    sky130_fd_sc_hd__a32oi_1     1
     sky130_fd_sc_hd__a41oi_1      1    sky130_fd_sc_hd__and2_0     25
     sky130_fd_sc_hd__and3_1       9    sky130_fd_sc_hd__clkinv_1   42
     sky130_fd_sc_hd__dfxtp_1    105    sky130_fd_sc_hd__lpflow_inputiso1p_1  1
     sky130_fd_sc_hd__lpflow_isobufsrc_1  3    sky130_fd_sc_hd__maj3_1  9
     sky130_fd_sc_hd__mux2_1       6    sky130_fd_sc_hd__mux2i_1    17
     sky130_fd_sc_hd__nand2_1     24    sky130_fd_sc_hd__nand2b_1    7
     sky130_fd_sc_hd__nand3_1     15    sky130_fd_sc_hd__nor2_1     25
     sky130_fd_sc_hd__nor3_1      33    sky130_fd_sc_hd__nor3b_1    50
     sky130_fd_sc_hd__nor4_1      17    sky130_fd_sc_hd__o211ai_1    1
     sky130_fd_sc_hd__o21a_1       1    sky130_fd_sc_hd__o21ai_0    18
     sky130_fd_sc_hd__o221ai_1    11    sky130_fd_sc_hd__o22a_1      1
     sky130_fd_sc_hd__o22ai_1     10    sky130_fd_sc_hd__o2bb2ai_1   2
     sky130_fd_sc_hd__o311a_1      8    sky130_fd_sc_hd__o32a_1      1
     sky130_fd_sc_hd__or3_1        1    sky130_fd_sc_hd__or3b_1      8
     sky130_fd_sc_hd__xnor2_1     41    sky130_fd_sc_hd__xnor3_1    12
     sky130_fd_sc_hd__xor3_1       5

   Chip area for module '\horus_norm': 5352.633600 µm²
```

Timing: not measured (OpenSTA not available in this environment).

# PATH_FAST Decision Inputs

**Date:** 2026-07-05 (PF18 update: 2026-07-05)  
**Status:** COMPLETE (PF18 update appended)  
**Artifacts:**
`sim/SYNTH_TOP_BASELINE.log` · `sim/SYNTH_TOP_PF.log` ·
`sim/SYNTH_NFE_PF18.log` · `sim/SYNTH_TOP_PF18.log` ·
`sim/pf_width_sweep.py` · `sim/pf_spotcheck.py` ·
`sim/PF_RTL_TRACE.csv`  
**Run:** `cd sim && make pf_derisk` (original) · `make pf18_check pf18_synth` (PF18)

---

## Background

Per `docs/PF_SYNTHESIS_COMPARISON.md`, the PATH_FAST RTL variant
(`rtl/horus_nfe_pf.v`) costs +58.9% area at the NFE core level under
Sky130 HD TT 025C 1v80.  The open questions before the accept/reject decision:
1. What is the cost at system level (horus_top: 16 NFE tiles + controller)?
2. Is 32 bits of accumulator actually needed, or can a narrower width achieve
   the same accuracy?
3. Does the Python model faithfully reproduce the RTL's per-cycle error
   trajectory, and does the RTL result hold under independent replication?

---

## Task 1 — System-Level Area Denominator

**Design level:** `horus_top` (4×4 systolic array of 16 `horus_nfe` + 1
`horus_controller`).  No memories, no black-boxes; synthesizes cleanly.
The PF variant replaces all 16 `horus_nfe` with `horus_nfe_pf` via Yosys
`rename horus_nfe_pf horus_nfe` before hierarchy elaboration; no RTL file
was modified.

**Hierarchy:** `horus_top` → `horus_systolic_array` (16 × `horus_nfe`) +
`horus_controller`

| Metric | Baseline (`horus_nfe` ×16) | PF (`horus_nfe_pf` ×16) | Delta | Delta % |
|--------|---------------------------|-------------------------|-------|---------|
| Total chip area (µm²) | 188 742.268800 | 289 487.641600 | +100 745.37 | **+53.4%** |
| Total cell count | 24 028 | 39 815 | +15 787 | **+65.7%** |
| DFF count (`dfrtp_1`) | 2 028 | 2 540 | +512 | **+25.3%** |
| Critical-path timing | not measured | not measured | — | — |

**NFE core share of baseline system area:**
16 × 10 422.5 µm² (per-NFE) = 166 759.9 µm² out of 188 742.3 µm² = **88.4%**

**NFE cost in PF system:**
16 × 16 717.3 µm² = 267 476.5 µm² out of 289 487.6 µm² = **92.4%**

All system-area increase (100 745 µm²) is attributable to the 16 PF NFE
instances; controller and array-level cells are essentially unchanged
(624 µm² and ~21 354 µm² in both variants).

**Timing remains not measured.** OpenSTA not installed; deferred.

---

## Task 2 — Accumulator Width Sweep

**Script:** `sim/pf_width_sweep.py`  
**Methodology:** Mirrors `rtl/horus_nfe_pf.v` fixed-point accumulation
(lines 533–585) and NOP readout (lines 613–679) at widths W ∈ {16,18,20,24,28,32}.
`PF_K_REF = 28`, `PF_SCALE_EXP = 16` held fixed.  Initial y ∈ [1.0, 2.0)
to match `tb/tb_horus_nfe_pf.v` testbench conditions.
100 neutral-regime chains of depth 256, seed=42.

**Key implementation note:** The RTL computes `exp_sum` with `+1` for
`scale_reg[13]=1` (lines 538–544), then the PF k formula subtracts
`scale_reg[13]` back out, yielding `k = e_a + e_b − EXP_BIAS − PF_K_REF`
independent of the leading-bit position.  This distinction is critical for
correct Python mirroring.

| W (bits) | Mean final error | DFF savings vs 32 (per tile) |
|----------|-----------------|------------------------------|
| 16 | 66.35% | 16 — overflow (max 32 768 < required ~131 072) |
| **18** | **0.35%** | **14 — minimum viable ≤ 0.5%** |
| 20 | 0.35% | 12 |
| 24 | 0.35% | 8 |
| 28 | 0.35% | 4 |
| 32 | 0.35% | 0 (RTL as-built) |

**Minimum viable width: W = 18 bits** (mean final error ≤ 0.5%).

W = 16 overflows because an 8-element row sum of neutral-regime products
with y ∈ [1.0, 2.0) reaches ~131 072 units (scale 2^(−16)), exceeding the
16-bit signed maximum of 32 767.  W = 18 (max = 131 071) is right at the
threshold; errors are ≤ 0.5% because clipping is rare and small.

**DFF savings at W=18 vs W=32:**  14 DFFs per accumulator × 16 tiles =
**224 DFFs** saved across `horus_top`.

The area savings from 14 fewer DFFs per tile is small relative to the
combinational PF overhead (priority encoder + barrel shifter), but the
number is a confirmed lower-bound for the accumulator register cost.

---

## Task 3 — Independent Spot-Check of 0.18%

**Testbench:** `tb/tb_horus_nfe_pf.v` (modified to write `sim/PF_RTL_TRACE.csv`
with per-cycle mean relative error; only logging added — DUT instantiation
and decode/golden math unchanged).  
**Python model:** `sim/pf_spotcheck.py` — replicates the testbench LFSR
(`SEED = 0xCAFEF00D`, r=1) in Python to generate the identical 8×8 matrix A
and initial y vector, then runs the RTL-faithful fixed-point PF chain (same
`pf_accumulate_rtl` and `pf_readout_rtl` functions as Task 2 after the
`exp_sum` correction; W=32).

| Metric | Value |
|--------|-------|
| Final mean rel err — Python RTL-faithful model | **0.1798%** |
| Final mean rel err — RTL PATH_FAST (sim) | **0.1798%** |
| Cycles where RTL and Python diverge by >2× | **0** |
| RTL worse than Python at any cycle | No |
| Suspected testbench/DUT coupling | None detected |
| Spot-check verdict | **PASS** |

The RTL and Python RTL-faithful model agree to 4 decimal places across all
256 cycles.  The 0.18% figure holds under independent replication.

**Note on trajectory agreement:** The Python fast path in `second_source_chain.py`
(floating-point accumulation) gives 0.38% for the same chain type (different
seed).  The RTL variant gives 0.18% on its specific seed/matrix because the
32-bit fixed-point accumulation is more precise than the 6-bit re-quantization
after each product in the baseline PATH_NFE path, not because of an error in
the testbench.

---

## PF18 Update — W=18 Variant (horus_nfe_pf18)

**Date:** 2026-07-05  
**Artifacts:**
`rtl/horus_nfe_pf18.v` · `tb/tb_horus_nfe_pf18.v` ·
`sim/SYNTH_NFE_PF18.log` · `sim/SYNTH_TOP_PF18.log`  
**Run:** `cd sim && make pf18_check pf18_synth`

### Motivation

The +53.4% system-level figure above uses W=32 accumulators.  Task 2 showed
W=18 is the minimum viable width (0.35% error).  The dominant PF cell cost is
combinational — the priority encoder (depth), barrel shifter width, and adder
width all scale with W.  The prior framing assumed "combinational overhead
unchanged" at reduced width; this section supplies the measured truth.

### Functional Check — horus_nfe_pf18 (tb/tb_horus_nfe_pf18.v)

**Neutral regime** (row_sum=1.00, SEED=0xCAFEF00D, r=1, 256 cycles):

| Criterion | Result |
|-----------|--------|
| Final mean rel err | **0.1798%** |
| Threshold (≤ 0.5%) | PASS |
| Within 2× of pf_width_sweep.py at W=18 (≤ 0.70%) | PASS (0.1798% ≤ 0.70%) |
| Divergence onset | NONE (stayed ≤ 1% all 256 cycles) |

**Expansive regime** (row_sum=1.10, SEED=0xCAFEF00D, r=2, 256 cycles):

| Metric | Value |
|--------|-------|
| Final mean rel err | 100.0% (format saturation, expected) |
| Saturation clamp count | **2039 row-accumulations** hit ±clamp boundary |
| Saturation guard verdict | **ENGAGED** — clamping rather than wrapping |

W=18 is not fragile in the neutral regime (0.18% vs 0.35% sweep prediction;
within 2×).  The saturation guard fired 2039 times in the expansive regime,
confirming clamping is active and no wrap artifacts occur.

### Synthesis Results — Full Three-Way Comparison

**Core level (standalone horus_nfe / horus_nfe_pf / horus_nfe_pf18):**

| Variant | Area (µm²) | Cells | DFFs | Δ area vs baseline | Δ cells vs baseline | Δ DFFs vs baseline |
|---------|-----------|-------|------|--------------------|---------------------|---------------------|
| Baseline (W=—) | 10 422.496 | 1 382 | 100 | — | — | — |
| PF-W32 | 16 557.130 | 2 320 | 132 | **+58.9%** | **+67.9%** | **+32.0%** |
| PF-W18 | 15 202.080 | 2 075 | 118 | **+45.9%** | **+50.1%** | **+18.0%** |

**System level (horus_top: 16 NFE tiles + horus_controller):**

| Variant | Area (µm²) | Cells | DFFs | Δ area vs baseline | Δ cells vs baseline | Δ DFFs vs baseline |
|---------|-----------|-------|------|--------------------|---------------------|---------------------|
| Baseline | 188 742.269 | 24 028 | 2 028 | — | — | — |
| PF-W32 | 289 487.642 | 39 815 | 2 540 | **+53.4%** | **+65.7%** | **+25.3%** |
| PF-W18 | 263 442.662 | 34 679 | 2 316 | **+39.6%** | **+44.3%** | **+14.2%** |

Sources: `SYNTH_NFE_BASELINE.log`, `SYNTH_NFE_PF.log`, `SYNTH_NFE_PF18.log`,
`SYNTH_TOP_BASELINE.log`, `SYNTH_TOP_PF.log`, `SYNTH_TOP_PF18.log`.

**Combinational overhead finding:** The assumption in the earlier framing that
"combinational overhead is unchanged at reduced width" was incorrect.  The W=18
adder, alignment shifter, and priority encoder (18 branches vs 31 branches)
are measurably cheaper: PF-W18 core area is 15 202 µm² vs 16 557 µm² for
PF-W32, a 8.2% reduction from PF-W32, despite adding the saturation guard.
The DFF savings alone (14 × 16 = 224 DFFs) would project only ~270 µm²;
the actual combinational saving is ~1 085 µm² additional.

---

## Updated Decision Framing

Timing is not measured (OpenSTA not installed).

| Variant | System-level area | Δ vs baseline | Neutral-regime error (RTL) |
|---------|------------------|---------------|---------------------------|
| Baseline | 188 742 µm² | — | 23.95% (PATH_NFE) |
| PF-W32 | 289 488 µm² | +53.4% | 0.18% |
| PF-W18 | 263 443 µm² | **+39.6%** | 0.18% |

PF at the minimum viable width (W=18) costs approximately **+39.6%
system-level area** for a neutral-regime deep-chain error improvement from
23.95% to 0.18%.  The saturation guard (clamp on overflow) is confirmed
active in the expansive regime.

The accept/reject decision is not made here.

---

## Appendix A — System-Level Baseline Stat Block

Source: `sim/SYNTH_TOP_BASELINE.log` lines 3046–3141 (design hierarchy final
`stat -liberty` output).

```
=== design hierarchy ===

   horus_top                         1
     $paramod\horus_systolic_array\ROWS=4\COLS=4      1
       horus_nfe                    16
     horus_controller                1

   Number of wires:              22555
   Number of wire bits:          40017
   Number of public wires:        1596
   Number of public wire bits:   18155
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:              24028
     sky130_fd_sc_hd__a2111oi_0     32
     sky130_fd_sc_hd__a211o_1       32
     sky130_fd_sc_hd__a211oi_1     166
     sky130_fd_sc_hd__a21boi_0      64
     sky130_fd_sc_hd__a21o_1       258
     sky130_fd_sc_hd__a21oi_1     2549
     sky130_fd_sc_hd__a221o_1       80
     sky130_fd_sc_hd__a221oi_1     192
     sky130_fd_sc_hd__a222oi_1      16
     sky130_fd_sc_hd__a22o_1       128
     sky130_fd_sc_hd__a22oi_1      161
     sky130_fd_sc_hd__a2bb2oi_1      1
     sky130_fd_sc_hd__a311o_1        1
     sky130_fd_sc_hd__a311oi_1      33
     sky130_fd_sc_hd__a31o_1        49
     sky130_fd_sc_hd__a31oi_1      234
     sky130_fd_sc_hd__a32o_1        16
     sky130_fd_sc_hd__and2_0       421
     sky130_fd_sc_hd__and3_1       385
     sky130_fd_sc_hd__and3b_1       32
     sky130_fd_sc_hd__and4_1        16
     sky130_fd_sc_hd__clkinv_1     572
     sky130_fd_sc_hd__dfrtp_1     2028
     sky130_fd_sc_hd__dfstp_2        1
     sky130_fd_sc_hd__lpflow_inputiso1p_1    191
     sky130_fd_sc_hd__lpflow_isobufsrc_1    508
     sky130_fd_sc_hd__maj3_1       862
     sky130_fd_sc_hd__mux2_1        32
     sky130_fd_sc_hd__mux2i_1       48
     sky130_fd_sc_hd__nand2_1     3107
     sky130_fd_sc_hd__nand2b_1     662
     sky130_fd_sc_hd__nand3_1      667
     sky130_fd_sc_hd__nand3b_1      18
     sky130_fd_sc_hd__nand4_1      176
     sky130_fd_sc_hd__nor2_1      1892
     sky130_fd_sc_hd__nor2b_1       65
     sky130_fd_sc_hd__nor3_1       374
     sky130_fd_sc_hd__nor3b_1       66
     sky130_fd_sc_hd__nor4_1        80
     sky130_fd_sc_hd__o2111ai_1    113
     sky130_fd_sc_hd__o211ai_1     192
     sky130_fd_sc_hd__o21a_1        82
     sky130_fd_sc_hd__o21ai_0     2125
     sky130_fd_sc_hd__o21bai_1      66
     sky130_fd_sc_hd__o221a_1       16
     sky130_fd_sc_hd__o221ai_1     192
     sky130_fd_sc_hd__o22a_1        96
     sky130_fd_sc_hd__o22ai_1      561
     sky130_fd_sc_hd__o311ai_0      52
     sky130_fd_sc_hd__o31a_1        16
     sky130_fd_sc_hd__o31ai_1      139
     sky130_fd_sc_hd__o32ai_1       16
     sky130_fd_sc_hd__o41ai_1        1
     sky130_fd_sc_hd__or3_1        112
     sky130_fd_sc_hd__or3b_1        16
     sky130_fd_sc_hd__or4_1         49
     sky130_fd_sc_hd__xnor2_1     2491
     sky130_fd_sc_hd__xnor3_1      172
     sky130_fd_sc_hd__xor2_1      1244
     sky130_fd_sc_hd__xor3_1        62

   Chip area for top module '\horus_top': 188742.268800
```

Logfile hash: `2fc7e7e31d`

---

## Appendix B — System-Level PF Stat Block

Source: `sim/SYNTH_TOP_PF.log` lines 3797–3898 (design hierarchy final
`stat -liberty` output).

```
=== design hierarchy ===

   horus_top                         1
     $paramod\horus_systolic_array\ROWS=4\COLS=4      1
       horus_nfe                    16
     horus_controller                1

   Number of wires:              37350
   Number of wire bits:          55804
   Number of public wires:        1612
   Number of public wire bits:   18667
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:              39815
     sky130_fd_sc_hd__a2111oi_0     48
     sky130_fd_sc_hd__a211o_1       64
     sky130_fd_sc_hd__a211oi_1     503
     sky130_fd_sc_hd__a21boi_0     176
     sky130_fd_sc_hd__a21o_1       418
     sky130_fd_sc_hd__a21oi_1     4500
     sky130_fd_sc_hd__a221o_1      112
     sky130_fd_sc_hd__a221oi_1     336
     sky130_fd_sc_hd__a222oi_1      16
     sky130_fd_sc_hd__a22o_1       160
     sky130_fd_sc_hd__a22oi_1       97
     sky130_fd_sc_hd__a2bb2oi_1     17
     sky130_fd_sc_hd__a311o_1       17
     sky130_fd_sc_hd__a311oi_1     144
     sky130_fd_sc_hd__a31o_1        49
     sky130_fd_sc_hd__a31oi_1      683
     sky130_fd_sc_hd__a32o_1        48
     sky130_fd_sc_hd__a32oi_1       16
     sky130_fd_sc_hd__a41oi_1       80
     sky130_fd_sc_hd__and2_0       613
     sky130_fd_sc_hd__and3_1       561
     sky130_fd_sc_hd__and3b_1       16
     sky130_fd_sc_hd__and4_1       112
     sky130_fd_sc_hd__clkinv_1     651
     sky130_fd_sc_hd__dfrtp_1     2540
     sky130_fd_sc_hd__dfstp_2        1
     sky130_fd_sc_hd__lpflow_inputiso1p_1    400
     sky130_fd_sc_hd__lpflow_isobufsrc_1    815
     sky130_fd_sc_hd__maj3_1       912
     sky130_fd_sc_hd__mux2_1       112
     sky130_fd_sc_hd__mux2i_1      432
     sky130_fd_sc_hd__nand2_1     6239
     sky130_fd_sc_hd__nand2b_1     486
     sky130_fd_sc_hd__nand3_1     1210
     sky130_fd_sc_hd__nand3b_1      50
     sky130_fd_sc_hd__nand4_1      192
     sky130_fd_sc_hd__nand4b_1      32
     sky130_fd_sc_hd__nor2_1      3604
     sky130_fd_sc_hd__nor2b_1      161
     sky130_fd_sc_hd__nor3_1       726
     sky130_fd_sc_hd__nor3b_1       66
     sky130_fd_sc_hd__nor4_1        64
     sky130_fd_sc_hd__o2111a_1      16
     sky130_fd_sc_hd__o2111ai_1    145
     sky130_fd_sc_hd__o211a_1       16
     sky130_fd_sc_hd__o211ai_1     288
     sky130_fd_sc_hd__o21a_1        98
     sky130_fd_sc_hd__o21ai_0     3995
     sky130_fd_sc_hd__o21bai_1      17
     sky130_fd_sc_hd__o221a_1       32
     sky130_fd_sc_hd__o221ai_1     304
     sky130_fd_sc_hd__o22a_1        96
     sky130_fd_sc_hd__o22ai_1      737
     sky130_fd_sc_hd__o2bb2ai_1     16
     sky130_fd_sc_hd__o311ai_0     116
     sky130_fd_sc_hd__o31a_1        48
     sky130_fd_sc_hd__o31ai_1      283
     sky130_fd_sc_hd__o32a_1        48
     sky130_fd_sc_hd__o41ai_1       17
     sky130_fd_sc_hd__or3_1        256
     sky130_fd_sc_hd__or3b_1        16
     sky130_fd_sc_hd__or4_1        113
     sky130_fd_sc_hd__xnor2_1     3427
     sky130_fd_sc_hd__xnor3_1      206
     sky130_fd_sc_hd__xor2_1      1983
     sky130_fd_sc_hd__xor3_1        63

   Chip area for top module '\horus_top': 289487.641600
```

Logfile hash: included in `SYNTH_TOP_PF.log`

---

---

## Appendix C — PF18 Core Stat Block

Source: `sim/SYNTH_NFE_PF18.log` (final `stat -liberty` output, logfile hash `dfe8f9fc2f`).

```
=== horus_nfe_pf18 ===

   Number of wires:               1977
   Number of wire bits:           3000
   Number of public wires:          93
   Number of public wire bits:    1043
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:               2075
     sky130_fd_sc_hd__a2111oi_0      2
     sky130_fd_sc_hd__a211o_1        1
     sky130_fd_sc_hd__a211oi_1      13
     sky130_fd_sc_hd__a21bo_1        1
     sky130_fd_sc_hd__a21boi_0       7
     sky130_fd_sc_hd__a21o_1        19
     sky130_fd_sc_hd__a21oi_1      258
     sky130_fd_sc_hd__a221o_1        3
     sky130_fd_sc_hd__a221oi_1      20
     sky130_fd_sc_hd__a222oi_1       4
     sky130_fd_sc_hd__a22o_1        13
     sky130_fd_sc_hd__a22oi_1       12
     sky130_fd_sc_hd__a2bb2oi_1      2
     sky130_fd_sc_hd__a311oi_1       5
     sky130_fd_sc_hd__a31o_1         1
     sky130_fd_sc_hd__a31oi_1       27
     sky130_fd_sc_hd__a32o_1         1
     sky130_fd_sc_hd__a41o_1         1
     sky130_fd_sc_hd__a41oi_1        5
     sky130_fd_sc_hd__and2_0        37
     sky130_fd_sc_hd__and3_1        17
     sky130_fd_sc_hd__and4_1         6
     sky130_fd_sc_hd__clkinv_1      40
     sky130_fd_sc_hd__dfrtp_1      118
     sky130_fd_sc_hd__lpflow_inputiso1p_1     13
     sky130_fd_sc_hd__lpflow_isobufsrc_1     34
     sky130_fd_sc_hd__maj3_1        60
     sky130_fd_sc_hd__mux2_1        19
     sky130_fd_sc_hd__mux2i_1       52
     sky130_fd_sc_hd__nand2_1      259
     sky130_fd_sc_hd__nand2b_1      46
     sky130_fd_sc_hd__nand3_1       49
     sky130_fd_sc_hd__nand3b_1       2
     sky130_fd_sc_hd__nand4_1       16
     sky130_fd_sc_hd__nand4bb_1      1
     sky130_fd_sc_hd__nor2_1       196
     sky130_fd_sc_hd__nor2b_1        9
     sky130_fd_sc_hd__nor3_1        30
     sky130_fd_sc_hd__nor3b_1       12
     sky130_fd_sc_hd__nor4_1         7
     sky130_fd_sc_hd__o2111a_1       1
     sky130_fd_sc_hd__o2111ai_1      1
     sky130_fd_sc_hd__o211ai_1      21
     sky130_fd_sc_hd__o21a_1        25
     sky130_fd_sc_hd__o21ai_0      204
     sky130_fd_sc_hd__o221a_1        1
     sky130_fd_sc_hd__o221ai_1      12
     sky130_fd_sc_hd__o22a_1         5
     sky130_fd_sc_hd__o22ai_1       45
     sky130_fd_sc_hd__o2bb2ai_1      1
     sky130_fd_sc_hd__o311ai_0       4
     sky130_fd_sc_hd__o31a_1         1
     sky130_fd_sc_hd__o31ai_1       13
     sky130_fd_sc_hd__o32ai_1        2
     sky130_fd_sc_hd__or3_1         12
     sky130_fd_sc_hd__or4_1          4
     sky130_fd_sc_hd__xnor2_1      192
     sky130_fd_sc_hd__xnor3_1       10
     sky130_fd_sc_hd__xor2_1        97
     sky130_fd_sc_hd__xor3_1         6

   Chip area for module '\horus_nfe_pf18': 15202.080000
```

---

## Appendix D — PF18 System-Level Stat Block

Source: `sim/SYNTH_TOP_PF18.log` (final `stat -liberty` output, logfile hash `2f64a2a31d`).

```
=== design hierarchy ===

   horus_top                         1
     $paramod\horus_systolic_array\ROWS=4\COLS=4      1
       horus_nfe                    16
     horus_controller                1

   Number of wires:              32662
   Number of wire bits:          50668
   Number of public wires:        1612
   Number of public wire bits:   18443
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:              34679
     sky130_fd_sc_hd__a2111o_1      16
     sky130_fd_sc_hd__a2111oi_0     48
     sky130_fd_sc_hd__a211o_1       64
     sky130_fd_sc_hd__a211oi_1     183
     sky130_fd_sc_hd__a21boi_0      80
     sky130_fd_sc_hd__a21o_1       610
     sky130_fd_sc_hd__a21oi_1     3812
     sky130_fd_sc_hd__a221o_1      112
     sky130_fd_sc_hd__a221oi_1     272
     sky130_fd_sc_hd__a22o_1       160
     sky130_fd_sc_hd__a22oi_1      129
     sky130_fd_sc_hd__a2bb2o_1      16
     sky130_fd_sc_hd__a2bb2oi_1      1
     sky130_fd_sc_hd__a311o_1        1
     sky130_fd_sc_hd__a311oi_1      80
     sky130_fd_sc_hd__a31o_1         1
     sky130_fd_sc_hd__a31oi_1      427
     sky130_fd_sc_hd__a32o_1        16
     sky130_fd_sc_hd__a32oi_1       16
     sky130_fd_sc_hd__a41o_1        16
     sky130_fd_sc_hd__a41oi_1       32
     sky130_fd_sc_hd__and2_0       533
     sky130_fd_sc_hd__and3_1       369
     sky130_fd_sc_hd__and4_1        16
     sky130_fd_sc_hd__clkinv_1     603
     sky130_fd_sc_hd__dfrtp_1     2316
     sky130_fd_sc_hd__dfstp_2        1
     sky130_fd_sc_hd__lpflow_inputiso1p_1    304
     sky130_fd_sc_hd__lpflow_isobufsrc_1    831
     sky130_fd_sc_hd__maj3_1      1072
     sky130_fd_sc_hd__mux2_1       384
     sky130_fd_sc_hd__mux2i_1      608
     sky130_fd_sc_hd__nand2_1     4095
     sky130_fd_sc_hd__nand2b_1     662
     sky130_fd_sc_hd__nand3_1      906
     sky130_fd_sc_hd__nand3b_1      98
     sky130_fd_sc_hd__nand4_1      192
     sky130_fd_sc_hd__nor2_1      3268
     sky130_fd_sc_hd__nor2b_1      257
     sky130_fd_sc_hd__nor3_1       534
     sky130_fd_sc_hd__nor3b_1      162
     sky130_fd_sc_hd__nor4_1       176
     sky130_fd_sc_hd__o2111ai_1    129
     sky130_fd_sc_hd__o211a_1       16
     sky130_fd_sc_hd__o211ai_1     320
     sky130_fd_sc_hd__o21a_1       306
     sky130_fd_sc_hd__o21ai_0     3179
     sky130_fd_sc_hd__o21ba_1       32
     sky130_fd_sc_hd__o21bai_1      65
     sky130_fd_sc_hd__o221ai_1     240
     sky130_fd_sc_hd__o22a_1        96
     sky130_fd_sc_hd__o22ai_1      753
     sky130_fd_sc_hd__o2bb2ai_1     16
     sky130_fd_sc_hd__o311ai_0     116
     sky130_fd_sc_hd__o31a_1        16
     sky130_fd_sc_hd__o31ai_1      251
     sky130_fd_sc_hd__o32a_1        16
     sky130_fd_sc_hd__o32ai_1       80
     sky130_fd_sc_hd__o41ai_1        1
     sky130_fd_sc_hd__or3_1        240
     sky130_fd_sc_hd__or4_1        129
     sky130_fd_sc_hd__xnor2_1     3107
     sky130_fd_sc_hd__xnor3_1      238
     sky130_fd_sc_hd__xor2_1      1743
     sky130_fd_sc_hd__xor3_1       111

   Chip area for top module '\horus_top': 263442.662400
```

---

*Horus (Native Fractional Engine project) · PATH_FAST Decision Inputs ·
Tasks 1–3 complete + PF18 update · Sky130 HD TT 025C 1v80 · Yosys 0.9 · Timing not measured*

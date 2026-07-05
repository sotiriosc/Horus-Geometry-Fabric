# PATH_FAST Gate-Cost vs PATH_NFE: Sky130 HD Synthesis Comparison

> **Superseded by ADR-001.** PF-W18 (`rtl/horus_nfe_pf18.v`) achieves equal
> accuracy (0.18% neutral-regime error) at lower cost (+45.9% core / +39.6%
> system) vs the W=32 numbers below (+58.9% / +53.4%).  See
> `docs/ADR_001_PF18_ADOPTION.md` and `docs/PF_DECISION_INPUTS.md` (PF18
> Update section).  This document is retained as a reference artifact.

**Date:** 2026-07-05  
**Status:** COMPLETE  
**Artifacts:** `rtl/horus_nfe_pf.v` · `tb/tb_horus_nfe_pf.v` ·
`sim/synth_nfe_baseline.ys` · `sim/synth_nfe_pf.ys` ·
`sim/SYNTH_NFE_BASELINE.log` · `sim/SYNTH_NFE_PF.log`  
**Run:** `cd sim && make pf_comparison`

---

## Background

Per `docs/SSC_RTL_VALIDATION.md`, the RTL (`rtl/horus_nfe.v`) has no PATH_FAST mode:
the MUL operation always quantizes the multiplier fraction to 6 bits
(`scale_reg[12:7]` / `scale_reg[11:6]`, lines 530–532).
Simulation of the neutral-regime 256-cycle feedback chain shows:

- PATH_NFE (current RTL): 23.95% final mean relative error vs FP64 golden
  (onset cycle 2; see `sim/SSC_CHAIN_TRACE.csv`).
- PATH_FAST (Python model prediction): ~0.38% final error.

The present document measures the gate cost of adding a PATH_FAST mode to
the RTL.

---

## Toolchain

| Tool | Version | Notes |
|------|---------|-------|
| Yosys | 0.9 (git sha1 1979e0b) | Both flows |
| Target library | sky130_fd_sc_hd TT 025C 1v80 | volare installation |
| Liberty path | `$VOLARE/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib` | Full path in appendix |
| OpenSTA | Not installed | Timing: not measured |

Synthesis command (both flows):
```
read_verilog <rtl_file>
synth -top <module>
dfflibmap -liberty <lib>
abc -liberty <lib>
clean
stat -liberty <lib>
```

---

## PATH_FAST Variant Design (`rtl/horus_nfe_pf.v`)

`horus_nfe_pf.v` is a copy of `horus_nfe.v` with the PATH_FAST mode added
under `mode_tag[2] = 1` (the reserved `3'b1xx` range).  `horus_nfe.v` is
byte-identical to its original (md5: `fa1cff365dda8afd42001da66a220e69`).

**Added hardware (all tagged `// PF:`):**

| Addition | Description | Lines in PF file |
|----------|-------------|-----------------|
| `localparam PF_SCALE_EXP = 16` | Fixed-point scale: pf\_accum × 2^(−16) = real value | ~160 |
| `localparam PF_K_REF = 28` | Reference exp\_sum for zero alignment shift | ~161 |
| `reg signed [31:0] pf_accum` | 32-bit fixed-point row accumulate | ~270 |
| MUL PF path | Aligns full 14-bit `scale_reg[13:0]` to fixed-point and adds to pf\_accum; shift k = exp\_sum − scale\_reg[13] − 28, clamped to [−8,+8] | ~572–585 |
| NOP readout | Priority-encoder + barrel-shift NFE encoder (30-level cascade); round-to-nearest; writes to `result`; clears pf\_accum | ~613–671 |

The original MUL `result` output (6-bit-quantized PATH_NFE product) is unchanged.
The PF accumulate path is **additional**, not a replacement.

**Original lines bypassed** (not removed; pf\_accum accumulates the full
product in parallel):  
`horus_nfe.v` lines 530–532 — `scale_reg[12:7]` / `scale_reg[11:6]` truncation.  
`horus_nfe.v` line 502 — `scale_reg` (the full 14-bit product) is now read
by the PF path on every PF-mode MUL.

---

## Functional Check

**Testbench:** `tb/tb_horus_nfe_pf.v`  
**Protocol:** neutral-regime 256-cycle feedback chain, identical matrix A and
initial vector to `tb/tb_second_source_chain.v` (SEED = `32'hCAFE_F00D`, r=1,
target row sum = 1.00).  Per row: 8 MULs with `mode_tag=3'b100`, then 1 NOP
with `mode_tag=3'b100` to trigger the PF readout.

| Metric | Value |
|--------|-------|
| Final mean relative error (256 cycles) | **0.1798%** |
| Divergence onset (>1% threshold) | **NONE** (stayed ≤1% for all 256 cycles) |
| Python model prediction | ~0.38% |
| Pass criterion (≤1%) | **PASS** |

The RTL PF variant achieves 0.18% — better than the Python model's 0.38%
because the hardware accumulates in 32-bit fixed-point (more precision than
the Python model's 6-bit per-product) and uses round-to-nearest at readout.

---

## Synthesis Results

| Metric | Baseline (`horus_nfe`) | PF (`horus_nfe_pf`) | Delta | Delta % |
|--------|------------------------|----------------------|-------|---------|
| Total cell area (µm²) | 10422.496 | 16557.130 | +6134.634 | **+58.9%** |
| Cell count (Sky130) | 1382 | 2320 | +938 | **+67.9%** |
| DFF count (`dfrtp_1`) | 100 | 132 | +32 | **+32.0%** |
| Critical-path timing | not measured | not measured | — | — |

**DFF breakdown:** The +32 DFFs correspond directly to the new `pf_accum`
register (32-bit signed).  The remaining 100 DFFs are unchanged from the
baseline.

**Combinational overhead:** The +938 combinational cells are dominated by:

1. **Product alignment shifter** — 8-level mux tree for k ∈ [−8,+8] applied
   to the 14-bit `scale_reg[13:0]` on every PF MUL.
2. **30-level priority encoder** — finds MSB of the 31-bit `|pf_accum|` on
   every PF NOP readout.
3. **Variable right-shift barrel shifter** — extracts 6 mantissa bits from
   `pf_abs` at the priority-encoder-selected position on every PF NOP.
4. **32-bit signed adder** — adds the aligned pf\_term to pf\_accum on every
   PF MUL.

The priority encoder and barrel shifter are the largest contributors; they
are structurally absent from the baseline PATH_NFE MUL path.

**Conclusion:**

PATH_FAST costs **+58.9% additional chip area** (10422 → 16557 µm² against
sky130_fd_sc_hd TT 025C 1v80) for a neutral-regime deep-chain error
improvement from 23.95% to 0.18% (RTL measured) / ~0.38% (Python model).

Timing is not measured (OpenSTA not installed); critical-path estimate deferred
to a follow-up with full STA.  The accept/reject decision on whether this area
cost is justified is not made here.

---

## Appendix A — Baseline Synthesis Stat Block

Source: `sim/SYNTH_NFE_BASELINE.log` (Yosys `stat -liberty` final output,
lines 1768–1837).

```
=== horus_nfe ===

   Number of wires:               1318
   Number of wire bits:           2307
   Number of public wires:          92
   Number of public wire bits:    1025
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:               1382
     sky130_fd_sc_hd__a2111oi_0      2
     sky130_fd_sc_hd__a211o_1        2
     sky130_fd_sc_hd__a211oi_1      10
     sky130_fd_sc_hd__a21boi_0       4
     sky130_fd_sc_hd__a21o_1        15
     sky130_fd_sc_hd__a21oi_1      155
     sky130_fd_sc_hd__a221o_1        5
     sky130_fd_sc_hd__a221oi_1      12
     sky130_fd_sc_hd__a222oi_1       1
     sky130_fd_sc_hd__a22o_1         8
     sky130_fd_sc_hd__a22oi_1       10
     sky130_fd_sc_hd__a311oi_1       1
     sky130_fd_sc_hd__a31o_1         3
     sky130_fd_sc_hd__a31oi_1       14
     sky130_fd_sc_hd__a32o_1         1
     sky130_fd_sc_hd__and2_0        26
     sky130_fd_sc_hd__and3_1        21
     sky130_fd_sc_hd__and3b_1        2
     sky130_fd_sc_hd__and4_1         1
     sky130_fd_sc_hd__clkinv_1      33
     sky130_fd_sc_hd__dfrtp_1      100
     sky130_fd_sc_hd__lpflow_inputiso1p_1     11
     sky130_fd_sc_hd__lpflow_isobufsrc_1     31
     sky130_fd_sc_hd__maj3_1        42
     sky130_fd_sc_hd__mux2_1         2
     sky130_fd_sc_hd__mux2i_1        3
     sky130_fd_sc_hd__nand2_1      182
     sky130_fd_sc_hd__nand2b_1      40
     sky130_fd_sc_hd__nand3_1       40
     sky130_fd_sc_hd__nand3b_1       1
     sky130_fd_sc_hd__nand4_1       11
     sky130_fd_sc_hd__nor2_1       113
     sky130_fd_sc_hd__nor2b_1        4
     sky130_fd_sc_hd__nor3_1        23
     sky130_fd_sc_hd__nor3b_1        4
     sky130_fd_sc_hd__nor4_1         5
     sky130_fd_sc_hd__o2111ai_1      7
     sky130_fd_sc_hd__o211ai_1      12
     sky130_fd_sc_hd__o21a_1         5
     sky130_fd_sc_hd__o21ai_0      132
     sky130_fd_sc_hd__o21bai_1       4
     sky130_fd_sc_hd__o221a_1        1
     sky130_fd_sc_hd__o221ai_1      12
     sky130_fd_sc_hd__o22a_1         6
     sky130_fd_sc_hd__o22ai_1       35
     sky130_fd_sc_hd__o311ai_0       2
     sky130_fd_sc_hd__o31a_1         1
     sky130_fd_sc_hd__o31ai_1        8
     sky130_fd_sc_hd__o32ai_1        1
     sky130_fd_sc_hd__or3_1          7
     sky130_fd_sc_hd__or3b_1         1
     sky130_fd_sc_hd__or4_1          3
     sky130_fd_sc_hd__xnor2_1      126
     sky130_fd_sc_hd__xnor3_1       10
     sky130_fd_sc_hd__xor2_1        68
     sky130_fd_sc_hd__xor3_1         3

   Chip area for module '\horus_nfe': 10422.496000
```

Logfile hash: `49fedd2bdf`

---

## Appendix B — PF Variant Synthesis Stat Block

Source: `sim/SYNTH_NFE_PF.log` (Yosys `stat -liberty` final output,
lines 2514–2585).

```
=== horus_nfe_pf ===

   Number of wires:               2065
   Number of wire bits:           3054
   Number of public wires:          92
   Number of public wire bits:    1025
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:               2320
     sky130_fd_sc_hd__a2111o_1       3
     sky130_fd_sc_hd__a2111oi_0      2
     sky130_fd_sc_hd__a211o_1        5
     sky130_fd_sc_hd__a211oi_1      37
     sky130_fd_sc_hd__a21boi_0       5
     sky130_fd_sc_hd__a21o_1        18
     sky130_fd_sc_hd__a21oi_1      263
     sky130_fd_sc_hd__a221o_1        6
     sky130_fd_sc_hd__a221oi_1      21
     sky130_fd_sc_hd__a222oi_1       4
     sky130_fd_sc_hd__a22o_1        16
     sky130_fd_sc_hd__a22oi_1       11
     sky130_fd_sc_hd__a311o_1        4
     sky130_fd_sc_hd__a311oi_1       6
     sky130_fd_sc_hd__a31o_1         5
     sky130_fd_sc_hd__a31oi_1       37
     sky130_fd_sc_hd__a32o_1         6
     sky130_fd_sc_hd__a32oi_1        2
     sky130_fd_sc_hd__a41oi_1        2
     sky130_fd_sc_hd__and2_0        42
     sky130_fd_sc_hd__and3_1        20
     sky130_fd_sc_hd__and3b_1        1
     sky130_fd_sc_hd__and4_1         4
     sky130_fd_sc_hd__clkinv_1      47
     sky130_fd_sc_hd__dfrtp_1      132
     sky130_fd_sc_hd__lpflow_inputiso1p_1     15
     sky130_fd_sc_hd__lpflow_isobufsrc_1     58
     sky130_fd_sc_hd__maj3_1        51
     sky130_fd_sc_hd__mux2_1         2
     sky130_fd_sc_hd__mux2i_1       23
     sky130_fd_sc_hd__mux4_2         1
     sky130_fd_sc_hd__nand2_1      316
     sky130_fd_sc_hd__nand2b_1      23
     sky130_fd_sc_hd__nand3_1       77
     sky130_fd_sc_hd__nand3b_1       5
     sky130_fd_sc_hd__nand4_1       18
     sky130_fd_sc_hd__nand4b_1       1
     sky130_fd_sc_hd__nor2_1       229
     sky130_fd_sc_hd__nor2b_1       14
     sky130_fd_sc_hd__nor3_1        39
     sky130_fd_sc_hd__nor3b_1        2
     sky130_fd_sc_hd__nor4_1         9
     sky130_fd_sc_hd__nor4b_1        1
     sky130_fd_sc_hd__o2111a_1       1
     sky130_fd_sc_hd__o2111ai_1      4
     sky130_fd_sc_hd__o211a_1        1
     sky130_fd_sc_hd__o211ai_1      22
     sky130_fd_sc_hd__o21a_1        10
     sky130_fd_sc_hd__o21ai_0      241
     sky130_fd_sc_hd__o21bai_1       5
     sky130_fd_sc_hd__o221a_1        1
     sky130_fd_sc_hd__o221ai_1      21
     sky130_fd_sc_hd__o22a_1         2
     sky130_fd_sc_hd__o22ai_1       47
     sky130_fd_sc_hd__o2bb2ai_1      1
     sky130_fd_sc_hd__o311ai_0       2
     sky130_fd_sc_hd__o31a_1         5
     sky130_fd_sc_hd__o31ai_1       27
     sky130_fd_sc_hd__o32a_1         2
     sky130_fd_sc_hd__or3_1         18
     sky130_fd_sc_hd__or3b_1         1
     sky130_fd_sc_hd__or4_1          9
     sky130_fd_sc_hd__xnor2_1      189
     sky130_fd_sc_hd__xnor3_1        8
     sky130_fd_sc_hd__xor2_1       116
     sky130_fd_sc_hd__xor3_1         4

   Chip area for module '\horus_nfe_pf': 16557.129600
```

Logfile hash: `2a0c2eb851`

---

## Appendix C — Liberty File

```
/home/sotiriosc/.volare/volare/sky130/versions/
  c6d73a35f524070e85faff4a6a9eef49553ebc2b/
  sky130A/libs.ref/sky130_fd_sc_hd/lib/
  sky130_fd_sc_hd__tt_025C_1v80.lib
```

Library: sky130_fd_sc_hd, 334 cells (94 skipped: 63 seq, 13 tri-state,
18 no func, 0 dont_use).

---

*Horus (Native Fractional Engine project) · PATH_FAST Gate-Cost Study ·
Sky130 HD TT 025C 1v80 · Yosys 0.9 · Timing not measured*

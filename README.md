# Horus-Geometry-Fabric

An open-hardware 13-bit floating-point format (NFE v3) with a verified RTL datapath,
an on-chip block-exponent normalizer, and two end-to-end inference applications — all
run through actual Verilog simulation on Sky130 standard cells.

**Full campaign story:** [docs/CAMPAIGN_OVERVIEW.md](docs/CAMPAIGN_OVERVIEW.md)

---

## What NFE Is

NFE v3 is a 13-bit float: 1 sign bit, 6-bit stored exponent (bias 32), 6-bit mantissa
fraction.  A value encodes as `(−1)^s × (1 + f/64) × 2^(E−32)`; representable range
≈ [2.4×10⁻⁹, 4.3×10⁹].  Sixteen `horus_nfe` cores tile into `horus_top` (188,742 µm²
baseline, Sky130 HD TT 025C 1v80), operating on 8×8 NFE matrix–vector blocks.

---

## Headline Results

| Claim | Measured | Evidence |
|---|---|---|
| NFE weight quantization | Lossless — pipeline (b) = 96.67%, identical to FP64 | `docs/MLP_INFERENCE_DEMO.md` |
| RTL digit inference accuracy | **96.39% (347/360)** vs 96.67% FP64 ceiling | `docs/MLP_INFERENCE_DEMO.md` |
| RTL vs Python model agreement | **360/360 predictions exact** | `sim/analyze_mlp.py` |
| Hopfield recall (120 trials) | **120/120 (100%)**, 0 divergent iterations | `docs/HOPFIELD_DEMO.md` |
| On-chip normalizer area | **+2.84% system area** (5,352.6 µm², 565 cells) | `docs/EXPNORM_RESULTS.md` |
| Normalizer vs accumulator-widening | **14× cheaper** (+2.84% vs +39.6%) | `docs/ADR_002_NORMALIZATION_ARCHITECTURE.md` |
| Feedback-chain error without normalization | 23.95% at depth 256 | `docs/SSC_RTL_VALIDATION.md` |
| Baseline + k=8 normalization, PI workload | 1.0000 alignment (PF-W18 fails at 0.9892) | `docs/NORM_VS_PF18.md` |
| Format war: inference | E4M3 wins — identical 96.39% at 0.53× NFE-13 multiplier area | `docs/FORMAT_COMPARISON.md`, `docs/AREA_COMPARISON.md` |
| Gradient-accumulation niche | NFE-13 = BF16-class sign fidelity at 0.59× BF16 area; compact form E3M6+block at 10.75 eff bits | `docs/GRADIENT_NICHE_FINAL.md`, `docs/COMPACT_NFE_VERDICT.md` |
| Dual-mode fused core | **Falsified** — 1.97× the standalone E3M6 core; fallback mandated | `docs/DUAL_CORE_RESULTS.md` |
| Integrated tile v1 (buffer + norm inside) | **K1 falsified** — 45.1% glue; the 8×13 serial buffer alone exceeds the budget | `docs/TILE_RESULTS.md` |
| Integrated tile v2 (respecified) | **K1 PASS** — 3,188.058 µm², glue 7.2% (budget 20%), 2,005/2,005 tests | `docs/TILE_V2_RESULTS.md` |
| Block-FP paradigm question (E0 endpoint) | E0M6 dies to instrumented intra-block flush; E0M9 matches E3M6 at 2.29× multiplier cost — per-element exponent is load-bearing | `docs/BLOCKFP_VERDICT.md` |

---

## 60-Second Quickstart

**Requirements:** Icarus Verilog ≥ 11, Python 3.8+, Yosys ≥ 0.9, Sky130 HD liberty file

```bash
git clone https://github.com/sotiriosc/Horus-Geometry-Fabric.git
cd Horus-Geometry-Fabric

# Python deps (MLP training, format sweeps, blockfp arenas)
python3 -m pip install -r requirements.txt

# Sky130 HD liberty for synthesis steps (tile_v2, blockfp).
# Auto-detected from PDK_ROOT, volare (~/.volare), or common open_pdks paths.
# Override manually if needed:
# export SKY130_HD_LIB=/path/to/sky130_fd_sc_hd__tt_025C_1v80.lib
# Or install via: pip install volare && volare enable sky130

cd sim
make check-deps    # verify iverilog, python, yosys, liberty
make quickstart    # runs all six campaigns below (~2 min)
```

Individual targets (same as `make quickstart`):

```bash
cd sim

# MLP digit inference — train, quantize, Python gate check, RTL testbench, cross-check
make mlp_all
# Expect: 4-way accuracy table, 3 ASCII digit outputs, "PREDICTIONS EXACT 360/360"

# Hopfield associative recall — H/T/X letter patterns, 120 corruption trials
make hopfield_all
# Expect: 120/120 recall, ASCII recall sequence, "0 divergent iterations"

# SSC feedback-chain validation — the gap that started everything
make ssc_chain
# Expect: P1 NOT CONFIRMED (PATH_FAST absent), P2/P3 CONFIRMED

# Normalization sweep — the measurement that reversed ADR-001
make norm_vs_pf18
# Expect: 3 RTL CONFIRMED cells, baseline beats PF-W18 on PI workload

# Integrated heterogeneous tile v2 (E4M3 + E3M6 cores + shims)
make tile_v2
# Expect: 2005/2005 tests, K1 PASS at 7.2% glue

# Block floating point — the paradigm question
make blockfp
# Expect: E0M6 K1 FAIL (intra-block flush), E0M9 K1 PASS at 2.29× multiplier cost
```

---

## Repo Map

```
rtl/
  horus_nfe.v           — core MAC datapath (PATH_NFE, 6-bit product, no modification)
  horus_norm.v          — 8-element block-exponent normalizer (v1)
  horus_norm_v2.v       — normalizer v2: e_max_out + external-offset mode
  horus_nfe_pf18.v      — PF-W18 accumulator variant (superseded, retained as evidence)
  fp8_e4m3_mul.v        — FP8-E4M3FN multiplier (inference winner)
  horus_e3m6_core.v     — E3M6 compact multiplier (gradient niche carrier)
  horus_dual_core.v     — fused dual-mode core (falsified, retained as evidence)
  horus_tile.v          — integrated tile v1 (K1 falsified, retained as evidence)
  horus_tile_v2.v       — respecified tile: cores + shims + mode (K1 PASS)
  blockfp_mul7.v/10.v   — E0M6/E0M9 mantissa multipliers (K3 iso-silicon probes)

tb/
  tb_horus_norm.v       — normalizer v1 unit tests + integration
  tb_horus_norm_v2.v    — normalizer v2 regression + composition tests
  tb_hopfield_recall.v  — Hopfield RTL testbench
  tb_mlp_inference.v    — MLP digit inference RTL testbench
  tb_second_source_chain.v — SSC feedback-chain validation
  tb_horus_e3m6_core.v  — E3M6 core golden + directed tests
  tb_horus_dual_core.v  — dual-core golden + mode-switch tests
  tb_horus_tile.v       — tile v1: golden sets, mode switch, smoke tests
  tb_horus_tile_v2.v    — tile v2: golden sets through v2 ports, mode switch

sim/
  Makefile              — all build targets
  mlp_train.py          — MLP training + NFE weight export
  mlp_infer_nfe.py      — Python inference: 4 pipelines, gate check
  analyze_mlp.py        — RTL vs Python cross-check
  hopfield_demo.py      — Hopfield Python model
  expnorm_sweep.py      — normalization sweep + golden generators
  format_zoo.py         — five-format codec zoo (single source of truth per format)
  gradient_range_v2.py  — gradient-accumulation sweep with error bars
  compact_nfe.py        — EnM6 compact family (E2–E6 + shared block exponent)
  dual_core_model.py    — bit-exact dual-mode multiply model
  tile_model.py         — bit-exact tile model (shims + shared normalizer)
  blockfp_test.py       — E0 block-FP arenas (paradigm question)
  HBS_CORE_MASTER_INDEX.log — one-line-per-finding campaign log

docs/
  CAMPAIGN_OVERVIEW.md  — the full arc, in order, with every claim cited
  ADR_001_PF18_ADOPTION.md  — PF-W18 adopted (superseded same day)
  ADR_002_NORMALIZATION_ARCHITECTURE.md — current architecture decision
  SSC_RTL_VALIDATION.md — feedback-chain RTL validation (PATH_FAST gap)
  NORM_VS_PF18.md       — normalization sweep that reversed ADR-001
  EXPNORM_RESULTS.md    — on-chip normalizer build, verification, synthesis
  HOPFIELD_DEMO.md      — Hopfield recall results
  MLP_INFERENCE_DEMO.md — MLP inference results (negative result → fix → RTL)
  FORMAT_COMPARISON.md  — format war: 5 formats, 3 arenas
  GRADIENT_NICHE_FINAL.md — the gradient-accumulation niche verdict
  COMPACT_NFE_VERDICT.md — compact family: exponent bits vs niche boundary
  DUAL_CORE_RESULTS.md  — fusion falsified at 1.97× (fallback mandated)
  TILE_RESULTS.md       — tile v1: K1 falsified at 45.1% glue, diagnosed
  TILE_V2_RESULTS.md    — tile v2: K1 PASS at 7.2% glue
  BLOCKFP_VERDICT.md    — block-FP paradigm question, answered
  FPGA_GUIDE.md         — Vivado/Yosys deployment guide
```

---

## License and Notice

**License:** [CERN-OHL-S-2.0](LICENSE) — strongly-reciprocal open hardware.
Anyone may use, study, modify, and build on this work, but any derivative work
must remain open under the same terms.  This project is released as a contribution,
not a commercial product.  It is intended to stay in the commons permanently.

This repository, including all RTL, simulation scripts, and results, constitutes
a public disclosure record as of 2026-07-05.

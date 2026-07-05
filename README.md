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

---

## 60-Second Quickstart

**Requirements:** Icarus Verilog ≥ 11, Python 3.8+, scikit-learn

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
```

---

## Repo Map

```
rtl/
  horus_nfe.v           — core MAC datapath (PATH_NFE, 6-bit product, no modification)
  horus_norm.v          — 8-element block-exponent normalizer (v1)
  horus_norm_v2.v       — normalizer v2: e_max_out + external-offset mode
  horus_nfe_pf18.v      — PF-W18 accumulator variant (superseded, retained as evidence)

tb/
  tb_horus_norm.v       — normalizer v1 unit tests + integration
  tb_horus_norm_v2.v    — normalizer v2 regression + composition tests
  tb_hopfield_recall.v  — Hopfield RTL testbench
  tb_mlp_inference.v    — MLP digit inference RTL testbench
  tb_second_source_chain.v — SSC feedback-chain validation

sim/
  Makefile              — all build targets
  mlp_train.py          — MLP training + NFE weight export
  mlp_infer_nfe.py      — Python inference: 4 pipelines, gate check
  analyze_mlp.py        — RTL vs Python cross-check
  hopfield_demo.py      — Hopfield Python model
  expnorm_sweep.py      — normalization sweep + golden generators
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

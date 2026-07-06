# Horus-Geometry-Fabric

## AI Acknowledgment

This project was developed in collaboration with AI (Claude, via Cursor),
used for RTL compilation and verification, test development, adversarial
review, and documentation. All architectural decisions, format design,
and final verification judgments are the author's.

The honest framing: AI acted as a compression of time. Work that would
have taken one independent researcher years — building, breaking, and
re-verifying a custom floating-point architecture through to physical
synthesis — happened in months. That compression is changing who gets
to do hardware research at all: verified, fabricatable silicon design is
no longer gated behind institutional teams and tool budgets. This repo
is one data point of what a single person can now build and prove.

Every claim in this repository is backed by artifacts — testbenches,
synthesis reports, demo results — that stand independent of how they
were produced. Verify accordingly.

I designed a custom 13-bit floating-point format (NFE-13), verified it to gate level
on Sky130 standard cells, and then spent the rest of the campaign trying to kill it —
against FP8, BF16, INT8, my own normalizer, and finally against floating point itself.

Most of it died. What survived is documented here, with the full falsification trail.

The two-sentence verdict: For single-pass inference, FP8-E4M3 with block-exponent
normalization is the correct choice — it matches NFE-13's accuracy at roughly half the
multiplier area. For heavy-tailed gradient accumulation, the 6-bit mantissa is
load-bearing: E3M6 + shared block exponent delivers BF16-class sign-error rates at
0.59× BF16 multiplier area, and the industry FP32-accumulator pattern cannot close the
gap because per-gradient encoding loss precedes accumulation.

**15-minute version:** [MINIMAL.md](MINIMAL.md)  
Full story, in order, every claim cited: [docs/CAMPAIGN_OVERVIEW.md](docs/CAMPAIGN_OVERVIEW.md)

Positioning note: shared block exponents over small-float elements correspond to
classical block floating point and the OCP Microscaling (MX) approach. This project's
contribution is not that concept — it is an open, gate-verified implementation with a
documented falsification trail, plus one measured boundary the MX spec doesn't cover:
where on the per-element-exponent axis a gradient-accumulation niche lives and dies.

## What was verified

| Result | Measured | Evidence |
|--------|----------|----------|
| RTL digit inference (360 images, real Verilog) | 96.39% vs 96.67% FP64 ceiling; 360/360 predictions match the Python model exactly | `docs/MLP_INFERENCE_DEMO.md` |
| NFE weight quantization | Lossless (96.67%, identical to FP64) | `docs/MLP_INFERENCE_DEMO.md` |
| Hopfield associative recall through RTL | 120/120, 0 divergent iterations vs model | `docs/HOPFIELD_DEMO.md` |
| On-chip block-exponent normalizer | +2.84% system area — 14× cheaper than accumulator-widening (+39.6%) at equal quality | `docs/EXPNORM_RESULTS.md`, `docs/ADR_002_NORMALIZATION_ARCHITECTURE.md` |
| Gradient-accumulation niche | NFE-13 = BF16-class sign fidelity at 0.59× BF16 multiplier area; compact form E3M6+block at 10.75 effective bits | `docs/GRADIENT_NICHE_FINAL.md`, `docs/COMPACT_NFE_VERDICT.md` |
| Heterogeneous tile (E4M3 + E3M6 + shims) | 3,188 µm², glue 7.2% (budget 20%), 2,005/2,005 tests | `docs/TILE_V2_RESULTS.md` |

## What was falsified (and kept as evidence)

| Hypothesis | How it died | Evidence |
|------------|-------------|----------|
| PATH_FAST (full-mantissa accumulate) | Existed only in two agreeing software models — the RTL was the only true second source | `docs/SSC_RTL_VALIDATION.md` |
| PF-W18 wide accumulator (ADR-001, +39.6%) | Reversed within a day: baseline + k=8 normalization beat it on the eigenvector workload | `docs/NORM_VS_PF18.md` |
| NFE-13 for inference | E4M3 matches it at ~0.53× multiplier area | `docs/FORMAT_COMPARISON.md`, `docs/AREA_COMPARISON.md` |
| Fused dual-mode core | 1.97× the standalone E3M6 core — mode-muxing two exponent disciplines doesn't collapse | `docs/DUAL_CORE_RESULTS.md` |
| Tile v1 (buffer + normalizer inside) | 45.1% glue; the 8×13 serial block buffer alone blew the budget — block machinery belongs at system level | `docs/TILE_RESULTS.md` |
| Pure block FP (E0, mantissa-only elements) | E0M6 dies to instrumented intra-block flush; E0M9 matches E3M6 only at 2.29× multiplier cost. Per-element exponent bits (≥2 marginal, ≥3 conservative) are load-bearing in silicon | `docs/BLOCKFP_VERDICT.md` |

Method: Python model first, RTL as second source, pre-registered kill criteria,
gates that stop broken pipelines, negative results published at the same prominence
as wins. Declined temptations to adjust experiments are documented in the verdicts.

Not yet measured: timing/STA (all area comparisons are pre-timing), full-MAC-level
area (comparisons are multiplier-centric), dynamic power (all energy statements are
area proxies), and system-level synthesis of the shared-normalizer amortization.

## 60-second quickstart

**Requirements:** Icarus Verilog ≥ 11, Python 3.8+, numpy, scikit-learn, Yosys ≥ 0.9, Sky130 HD liberty

```bash
git clone https://github.com/sotiriosc/Horus-Geometry-Fabric.git
cd Horus-Geometry-Fabric
python3 -m pip install -r requirements.txt
# Sky130 liberty: auto-detected from PDK_ROOT / volare, or:
# export SKY130_HD_LIB=/path/to/sky130_fd_sc_hd__tt_025C_1v80.lib
cd sim
```

```bash
make mlp_all         # ~4s   — digit inference; expect "PREDICTIONS EXACT 360/360"
make hopfield_all    # ~5s   — associative recall; expect 120/120, 0 divergent iterations
make ssc_chain       # ~2s   — feedback-chain validation; P1 NOT CONFIRMED, P2/P3 CONFIRMED
make norm_vs_pf18    # ~35s  — measurement that reversed ADR-001
make tile_v2         # ~1s   — heterogeneous tile; 2,005/2,005 tests, K1 PASS at 7.2% glue
make blockfp         # ~29s  — E0M6 FAIL (flush), E0M9 PASS at 2.29× cost
make gradient_final  # ~2.5 min — gradient-accumulation niche sweep
```

## Repo map

```
rtl/    horus_nfe.v (original core) · horus_norm_v2.v (the anchor) ·
        fp8_e4m3_mul.v (inference winner) · horus_e3m6_core.v (gradient carrier) ·
        horus_tile_v2.v (integrated tile) · superseded variants retained as evidence

tb/     one testbench per module + per application; golden-file driven

sim/    Makefile (all targets) · format_zoo.py (single source of truth per format) ·
        training, inference, sweep, and cross-check scripts ·
        HBS_CORE_MASTER_INDEX.log (one line per finding, whole campaign)

docs/   CAMPAIGN_OVERVIEW.md (start here) · two ADRs (one honestly reversed) ·
        one results doc per experiment, including every negative result
```

## License and notice

**License:** [CERN-OHL-S-2.0](LICENSE) — strongly-reciprocal open hardware.
Anyone may use, study, modify, and build on this work, but any derivative work
must remain open under the same terms. This project is released as a contribution,
not a commercial product. It is intended to stay in the commons permanently.

This repository, including all RTL, simulation scripts, and results, constitutes
a public disclosure record as of 2026-07-05.

**Author:** Sotirios Chortogiannos

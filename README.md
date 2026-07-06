Horus-Geometry-Fabric

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

Full story, in order, every claim cited: docs/CAMPAIGN_OVERVIEW.md

Positioning note: shared block exponents over small-float elements correspond to
classical block floating point and the OCP Microscaling (MX) approach. This project's
contribution is not that concept — it is an open, gate-verified implementation with a
documented falsification trail, plus one measured boundary the MX spec doesn't cover:
where on the per-element-exponent axis a gradient-accumulation niche lives and dies.


What was verified

ResultMeasuredEvidenceRTL digit inference (360 images, real Verilog)96.39% vs 96.67% FP64 ceiling; 360/360 predictions match the Python model exactlydocs/MLP_INFERENCE_DEMO.mdNFE weight quantizationLossless (96.67%, identical to FP64)docs/MLP_INFERENCE_DEMO.mdHopfield associative recall through RTL120/120, 0 divergent iterations vs modeldocs/HOPFIELD_DEMO.mdOn-chip block-exponent normalizer+2.84% system area — 14× cheaper than accumulator-widening (+39.6%) at equal qualitydocs/EXPNORM_RESULTS.md, docs/ADR_002_NORMALIZATION_ARCHITECTURE.mdGradient-accumulation nicheNFE-13 = BF16-class sign fidelity at 0.59× BF16 multiplier area; compact form E3M6+block at 10.75 effective bitsdocs/GRADIENT_NICHE_FINAL.md, docs/COMPACT_NFE_VERDICT.mdHeterogeneous tile (E4M3 + E3M6 + shims)3,188 µm², glue 7.2% (budget 20%), 2,005/2,005 testsdocs/TILE_V2_RESULTS.md

What was falsified (and kept as evidence)

HypothesisHow it diedEvidencePATH_FAST (full-mantissa accumulate)Existed only in two agreeing software models — the RTL was the only true second sourcedocs/SSC_RTL_VALIDATION.mdPF-W18 wide accumulator (ADR-001, +39.6%)Reversed within a day: baseline + k=8 normalization beat it on the eigenvector workloaddocs/NORM_VS_PF18.mdNFE-13 for inferenceE4M3 matches it at ~0.53× multiplier areadocs/FORMAT_COMPARISON.md, docs/AREA_COMPARISON.mdFused dual-mode core1.97× the standalone E3M6 core — mode-muxing two exponent disciplines doesn't collapsedocs/DUAL_CORE_RESULTS.mdTile v1 (buffer + normalizer inside)45.1% glue; the 8×13 serial block buffer alone blew the budget — block machinery belongs at system leveldocs/TILE_RESULTS.mdPure block FP (E0, mantissa-only elements)E0M6 dies to instrumented intra-block flush; E0M9 matches E3M6 only at 2.29× multiplier cost. Per-element exponent bits (≥2 marginal, ≥3 conservative) are load-bearing in silicondocs/BLOCKFP_VERDICT.md

Method: Python model first, RTL as second source, pre-registered kill criteria,
gates that stop broken pipelines, negative results published at the same prominence
as wins. Declined temptations to adjust experiments are documented in the verdicts.

Not yet measured: timing/STA (all area comparisons are pre-timing), full-MAC-level
area (comparisons are multiplier-centric), dynamic power (all energy statements are
area proxies), and system-level synthesis of the shared-normalizer amortization.


60-second quickstart

Requirements: Icarus Verilog ≥ 11, Python 3.8+, scikit-learn

bashcd sim

make mlp_all       # digit inference: train → quantize → gate check → RTL → cross-check
                   # expect: 4-way accuracy table, ASCII digits, "PREDICTIONS EXACT 360/360"

make hopfield_all  # associative recall: H/T/X patterns, 120 corruption trials
                   # expect: 120/120 recall, ASCII recall sequence, 0 divergent iterations

make ssc_chain     # the feedback-chain validation that started everything
                   # expect: P1 NOT CONFIRMED (the PATH_FAST gap), P2/P3 CONFIRMED

make norm_vs_pf18  # the measurement that reversed ADR-001
make tile_v2       # heterogeneous tile: 2,005/2,005 tests, K1 PASS at 7.2% glue
make blockfp       # the paradigm question: E0M6 FAIL (flush), E0M9 PASS at 2.29× cost


Repo map

rtl/    horus_nfe.v (original core) · horus_norm_v2.v (the anchor) ·
        fp8_e4m3_mul.v (inference winner) · horus_e3m6_core.v (gradient carrier) ·
        horus_tile_v2.v (integrated tile) · superseded variants retained as evidence

tb/     one testbench per module + per application; golden-file driven

sim/    Makefile (all targets) · format_zoo.py (single source of truth per format) ·
        training, inference, sweep, and cross-check scripts ·
        HBS_CORE_MASTER_INDEX.log (one line per finding, whole campaign)

docs/   CAMPAIGN_OVERVIEW.md (start here) · two ADRs (one honestly reversed) ·
        one results doc per experiment, including every negative result


License and notice

License: CERN-OHL-S-2.0 — strongly-reciprocal open hardware.
Anyone may use, study, modify, and build on this work, but any derivative work
must remain open under the same terms. This project is released as a contribution,
not a commercial product. It is intended to stay in the commons permanently.

This repository, including all RTL, simulation scripts, and results, constitutes
a public disclosure record as of 2026-07-05.

# Horus-Geometry-Fabric — Minimal Entry Point

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

## The claim

NFE-13 (13-bit float: 1s 6e 6f) matches BF16 sign-error rates in mixed-sign
heavy-tailed gradient accumulation at **0.59× BF16 multiplier area**
(1,611.5 µm² vs 2,740.1 µm², Yosys/Sky130 HD TT 025C 1v80).
The FP32-accumulator pattern (E4M3 inputs + FP32 running sum) does not close
this gap: the loss happens at **encoding**, before the accumulator sees the
value — a gradient rounded away by a 3-bit mantissa is gone regardless of
accumulator width. ([`docs/GRADIENT_NICHE_FINAL.md`](docs/GRADIENT_NICHE_FINAL.md))

## Two falsifications worth reusing

**Dual-core fusion is not free** (`docs/DUAL_CORE_RESULTS.md`):
Fusing E4M3 and E3M6 into one datapath costs **1.97× the standalone E3M6
core**. The overhead is structural — exponent paths, rounding logic, and
sentinel rules (FP8 NaN/max-finite vs none) produce distinct logic cones
that synthesis cannot merge even after sharing the mantissa array.
Fallback: two separate cores, one shared normalizer, straight-sum area.

**Block-FP mantissa-only endpoint fails** (`docs/BLOCKFP_VERDICT.md`):
E0M6 (block-FP, 6-bit mantissa, no per-element exponent) dies to measured
intra-block flush — 11–14% of elements lose >50% of mantissa bits,
sign-error rates 6–22× the E3M6+block reference at all R.
E0M9 (9-bit mantissa) passes, but at **2.29× the E3M6 core** multiplier
area. The per-element exponent is not overhead — it encodes intra-block
dynamic range that mantissa bits cannot absorb at equal cost.

## Reproduce

**Requirements**: Icarus Verilog ≥ 11, Python 3.8+, numpy, scikit-learn,
Yosys ≥ 0.9, Sky130 HD liberty
(`export SKY130_HD_LIB=/path/to/sky130_fd_sc_hd__tt_025C_1v80.lib`)

```bash
cd sim

# Block-FP: does the per-element exponent matter? (Python arenas + Yosys synthesis)
# Runtime: ~29s
make blockfp
# Expect: "E0M6+block (7.75 eff bits): K1 FAIL"
#         "E0M9+block (10.75 eff bits): K1 PASS"
#         blockfp_mul7: 1848.022 µm²  blockfp_mul10: 3836.179 µm²

# Gradient-accumulation niche (11 format conditions, 1000 trials)
# Runtime: ~2.5 min
make gradient_final
# Expect: NFE-13 bare  = 0.0010 sign-flip rate at R=10²
#         BF16 bare    = 0.0010  (tied, within error bars)
#         E4M3+FP32acc = 0.0030  (3× worse)
#         Results: GRAD_V2_MAIN.csv  GRAD_V2_ZERO.csv
```

## Full trail

[`docs/CAMPAIGN_OVERVIEW.md`](docs/CAMPAIGN_OVERVIEW.md) — every experiment,
in order, with every number cited to its source doc.

# ANNOUNCEMENT_DRAFT — r/FPGA post (adaptable to LinkedIn)

**DRAFT — author will edit voice before posting. Numbers sourced directly from
simulation logs and synthesis reports. Banned words: revolutionary, breakthrough,
novel, state-of-the-art, groundbreaking, synergy, innovative.**

---

## Draft text

---

**Title:** I built a custom 13-bit float, RTL-verified it against 96.39% digit accuracy,
ran eleven falsifications, and here is what the format war actually looked like

I've been working on a 13-bit floating-point format called NFE v3: 1 sign bit, 6-bit
exponent (bias 32), 6-bit mantissa. The goals were compact weight storage and enough
dynamic range to avoid saturation in recurrent feedback chains. This post is about
what the verification campaign found — including the parts that came out wrong.

**The two-agreeing-models lesson.**

Before I had any RTL numbers, two software implementations both predicted ≤ 0.38% error
for a hypothetical fast feedback mode. One in C, one in Python. They agreed, so I treated
the agreement as confirmation.

It wasn't. Both implemented the same assumption: that a 14-bit intermediate product was
preserved through row accumulation. Reading `horus_nfe.v` lines 530–532 showed that the
product is immediately truncated to 6 bits in a local register with no output port. The
faster mode does not exist in hardware. Two models agreed because they shared the same
unverified assumption, not because either was independent.

RTL result: divergence past 1% at cycle 2, 23.95% final error at depth 256, DUT stalled
at the codeword for 1.25 while FP64 converged to 1.64. That's the number, and it's in
the repo.

**The architecture decision that got reversed the same day it was accepted.**

The 23.95% error motivated a wider accumulator variant (W=18, +39.6% system area, Sky130 HD
PDK, Yosys synthesis). Decision written up, evidence documented, accepted.

Same day: a normalization sweep showed that block-exponent rescaling every k=8 steps
achieves 1.0000 alignment on the power-iteration workload where W=18 actually *fails*
(W=18 saturates at row sums above ~2.0; alignment 0.9892 < threshold). The baseline
format with a normalizer: 14× cheaper (+2.84% system area) for equal or better accuracy.

Both ADRs, both evidence trails, are in the repo in the state they were written.

**The inference result — stated plainly.**

After building the normalizer (`rtl/horus_norm.v`, 565 cells, RTL-verified) and running
the full pipeline through 360 test digits (96.39% RTL accuracy, 360/360 exact prediction
agreement with Python), the format-zoo comparison asked the harder question: how does
NFE-13 actually compare against FP8-E4M3, BF16, INT8?

For single-pass inference: FP8-E4M3 with block-exponent normalization achieves identical
96.39% MLP accuracy at 857 µm² multiplier area. NFE-13 costs 1 612 µm² — 1.88× more —
for the same result. There is no inference workload in this campaign where NFE-13
justified its premium over E4M3. That is the finding, and it is the title of a doc.

**Where the format war ended — and where a niche was found.**

After falsifying NFE-13 for recurrent tasks (block-exponent re-grounding makes all
formats equivalent — the mantissa hypothesis is dead under normalization) and for all-positive
expansive chains (Perron-Frobenius theorem: saturation preserves direction when the dominant
eigenvector is all-positive, so dynamic range never mattered), one hypothesis remained:
mixed-sign gradient accumulation.

The test: 256-step accumulate-and-requantize chain, log-uniform gradient magnitudes,
random signs, dynamic range R sweeping 10² to 10¹⁰. Eleven format conditions including
BF16, FP16, and the industry pattern — E4M3 inputs with a float32 running sum (what real
FP8 training does).

Result (1 000 trials, error bars, pre-registered claim options):

| Sign-error rate at R=10² | Format |
|---|---|
| 0.0000 | FP16 |
| 0.0010 ± 0.0030 | **NFE-13** and **BF16** (identical, within error bars) |
| 0.0030 ± 0.0065 | E4M3+FP32acc (industry pattern) |
| 0.0475 ± 0.0235 | E4M3 bare |
| 0.0830 ± 0.0303 | E5M2 bare |

NFE-13 matches BF16 sign-error rate at **0.59× BF16 multiplier area** and beats the
FP32-accumulator pattern by **3× at R=10²**.

**The sharpest finding in the whole campaign**: the FP32 accumulator does not close
the gap between E4M3 and NFE-13. The loss happens at *encoding* — a gradient rounded
away before the accumulator sees it is gone regardless of how good the accumulator is.
Per-element mantissa width is the only mechanism that retains small contributions.
This is also why block-floating-point (MX formats, one shared exponent per group) doesn't
solve this particular problem: individual gradient magnitudes span many orders of magnitude
and cannot all share a scale without losing the small ones.

**Limitations — stated as clearly as the results.**

The FP16 zero-error score was audited before closing: ~40% of gradients at R=10¹² fall
below FP16's subnormal floor, but their total signed contribution per 4096-step trial
is at most 2.1×10⁻⁶ — roughly 0.002% of the smallest valid FP64 sum. The score is
genuine. NFE-13 is ≥ 1.70× more area-efficient than FP16 (BF16 used as FP16 area lower
bound; analytical estimate puts the centre ratio at ≈ 3.8×; synthesis not performed).

All area numbers are multiplier-only (Yosys, Sky130 HD PDK). Full MAC area, accumulator
circuits, routing, and timing are unmeasured. No frequency claim is made anywhere in the
repo. OpenSTA is not in my environment.

The FP8 training comparison is a proxy: the test measures sign-error rates in a synthetic
accumulation chain, not actual training convergence on a real model.

**Final verdict (from `docs/GRADIENT_NICHE_FINAL.md`):**

For inference: FP8-E4M3 + block-exponent normalization wins. NFE-13's premium is
unjustified.

For heavy-tailed gradient accumulation: NFE-13 delivers BF16-class quality at 0.59×
BF16 area, and the industry FP32-accumulator pattern does not match it because
encoding loss precedes accumulation.

---

**Repo:** [github.com/sotiriosc/Horus-Geometry-Fabric]  
**License:** CERN-OHL-S-2.0. RTL, testbenches, synthesis scripts, all logs — in the repo.

---

*End of draft. Author should adjust title and personal voice before posting.*

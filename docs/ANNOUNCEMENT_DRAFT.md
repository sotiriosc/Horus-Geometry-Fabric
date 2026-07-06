# ANNOUNCEMENT_DRAFT — r/FPGA post (adaptable to LinkedIn)

**DRAFT — numbers sourced directly from simulation logs and synthesis reports.
Banned words: revolutionary, breakthrough, novel, state-of-the-art, groundbreaking,
synergy, innovative.**

---

## Draft text

---

**Title:** I built a 13-bit float and then spent the whole campaign trying to beat it.
Here's what survived and what didn't.

I've been working on a 13-bit floating-point format called NFE v3: 1 sign bit, 6-bit
exponent (bias 32), 6-bit mantissa. The idea was compact weight storage with enough
dynamic range to survive recurrent feedback chains without saturating.

I'm not sure any of this will truly be useful to anyone. I'm sharing it because the
most important thing I've learned doing this is that if you want to know whether
something works, you have to try to beat it. Not demo it — beat it. So that's what
this post is: eleven falsification attempts, the ones the format lost, and the one
place it held.

The other thing I learned: don't claim things. A claim is a distortion — it's you
telling the data what it says instead of the other way around. So I'm not going to
claim anything here. I'll just show you what the logs say, including the parts that
came out wrong. And if you're lucky enough to taste something satisfactory at the
end of all that beating, you share it. That's the whole reason for this post.

**The lesson that set the tone: two models agreeing means nothing.**

Before I had any RTL numbers, two software implementations — one in C, one in Python —
both predicted ≤ 0.38% error for a hypothetical fast feedback mode. They agreed with
each other, so I treated the agreement as confirmation.

It wasn't. Both implemented the same assumption: that a 14-bit intermediate product
survived through row accumulation. When I actually read `horus_nfe.v` lines 530–532,
the product is truncated to 6 bits in a local register with no output port. The faster
mode does not exist in the hardware. Two models agreed because they shared the same
unverified assumption, not because either one was independent.

The RTL told the real story: divergence past 1% at cycle 2, 23.95% final error at
depth 256, the DUT stalled at the codeword for 1.25 while FP64 converged to 1.64.
That number is in the repo. I left it there because pretending it didn't happen would
be the distortion I'm trying to avoid.

**A decision I accepted and reversed the same day.**

The 23.95% error pushed me toward a wider accumulator variant (W=18, +39.6% system
area, Sky130 HD PDK, Yosys synthesis). I wrote up the decision, documented the
evidence, accepted it.

Then, same day, I tried to beat that decision too. A normalization sweep showed that
block-exponent rescaling every k=8 steps achieves 1.0000 alignment on the
power-iteration workload where W=18 actually *fails* (W=18 saturates at row sums
above ~2.0; alignment 0.9892, below threshold). The baseline format with a
normalizer: 14× cheaper (+2.84% system area) for equal or better accuracy.

Both ADRs are in the repo, in the state they were written. The wrong one stays.

**The inference result, stated plainly — my format lost.**

After building the normalizer (`rtl/horus_norm.v`, 565 cells, RTL-verified) and
running the full pipeline through 360 test digits (96.39% RTL accuracy, 360/360 exact
prediction agreement with Python), I put NFE-13 up against FP8-E4M3, BF16, and INT8.

For single-pass inference: FP8-E4M3 with block-exponent normalization hits the
identical 96.39% MLP accuracy at 857 µm² multiplier area. NFE-13 costs 1 612 µm² —
1.88× more — for the same result. There is no inference workload in this campaign
where NFE-13 justified its premium over E4M3. I wanted my format to win here. It
didn't, and that's the title of one of the docs.

**Where the format war ended — and the one place something held.**

I kept beating on it. NFE-13 fell for recurrent tasks (block-exponent re-grounding
makes all the formats equivalent — the mantissa hypothesis is dead under
normalization). It fell for all-positive expansive chains (Perron-Frobenius:
saturation preserves direction when the dominant eigenvector is all-positive, so
dynamic range never mattered there). One hypothesis was left standing to test:
mixed-sign gradient accumulation.

The test: 256-step accumulate-and-requantize chain, log-uniform gradient magnitudes,
random signs, dynamic range R sweeping 10² to 10¹⁰. Eleven format conditions
including BF16, FP16, and the industry pattern — E4M3 inputs feeding a float32
running sum, which is what real FP8 training does.

Result (1 000 trials, error bars, claim options pre-registered before running):

| Sign-error rate at R=10² | Format |
|---|---|
| 0.0000 | FP16 |
| 0.0010 ± 0.0030 | **NFE-13** and **BF16** (identical, within error bars) |
| 0.0030 ± 0.0065 | E4M3+FP32acc (industry pattern) |
| 0.0475 ± 0.0235 | E4M3 bare |
| 0.0830 ± 0.0303 | E5M2 bare |

NFE-13 matches BF16's sign-error rate at 0.59× BF16 multiplier area, and beats the
FP32-accumulator pattern by 3× at R=10².

The part that surprised me most: the FP32 accumulator does not close the gap between
E4M3 and NFE-13. The loss happens at *encoding* — a gradient that gets rounded away
before the accumulator ever sees it is gone, no matter how good the accumulator is.
Per-element mantissa width is the only mechanism that retains small contributions.
This is also why block-floating-point (MX formats, one shared exponent per group)
doesn't fix this particular problem: individual gradient magnitudes span many orders
of magnitude and can't all share one scale without losing the small ones.

This is the one satisfactory taste in the whole campaign. I tried to beat it and
couldn't — which is the only reason I'm comfortable sharing it.

**Limitations, stated as clearly as the results — because leaving them out would be claiming.**

The FP16 zero-error score got audited before I closed the book on it: ~40% of
gradients at R=10¹² fall below FP16's subnormal floor, but their total signed
contribution per 4096-step trial is at most 2.1×10⁻⁶ — roughly 0.002% of the smallest
valid FP64 sum. The score is genuine. NFE-13 is ≥ 1.70× more area-efficient than FP16
(BF16 used as the FP16 area lower bound; an analytical estimate puts the centre ratio
at ≈ 3.8×; synthesis not performed).

All area numbers are multiplier-only (Yosys, Sky130 HD PDK). Full MAC area,
accumulator circuits, routing, and timing are unmeasured. There is no frequency claim
anywhere in the repo — OpenSTA is not in my environment, so I can't make one honestly.

The FP8 training comparison is a proxy: it measures sign-error rates in a synthetic
accumulation chain, not actual training convergence on a real model. If someone with
real training infrastructure wants to try to beat this result properly, I'd genuinely
like to see the outcome either way.

**Where it landed (from `docs/GRADIENT_NICHE_FINAL.md`):**

For inference: FP8-E4M3 + block-exponent normalization wins. NFE-13's premium is
unjustified. My format lost this one and the doc says so.

For heavy-tailed gradient accumulation: NFE-13 delivers BF16-class quality at 0.59×
BF16 area, and the industry FP32-accumulator pattern doesn't match it, because the
loss happens at encoding, before the accumulator.

That's it. Not a claim — just what survived eleven attempts to kill it. Everything is
in the repo if you want to try to beat it yourself. Honestly, I hope somebody does.

---

**Repo:** [github.com/sotiriosc/Horus-Geometry-Fabric]  
**License:** CERN-OHL-S-2.0. RTL, testbenches, synthesis scripts, all logs — in the repo.

---

*End of draft. Author gives final read before posting.*

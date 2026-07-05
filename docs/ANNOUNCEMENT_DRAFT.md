# ANNOUNCEMENT_DRAFT — r/FPGA post (adaptable to LinkedIn)

**DRAFT — author will edit voice before posting. The job of this draft is
accuracy and structure. Numbers are sourced directly from simulation logs.**

---

## Draft text

---

**Title:** I ran 360 handwritten digits through actual RTL at 96.39% accuracy — here's
what the process found along the way

I've been building a 13-bit open-hardware floating-point format (NFE v3: 1 sign,
6-bit exponent bias 32, 6-bit mantissa fraction) and a Verilog datapath for it.
This week I closed the loop: 360 test images through `horus_nfe` + a block-exponent
normalizer I built and synthesized, reading out predictions and comparing them to a
Python reference model.  The RTL and Python agree on every single prediction
(360/360).  The accuracy is 96.39% against a 96.67% FP64 ceiling.

That's the end of the story.  The more interesting part for a hardware audience
is what the process found in the middle.

---

**The finding that surprised me most: two agreeing software models were not
independent confirmation.**

Before I had any RTL results, two software implementations both predicted ≤ 0.38%
error for a hypothetical faster feedback mode — one in C, one in Python.  They agreed.
I thought that was useful evidence.

It wasn't.  Both implemented the same assumption: that a 14-bit intermediate product
was available to the accumulator after each multiply.  When I actually read the RTL,
`horus_nfe.v` lines 530–532 truncate that product to 6 bits immediately and store the
result in a local register with no output port.  The faster mode does not exist in
hardware.  The two models agreed because they shared the same unverified assumption,
not because either was an independent check.

The RTL is the only true second source.  Running the actual datapath in feedback for
256 iterations: divergence past 1% at cycle 2, final error 23.95%, DUT stalled at the
NFE value for 1.25 while the FP64 reference converged to 1.64.  Confirmed, not flattering.

---

**The architecture decision that got reversed the same day it was accepted.**

That 23.95% error motivated building a wider accumulator variant (W=18 bits, +39.6%
system area on Sky130 HD, Yosys synthesis).  I wrote up the decision, ran the numbers,
accepted it.

Same day, a normalization-interval sweep asked: what if the harness just renormalizes
the state vector every k steps instead?  For the feedback (SSC) workload, baseline
catches up to the wider accumulator at k=128 — within 0.22 percentage points at 14× lower
area.  For the power-iteration (PI) workload, the wider accumulator actually *fails* the
accuracy threshold (W=18 saturates for row sums above ~2.0; alignment 0.9892 < 0.99);
baseline with k=8 normalization achieves 1.0000.

Decision reversed.  Both the original decision and the reversal are in the repo with
full evidence trails.  The process working is more useful than hiding that it required
two passes.

---

**What I actually built and what the numbers are.**

The normalizer (`rtl/horus_norm.v`): 8-element block-exponent rescale, combinational
max-exponent tree, 1-cycle registered output.  Synthesis: 565 cells, +2.84% system area
(I estimated +0.3–1.3%; the discrepancy is traced to an unaccounted 104-bit output
register bank, 39% of module area).

Two applications: a Hopfield associative-memory network (120/120 recall on three 8×8
letter patterns at two corruption levels, 0 divergent iterations between Python and RTL),
and the MLP digit classifier (96.39% RTL, 96.67% FP64, 360/360 exact prediction agreement).

The MLP demo also produced a documented negative result first: the initial normalizer
applied independent offsets to two halves of the 16-neuron hidden layer, which destroyed
inter-block magnitudes and dropped accuracy to 84.72%.  The gate triggered, RTL work
stopped, root cause was diagnosed in Python, a v2 normalizer with external-offset mode
was built and tested, and then the RTL testbench ran.

---

**What's open.**

Timing is not measured — OpenSTA is not in my environment.  The normalizer rescale path
probably introduces a new critical-path segment; I don't know the frequency.  FPGA
deployment is documented in `docs/FPGA_GUIDE.md` but I haven't run it yet.

The harness handles ReLU, bias addition, and argmax in software.  These are not on-chip.
The DUT (RTL) does all multiply-accumulate and all exponent normalization; everything else
is the testbench.  The digits are 8×8 grayscale (sklearn `load_digits`), not MNIST 28×28.

Contractive-regime behavior (state shrinking toward zero) currently stalls at an NFE
floor value rather than continuing to decay.  This is a known open item in the architecture
docs.

---

**Repo:** [github.com/sotiriosc/Horus-Geometry-Fabric]

**License:** CERN-OHL-S-2.0.  Everything — RTL, testbenches, scripts, logs — is in the repo.

---

*End of draft. Author should edit for personal voice, adjust title, and verify repo URL
before posting.*

# Horus-Geometry-Fabric

NFE-13 (13-bit float: 1s 6e 6f) matches BF16 sign-error rates in mixed-sign
heavy-tailed gradient accumulation at **0.59× BF16 multiplier area**
(1,611.5 µm² vs 2,740.1 µm², Yosys/Sky130 HD).
The FP32-accumulator pattern does not close this gap — the loss happens at
encoding, before the accumulator sees the value.

**15-minute version: [MINIMAL.md](MINIMAL.md)**  
Full trail: [docs/CAMPAIGN_OVERVIEW.md](docs/CAMPAIGN_OVERVIEW.md)

> **Acknowledgment**  
> Developed with AI assistance (Claude via Cursor) for RTL verification, testing, and documentation.  
> All architectural decisions and final verification by the author.

---

## Scope and limitations

Read this before the results.

- **Timing not measured.** OpenSTA is not available in this environment.
  No frequency claim appears anywhere in this repo.
- **Comparisons are multiplier area only.** Numbers are from Yosys synthesis
  of the combinational multiply stage under Sky130 HD TT 025C 1v80.
  Full MAC area (adder trees, registers, accumulator, routing) is not measured.
  The FP32-accumulator pattern adds an unmeasured FP32 accumulator on top of
  the E4M3 multiplier.
- **Energy statements are area proxies.** Gated-area fractions are reported
  as proxies only. No dynamic power number appears anywhere in this repo.
- **Workloads are small-scale.** Gradient sweep: 256-step single-element
  accumulator, depth ≤ 4096, log-uniform mixed-sign gradients.
  Inference: 64→16→10 MLP, sklearn digits (8×8 pixels, 360 test images).
  Matrix operations: 8×8 NFE blocks. These are not production-scale workloads.
- **No claim holds at depth > 256 without qualification.** At depth 4096
  and R = 10¹², BF16 is 3.1× better than NFE-13; FP16 remains zero.
  The main claim (BF16-class at 0.59× area) is stated and verified for
  depth ≤ 256.

---

## Reproduce the main result

**Requirements:** Icarus Verilog ≥ 11, Python 3.8+, numpy, scikit-learn,
Yosys ≥ 0.9, Sky130 HD liberty

```bash
git clone https://github.com/sotiriosc/Horus-Geometry-Fabric.git
cd Horus-Geometry-Fabric
python3 -m pip install -r requirements.txt
# Sky130 liberty: auto-detected from PDK_ROOT / volare, or:
# export SKY130_HD_LIB=/path/to/sky130_fd_sc_hd__tt_025C_1v80.lib
cd sim
```

```bash
# Block-FP: does the per-element exponent matter? (~29s)
make blockfp
# Expect: "E0M6+block (7.75 eff bits): K1 FAIL"
#         "E0M9+block (10.75 eff bits): K1 PASS"

# Gradient-accumulation niche (~2.5 min)
make gradient_final
# Expect: NFE-13 bare = 0.0010 at R=10²
#         BF16 bare   = 0.0010 (tied)
#         E4M3+FP32acc = 0.0030 (3× worse)
```

---

## Additional verified targets (fresh-clone runtimes)

```bash
make mlp_all         # ~4s   — 96.39% RTL accuracy, PREDICTIONS EXACT 360/360
make hopfield_all    # ~5s   — 120/120 recall, 0 divergent iterations
make tile_v2         # ~1s   — 2005/2005 tests, K1 PASS 7.2% glue
make norm_vs_pf18    # ~35s  — 3 RTL CONFIRMED cells
make ssc_chain       # ~2s   — P1 NOT CONFIRMED (PATH_FAST absent), P2/P3 CONFIRMED
```

---

## What NFE is

NFE v3 is a 13-bit float: 1 sign bit, 6-bit stored exponent (bias 32), 6-bit
mantissa fraction. Encodes as `(−1)^s × (1 + f/64) × 2^(E−32)`.
Range ≈ [2.4×10⁻⁹, 4.3×10⁹]. Sixteen `horus_nfe` cores tile into `horus_top`
(188,742 µm² baseline, Sky130 HD TT 025C 1v80), operating on 8×8 blocks.

---

## Results summary

| Result | Measured | Source |
|--------|----------|--------|
| Gradient niche — NFE-13 vs BF16 sign-error rate | 0.0010 vs 0.0010 at R=10² (tied) | `docs/GRADIENT_NICHE_FINAL.md` |
| NFE-13 multiplier area vs BF16 | 1,611.5 µm² vs 2,740.1 µm² = **0.59×** | `docs/AREA_COMPARISON.md` |
| NFE-13 vs E4M3+FP32acc at R=10² | 0.0010 vs 0.0030 — 3× fewer sign errors | `docs/GRADIENT_NICHE_FINAL.md` |
| Inference: NFE-13 vs E4M3 | E4M3 wins — same 96.39% at **0.53× NFE-13 area** | `docs/FORMAT_COMPARISON.md` |
| Dual-core fusion overhead | **1.97× standalone E3M6** — falsified | `docs/DUAL_CORE_RESULTS.md` |
| Block-FP E0M6 gradient niche | **FAIL** — intra-block flush, 6–22× reference rate | `docs/BLOCKFP_VERDICT.md` |
| Block-FP E0M9 vs E3M6 area | E0M9 passes K1 at **2.29× E3M6 multiplier area** | `docs/BLOCKFP_VERDICT.md` |
| Tile v2 | 2,005/2,005 tests, K1 PASS at 7.2% glue, 3,188 µm² total | `docs/TILE_V2_RESULTS.md` |
| RTL MLP inference | 96.39% (347/360), 360/360 predictions exact vs Python | `docs/MLP_INFERENCE_DEMO.md` |
| Hopfield recall | 120/120 (100%), 0 divergent iterations | `docs/HOPFIELD_DEMO.md` |

---

## Repo map

```
rtl/
  horus_nfe.v           — core MAC datapath (PATH_NFE, 6-bit product)
  horus_norm_v2.v       — block-exponent normalizer v2 (shared-offset mode)
  fp8_e4m3_mul.v        — FP8-E4M3FN multiplier (inference winner)
  horus_e3m6_core.v     — E3M6 compact multiplier (gradient niche carrier)
  horus_dual_core.v     — fused dual-mode core (falsified, retained as evidence)
  horus_tile_v2.v       — respecified tile: cores + shims + mode (K1 PASS)
  blockfp_mul7.v        — E0M6 mantissa multiplier (K3 iso-silicon probe)
  blockfp_mul10.v       — E0M9 mantissa multiplier (K3 iso-silicon probe)

sim/
  Makefile              — all build targets
  gradient_range_v2.py  — gradient-accumulation sweep (main niche result)
  blockfp_test.py       — block-FP arenas (paradigm question)
  format_zoo.py         — five-format codec zoo
  mlp_train.py / mlp_infer_nfe.py / analyze_mlp.py — MLP pipeline
  hopfield_demo.py / analyze_hopfield.py — Hopfield pipeline

docs/
  CAMPAIGN_OVERVIEW.md  — the full arc, every claim cited
  GRADIENT_NICHE_FINAL.md — gradient-accumulation niche verdict
  BLOCKFP_VERDICT.md    — block-FP verdict
  DUAL_CORE_RESULTS.md  — fusion falsified
  TILE_V2_RESULTS.md    — tile v2 K1 PASS
  FORMAT_COMPARISON.md  — format war: 5 formats, 3 arenas
  AREA_COMPARISON.md    — multiplier area synthesis
  MLP_INFERENCE_DEMO.md — MLP inference end-to-end
  HOPFIELD_DEMO.md      — Hopfield recall
```

---

## License and Notice

**License:** [CERN-OHL-S-2.0](LICENSE) — strongly-reciprocal open hardware.
Anyone may use, study, modify, and build on this work, but any derivative work
must remain open under the same terms.  This project is released as a contribution,
not a commercial product.  It is intended to stay in the commons permanently.

This repository, including all RTL, simulation scripts, and results, constitutes
a public disclosure record as of 2026-07-05.

**Author:** Sotirios Chortogiannos

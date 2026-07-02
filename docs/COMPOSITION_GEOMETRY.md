# Composition Geometry — Horus NFE v3

**Document class:** Principal Architecture Reference  
**Scope:** Deterministic error geometry under operator composition, cancellation,
and multi-cycle accumulation. Observe-only verification; no RTL modification implied.  
**DUT:** `horus_system` · `host_tile_depth = 63` · `accum_en = 1`

For format identity and the Digital Physics paradigm, see
[ARCHITECTURE_PHILOSOPHY.md](ARCHITECTURE_PHILOSOPHY.md).  
For architectural trade-offs and fidelity limits, see
[DESIGN_LIMITATIONS.md](DESIGN_LIMITATIONS.md).

---

## 1. Executive Summary

Horus NFE v3 does **not** produce IEEE-754-style floating-point cancellation.
It produces **deterministic codeword-space residuals** whose geometry is:

| Property | Finding |
|----------|---------|
| **Sequence-dependent** | Residual bias changes with operator permutation (Test 10B) |
| **Depth-dependent** | Shallow chains (depth ≤ 4) retain full bias-table predictability; deep chains (depth ≥ 30) enter a **deterministic floor regime** (Test 10C) |
| **Not random noise** | Residuals are repeatable, bucket-deterministic, and learnable — not irreducible quantization noise |
| **Classification** | **Partially stable (Category B)** under composition; **fully structured (Category A)** under isolated cancellation pairs |

**Principal conclusion:** Error in Horus is a **deterministic residual manifold** indexed by
operator sequence, composition depth, and operand exponent/fraction band — not a stochastic
process. Software must model this geometry explicitly; hardware changes are not required
for shallow-chain exploitation.

---

## 2. Composition Sensitivity

### 2.1 Definition

**Composition Sensitivity** is the measure of how Horus residual bias changes when:

1. **Operator order changes** — the same operand set routed through different MAC sequences
   produces different final codeword residuals.
2. **Composition depth increases** — chained MUL/ADD/SUB feedback re-quantization drives
   state toward floor, saturation, or bounded intermediate bands.

Formally, for operand `y` with stored exponent `E(y)` and fraction `f(y)`:

```
residual = f_composition(sequence, depth, E(y), f(y))
```

where `f_composition` is **deterministic** and **repeatable**, but **not permutation-invariant**.

### 2.2 The Deterministic Residual Manifold

Horus accumulates **integer sums of 13-bit codewords** in `pe_accum` (`accum_reg`), not
real-valued partial sums. When algebraic cancellation is expected (e.g. `x×y + x×(-y)`), the
hardware instead produces a **non-zero codeword offset** that lies on a low-dimensional
manifold:

```
Ideal (ℝ):     decode(x×y) + decode(x×(-y)) = 0
Hardware:      codeword(MUL(x,y)) + codeword(MUL(x,-y)) = B(E, f) ≠ 0
```

Properties of this manifold (verified Tests 9–10):

- **Zero cycle-to-cycle variance** for fixed `(sequence, y)` — not noise
- **Strong correlation** with stored exponent (`|r| ≈ 0.99–1.0`) and weak correlation with
  fraction alone (`|r| ≈ 0.001`)
- **Permutation-dependent geometry** — each canonical operator sequence defines its own bias surface
- **Depth-regime transitions** — shallow chains explore the full bias surface; deep chains
  collapse to `13'h000` (floor) as a **stable attractor**, not a random failure

This is **structured signal**, not Category-C noise. The engineering question is not
*whether* to correct it, but *which regime and sequence context* the correction table applies to.

### 2.3 Sequence Dependence vs. Depth Dependence

| Dimension | Shallow behavior | Deep behavior |
|-----------|------------------|---------------|
| **Sequence** | Fixed order → unique (E,f) → residual map | Same, but intermediate states hit floor earlier |
| **Depth** | 4-op chains: 153+ distinct residuals, std = 0 per repeated y | 30-op chains: 83/100 terminate at floor (`0x000`) |
| **Predictability** | 100% bucket prediction (Test 10A) | 100% bucket prediction within floor regime (Test 10C) |
| **Drift** | Linear `pe_acc` growth (expected integer sum) | Bounded; 633 inner-iteration floor events, no exponential runaway |

---

## 3. Verification Evidence — Complete Test Portfolio

All tests run observe-only against `horus_system`. Reproduction commands at §6.

### 3.1 RTL Regression — 26/26 PASS

| Suite | Tests | Scope |
|-------|------:|-------|
| `tb_horus_nfe` | 4 | ADD/SUB/MUL core arithmetic |
| `tb_horus_pgate_ctrl` | 3 | Power-gate / tile-depth gating |
| `tb_horus_router` | 8 | XY mesh routing |
| `tb_horus_nfe_wrapper` | 4 | Tile-depth wrapper |
| `tb_horus_mesh_top` | 7 | 2×2 mesh integration |

**Finding:** Core MAC contract intact. Composition geometry analysis builds on this baseline.

---

### 3.2 Fidelity Benchmark — Deep-Chain vs. FP64

**Testbench:** `tb/tb_fidelity_benchmark.v` · **Command:** `make fidelity`

1024-cycle deep-chain ADD with noise injection and FP64 golden model comparison.

| Milestone | Cycle | Observation |
|-----------|------:|-------------|
| 1% relative divergence | **278** | Hardware departs >1% from FP64 ideal |
| Saturation plateau | **384** | Horus clamps (~4.26×10⁹); FP64 continues |
| Mean relative error (full chain) | — | **~3.94%** |

**Finding:** Long-horizon accumulation diverges from IEEE semantics by design. This is the
**efficiency-vs-fidelity trade-off** — not a composition-geometry defect, but the bound within
which QAT must operate. v4 SRS normalization on `accum_out` is the planned mitigation.

---

### 3.3 Boundary Stress — Floor / Saturate / Mixed-Scale

**Testbench:** `tb/tb_boundary_stress.v` · **Command:** `make -C sim sim_boundary && vvp sim_boundary`

| Case | Behavior verified |
|------|-------------------|
| Hard floor | Exponent underflow → `13'h000` + `underflow_flag` |
| Saturation | Exponent overflow → `13'hFFF` + `exp_ovf_flag` |
| Mixed tiny/large | Large operands propagate; tiny operands floor predictably |

**Finding:** Edge regimes are **flaggable and deterministic** — foundational to the
floor-attractor behavior observed in Test 10C.

---

### 3.4 HBS Core Stability Suite — Failure Mapping

**Testbench:** `tb/tb_hbs_core_stability.v` · **Command:** `make hbs_stability`

Six observe-only stress tests on `horus_system` (`host_tile_depth=63`).

| Test | Focus | Key result |
|------|-------|------------|
| **01 — Underflow scan** | MUL floor-sentinel collapse | **126 UF events**; first collapse at boundary `f` |
| **02 — Exponent chaos** | Scale feedback loop stability | **100/100 confidence**; bounded oscillation, no sat/floor lock-in |
| **03 — Accum bias** | Integer codeword accumulation | Monotonic `pe_accum` growth; **392 UF**; floor regime dominant |
| **04 — Cancellation** | ADD/SUB/MUL adversarial cancel | **100/100 confidence**; codeword asymmetry confirmed (not float cancel) |
| **05 — Distribution shock** | Spike vs. noise injection | **94/100 confidence**; saturation under spikes (**34 OVF**) |
| **06 — Ghost Zero** | Zero-collapse flagging | **100/100 confidence**; **0 Ghost Zero** on MUL in v3 when UF asserted |

**Finding:** `pe_accum` is an integer codeword sum — the root mechanism behind Test 9/10
residual manifolds. Ghost Zero eliminated in v3 MUL path.

---

### 3.5 Failure-Domain Analysis — Weakness Map

**Testbench:** `tb/tb_horus_failure_domain.v` · **Command:** `make failure_domain`

Eight registered weaknesses across six test scenarios.

| ID | Severity | Category | Finding |
|----|----------|----------|---------|
| **W01-CANCEL-CODEWORD** | HIGH | B (QAT) | Real-valued zero not preserved in event counter |
| **W01-CANCEL-DRIFT** | MED | B (QAT) | Integer codeword sum compounds over paired sequences |
| **W02-EXP-FLOOR-LOCK** | HIGH | A (HW) | Floor collapse under chaos feedback loop |
| **W03-E0-UF-DENSITY** | HIGH | C (structural) | High UF rate on E=0 tiny MUL bands |
| **W03-RESOLUTION-COLLAPSE** | HIGH | B (QAT) | Tiny activations indistinguishable from noise floor |
| **W04-SAT-FREQUENCY** | MED | C (structural) | Saturation under 20% spike injection (by design) |
| **W05-FLOOR-AMBIGUITY** | **CRITICAL** | A (HW) | **33% ambiguity** — `RESULT=0x000` with **UF=0** when multiplying floor sentinel |
| **W06-SAT-APPROACH** | HIGH | C (structural) | Saturation domain in long-horizon mixed injection |

**Portfolio estimate:**

| Fix locus | Share of failure modes |
|-----------|------------------------|
| Hardware (A) | ~15–20% |
| Compiler/QAT (B) | ~45–55% |
| Structural / accept (C) | ~30–40% |

**Finding:** The majority of observed behavior is **compensatable in software** — consistent
with the Composition Geometry thesis.

---

### 3.6 TEST 9 — Cancellation Residual Structure

**Testbench:** `tb/tb_horus_cancel_analysis.v` · **Command:** `make cancel_analysis`  
**Classification:** **A — Structured Signal**

| Subtest | Stimulus | Result |
|---------|----------|--------|
| **9A** | 5 fixed `y` × 50 repeats; `MUL(x,y)+MUL(x,-y)` | **std = 0.0** per `y`; deterministic bias (5632–8704) |
| **9B** | 100 pairs, fixed `y=0x600`, random order | Order shift **0.0** — pair addition commutative |
| **9C** | 1000 random-`y` cancel pairs | **\|r\|(y, \|residual\|) = 1.0**; **\|r\|(E, residual) = 0.999** |
| **9D** | Bucket predictability (E,f → mean residual) | **739 buckets**; prediction error **0.0**; **100% improvement** |

**Key question answered:** Residuals converge to a **predictable bias**, not algebraic zero.

**Recommended action:** Exploit — per-(E,f) or per-`y` bias correction in compiler/QAT.

---

### 3.7 TEST 10 — Multi-Operation Composition Stress

**Testbench:** `tb/tb_horus_composition_analysis.v` · **Command:** `make composition_analysis`  
**Classification:** **B — Partially Stable**

#### 10A — Short Chain Stability (depth = 4)

Fixed sequence: `MUL(x,y) → ADD(·,x) → MUL(·,-y) → SUB(·,x)`

| Metric | Value |
|--------|-------|
| Max std across y buckets | **0.0** |
| \|corr(E, residual)\| | **0.991** |
| Bucket prediction error | **0.0** |
| Unique residuals (200 cycles) | **153** |
| `pe_acc` drift (cycle 0→199) | +307,465 (linear integer sum) |

**Finding:** Test 9 bias-table model **extends to depth-4 composition** when operator order is fixed.

#### 10B — Operator Order Perturbation

Three permutation geometries on the same operand pool:

| Perm | Sequence | Mean residual | Variance |
|------|----------|--------------:|---------:|
| 0 | MUL → ADD → MUL → SUB | 5,051 | 737,749 |
| 1 | ADD → MUL → SUB → MUL | 5,525 | 173,021 |
| 2 | SUB → MUL → ADD → MUL | 5,383 | 198,020 |

**Permutation spread: 473.8 codeword units** — ordering changes residual distribution.

**Finding:** A single global cancel table is **invalid across permutations**. Each sequence
defines a distinct **Permutation Geometry**.

#### 10C — Deep Composition Chain (depth = 30)

Inner loop (×10): `MUL(state,y) → ADD(state,x) → SUB(state,y)`

| Metric | Value |
|--------|-------|
| Cycles ending at floor (`0x000`) | **83 / 100** |
| Inner-iteration floor events | **633** |
| UF flags | **83** |
| Residual range | 0 – 3,968 (bounded, not exponential) |
| Bucket prediction improvement | **100%** |

**Finding:** Deep chains enter a **deterministic floor regime**. Residuals remain learnable;
they are not chaotic. Floor output is a **regime-stable attractor**, not an error event.

#### 10D — Residual Model Breakpoint (1000 mixed compositions)

| Subset | n | Bucket pred. error | \|corr(E, r)\| |
|--------|--:|-------------------:|---------------:|
| Shallow (depth=4, mixed perm) | 500 | 43.1 | 0.880 |
| Deep (depth=30) | 500 | **0.0** | 0.682 |
| Full mix | 1000 | 675.5 | — (76% improvement) |

**Finding:** Shallow error rises when permutations share one table. Deep chains require a
**separate floor-regime table**. Model persistence: **Yes**, with context partitioning.

---

## 4. Cross-Test Synthesis

```
                    ┌─────────────────────────────────────┐
                    │   Horus Error Geometry (v3)         │
                    └─────────────────────────────────────┘
                                      │
          ┌───────────────────────────┼───────────────────────────┐
          ▼                           ▼                           ▼
   Cancellation pairs          Shallow composition          Deep composition
   (Test 9, Cat A)             (Test 10A, depth≤4)           (Test 10C, depth≥30)
   ─────────────────           ───────────────────           ───────────────────
   Commutative pairs           Sequence-fixed bias           Floor attractor 0x000
   (E,f) table exact           (E,f) table exact             (E,f) → 0 deterministic
   Exploit globally            Exploit per-sequence          Treat as regime constant
```

| Question | Answer |
|----------|--------|
| Is error random? | **No** — zero variance on repeat, perfect bucket determinism |
| Does Test 9 model survive composition? | **Yes** at depth ≤ 4 with fixed order; **No** as a single global table |
| When does the model break? | Not unpredictably — it **partitions** into permutation-specific and depth-specific regimes |
| Is floor output an error? | **No** — it is **Regime-Stable** (83% deterministic at depth 30) |
| Primary software action? | Context-aware bias tables + depth bounding |
| Primary hardware gap? | W05 floor ambiguity (33%); v4 SRS for accum normalize |

---

## 5. Compiler / QAT Implementation Guide

### 5.1 Core Principle

**Do not assume float semantics in `pe_accum`.** Every fused operator sequence the compiler
emits must be mapped to a known **Permutation Geometry** with its own bias surface.

### 5.2 Context-Aware Bias Tables

Implement a two-level lookup:

```
bias = BIAS_TABLE[sequence_id][E(y)][f(y)]
```

| `sequence_id` | Canonical sequence | Source |
|---------------|-------------------|--------|
| `CANCEL_PAIR` | `MUL(x,y) + MUL(x,-y)` | Test 9 |
| `PERM_0` | `MUL → ADD → MUL → SUB` | Test 10B perm 0 |
| `PERM_1` | `ADD → MUL → SUB → MUL` | Test 10B perm 1 |
| `PERM_2` | `SUB → MUL → ADD → MUL` | Test 10B perm 2 |
| `DEEP_FLOOR` | 10× `(MUL → ADD → SUB)` | Test 10C floor regime |

**Rules:**

1. **Never share** a Test 9 cancel table across permutations — Test 10B spread = 473.8 proves
   distinct geometries.
2. **Key tables by `(sequence_id, E, f)`**, not by `y` alone, unless `y` is compile-time constant.
3. **Precompute tables offline** via `make cancel_analysis` and `make composition_analysis`;
   embed as constexpr LUTs in the inference runtime.
4. At graph-compile time, **assign `sequence_id`** to each fused MAC subgraph from its operator
   schedule — do not infer at runtime.

### 5.3 Depth Policy

| Depth | Policy |
|-------|--------|
| **≤ 4 ops** | Full bias correction via permutation-specific (E,f) table |
| **5–29 ops** | Insert rescaling or `accum_clr` between tiles; re-verify bias table applicability |
| **≥ 30 ops** | Assume **floor-regime attractor** unless proven otherwise by re-simulation |

When depth exceeds 4, prefer **tile-boundary normalization** (v4 SRS target) over extending
a shallow-chain table.

### 5.4 Regime-Stable Floor Outputs

**Critical guidance:** Deep-chain outputs of `13'h000` with asserted or expected underflow are
**Regime-Stable deterministic constants**, not errors to be corrected stochastically.

| Property | Implication for QAT |
|----------|---------------------|
| 83/100 deep chains end at `0x000` | Quantization-aware training must **expect** floor saturation |
| Bucket prediction error = 0.0 in deep regime | LUT entry is **exactly zero** — no noise model needed |
| 633 inner floor events | Intermediate states may floor before final output; log `underflow_flag` for telemetry only |

**Do:**

- Treat `DEEP_FLOOR → 0x000` as a named quantization level in the training graph
- Shape activation distributions to avoid unintended deep-chain composition (Tests 3, 5, 6 in failure domain)
- Use `underflow_flag` as a **regime marker**, not a retry trigger

**Do not:**

- Apply Gaussian noise models to floor outputs
- Assume `pe_accum` partial sums approximate ℝ
- Retry or re-execute MAC on floor — result is deterministic

### 5.5 Accumulator Discipline

From failure-domain and HBS findings:

1. **`pe_accum` is integer codeword sum** — periodic normalize or tile-boundary clear (v4 SRS)
2. **Avoid E=0 operand bands** for tiny activations (W03-E0-UF-DENSITY)
3. **Distinguish floor sentinel from true zero** — W05-FLOOR-AMBIGUITY (33% `UF=0` on `0x000`)
   requires sticky underflow latch or host-side sentinel tracking until v4 HW fix
4. **Monitor `exp_ovf_flag`** under spike injection; saturation is structural, not bug (W04, W06)

### 5.6 Recommended QAT Workflow

```
1. Extract fused MAC sequences from model graph
2. Assign sequence_id per subgraph (§5.2)
3. Simulate or LUT-load bias tables from Test 9/10 CSVs
4. Inject bias correction before accum readback
5. Bound composition depth ≤ 4 per tile, or switch to DEEP_FLOOR regime table
6. Train with floor and saturation as named quantization levels, not noise
7. Validate with make cancel_analysis && make composition_analysis in CI
```

---

## 6. Reproduction

```bash
# Full RTL regression
make test                                    # 26/26 PASS

# Fidelity vs FP64
make fidelity                                # 1% @ cycle 278; sat @ 384

# Stability and failure mapping
make hbs_stability                           # HBS 6-test suite
make failure_domain                          # 8-weakness map

# Composition geometry (this document)
make cancel_analysis                         # TEST 9  → TEST_09_SUMMARY.log
make composition_analysis                    # TEST 10 → TEST_10_SUMMARY.log
```

**Artifacts:**

| Output | Path |
|--------|------|
| Cancellation CSV | `sim/cancel_analysis.csv` |
| Composition CSV | `sim/composition_analysis.csv` |
| Test 9 summary | `sim/TEST_09_SUMMARY.log` |
| Test 10 summary | `sim/TEST_10_SUMMARY.log` |
| HBS logs | `sim/HBS_CORE_TEST_01..06_*.log` |
| Weakness map | `sim/HORUS_WEAKNESS_MAP.log` |
| Fidelity plots | `sim/fidelity_plot.png`, `sim/fidelity_error_plot.png` |

---

## 7. Status and Roadmap

| Item | Status |
|------|--------|
| Composition geometry (Tests 9–10) | **Verified** — stable in shallow chains; deterministic in deep regime |
| Cancellation bias (Test 9) | **Category A** — exploit |
| Composition stress (Test 10) | **Category B** — constrain depth; per-sequence tables |
| Floor ambiguity (W05) | **Open** — v4 sticky underflow latch |
| Accum normalize (W01-DRIFT) | **v4 target** — SRS on `accum_out` |

---

*Horus NFE · Composition Geometry Reference · v3 (Bias-32)*

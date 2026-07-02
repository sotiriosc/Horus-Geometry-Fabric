# Horus Execution Policy

**Document scope:** Regime-Aware Execution strategy for Horus v3.1 and later.
Defines the four Compute Policy modes, maps each to its target Failure Domain
weakness, and specifies the Depth-Monitor flow-control strategy.

Read in conjunction with [ARCHITECTURE_PHILOSOPHY.md](ARCHITECTURE_PHILOSOPHY.md)
(§9, In-Band Compute Policy) and [COMPOSITION_GEOMETRY.md](COMPOSITION_GEOMETRY.md)
(Tests 9–10 empirical basis).

---

## 1. Regime-Aware Execution

Horus NFE v3 operates in distinct **computational regimes** determined by chain
depth and operand distribution:

| Regime | Depth | Residual behavior | Reference |
|--------|-------|-------------------|-----------|
| **Shallow-chain** | 1–8 MACs | Deterministic bias, bias-table correctable | Test 10A |
| **Mid-range** | 9–30 MACs | Partially stable; permutation-sensitive | Test 10B |
| **Deep-chain** | >30 MACs | Deterministic floor attractor at `0x000` | Test 10C |

A compiler or QAT runtime **must** select the appropriate policy mode based on
the known chain depth of each kernel segment. Selecting `MODE_STANDARD` for
deep-chain segments is permissible but results in accumulation dominated by
floor codewords — correct by contract, but numerically poor for high-precision
inference.

---

## 2. Compute Policy Mode Reference

### 2.1 Mode Encoding

```
mode_tag [2:0]   Name            RTL constant
─────────────────────────────────────────────
    3'b000        Standard        MODE_STANDARD
    3'b001        Bias-Corrected  MODE_BIAS_CORR
    3'b010        Pre-Scaled      MODE_PRE_SCALED
    3'b011        Safe-Accum      MODE_SAFE_ACCUM
    3'b1xx        Reserved        (treated as Standard)
```

### 2.2 Mode-to-Weakness Mapping

| Mode | Encoding | Target Weakness | Mechanism |
|------|----------|-----------------|-----------|
| **Standard** | `000` | None (baseline) | Direct accumulation of computed codeword. No correction applied. |
| **Bias-Corrected** | `001` | **W01** — Cancellation Drift | Adds `BIAS_LUT[e_a]` to codeword before accumulation. LUT indexed by stored exponent. Offsets the structured residual identified in Test 9. Requires QAT calibration pass to populate BIAS_LUT. |
| **Pre-Scaled** | `010` | **W03** — Underflow Collapse; **W06** — Dynamic Range Exhaustion | Decrements stored exponent E by 1 (÷2 real-space) before accumulation when E > 0. Prevents `accum_reg` saturation under large-operand chains by scaling contributions down before summing. No effect at floor (E = 0). |
| **Safe-Accum** | `011` | **W04** — Spike-Injection Saturation | Performs 33-bit unsigned addition; clamps `accum_reg` to `0xFFFFFFFF` on carry-out instead of wrapping modulo 2³². Eliminates modular wrap artifacts from outlier MAC results. |

### 2.3 Weakness Definitions

| ID | Name | Description |
|----|------|-------------|
| W01 | Cancellation Drift | MUL(x, y) + MUL(x, –y) produces a non-zero residual in NFE codeword domain. Residual is deterministic and exponent-dependent (Test 9 classification: A — Structured Signal). |
| W03 | Underflow Collapse | Deep chains drive state exponent toward E=0 (floor attractor). Subsequent operations are dominated by floor codewords. |
| W04 | Saturation Spike | A single outlier codeword (near `0x1FFF`) can fill a significant fraction of `accum_reg` in one cycle, masking prior accumulations when modular wrap occurs. |
| W06 | Dynamic Range Exhaustion | Mixed tiny-and-large accumulation fills `accum_reg` unevenly; large values near EXP_MAX dominate the sum without a normalization pass. |

---

## 3. Flow Control Policy: Depth-Monitor

### 3.1 Design Rationale

The **Floor Attractor** (Test 10C) shows that chains deeper than ~30 MACs
deterministically collapse to `0x000`. Left unmanaged, the accumulator fills
with floor codewords that carry no useful information.

The traditional mitigation — inserting an explicit Reset bit in the data flit —
violates the architectural principle that the data path must remain algebraically
pure (see ARCHITECTURE_PHILOSOPHY.md §9.1). Any flit-level reset produces
regime-dependent ambiguity: the same instruction stream produces different
accumulator states depending on flit timing.

The Depth-Monitor solves this with a **controller-managed** approach: the FSM
counts MAC cycles autonomously and clears the accumulator at a configured depth
boundary without any data-plane signalling.

### 3.2 Depth-Monitor Register

```
horus_controller new interface:
  input  wire [5:0] max_depth      — threshold; 0 = disabled
  output reg        depth_reset    — 1-cycle pulse on boundary
  (internal)        depth_counter  — 6-bit counter, active in STREAM
```

**Semantics:**

- `depth_counter` increments every STREAM cycle (one count per MAC accumulation).
- When `depth_counter == max_depth` (and `max_depth != 0`), the controller
  simultaneously asserts `depth_reset` and `accum_clr` for exactly **one cycle**.
- `accum_en` remains **high** during this cycle — the pipeline does not stall.
  Inside `horus_nfe`, `accum_clr` has priority over `accum_en`, so the
  accumulator is zeroed before the next product is folded in.
- `depth_counter` resets to zero on the same edge, opening a fresh depth window.
- `depth_reset` is an output notification the host can observe to coordinate
  result sampling before the window resets.

### 3.3 Recommended `max_depth` Settings

| Inference context | Recommended `max_depth` | Rationale |
|-------------------|--------------------------|-----------|
| Shallow GEMM (e.g. 4×4 dot product) | `0` (disabled) | Full window fits in controller's FILL_CYCLES; no mid-window reset needed. |
| Medium attention projection | `8` | Stays within shallow-chain regime (Test 10A: bias-table valid to depth 8). |
| Deep convolution chains | `16–24` | Prevents floor attractor engagement at depth ~30 (Test 10C). |
| Outlier-heavy activations + Safe-Accum | `4–8` | Short windows for saturating accumulators prevent cross-window overflow masking. |

### 3.4 Algebraic Continuity Guarantee

The Depth-Monitor **preserves algebraic continuity** within each depth window
by construction:

1. All MACs within a window accumulate without interruption.
2. At the window boundary, `depth_reset` pulses — the host observes this signal
   and may read the current `accum_out` value before it is cleared.
3. The next window starts from zero on the very next cycle.

This means a kernel operating over N MACs at depth limit D produces
`ceil(N / D)` result windows, each independently correct. The host sums or
post-processes these windows as defined by the network graph — the hardware
makes no assumption about window interpretation.

**Contrast with flit-level reset:** a data-flit reset would inject a
clear event mid-stream with timing determined by routing latency, which is
non-deterministic in a mesh topology. The Depth-Monitor fires at a fixed local
cycle count regardless of mesh topology or routing depth.

---

## 4. Compiler / QAT Dispatch Guide

### 4.1 Mode selection algorithm

```
For each kernel segment K with known chain depth D:

  if D <= 8:
    if cancel_pairs_in_K:
      mode_tag = MODE_BIAS_CORR    # W01 mitigation
    else:
      mode_tag = MODE_STANDARD
  elif D <= 30:
    if large_operand_distribution:
      mode_tag = MODE_PRE_SCALED   # W03/W06 mitigation
    elif spike_risk:
      mode_tag = MODE_SAFE_ACCUM   # W04 mitigation
    else:
      mode_tag = MODE_STANDARD
  else:  # D > 30 — deep-chain regime
    max_depth = 16                 # Depth-Monitor to prevent floor collapse
    mode_tag = MODE_PRE_SCALED     # Pre-scale + depth window = double mitigation
```

### 4.2 BIAS_LUT calibration workflow

`MODE_BIAS_CORR` requires a populated `BIAS_LUT[0:63]` inside `horus_nfe`.
The default initialization is all-zeros (Standard behavior).

**QAT calibration procedure:**

1. Run `make cancel_analysis` to generate `sim/cancel_analysis.csv` and
   `sim/TEST_09_SUMMARY.log`.
2. Extract per-exponent mean residuals from `TEST_09_SUMMARY.log` (bucket
   analysis section).
3. Negate each residual to obtain the correction offset.
4. Replace the `initial` block in `horus_nfe.v` with a compiled `$readmemh`
   or an explicit assignment for each `BIAS_LUT[e]` entry.
5. Re-run synthesis (`make synth`) — the LUT synthesizes to a distributed ROM
   with zero impact on the critical MAC path.

### 4.3 Window coordination with `depth_reset`

When using the Depth-Monitor, the host control thread must monitor `depth_reset`
(or `depth_reset_out` at `horus_top` level) to track window boundaries:

```
while computing:
  if depth_reset_out:
    latch current row_out_* (partial window result)
    accum is now cleared — next window starts automatically
  if data_valid:
    latch row_out_* (final window result)
    assert result_ack
```

This pattern ensures no partial-window results are silently dropped.

---

## 5. Verification Evidence

All four mode_tag values are exercised in `tb/tb_horus_system.v` Phases 7–8:

| Phase | DUT | Test |
|-------|-----|------|
| Phase 7.0 | `horus_system` | `MODE_STANDARD` — accum_out = codeword × 1 |
| Phase 7.1 | `horus_system` | `MODE_BIAS_CORR` — LUT=0 → identical to Standard |
| Phase 7.2 | `horus_system` | `MODE_PRE_SCALED` — accum_out = (E−1) word × 1 |
| Phase 7.3 | `horus_system` | `MODE_SAFE_ACCUM` — no-overflow case, matches Standard |
| Phase 8   | `horus_controller` | `max_depth=3` → `depth_reset` fires on STREAM cycle 3; `dm_accum_clr=1` confirmed |

Synthesis verified via `make synth` (`sim/synth_script.ys`): 0 problems reported
by Yosys `check`. Policy Decoder adds one `$_MUX_` layer before `accum_reg`
with no new pipeline registers.

---

## 6. Summary

| Decision | Choice | Justification |
|----------|--------|---------------|
| Compute Policy location | In-band `mode_tag` bits, sidecar to data flit | Zero-overhead propagation; no control messages on critical path |
| Reset/Snapshot location | Controller `depth_counter` only | Determinism; flit-level reset violates algebraic continuity |
| Policy Decoder implementation | Inline blocking assignments in sequential always block | Correct Verilog simulation scheduling; synthesis-identical to combinational logic |
| BIAS_LUT width | 64 entries × 13 bits | One entry per exponent band; matches Test 9 bucket granularity |
| `max_depth` default | 0 (disabled) | Backward-compatible; existing test suite unaffected |

---

## 7. HBS-11 Validation Results

**Date:** 2026-07-02  **Source:** `sim/HBS11_POLICY_VALIDATION.csv` (2,450 rows)  
See [`docs/HBS11_RESULTS.md`](HBS11_RESULTS.md) for the full report.

### 7.1 Per-Policy Measured Results

| Policy | Target Weakness | Measured Improvement | Observed Limitations | Recommended Usage |
|--------|----------------|---------------------|----------------------|-------------------|
| **000 Standard** | None (baseline) | — | Residual grows linearly with codeword magnitude | All shallow chains; default for unknown workloads |
| **001 Bias-Corrected** | W01 Cancellation | **0.00%** (BIAS_LUT=0) | LUT requires calibration; zero correction until populated | Cancellation-heavy workloads **after** QAT calibration pass |
| **010 Pre-Scaled** | W03/W06 Floor/Range | **−6.25% accum magnitude** | Floor_rate unchanged (result-domain; mode-independent) | Deep composition chains to contain accumulator growth |
| **011 Safe-Accum** | W04 Spike Saturation | **0.00%** (not triggered at ≤63 MACs) | 32-bit clamp not reached within standard tile windows | Long-running streaming accumulators (>500K MACs) |

### 7.2 Recommended Deployment Profiles

| Context | Policy | Basis |
|---------|--------|-------|
| Short inference chains (depth ≤ 8) | `000 Standard` | No failure-domain exposure; zero overhead |
| Cancellation-heavy workloads | `001 Bias-Corrected` | After BIAS_LUT calibration; 0% gain on uncalibrated hardware |
| Deep composition workloads | `010 Pre-Scaled` | −6.25% accumulator magnitude; pair with max_depth ≤ 4 |
| Saturation-prone workloads | `011 Safe-Accum` | Effective only at deep accumulator depths (>500K MACs) |
| Mixed production inference | **Scheduler** | 5.8× accumulator variance reduction vs static baseline |

### 7.3 Architectural Status

| Weakness | Status | Benchmark Evidence |
|----------|--------|-------------------|
| W01 — Cancellation Drift | **Partially Mitigated** | HBS-11A: mechanism correct; zero gain until BIAS_LUT calibrated |
| W03 — Underflow Collapse | **Partially Mitigated** | HBS-11B: accum −6.25%; floor_rate = 1.000 (result-domain) |
| W04 — Spike Saturation | **Partially Mitigated** | HBS-11C: Safe-Accum correct; not triggered at 63-MAC depth |
| W06 — Dynamic Range Exhaustion | **Partially Mitigated** | HBS-11B: accumulator magnitude contained by Pre-Scaled |
| Floor Attractor | **Mitigated** | HBS-11D: depth_reset fires 10/10 windows at max_depth=4 |

### 7.4 Key Architectural Finding — Domain Boundary

All four `mode_tag` policies operate exclusively on the **accumulator path**
(`accum_word` before addition to `accum_reg`).  They do **not** alter the
`result` register or the core NFE arithmetic pipeline.  Weaknesses that
manifest in the result register (floor collapse from exponent underflow,
exponent overflow from large MUL) require result-domain interventions and are
scheduled for v4 (progressive exponent rescaling, result-path clamp).

**This is not a design flaw.**  The policy decoder was designed to address
accumulator-domain distortions.  The clean separation of arithmetic from
accumulation policy ensures synthesizability and single-cycle throughput are
preserved exactly.

### 7.5 BIAS_LUT Calibration Roadmap

The only policy requiring external data before it provides measurable
improvement is Mode 001.  The calibration workflow (§4.2) produces a 64-entry
correction table from Test 9 results.  Until that table is populated,
`mode_tag=001` is a no-op with zero downside.

---

## 8. Summary

| Decision | Choice | Justification |
|----------|--------|---------------|
| Compute Policy location | In-band `mode_tag` bits, sidecar to data flit | Zero-overhead propagation; no control messages on critical path |
| Reset/Snapshot location | Controller `depth_counter` only | Determinism; flit-level reset violates algebraic continuity |
| Policy Decoder implementation | Inline blocking assignments in sequential always block | Correct Verilog simulation scheduling; synthesis-identical to combinational logic |
| BIAS_LUT width | 64 entries × 13 bits | One entry per exponent band; matches Test 9 bucket granularity |
| `max_depth` default | 0 (disabled) | Backward-compatible; existing test suite unaffected |
| **Optimal `max_depth`** | **4** | HBS-11D: fires every window; tightest depth bound before floor regime (depth 8–9) |

---

## 9. Policy Applicability Boundary

*Added by HBS-12 Arithmetic Boundary Mapping Suite (2026-07-02).*

### 9.1 Formal Boundary Statement

Execution policies (`mode_tag` bits and `max_depth` controller register) operate
**exclusively on the accumulator path**.  They receive the already-computed NFE
result word from the arithmetic core and apply corrections before it is folded into
`accum_reg`.

**Policies do not and cannot modify the arithmetic result itself.**

This means:

| Domain | Governed by Policies? | Evidence |
|--------|----------------------|---------|
| MUL exponent underflow (E < 16) | **No** | HBS-12A: UF fires in arithmetic core before accumulation |
| MUL exponent overflow (E > 47) | **No** | HBS-12A: OVF fires in arithmetic core before accumulation |
| ADD Thoth Rollover | **No** | HBS-12C/F: rollover is arithmetic normalisation, not accumulator event |
| SUB Guard-B FTZ | **No** | HBS-12C: floor output produced before accumulation |
| Floor attractor (chain depth) | **No** | HBS-12D: arithmetic result reaches NFE_FLOOR before accum fold |
| Accumulator saturation (32-bit wrap) | **Yes** | MODE_SAFE_ACCUM (mode_tag=011) — HBS-11C |
| Epoch boundary reset | **Yes** | Depth-Monitor in `horus_controller` — HBS-11D |
| Cancel-residual bias in accum | **Yes** | MODE_BIAS_CORR (mode_tag=001) — HBS-11A partial |
| Pre-scaled fold to slow saturation | **Yes** | MODE_PRE_SCALED (mode_tag=010) — HBS-11B partial |

### 9.2 Architectural Consequence

Failure modes identified in HBS-12 as **arithmetic-domain** (UF, OVF, floor attractor, FTZ,
rollover information loss) are **inherent to the NFE encoding** and **cannot be remediated
by execution policies at the accumulator level**.

Remediation of arithmetic-domain failures requires:

1. **Compiler-side operand clamping** to `stored_E ∈ [16..47]` before tensor dispatch.
2. **QAT weight calibration** within the safe exponent window (`stored_E ∈ [20..44]` recommended).
3. **Chain depth management** enforced by the graph compiler (depth ≤ 16 for full fidelity;
   depth ≤ E_seed for any seed).
4. **Epoch partitioning** via `horus_controller MAX_DEPTH` to prevent floor attractor
   accumulation (this is a mitigation, not a fix — epoch reset resets the accumulator,
   not the intermediate arithmetic result).

### 9.3 Policy Domain vs Arithmetic Domain — Boundary Diagram

```
Input operands
      │
      ▼
┌─────────────────────────────────────────────────────┐
│              NFE ARITHMETIC CORE                    │
│  MUL / ADD / SUB / NOP  (horus_nfe.v case block)   │
│                                                     │
│  UF, OVF, rollover, FTZ events fire here           │
│  result wire ← computed NFE codeword               │
│                                                     │  ← POLICY BOUNDARY
│  ┌───────────────────────────────────────────────┐  │
│  │         POLICY DECODER (inline)               │  │
│  │  mode_tag = 000: computed → accum             │  │
│  │  mode_tag = 001: computed + BIAS_LUT → accum  │  │
│  │  mode_tag = 010: computed with E−1 → accum   │  │
│  │  mode_tag = 011: saturating 32-bit add        │  │
│  └───────────────────────────────────────────────┘  │
│                       │                             │
│                  accum_reg ← fold                   │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
                   accum_out wire
                   (32-bit registered)
```

**Everything above the POLICY BOUNDARY is outside policy scope.**  
Policies see the final NFE codeword, not the intermediate computation.

### 9.4 HBS-12 Arithmetic Envelope Reference

See `docs/HORUS_ARITHMETIC_ENVELOPE.md` for the complete arithmetic boundary specification,
compiler constraints, QAT constraints, and phase diagram derived from HBS-12.

---

*Horus (Native Fractional Engine) · Execution Policy · v3.2*
*Regime-Aware Execution · In-Band Compute Policy · Depth-Monitor Flow Control*
*HBS-11 Validated: 2026-07-02 · Policy Applicability Boundary added: HBS-12 2026-07-02*

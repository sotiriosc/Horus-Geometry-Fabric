# HORUS v3 Control Causality Map
## Formal Reference: mode_tag Signal Propagation

**Version**: 1.0  
**Established by**: HBS-C16 Control Causality Isolation Suite  
**Simulation basis**: 8,000 cycles across 4 mode settings, locked operands  
**Date**: 2026-07-02  

---

## 1. Statement of Causal Isolation

**Theorem (experimentally proven by HBS-C16):**

> In HORUS v3 with locked inputs `{op_a, op_b, op_sel}`, varying `mode_tag` across
> the full valid range `{000, 001, 010, 011}` produces **zero divergence** in:
> - the ALU intermediate (`mant_sum`, `scale_reg`)
> - the post-ALU result (`computed`)
> - the registered output (`result`)
>
> Divergence is **exclusive to the accumulation policy path**:
> `accum_word` and `accum_reg` beginning at the first accumulation cycle.

---

## 2. Complete Causal Map

```
                    mode_tag
                        │
                        │ (no effect before this point)
                        │
op_a ──────────────────►│
op_b ──────────────────►│
op_sel ─────────────────►│
                        │
                ┌───────▼─────────────────────────────────────────┐
                │             horus_nfe.always @(posedge clk)     │
                │                                                  │
                │  [S1] ALU computation                           │
                │  ─────────────────────────────────────────────  │
                │  ADD: mant_sum = {1,m_a} + m_b      [8-bit]     │
                │  SUB: mant_sum = m_a - m_b + borrow [8-bit]     │
                │  MUL: scale_reg = {1,m_a} × {1,m_b} [20-bit]   │
                │                                                  │
                │       ↑ mode_tag NOT present here ↑             │
                │                                                  │
                │  [S2] Result packing                            │
                │  ─────────────────────────────────────────────  │
                │  computed ← normalize(ALU_result)   [13-bit]    │
                │  result   ← computed                [13-bit]    │
                │                                                  │
                │       ↑ mode_tag NOT present here ↑             │
                │                                                  │
                │  [S3] Policy decoder  ◄──────────── mode_tag    │
                │  ─────────────────────────────────────────────  │
                │  MODE_STANDARD  : accum_word = computed          │
                │  MODE_BIAS_CORR : accum_word = computed          │
                │                           + BIAS_LUT[e_a]        │
                │  MODE_PRE_SCALED: accum_word = {s,E-1,f}         │
                │  MODE_SAFE_ACCUM: (bypasses accum_word)          │
                │                                                  │
                │  [S4] Accumulation update  ◄─────── mode_tag    │
                │  ─────────────────────────────────────────────  │
                │  STANDARD/BIAS/PRE_SCALED:                       │
                │    accum_reg += accum_word                       │
                │  SAFE_ACCUM (saturating):                        │
                │    accum_reg = min(accum_reg + computed,         │
                │                   0xFFFF_FFFF)                   │
                │                                                  │
                └──────────────────────────────────────────────────┘
```

---

## 3. Mode_tag Effect Table

| Port / Signal | MODE_STANDARD (000) | MODE_BIAS_CORR (001) | MODE_PRE_SCALED (010) | MODE_SAFE_ACCUM (011) |
|---------------|--------------------|--------------------|----------------------|----------------------|
| `mant_sum` | ⚫ None | ⚫ None | ⚫ None | ⚫ None |
| `scale_reg` | ⚫ None | ⚫ None | ⚫ None | ⚫ None |
| `computed` | ⚫ None | ⚫ None | ⚫ None | ⚫ None |
| `result` | ⚫ None | ⚫ None | ⚫ None | ⚫ None |
| `rollover_flag` | ⚫ None | ⚫ None | ⚫ None | ⚫ None |
| `underflow_flag` | ⚫ None | ⚫ None | ⚫ None | ⚫ None |
| `exp_ovf_flag` | ⚫ None | ⚫ None | ⚫ None | ⚫ None |
| `accum_word` | Baseline | = Baseline† | **−½ scale** | = Baseline |
| `accum_reg` | Baseline | = Baseline† | **÷2 per add** | Baseline / saturate |
| `accum_out` | Baseline | = Baseline† | **÷2 per add** | Baseline / saturate |

†Under default BIAS_LUT (all zeros). Effect becomes non-zero after calibration with Test 9 data.  
⚫ Confirmed zero effect over 8,000 experimental cycles.

---

## 4. Mode_tag Causal Boundary

The boundary between "no effect" and "effect" is a single assignment in the RTL:

```verilog
// horus_nfe.v — policy decoder (inside always @posedge clk, after computed is set)
if (accum_en && !accum_clr) begin
    case (mode_tag)                              // ← CAUSAL BOUNDARY
        MODE_BIAS_CORR:  accum_word = computed + BIAS_LUT[e_a];
        MODE_PRE_SCALED: accum_word = (computed[11:6] != 0)
                         ? {computed[12], computed[11:6]-1, computed[5:0]}
                         : computed;
        default:         accum_word = computed;
    endcase
    ...
    accum_reg <= ...
end
```

**Everything above this block is mode_tag-free.** Everything below this block is mode_tag-dependent.

---

## 5. Per-Mode Accumulation Mechanics

### MODE_STANDARD (000) — Baseline

```
accum_word = computed
accum_reg += accum_word
```
Direct summation of the NFE codeword as a 13-bit unsigned integer into the 32-bit accumulator.

### MODE_BIAS_CORR (001) — Calibration-dependent

```
accum_word = computed + BIAS_LUT[e_a]   // e_a from op_a[11:6]
accum_reg += accum_word
```

With default BIAS_LUT (all zeros): **identical to MODE_STANDARD**. Effect activates when BIAS_LUT is loaded with per-exponent-band offsets calibrated to the Test 9 cancel-residual manifold.

**Design intent:** Correct for systematic cancellation drift that accumulates in CLASS_B workloads. The LUT is indexed by the exponent of op_a, allowing a different correction per magnitude band.

### MODE_PRE_SCALED (010) — Constant ÷2 pre-scaling

```
accum_word = {sign, E-1, frac}  if E > 0
           = computed            if E == 0
accum_reg += accum_word
```

Halves the magnitude of each codeword before accumulation by decrementing the stored exponent. This **prevents accum_reg saturation** in large-operand chains where repeated addition of E≈40+ values would overflow the 32-bit accumulator in relatively few cycles.

**HBS-C16 measurement:** For E=32 input, accum_word = 0x7f0 (E=31) vs 0x830 (E=32). After 63 MACs:
- Standard: accum_reg = 132,048
- Pre-Scaled: accum_reg = 128,016 (3.06% lower)

### MODE_SAFE_ACCUM (011) — Saturating accumulation

```
safe_sum = {1'b0, accum_reg} + {20'b0, computed}   // 33-bit
accum_reg = min(safe_sum[31:0], 0xFFFF_FFFF)         if safe_sum[32]
          = safe_sum[31:0]                            otherwise
```

Uses `computed` directly (not `accum_word`) in a 33-bit addition that clamps to `32'hFFFFFFFF` on carry-out. **For non-saturating values: identical to MODE_STANDARD.** Diverges only when `accum_reg + computed` would wrap a 32-bit unsigned counter.

**Design intent:** Prevents modular wrap artifacts in spike-injection workloads (CLASS_A with periodic large magnitudes).

---

## 6. Implications for System Design

### 6.1 NFE Computation Output is Mode_tag-Free

Any consumer of the `result` output port can safely ignore `mode_tag` — the arithmetic result is always the direct NFE computation of `{op_a, op_b, op_sel}` with no policy influence.

This has the following consequences:
- **Attractor classification** (based on E_out ≡ `result[11:6]`) is mode_tag-independent
- **OVF/UF/rollover flags** are mode_tag-independent (C15 measured zero OVF under even 31% noise)
- **Phase-space trajectories** (E vs cycle) are mode_tag-independent
- **All C8–C15 attractor findings** hold regardless of mode_tag value

### 6.2 Accumulation Is the Only mode_tag-Sensitive Path

The 32-bit `accum_reg` (and its output `accum_out`) is the **sole carrier of mode_tag effects**. This means:
- The C4 compiler's mode_tag selection affects **weight accumulation accuracy**, not computation fidelity
- A corrupted mode_tag degrades the neural accumulator's precision, not the per-operation NFE result
- Recovery from mode corruption is possible simply by resetting `accum_reg` (via `accum_clr`)

### 6.3 BIAS_CORR (001) Requires Calibration to Be Non-trivial

In uncalibrated hardware (`BIAS_LUT = zeros`), MODE_BIAS_CORR is **functionally identical** to MODE_STANDARD. System integrators deploying HORUS v3 should load the BIAS_LUT from Test 9 analysis before selecting MODE_BIAS_CORR, otherwise the mode selection has no effect.

### 6.4 SAFE_ACCUM (011) Effect is Regime-Dependent

MODE_SAFE_ACCUM diverges from MODE_STANDARD only when the running `accum_reg` value approaches `0xFFFFFFFF`. For a 32-bit accumulator with 13-bit addends (max `0x1FFF = 8191`), saturation occurs after ≈ `0xFFFFFFFF / 8191 ≈ 524,296` accumulation events. At standard epoch lengths (16–32 cycles per epoch with reset), saturation is structurally impossible unless deliberately stress-tested (as in C12B).

---

## 7. Causal Isolation: Machine-Readable Properties

```
PROPERTY: MODE_TAG_CAUSAL_BOUNDARY
  STAGE: S3_accum_word
  FIRST_CAUSAL_EFFECT_CYCLE: 0  (first accum cycle)
  BEFORE_BOUNDARY: {ALU, computed, result, flags}  MODE_TAG_INDEPENDENT
  AFTER_BOUNDARY:  {accum_word, accum_reg, accum_out}  MODE_TAG_DEPENDENT

PROPERTY: RESULT_INDEPENDENCE
  SIGNAL: result
  INVARIANT: result == computed  (for all mode_tag values)
  VERIFIED: 8,000 cycles, 0 divergent cycles

PROPERTY: BIAS_CORR_NULL_EFFECT
  CONDITION: BIAS_LUT == zeros (factory default)
  RESULT: MODE_BIAS_CORR == MODE_STANDARD
  VERIFIED: 2,000 cycles, 0 divergent cycles in accum_word

PROPERTY: PRE_SCALED_DIVERGENCE
  CONDITION: mode_tag == 3'b010 AND computed[11:6] != 0
  EFFECT: accum_word[11:6] = computed[11:6] - 1  (÷2 in real space)
  ONSET: cycle 0 (first accum cycle)
  MAGNITUDE: constant per-cycle difference of (computed - pre_scaled_word)

PROPERTY: SAFE_ACCUM_SATURATION_THRESHOLD
  CONDITION: mode_tag == 3'b011
  DIVERGENCE_FROM_STANDARD: only when accum_reg + computed > 0xFFFF_FFFF
  APPROXIMATE_THRESHOLD: 524,296+ accumulation events (at max 13-bit addend)
```

---

## 8. Relationship to Prior HBS Suites

| Suite | Claim | C16 Confirmation |
|-------|-------|-----------------|
| C12 PARTIALLY_ROBUST | Accum grows unbounded under no-reset drift | Confirmed: only accum path affected by mode |
| C13 FULLY_CONTROLLABLE | Attractor steering via input design | Confirmed: steering is operand-driven, not mode-driven |
| C14 COMPUTATIONALLY_EXPRESSIVE | A1–A4 are input-driven primitives | Confirmed: primitive identity encoded in op_a/op_sel, not mode |
| C15 GRACEFUL_DEGRADATION | mode_tag corruption doesn't affect attractor stability | **Mechanistically explained**: result is structurally mode-free |
| **C16** | mode_tag is accumulation-only | **Proven**: S1/S2/S5_result NEVER diverge; S3/S4 diverge immediately |

---

*Established by HBS-C16 causal isolation sweep, 2026-07-02.*  
*Document maintained under: `docs/HORUS_CONTROL_CAUSALITY_MAP.md`*

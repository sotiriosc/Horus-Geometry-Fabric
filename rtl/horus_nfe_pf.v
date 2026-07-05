`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_nfe  (v3 — Biased Exponent + Implicit Leading Bit)
// Project  : Horus Engine — Native Fractional Engine
// File     : horus_nfe.v
//
// v3 adds a standard exponent bias of 32 to the Hidden-Bit architecture of v2.
// This is a zero-silicon change in the combinational decode path: the stored
// 6-bit exponent field E is interpreted as  actual_E = E − 32.
//
// ─────────────────────────────────────────────────────────────────────────────
// 13-Bit NFE Word Layout
// ─────────────────────────────────────────────────────────────────────────────
//
//   [12]   Sign S    0 = positive  /  1 = negative
//   [11:6] Exp  E    6-bit BIASED exponent.  actual_E = E − 32.
//                    Stored range 0..63 maps to actual exponent −32..+31.
//   [5:0]  Frac f    fractional part of the 1.f mantissa
//                      bit5 = 1/2   bit4 = 1/4   bit3 = 1/8
//                      bit2 = 1/16  bit1 = 1/32  bit0 = 1/64
//
//   Encoded value:  V = (−1)^S  ×  2^(E−32)  ×  (1 + f/64)
//
//   The leading '1' is IMPLICIT — hardware inserts it as bit[6] of the
//   7-bit full mantissa  {1, f[5:0]} = 64 + f.
//
//   Representable range:
//     Minimum positive:  E=0,  f=0  →  2^(−32) × 1.0  ≈ 2.33 × 10^−10
//     Maximum positive:  E=63, f=63 →  2^(+31) × 1.984375 ≈ 4.26 × 10^9
//     Value 1.0:         E=32, f=0  →  2^0 × 1.0  (exponent "1.0 point")
//
// ─────────────────────────────────────────────────────────────────────────────
// Minimum / Zero Convention
// ─────────────────────────────────────────────────────────────────────────────
//   13'h000 (all-zeros, S=0 E=0 f=0) is the architectural MINIMUM sentinel
//   and the Underflow Floor output.  It decodes to 2^−32 × 1.0.
//   The underflow_flag signals when the floor has been reached or a MUL
//   product fell below the minimum representable value.
//
// ─────────────────────────────────────────────────────────────────────────────
// Special Hardware Rules
// ─────────────────────────────────────────────────────────────────────────────
//
//   THOTH ROLLOVER  (from v2, unchanged)
//     Fires when the 7-bit adder produces a carry into bit 6  (f_a + Δ ≥ 64).
//     Complement: E ← E + 1,  f_result ← mant_sum[5:0]  (fractional remainder
//     after the carry, NOT cleared to zero as in v1).
//
//   UNDERFLOW FLOOR  (from v2, unchanged)
//     ADD: cannot underflow — result is always ≥ minimum with hidden bit.
//     SUB Guard-A (f_a ≥ Δ): fires when e_a=0 and f_result=0.
//     SUB Guard-B (f_a < Δ): fires when E=0 OR normalization shift > headroom.
//     MUL: fires when biased exp_sum wraps negative (8-bit bit 7 set).
//       Ghost-Zero structurally impossible: min product = 64² = 4096 > 0.
//
//   MUL NORMALIZATION + BIAS CORRECTION  (v3 update)
//     Product P = (64+f_a) × (64+f_b).  Range [4096, 16129] — 14 bits.
//     Biased exponent addition:
//       stored_E_result = E_a + E_b − EXP_BIAS  [+ 1 if P[13]=1]
//     This corrects for the double-bias introduced by adding two biased fields.
//     If P[13]=0 (P < 8192): hidden-1 at bit 12, f_result = P[11:6].
//     If P[13]=1 (P ≥ 8192): hidden-1 at bit 13, f_result = P[12:7].
//
//   SUB NORMALIZATION  (new)
//     After a borrow, raw = 64 + f_a − Δ ∈ [1, 63] lacks the hidden bit.
//     A priority-encoder finds shift k (1..6) such that raw<<k ∈ [64,127].
//     E_final = (E − 1) − k.  FTZ if E ≤ k.
//
// ─────────────────────────────────────────────────────────────────────────────
// op_sel Encoding
// ─────────────────────────────────────────────────────────────────────────────
//   2'b00  ADD_FRAC  f_a + Δ_b  (Δ treated as raw fraction, no hidden bit)
//   2'b01  SUB_FRAC  f_a − Δ_b  (Δ treated as raw fraction; borrow+normalise)
//   2'b10  MUL       (1.f_a) × (1.f_b)  hidden-bit multiply + normalise
//   2'b11  NOP       result ← op_a  (pass-through; no flag side-effects)
// ============================================================================

// ── Compute Policy Mode Tags ──────────────────────────────────────────────────
// These constants define the 3-bit in-band policy field (mode_tag).
// 3'b100..3'b111 are reserved and treated as MODE_STANDARD by the decoder.
// ─────────────────────────────────────────────────────────────────────────────
//   MODE_STANDARD   (3'b000) : Baseline arithmetic — current behavior unchanged.
//   MODE_BIAS_CORR  (3'b001) : Bias-Corrected accumulation.
//                              Adds a per-exponent-band correction offset (from
//                              the hardcoded BIAS_LUT) to each codeword before
//                              it is folded into accum_reg.  Targets W01/Test 9
//                              cancel-drift mitigation.
//   MODE_PRE_SCALED (3'b010) : Pre-Scaled accumulation.
//                              Decrements the stored exponent by 1 before
//                              accumulation (÷2 in real space) when the codeword
//                              exponent is non-zero.  Prevents accum_reg
//                              saturation under large-operand chains (W03/W06).
//   MODE_SAFE_ACCUM (3'b011) : Safe-Accumulation.
//                              Adds with 32-bit unsigned saturating arithmetic:
//                              accum_reg is clamped to 32'hFFFFFFFF on overflow
//                              rather than wrapping.  Targets W04 spike-injection
//                              saturation without modular wrap artifacts.
// ─────────────────────────────────────────────────────────────────────────────

module horus_nfe_pf (
    input  wire        clk,
    input  wire        rst_n,       // Active-low synchronous reset

    // ── Operands (13-bit NFE encoded) ────────────────────────────────────────
    input  wire [12:0] op_a,        // Operand A
    input  wire [12:0] op_b,        // Operand B  /  fractional delta for ADD|SUB
    input  wire [1:0]  op_sel,      // Operation select

    // ── Compute Policy (in-band, single-cycle mux path) ──────────────────────
    // Decoded combinationally in the Policy Decoder block below.
    // Drives only the accumulation path — arithmetic result is unaffected.
    input  wire [2:0]  mode_tag,    // 000=Standard 001=Bias-Corrected
                                    // 010=Pre-Scaled 011=Safe-Accum 1xx=Reserved

    // ── Neural-network accumulator control ───────────────────────────────────
    input  wire        accum_en,    // Fold current result into 32-bit accumulator
    input  wire        accum_clr,   // Synchronous clear of accumulator (priority)

    // ── Outputs ──────────────────────────────────────────────────────────────
    output reg  [12:0] result,          // NFE-encoded result (registered)
    output reg  [31:0] accum_out,       // 32-bit accumulated sum (registered)
    output reg         rollover_flag,   // 1-cycle pulse: Thoth Rollover fired
    output reg         underflow_flag,  // 1-cycle pulse: Underflow Floor fired
    output reg         exp_ovf_flag     // 1-cycle pulse: exponent saturated
);

    // =========================================================================
    // Compute Policy constants  (must match module-level comment above)
    // =========================================================================
    localparam [2:0] MODE_STANDARD   = 3'b000;
    localparam [2:0] MODE_BIAS_CORR  = 3'b001;
    localparam [2:0] MODE_PRE_SCALED = 3'b010;
    localparam [2:0] MODE_SAFE_ACCUM = 3'b011;

    // =========================================================================
    // Local constants
    // =========================================================================
    localparam NFE_W       = 13;  // Total NFE word width
    localparam EXP_W       =  6;  // Exponent field width
    localparam MANT_W      =  6;  // Fraction-field width (the 'f' in 1.f)
    localparam MANT_ADD_W  =  8;  // Mantissa adder width  (bit[7] = carry for ADD hidden-bit)
    localparam EXP_INC_W   =  7;  // Exponent incrementer  (bit[6] = overflow)
    localparam EXP_SUM_W   =  8;  // MUL exponent summer   (bits[7:6] = overflow)
    localparam SCALE_W     = 20;  // MUL intermediate product register
    localparam ACCUM_W     = 32;  // Running accumulator width

    localparam MANT_MAX    = 6'b111111;  // Maximum fraction field  (63/64 → 1.984375)
    localparam EXP_MAX     = 6'b111111;  // Maximum exponent        (stored 63 → actual +31)
    localparam EXP_BIAS    = 6'd32;      // Exponent bias.  actual_E = stored_E − EXP_BIAS
                                         // "1.0 point": stored E=32 → actual 2^0 × 1.0

    // =========================================================================
    // PF: PATH_FAST fixed-point accumulate parameters
    // =========================================================================
    // PF: pf_accum × 2^(PF_SCALE_EXP − EXP_BIAS) = real accumulated value
    //     = pf_accum × 2^(16 − 32) = pf_accum × 2^(−16)
    // PF: reference exp_sum for zero alignment shift: PF_K_REF = 28
    //     k = exp_sum[5:0] − scale_reg[13] − PF_K_REF
    //     For neutral-regime anchor products (E_A≈28, E_B≈32): k ≈ 0.
    localparam [5:0]  PF_SCALE_EXP = 6'd16;   // PF: pf_accum LSB = 2^(16−32)
    localparam [5:0]  PF_K_REF     = 6'd28;   // PF: zero-shift reference


    // =========================================================================
    // Field-extraction aliases (combinational)
    // =========================================================================
    wire                 s_a = op_a[12];
    wire [EXP_W-1:0]     e_a = op_a[11:6];
    wire [MANT_W-1:0]    m_a = op_a[5:0];    // stored fraction bits of op_a

    wire                 s_b = op_b[12];
    wire [EXP_W-1:0]     e_b = op_b[11:6];
    wire [MANT_W-1:0]    m_b = op_b[5:0];    // stored fraction bits of op_b

    // =========================================================================
    // State registers
    // =========================================================================
    reg [ACCUM_W-1:0] accum_reg;  // Persistent 32-bit NN weight accumulator

    // ── SUB Guard-B 2-cycle pipeline registers ────────────────────────────────
    // The borrow + normalise path is split across two clock cycles to break the
    // priority-encoder → barrel-shifter → exponent-subtract critical path.
    //
    //   Cycle 1 (DETECT): mant_sum computed, norm_shift priority-encoded, barrel
    //     shift applied.  Six output bits of the shifter are registered here.
    //   Cycle 2 (PACK):   norm_shift subtracted from pre-stored (e_a−1), final
    //     NFE word assembled, result written.
    //
    // NBA last-write-wins rule: the Stage-2 output block is placed AFTER the
    // main case statement so its `result <=` takes priority over any 1-cycle
    // op that may be scheduled on the same cycle.  A NOP bubble between a
    // Guard-B SUB and the next consumer is sufficient to avoid hazards.
    //
    // Total new DFFs: 20  (6 × frac + 6 × e_pre + 4 × shift + 3 × flags)
    // The 6 sub_p1_frac DFFs are the key register: they latch the barrel-shift
    // output and allow the shifter combinational cloud to settle fully.
    // ─────────────────────────────────────────────────────────────────────────
    reg        sub_p1_armed;  //  1 DFF — Guard-B stage-1 data waiting in sub_p1_*
    reg        sub_p1_ftz;    //  1 DFF — flush-to-zero decision from Stage 1
    reg        sub_p1_uf;     //  1 DFF — underflow flag to assert in Stage 2
    reg        sub_p1_sign;   //  1 DFF — sign bit (s_a)
    reg [5:0]  sub_p1_e_pre;  //  6 DFFs — e_a (stored exponent; norm_shift subtracted in Stage 2)
    reg [3:0]  sub_p1_shift;  //  4 DFFs — norm_shift from priority encoder
    reg [5:0]  sub_p1_frac;   //  6 DFFs — barrel-shift output (norm_mant[5:0])

    // =========================================================================
    // Intra-cycle intermediates  (blocking-assigned; synthesise to combinational)
    // ─────────────────────────────────────────────────────────────────────────
    //  scale_reg   20-bit MUL intermediate.  With hidden bit the product is:
    //                  scale_reg = {1'b1, m_a} * {1'b1, m_b}
    //              Both 7-bit operands are promoted to 20 bits by the LHS
    //              context (Verilog LRM §4.4) before the multiply.
    //              Max product: 127 × 127 = 16129 (14-bit); fits in 20 bits.
    //
    //  mant_sum    7-bit ADD/SUB intermediate. bit[6] = carry (ADD) or used
    //              as the raw borrow result (SUB Guard-B) before normalisation.
    //
    //  norm_shift  Priority-encoded left-shift for SUB Guard-B normalisation.
    //              Range 1..6 (raw ∈ [1..63] needs at most 6 shifts).
    //
    //  norm_mant   7-bit normalised mantissa after left-shift (SUB Guard-B).
    //              norm_mant[5:0] becomes the f_result field.
    // =========================================================================
    reg [SCALE_W-1:0]    scale_reg;   // 20-bit MUL product register
    reg [NFE_W-1:0]      computed;    // Current-cycle scratch NFE result
    reg [MANT_ADD_W-1:0] mant_sum;    // 7-bit ADD/SUB working register
    reg [EXP_INC_W-1:0]  exp_next;    // 7-bit exponent incrementer
    reg [EXP_SUM_W-1:0]  exp_sum;     // 8-bit MUL exponent summer
    reg                  res_sign;    // MUL sign (S_a XOR S_b)
    reg [3:0]            norm_shift;  // SUB Guard-B: normalisation shift count
    reg [6:0]            norm_mant;   // SUB Guard-B: normalised mantissa

    // =========================================================================
    // Bias LUT — per-exponent-band correction offset  (MODE_BIAS_CORR)
    // ─────────────────────────────────────────────────────────────────────────
    // 64-entry ROM indexed by stored exponent e_a[5:0].  Each entry is a
    // 13-bit correction codeword derived from the Test 9 cancel-residual
    // manifold.  Initialised to zero here; override at graph-compile time or
    // via a parameter ROM replacement for production calibration.
    //
    // Synthesis: inferred as a distributed ROM (LUTRAM / registers).
    // Single-cycle read — no pipeline stage.
    // =========================================================================
    reg [12:0] BIAS_LUT [0:63];
    integer    lut_i;
    initial begin
        for (lut_i = 0; lut_i < 64; lut_i = lut_i + 1)
            BIAS_LUT[lut_i] = 13'd0;   // Calibration placeholder — replace with
                                        // per-exponent bias table from Test 9.
    end

    // =========================================================================
    // Policy Decoder intermediates — blocking-assigned registers
    // ─────────────────────────────────────────────────────────────────────────
    // accum_word and safe_sum_reg are computed using blocking '=' assignments
    // INSIDE the sequential always block, immediately after 'computed' is set.
    // This ensures the NBA  accum_reg <= ... accum_word  reads the CURRENT
    // cycle's value without a delta-cycle scheduling gap.
    //
    // All three mux paths are single-cycle combinational:
    //   BIAS_CORR   : 13-bit add  (computed + BIAS_LUT[e_a])
    //   PRE_SCALED  : 1-bit mux   ({sign, E−1, frac}  or computed)
    //   SAFE_ACCUM  : 33-bit add  with carry-out saturation mux
    //   Standard    : passthrough (computed unchanged)
    // =========================================================================
    reg [12:0] accum_word;    // Policy-decoded word folded into accum_reg
    reg [32:0] safe_sum_reg;  // 33-bit intermediate for SAFE_ACCUM saturation

    // PF: PATH_FAST state and intra-cycle intermediates
    reg signed [31:0] pf_accum;    // PF: 32-bit fixed-point row accumulate (units: 2^−16)
    // PF: intra-cycle compute regs (blocking, combinational in synthesis)
    reg signed [6:0]  pf_k;        // PF: alignment shift (signed, −8..+8)
    reg        [3:0]  pf_k_abs;    // PF: |pf_k| clamped to [0,8]
    reg               pf_k_neg;    // PF: sign of pf_k
    reg [31:0]        pf_term_u;   // PF: unsigned aligned product magnitude
    reg signed [31:0] pf_term;     // PF: signed aligned product
    reg [30:0]        pf_abs;      // PF: |pf_accum| for NFE readout encode
    reg               pf_sign;     // PF: sign of pf_accum
    reg [4:0]         pf_msb;      // PF: MSB bit position of pf_abs
    reg [5:0]         pf_es;       // PF: NFE stored exponent for readout
    reg [5:0]         pf_f;        // PF: NFE fraction field for readout
    reg [12:0]        pf_nfe;      // PF: packed NFE readout word


    // =========================================================================
    // Sequential core
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin

        // ── Reset ─────────────────────────────────────────────────────────────
        if (!rst_n) begin
            result         <= {NFE_W{1'b0}};
            accum_reg      <= {ACCUM_W{1'b0}};
            accum_out      <= {ACCUM_W{1'b0}};
            rollover_flag  <= 1'b0;
            underflow_flag <= 1'b0;
            exp_ovf_flag   <= 1'b0;
            scale_reg       = {SCALE_W{1'b0}};
            computed        = {NFE_W{1'b0}};
            norm_shift      = 4'd0;
            norm_mant       = 7'b0;
            sub_p1_armed   <= 1'b0;
            sub_p1_ftz     <= 1'b0;
            sub_p1_uf      <= 1'b0;
            sub_p1_sign    <= 1'b0;
            sub_p1_e_pre   <= {EXP_W{1'b0}};
            sub_p1_shift   <= 4'd0;
            sub_p1_frac    <= {MANT_W{1'b0}};
            pf_accum       <= 32'sd0;   // PF: reset fixed-point accumulate

        end else begin

            // ── Per-cycle flag auto-clear ─────────────────────────────────────
            rollover_flag  <= 1'b0;
            underflow_flag <= 1'b0;
            exp_ovf_flag   <= 1'b0;

            // ── SUB pipeline auto-arm clear (Guard-B Stage-1 re-arms below) ───
            sub_p1_armed   <= 1'b0;

            // ── Accumulator clear (priority over accum_en) ────────────────────
            if (accum_clr) begin
                accum_reg <= {ACCUM_W{1'b0}};
                pf_accum  <= 32'sd0;  // PF: clear fixed-point accumulate (same priority)
            end

            // ── Operation dispatch ────────────────────────────────────────────
            case (op_sel)

                // =============================================================
                // 2'b00  ADD_FRAC — Fraction addition with Thoth Rollover
                // -------------------------------------------------------------
                // op_b is treated as a raw fractional delta Δ (no hidden bit).
                // The operation computes:
                //   (1 + f_a/64) + Δ/64
                //
                // 8-bit adder includes op_a's hidden bit:
                //   sum = {1'b1, m_a} + m_b  =  (64 + m_a) + m_b   [0..190]
                //
                // No rollover (sum < 128, bit[7]=0):
                //   bit[6] = 1 (hidden bit preserved), f_result = sum[5:0].
                //
                // THOTH ROLLOVER (sum ≥ 128, bit[7]=1):
                //   Normalize right by 1: E ← E+1, f_result ← sum[6:1].
                //   Derivation: (64+m_a+Δ)/64 × 2^E = (64+m_a+Δ)/128 × 2^(E+1)
                //     In 1.f:  f = ((64+m_a+Δ)/128 − 1) × 64 = (m_a+Δ−64)/2
                //              = sum[6:1]  (sum = 64+m_a+Δ, right-shifted by 1).
                // =============================================================
                2'b00: begin

                    // Include hidden bit of op_a for correct normalization
                    mant_sum = {1'b0, 1'b1, m_a} + {2'b0, m_b};  // 8-bit

                    if (mant_sum[7]) begin
                        // ── THOTH ROLLOVER: sum ≥ 128, normalize right by 1 ───
                        rollover_flag <= 1'b1;
                        exp_next       = {1'b0, e_a} + {{(EXP_INC_W-1){1'b0}}, 1'b1};

                        if (exp_next[6]) begin
                            // Exponent would overflow 6 bits — saturate
                            exp_ovf_flag <= 1'b1;
                            computed      = {s_a, EXP_MAX, MANT_MAX};
                        end else begin
                            // E+1, f = sum[6:1]  (right-shift → correct frac)
                            computed = {s_a, exp_next[EXP_W-1:0], mant_sum[6:1]};
                        end

                    end else begin
                        // No rollover: bit[6]=1 is hidden-1, bits[5:0] = fraction
                        computed = {s_a, e_a, mant_sum[MANT_W-1:0]};
                    end

                    result <= computed;
                    if (accum_en && !accum_clr) begin
                        // ── Policy Decoder (inline, blocking) ─────────────────
                        case (mode_tag)
                            MODE_BIAS_CORR:  accum_word = computed + BIAS_LUT[e_a];
                            MODE_PRE_SCALED: accum_word = (computed[11:6] != 6'd0)
                                             ? {computed[12], computed[11:6]-6'd1, computed[5:0]}
                                             : computed;
                            default:         accum_word = computed;
                        endcase
                        safe_sum_reg = {1'b0, accum_reg} + {20'b0, computed};
                        accum_reg <= (mode_tag == MODE_SAFE_ACCUM)
                                     ? (safe_sum_reg[32] ? 32'hFFFF_FFFF : safe_sum_reg[31:0])
                                     : accum_reg + {{(ACCUM_W-NFE_W){1'b0}}, accum_word};
                    end
                end

                // =============================================================
                // 2'b01  SUB_FRAC — Fraction subtraction with normalisation
                // -------------------------------------------------------------
                // op_b is treated as raw fractional delta Δ (no hidden bit).
                // The operation computes:
                //   (1 + f_a/64) − Δ/64  =  1 + (f_a − Δ)/64
                //
                // Guard Path A (f_a ≥ Δ): no borrow.
                //   f_result = f_a − Δ,  E unchanged.  1-cycle latency.
                //   Minimum floor: if E=0 and f_result=0 → output minimum,
                //   fire underflow_flag.
                //
                // Guard Path B (f_a < Δ): borrow required.  2-cycle latency.
                //   If E = 0: no higher scale → immediate floor (1 cycle).
                //   If E > 0: borrow one E unit.
                //     raw = 64 + f_a − Δ  ∈ [1, 63]  (hidden bit missing).
                //
                //   ── 2-Cycle Pipeline Break (LayerNorm Cascade fix) ─────────
                //   Cycle 1 (DETECT): priority-encoder computes norm_shift,
                //     barrel-shifter applies `raw << norm_shift`.
                //     The 6 fractional output bits and supporting state are
                //     registered into sub_p1_*.
                //   Cycle 2 (PACK): Stage-2 block (after this case) reads
                //     sub_p1_*, subtracts norm_shift from (e_a−1), assembles
                //     and writes the final NFE result word.
                //   Consumer must insert one NOP bubble between Guard-B issue
                //   and the first read of `result`.
                //   ──────────────────────────────────────────────────────────
                // =============================================================
                2'b01: begin

                    if (m_a >= m_b) begin
                        // ── Guard Path A: direct subtraction (1 cycle) ────────
                        computed = {s_a, e_a, m_a - m_b};

                        if ((e_a == {EXP_W{1'b0}}) &&
                            ((m_a - m_b) == {MANT_W{1'b0}}))
                            underflow_flag <= 1'b1;

                        result <= computed;
                        if (accum_en && !accum_clr) begin
                            case (mode_tag)
                                MODE_BIAS_CORR:  accum_word = computed + BIAS_LUT[e_a];
                                MODE_PRE_SCALED: accum_word = (computed[11:6] != 6'd0)
                                                 ? {computed[12], computed[11:6]-6'd1, computed[5:0]}
                                                 : computed;
                                default:         accum_word = computed;
                            endcase
                            safe_sum_reg = {1'b0, accum_reg} + {20'b0, computed};
                            accum_reg <= (mode_tag == MODE_SAFE_ACCUM)
                                         ? (safe_sum_reg[32] ? 32'hFFFF_FFFF : safe_sum_reg[31:0])
                                         : accum_reg + {{(ACCUM_W-NFE_W){1'b0}}, accum_word};
                        end

                    end else begin
                        // ── Guard Path B: borrow required ─────────────────────
                        if (e_a == {EXP_W{1'b0}}) begin
                            // E=0 — no higher scale to borrow → immediate floor (1 cycle)
                            underflow_flag <= 1'b1;
                            result         <= {s_a, {EXP_W{1'b0}}, {MANT_W{1'b0}}};

                        end else begin
                            // ── Stage 1 of 2-cycle pipeline ───────────────────
                            // Borrow one E unit: raw_mant = 64 + f_a − Δ ∈ [1,63]
                            mant_sum = {1'b0, m_a} + 7'd64 - {1'b0, m_b};
                            // mant_sum[6] = 0 guaranteed (result < 64)

                            // Priority-encode normalisation left-shift k:
                            // find minimum k so (raw << k) has bit[6] = 1.
                            if      (mant_sum[5]) norm_shift = 4'd1; // raw ∈ [32,63]
                            else if (mant_sum[4]) norm_shift = 4'd2; // raw ∈ [16,31]
                            else if (mant_sum[3]) norm_shift = 4'd3; // raw ∈ [8,15]
                            else if (mant_sum[2]) norm_shift = 4'd4; // raw ∈ [4,7]
                            else if (mant_sum[1]) norm_shift = 4'd5; // raw ∈ [2,3]
                            else                  norm_shift = 4'd6; // raw = 1

                            // Barrel-shift: apply the normalisation shift.
                            // The 6 LSBs of norm_mant become f_result in Stage 2.
                            norm_mant = mant_sum << norm_shift;

                            // ── Register pipeline state ────────────────────────
                            // sub_p1_armed was cleared at the top of this else-begin;
                            // setting it here wins the NBA last-write race (source
                            // order: clear earlier, set here = later = wins).
                            sub_p1_armed <= 1'b1;
                            sub_p1_sign  <= s_a;
                            sub_p1_frac  <= norm_mant[MANT_W-1:0]; // 6 DFFs — key break
                            sub_p1_shift <= norm_shift;
                            // FIX: store e_a directly (no −1 borrow step).
                            // Stage-2 computes e_a − norm_shift as the correct final exponent.
                            // Derivation: raw = 64+m_a−Δ;  true_val = raw/64 × 2^actual_E_a
                            //   normalized: raw<<k / 64 × 2^(actual_E_a − k)
                            //   stored_E_final = e_a − norm_shift  (no extra −1).
                            sub_p1_e_pre <= e_a;

                            // FTZ when e_a − norm_shift < 0, i.e. e_a < norm_shift (strictly).
                            // FIX: changed <= to < (e_a = norm_shift is valid: stored_E = 0).
                            if (e_a < {{(EXP_W-4){1'b0}}, norm_shift}) begin
                                sub_p1_ftz <= 1'b1;
                                sub_p1_uf  <= 1'b1;
                            end else begin
                                sub_p1_ftz <= 1'b0;
                                sub_p1_uf  <= 1'b0;
                            end
                            // result NOT written here — Stage 2 writes next cycle.
                        end
                    end
                end

                // =============================================================
                // 2'b10  MUL — Hidden-bit fractional multiplication
                // Optimised for neural-network weight scaling.
                // -------------------------------------------------------------
                // Full-mantissa multiplication:
                //   A = {1, f_a} = 64 + f_a   (7-bit, range [64,127])
                //   B = {1, f_b} = 64 + f_b   (7-bit, range [64,127])
                //   P = A × B                  (14-bit, range [4096,16129])
                //
                //   Ghost-Zero structurally impossible: min P = 64² = 4096 > 0.
                //
                // Normalization via single-bit check on P[13]:
                //   P[13]=0 (P < 8192): hidden-1 is at P[12], f_result = P[11:6]
                //   P[13]=1 (P ≥ 8192): hidden-1 is at P[13], f_result = P[12:7]
                //
                // ── Biased-exponent correction ────────────────────────────────
                //   Both operands carry a bias of EXP_BIAS=32.  Adding them
                //   introduces a double-bias, so one bias must be subtracted:
                //     stored_E_result = E_a + E_b − EXP_BIAS  [+1 for P[13]=1]
                //   This preserves the invariant  actual_E = stored_E − EXP_BIAS.
                //
                // ── Guard-bit semantics of the 8-bit exp_sum ─────────────────
                //   exp_sum[7]=1  → e_a+e_b < EXP_BIAS: unsigned wrap → UNDERFLOW
                //   exp_sum[7:6]=01 → 64 ≤ stored_E ≤ 95: exceeds 6-bit max → OVERFLOW
                //   exp_sum[7:6]=00 → valid stored exponent in [0,63]
                // =============================================================
                2'b10: begin

                    // Step 1 — Sign XOR
                    res_sign = s_a ^ s_b;

                    // Step 2 — Hidden-bit product in 20-bit context.
                    // {1'b1,m_a} and {1'b1,m_b} are 7-bit self-determined
                    // concatenations; the 20-bit LHS promotes them before ×.
                    scale_reg = {1'b1, m_a} * {1'b1, m_b};

                    // Step 3 — Biased exponent summation.
                    // Subtract one copy of EXP_BIAS to remove the double-bias
                    // introduced by adding two biased exponent fields.
                    if (scale_reg[13]) begin
                        exp_sum = {{2{1'b0}}, e_a} + {{2{1'b0}}, e_b}
                                  - {{2{1'b0}}, EXP_BIAS} + 8'd1;
                    end else begin
                        exp_sum = {{2{1'b0}}, e_a} + {{2{1'b0}}, e_b}
                                  - {{2{1'b0}}, EXP_BIAS};
                    end

                    // Step 4 — Guard checks and result packing.
                    if (exp_sum[7]) begin
                        // UNDERFLOW: e_a + e_b < EXP_BIAS → product below 2^(−32).
                        // 8-bit subtraction wrapped negative (bit 7 set).
                        underflow_flag <= 1'b1;
                        computed        = {res_sign, {EXP_W{1'b0}}, {MANT_W{1'b0}}};

                    end else if (exp_sum[6]) begin
                        // OVERFLOW: stored_E_result > 63 → product above 2^(+31).
                        exp_ovf_flag <= 1'b1;
                        computed      = {res_sign, EXP_MAX, MANT_MAX};

                    end else begin
                        // Normal: pack result with the correctly biased exponent.
                        // f_result comes from bits adjacent to whichever hidden-1 fired.
                        computed = {res_sign, exp_sum[EXP_W-1:0],
                                    scale_reg[13] ? scale_reg[12:7]
                                                  : scale_reg[11:6]};
                    end

                    // Step 5 — Register output; fold into NN accumulator if enabled.
                    result <= computed;

                    // PF: accumulate full 14-bit product into pf_accum when mode_tag[2]=1.
                    // Bypasses the 6-bit truncation at original lines 530–532.
                    // k = exp_sum[5:0] − scale_reg[13] − PF_K_REF aligns to 2^(−16) scale.
                    if (mode_tag[2] && !exp_sum[7] && !exp_sum[6]) begin
                        pf_k = $signed({1'b0, exp_sum[5:0]})
                               - $signed({1'b0, PF_K_REF})
                               - $signed({6'b0, scale_reg[13]});
                        pf_k_neg = pf_k[6];
                        pf_k_abs = (pf_k[6]) ? ((~pf_k[3:0]) + 4'd1) : pf_k[3:0];
                        if (pf_k_abs > 4'd8) pf_k_abs = 4'd8;
                        pf_term_u = pf_k_neg
                                    ? ({18'b0, scale_reg[13:0]} >> pf_k_abs)
                                    : ({18'b0, scale_reg[13:0]} << pf_k_abs);
                        pf_term = res_sign ? -$signed({1'b0, pf_term_u})
                                           :  $signed({1'b0, pf_term_u});
                        pf_accum <= pf_accum + pf_term;
                    end
                    if (accum_en && !accum_clr) begin
                        case (mode_tag)
                            MODE_BIAS_CORR:  accum_word = computed + BIAS_LUT[e_a];
                            MODE_PRE_SCALED: accum_word = (computed[11:6] != 6'd0)
                                             ? {computed[12], computed[11:6]-6'd1, computed[5:0]}
                                             : computed;
                            default:         accum_word = computed;
                        endcase
                        safe_sum_reg = {1'b0, accum_reg} + {20'b0, computed};
                        accum_reg <= (mode_tag == MODE_SAFE_ACCUM)
                                     ? (safe_sum_reg[32] ? 32'hFFFF_FFFF : safe_sum_reg[31:0])
                                     : accum_reg + {{(ACCUM_W-NFE_W){1'b0}}, accum_word};
                    end
                end

                // =============================================================
                // 2'b11  NOP — Pass-through; no arithmetic, no flag events
                // =============================================================
                2'b11: begin
                    result <= op_a;
                end

                default: result <= {NFE_W{1'b0}};

            endcase


            // PF: NOP readout — encode pf_accum as NFE when mode_tag[2]=1 and op_sel=NOP.
            // Overrides the NOP pass-through (result <= op_a) via NBA last-write-wins.
            // Clears pf_accum for the next row.
            if (mode_tag[2] && (op_sel == 2'b11)) begin
                pf_sign = pf_accum[31];
                pf_abs  = pf_accum[31] ? (~pf_accum[30:0] + 31'd1) : pf_accum[30:0];

                // PF: priority encoder — find MSB position of pf_abs[30:0]
                if      (pf_abs[30]) pf_msb = 5'd30;
                else if (pf_abs[29]) pf_msb = 5'd29;
                else if (pf_abs[28]) pf_msb = 5'd28;
                else if (pf_abs[27]) pf_msb = 5'd27;
                else if (pf_abs[26]) pf_msb = 5'd26;
                else if (pf_abs[25]) pf_msb = 5'd25;
                else if (pf_abs[24]) pf_msb = 5'd24;
                else if (pf_abs[23]) pf_msb = 5'd23;
                else if (pf_abs[22]) pf_msb = 5'd22;
                else if (pf_abs[21]) pf_msb = 5'd21;
                else if (pf_abs[20]) pf_msb = 5'd20;
                else if (pf_abs[19]) pf_msb = 5'd19;
                else if (pf_abs[18]) pf_msb = 5'd18;
                else if (pf_abs[17]) pf_msb = 5'd17;
                else if (pf_abs[16]) pf_msb = 5'd16;
                else if (pf_abs[15]) pf_msb = 5'd15;
                else if (pf_abs[14]) pf_msb = 5'd14;
                else if (pf_abs[13]) pf_msb = 5'd13;
                else if (pf_abs[12]) pf_msb = 5'd12;
                else if (pf_abs[11]) pf_msb = 5'd11;
                else if (pf_abs[10]) pf_msb = 5'd10;
                else if (pf_abs[9])  pf_msb = 5'd9;
                else if (pf_abs[8])  pf_msb = 5'd8;
                else if (pf_abs[7])  pf_msb = 5'd7;
                else if (pf_abs[6])  pf_msb = 5'd6;
                else if (pf_abs[5])  pf_msb = 5'd5;
                else if (pf_abs[4])  pf_msb = 5'd4;
                else if (pf_abs[3])  pf_msb = 5'd3;
                else if (pf_abs[2])  pf_msb = 5'd2;
                else if (pf_abs[1])  pf_msb = 5'd1;
                else                 pf_msb = 5'd0;

                if (pf_abs == 31'd0) begin
                    pf_nfe = {pf_sign, {EXP_W{1'b0}}, {MANT_W{1'b0}}};
                end else begin
                    // PF: stored_E = pf_msb + PF_SCALE_EXP (= pf_msb + 16)
                    pf_es = pf_msb + {PF_SCALE_EXP};
                    // PF: 6-bit mantissa, round-to-nearest (matches nfe_encode +0.5 in testbench).
                    // Extract f = 6 bits below MSB, then check the guard bit at (pf_msb-7)
                    // and round up if set to eliminate systematic floor bias.
                    if (pf_msb >= 5'd6) begin
                        pf_f = (pf_abs >> (pf_msb - 5'd6)) & 6'h3F;
                        if (pf_msb >= 5'd7 && ((pf_abs >> (pf_msb - 5'd7)) & 31'b1)) begin
                            if (pf_f == 6'h3F) begin
                                pf_f = 6'd0;
                                pf_es = pf_es + 6'd1;  // carry into exponent
                            end else
                                pf_f = pf_f + 6'd1;
                        end
                    end else
                        pf_f = (pf_abs << (5'd6 - pf_msb)) & 6'h3F;
                    if (pf_es > 6'd63)
                        pf_nfe = {pf_sign, EXP_MAX, MANT_MAX};
                    else
                        pf_nfe = {pf_sign, pf_es, pf_f};
                end

                result   <= pf_nfe;
                pf_accum <= 32'sd0;
            end

            // =================================================================
            // SUB Guard-B Stage-2 pipeline output
            // -----------------------------------------------------------------
            // Placed AFTER the case statement so these NBA writes have lower
            // source-code index than any writes made inside the case.
            // Verilog LRM §4.9.4 (last NBA write to same reg wins):
            //   → This block's `result <=` overrides any 1-cycle op that ran
            //     in the same clock cycle, making a NOP bubble the natural and
            //     sufficient hazard avoidance.
            //
            // sub_p1_armed was set by Guard-B Stage-1 in the previous cycle.
            // The auto-clear `sub_p1_armed <= 1'b0` earlier in this block uses
            // the OLD value of sub_p1_armed (NBA RHS eval); Stage-1's
            // `sub_p1_armed <= 1'b1` (set inside case above) overwrites that
            // default clear if Guard-B fired this cycle, keeping the stage-1
            // data live for Stage-2 on the NEXT cycle.
            // =================================================================
            if (sub_p1_armed) begin
                underflow_flag <= sub_p1_uf;

                if (sub_p1_ftz) begin
                    // FTZ: insufficient exponent headroom after borrow + shift
                    result <= {sub_p1_sign, {EXP_W{1'b0}}, {MANT_W{1'b0}}};

                end else begin
                    // Final stored exponent = e_a − norm_shift.
                    // sub_p1_e_pre holds e_a (Stage 1 fix: no −1 borrow step).
                    result <= {sub_p1_sign,
                               sub_p1_e_pre - {{(EXP_W-4){1'b0}}, sub_p1_shift},
                               sub_p1_frac};
                end
            end

            // accum_out mirrors accum_reg with one-cycle latency.
            // Insert a NOP cycle after the final accumulation before sampling.
            accum_out <= accum_reg;

        end
    end

endmodule

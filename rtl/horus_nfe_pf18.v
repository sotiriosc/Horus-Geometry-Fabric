`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_nfe_pf18  (PATH_FAST variant, W=18 accumulator)
// Project  : Horus Engine — Native Fractional Engine
// File     : horus_nfe_pf18.v
//
// Derived from rtl/horus_nfe_pf.v (32-bit PF accumulator) by narrowing the
// PF-specific datapath to W=18 bits:
//   • pf_accum register:   signed [17:0]   (was signed [31:0])
//   • pf_term intermediate: signed [22:0]  (was signed [31:0])
//   • pf_sum_wide saturator: signed [22:0] (new; replaces unchecked add)
//   • pf_abs magnitude:     [17:0]          (was [30:0])
//   • pf_msb priority-enc:  [4:0]           (max position 17, was 30)
//   • Readout priority encoder: 18 branches (pf_abs[17]..pf_abs[0])
//
// PF18: Saturation guard on pf_accum — clamp on overflow rather than wrap.
// Motivation: pf_width_sweep.py (sim/pf_width_sweep.py) showed W=18 yields
// 0.35% neutral-regime error and W=16 overflows (~66% error).  The maximum
// neutral-regime row-sum magnitude is ~131,072 units (≈ 2^17), sitting exactly
// at the W=18 signed ceiling.  Wrapping on overflow would corrupt the
// accumulate; clamping to [−131072, +131071] preserves sign and magnitude
// ordering on the rare overflow event.
//
// All non-PF arithmetic (ADD, SUB, MUL, NOP, accum_reg, mode_tag) is
// byte-identical to horus_nfe_pf.v.  rtl/horus_nfe.v and rtl/horus_nfe_pf.v
// remain untouched.
// ============================================================================

// ── Compute Policy Mode Tags ──────────────────────────────────────────────────
// These constants define the 3-bit in-band policy field (mode_tag).
// 3'b100..3'b111 are reserved and treated as MODE_STANDARD by the decoder.
// ─────────────────────────────────────────────────────────────────────────────
//   MODE_STANDARD   (3'b000) : Baseline arithmetic — current behavior unchanged.
//   MODE_BIAS_CORR  (3'b001) : Bias-Corrected accumulation.
//   MODE_PRE_SCALED (3'b010) : Pre-Scaled accumulation.
//   MODE_SAFE_ACCUM (3'b011) : Safe-Accumulation (32-bit accum_reg saturation).
// ─────────────────────────────────────────────────────────────────────────────

module horus_nfe_pf18 (
    input  wire        clk,
    input  wire        rst_n,       // Active-low synchronous reset

    // ── Operands (13-bit NFE encoded) ────────────────────────────────────────
    input  wire [12:0] op_a,        // Operand A
    input  wire [12:0] op_b,        // Operand B  /  fractional delta for ADD|SUB
    input  wire [1:0]  op_sel,      // Operation select

    // ── Compute Policy (in-band, single-cycle mux path) ──────────────────────
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
    localparam MANT_ADD_W  =  8;  // Mantissa adder width
    localparam EXP_INC_W   =  7;  // Exponent incrementer
    localparam EXP_SUM_W   =  8;  // MUL exponent summer
    localparam SCALE_W     = 20;  // MUL intermediate product register
    localparam ACCUM_W     = 32;  // Running accumulator width (accum_reg unchanged)

    localparam MANT_MAX    = 6'b111111;
    localparam EXP_MAX     = 6'b111111;
    localparam EXP_BIAS    = 6'd32;

    // =========================================================================
    // PF18: PATH_FAST fixed-point accumulate parameters (W=18)
    // =========================================================================
    // PF18: pf_accum x 2^(PF_SCALE_EXP - EXP_BIAS) = real accumulated value
    //       = pf_accum x 2^(16 - 32) = pf_accum x 2^(-16)
    // PF18: reference exp_sum for zero alignment shift: PF_K_REF = 28
    //       k = exp_sum[5:0] - scale_reg[13] - PF_K_REF
    //       For neutral-regime anchor products (E_A~28, E_B~32): k ~ 0.
    localparam [5:0]  PF_SCALE_EXP = 6'd16;   // PF18: pf_accum LSB = 2^(16-32)
    localparam [5:0]  PF_K_REF     = 6'd28;   // PF18: zero-shift reference

    // =========================================================================
    // Field-extraction aliases (combinational)
    // =========================================================================
    wire                 s_a = op_a[12];
    wire [EXP_W-1:0]     e_a = op_a[11:6];
    wire [MANT_W-1:0]    m_a = op_a[5:0];

    wire                 s_b = op_b[12];
    wire [EXP_W-1:0]     e_b = op_b[11:6];
    wire [MANT_W-1:0]    m_b = op_b[5:0];

    // =========================================================================
    // State registers
    // =========================================================================
    reg [ACCUM_W-1:0] accum_reg;  // Persistent 32-bit NN weight accumulator

    // ── SUB Guard-B 2-cycle pipeline registers ────────────────────────────────
    reg        sub_p1_armed;
    reg        sub_p1_ftz;
    reg        sub_p1_uf;
    reg        sub_p1_sign;
    reg [5:0]  sub_p1_e_pre;
    reg [3:0]  sub_p1_shift;
    reg [5:0]  sub_p1_frac;

    // =========================================================================
    // Intra-cycle intermediates  (blocking-assigned; synthesise to combinational)
    // =========================================================================
    reg [SCALE_W-1:0]    scale_reg;
    reg [NFE_W-1:0]      computed;
    reg [MANT_ADD_W-1:0] mant_sum;
    reg [EXP_INC_W-1:0]  exp_next;
    reg [EXP_SUM_W-1:0]  exp_sum;
    reg                  res_sign;
    reg [3:0]            norm_shift;
    reg [6:0]            norm_mant;

    // =========================================================================
    // Bias LUT — per-exponent-band correction offset  (MODE_BIAS_CORR)
    // =========================================================================
    reg [12:0] BIAS_LUT [0:63];
    integer    lut_i;
    initial begin
        for (lut_i = 0; lut_i < 64; lut_i = lut_i + 1)
            BIAS_LUT[lut_i] = 13'd0;
    end

    // =========================================================================
    // Policy Decoder intermediates
    // =========================================================================
    reg [12:0] accum_word;
    reg [32:0] safe_sum_reg;

    // =========================================================================
    // PF18: PATH_FAST state and intra-cycle intermediates (W=18)
    // =========================================================================
    // PF18: 18-bit signed fixed-point row accumulate (units: 2^-16).
    //       Range: [-131072, +131071].  Width chosen from pf_width_sweep.py:
    //       W=18 -> 0.35% error (minimum viable <= 0.5%), W=16 overflows.
    reg signed [17:0] pf_accum;    // PF18: 18-bit fixed-point accumulate register

    // PF18: intra-cycle compute regs (blocking, combinational in synthesis)
    reg signed [6:0]  pf_k;        // PF18: alignment shift (signed, -8..+8)
    reg        [3:0]  pf_k_abs;    // PF18: |pf_k| clamped to [0,8]
    reg               pf_k_neg;    // PF18: sign of pf_k
    // PF18: pf_term_u is 22-bit: scale_reg[13:0] (14-bit) << 8 max = 22 bits.
    reg [21:0]        pf_term_u;   // PF18: unsigned aligned product magnitude
    reg signed [22:0] pf_term;     // PF18: signed aligned product (23-bit)
    // PF18: pf_sum_wide is the 23-bit saturating intermediate.
    // Bits [22:17] must be equal (all 0 or all 1) for no 18-bit overflow.
    reg signed [22:0] pf_sum_wide; // PF18: 23-bit sum for saturation check
    // PF18: readout intermediates sized for 18-bit pf_accum
    reg [17:0]        pf_abs;      // PF18: |pf_accum|, 18-bit (handles -131072 case)
    reg               pf_sign;     // PF18: sign of pf_accum
    reg [4:0]         pf_msb;      // PF18: MSB bit position of pf_abs (max 17)
    reg [5:0]         pf_es;       // PF18: NFE stored exponent for readout
    reg [5:0]         pf_f;        // PF18: NFE fraction field for readout
    reg [12:0]        pf_nfe;      // PF18: packed NFE readout word


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
            pf_accum       <= 18'sd0;   // PF18: reset 18-bit fixed-point accumulate

        end else begin

            // ── Per-cycle flag auto-clear ─────────────────────────────────────
            rollover_flag  <= 1'b0;
            underflow_flag <= 1'b0;
            exp_ovf_flag   <= 1'b0;

            // ── SUB pipeline auto-arm clear ───────────────────────────────────
            sub_p1_armed   <= 1'b0;

            // ── Accumulator clear (priority over accum_en) ────────────────────
            if (accum_clr) begin
                accum_reg <= {ACCUM_W{1'b0}};
                pf_accum  <= 18'sd0;  // PF18: clear 18-bit fixed-point accumulate
            end

            // ── Operation dispatch ────────────────────────────────────────────
            case (op_sel)

                // =============================================================
                // 2'b00  ADD_FRAC
                // =============================================================
                2'b00: begin

                    mant_sum = {1'b0, 1'b1, m_a} + {2'b0, m_b};

                    if (mant_sum[7]) begin
                        rollover_flag <= 1'b1;
                        exp_next       = {1'b0, e_a} + {{(EXP_INC_W-1){1'b0}}, 1'b1};

                        if (exp_next[6]) begin
                            exp_ovf_flag <= 1'b1;
                            computed      = {s_a, EXP_MAX, MANT_MAX};
                        end else begin
                            computed = {s_a, exp_next[EXP_W-1:0], mant_sum[6:1]};
                        end

                    end else begin
                        computed = {s_a, e_a, mant_sum[MANT_W-1:0]};
                    end

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
                end

                // =============================================================
                // 2'b01  SUB_FRAC
                // =============================================================
                2'b01: begin

                    if (m_a >= m_b) begin
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
                        if (e_a == {EXP_W{1'b0}}) begin
                            underflow_flag <= 1'b1;
                            result         <= {s_a, {EXP_W{1'b0}}, {MANT_W{1'b0}}};

                        end else begin
                            mant_sum = {1'b0, m_a} + 7'd64 - {1'b0, m_b};

                            if      (mant_sum[5]) norm_shift = 4'd1;
                            else if (mant_sum[4]) norm_shift = 4'd2;
                            else if (mant_sum[3]) norm_shift = 4'd3;
                            else if (mant_sum[2]) norm_shift = 4'd4;
                            else if (mant_sum[1]) norm_shift = 4'd5;
                            else                  norm_shift = 4'd6;

                            norm_mant = mant_sum << norm_shift;

                            sub_p1_armed <= 1'b1;
                            sub_p1_sign  <= s_a;
                            sub_p1_frac  <= norm_mant[MANT_W-1:0];
                            sub_p1_shift <= norm_shift;
                            sub_p1_e_pre <= e_a;

                            if (e_a < {{(EXP_W-4){1'b0}}, norm_shift}) begin
                                sub_p1_ftz <= 1'b1;
                                sub_p1_uf  <= 1'b1;
                            end else begin
                                sub_p1_ftz <= 1'b0;
                                sub_p1_uf  <= 1'b0;
                            end
                        end
                    end
                end

                // =============================================================
                // 2'b10  MUL — Hidden-bit fractional multiplication
                // =============================================================
                2'b10: begin

                    // Step 1 — Sign XOR
                    res_sign = s_a ^ s_b;

                    // Step 2 — Hidden-bit product (lines 530-532 of horus_nfe.v bypassed
                    // when mode_tag[2]=1; full 14-bit product feeds pf_accum instead).
                    scale_reg = {1'b1, m_a} * {1'b1, m_b};

                    // Step 3 — Biased exponent summation.
                    if (scale_reg[13]) begin
                        exp_sum = {{2{1'b0}}, e_a} + {{2{1'b0}}, e_b}
                                  - {{2{1'b0}}, EXP_BIAS} + 8'd1;
                    end else begin
                        exp_sum = {{2{1'b0}}, e_a} + {{2{1'b0}}, e_b}
                                  - {{2{1'b0}}, EXP_BIAS};
                    end

                    // Step 4 — Guard checks and result packing.
                    if (exp_sum[7]) begin
                        underflow_flag <= 1'b1;
                        computed        = {res_sign, {EXP_W{1'b0}}, {MANT_W{1'b0}}};

                    end else if (exp_sum[6]) begin
                        exp_ovf_flag <= 1'b1;
                        computed      = {res_sign, EXP_MAX, MANT_MAX};

                    end else begin
                        computed = {res_sign, exp_sum[EXP_W-1:0],
                                    scale_reg[13] ? scale_reg[12:7]
                                                  : scale_reg[11:6]};
                    end

                    // Step 5 — Register output.
                    result <= computed;

                    // PF18: accumulate full 14-bit product into 18-bit pf_accum
                    // when mode_tag[2]=1.  Bypasses 6-bit truncation (horus_nfe.v
                    // lines 530-532).  k aligns product to 2^(-16) scale.
                    if (mode_tag[2] && !exp_sum[7] && !exp_sum[6]) begin
                        pf_k = $signed({1'b0, exp_sum[5:0]})
                               - $signed({1'b0, PF_K_REF})
                               - $signed({6'b0, scale_reg[13]});
                        pf_k_neg = pf_k[6];
                        pf_k_abs = (pf_k[6]) ? ((~pf_k[3:0]) + 4'd1) : pf_k[3:0];
                        if (pf_k_abs > 4'd8) pf_k_abs = 4'd8;
                        // PF18: pf_term_u is 22-bit (14-bit scale_reg[13:0] << 8 max)
                        pf_term_u = pf_k_neg
                                    ? ({8'b0, scale_reg[13:0]} >> pf_k_abs)
                                    : ({8'b0, scale_reg[13:0]} << pf_k_abs);
                        pf_term = res_sign ? -$signed({1'b0, pf_term_u})
                                           :  $signed({1'b0, pf_term_u});
                        // PF18: saturating accumulate — clamp to [-131072, +131071].
                        // pf_sum_wide is 23-bit; bits [22:17] equal iff result fits
                        // in 18-bit signed range.  18'h1FFFF = +131071 (max),
                        // 18'h20000 = -131072 (min, two's complement).
                        // Motivated by width-sweep: max neutral row-sum ~2^17 units.
                        pf_sum_wide = {{5{pf_accum[17]}}, pf_accum} + pf_term;
                        pf_accum <= (pf_sum_wide[22:17] == 6'b000000 ||
                                     pf_sum_wide[22:17] == 6'b111111)
                                    ? pf_sum_wide[17:0]
                                    : (pf_sum_wide[22] ? 18'h20000 : 18'h1FFFF);
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


            // PF18: NOP readout — encode 18-bit pf_accum as NFE when mode_tag[2]=1
            // and op_sel=NOP.  NBA last-write-wins overrides result <= op_a above.
            // Clears pf_accum for the next row.
            if (mode_tag[2] && (op_sel == 2'b11)) begin
                pf_sign = pf_accum[17];
                // PF18: two's complement absolute value; 18-bit handles -131072 case.
                // For pf_accum=18'h20000 (-131072): ~18'h20000+1 = 18'h20000 = 131072 unsigned.
                pf_abs  = pf_accum[17] ? (~pf_accum + 18'd1) : {1'b0, pf_accum[16:0]};

                // PF18: priority encoder — find MSB position of pf_abs[17:0]
                // (18 branches for 18-bit magnitude; was 31 branches for 31-bit)
                if      (pf_abs[17]) pf_msb = 5'd17;
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

                if (pf_abs == 18'd0) begin
                    pf_nfe = {pf_sign, {EXP_W{1'b0}}, {MANT_W{1'b0}}};
                end else begin
                    // PF18: stored_E = pf_msb + PF_SCALE_EXP (= pf_msb + 16).
                    // Max: pf_msb=17 -> pf_es=33 (< 63, safe).
                    pf_es = {1'b0, pf_msb} + {PF_SCALE_EXP};
                    // PF18: 6-bit mantissa, round-to-nearest
                    // (same logic as horus_nfe_pf.v; matches nfe_encode +0.5).
                    if (pf_msb >= 5'd6) begin
                        pf_f = (pf_abs >> (pf_msb - 5'd6)) & 6'h3F;
                        if (pf_msb >= 5'd7 && ((pf_abs >> (pf_msb - 5'd7)) & 18'b1)) begin
                            if (pf_f == 6'h3F) begin
                                pf_f = 6'd0;
                                pf_es = pf_es + 6'd1;
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
                pf_accum <= 18'sd0;
            end

            // =================================================================
            // SUB Guard-B Stage-2 pipeline output
            // =================================================================
            if (sub_p1_armed) begin
                underflow_flag <= sub_p1_uf;

                if (sub_p1_ftz) begin
                    result <= {sub_p1_sign, {EXP_W{1'b0}}, {MANT_W{1'b0}}};

                end else begin
                    result <= {sub_p1_sign,
                               sub_p1_e_pre - {{(EXP_W-4){1'b0}}, sub_p1_shift},
                               sub_p1_frac};
                end
            end

            // accum_out mirrors accum_reg with one-cycle latency.
            accum_out <= accum_reg;

        end
    end

endmodule

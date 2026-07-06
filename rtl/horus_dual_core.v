// rtl/horus_dual_core.v — Dual-mode E4M3/E3M6 compact multiplier.
//
// One datapath serving two number formats selected by a registered mode input:
//
//   mode_r = 0 (E3M6+block, accumulation):
//     10-bit codewords [9]=s, [8:6]=e3 (bias 4), [5:0]=f6.
//     No NaN/Inf. Flush-subnormal-input convention. Subnormal outputs supported.
//     Truncation (no rounding). Matching horus_e3m6_core.v.
//
//   mode_r = 1 (E4M3FN, inference):
//     8-bit codewords [7]=s, [6:3]=e4 (bias 7), [2:0]=f3.
//     NaN: s.1111.111. Max finite: 448. Subnormal inputs/outputs.
//     RNE on 3-bit result. Matching fp8_e4m3_mul.v spec.
//
//   Interface: 10-bit ports; E4M3 uses bits [7:0]; bits [9:8] ignored.
//
// ── Shared Mantissa Array ─────────────────────────────────────────────────────
//
//   The shared 7×7 array computes P = mant_a × mant_b [13:0].
//
//   E3M6 operands: mant = {H=1, f6[5:0]}  value 64..127, P in [4096,16129].
//   E4M3 operands: mant = {0_gated, 0_gated, 0_gated, H_e4m3, f3[2:0]}
//                        value 0..15, P in [0,225]; result in P[7:0].
//
//   Bits [6:4] of each operand mantissa are EXPLICITLY GATED to 0 in E4M3 mode
//   via AND with hi_en = ~mode_r.  Synthesis preserves these AND cells as the
//   gating boundary; the fraction is K3 = gated_area / dual_core_area ≥ 25%.
//
// ── Exponent Path Unification ─────────────────────────────────────────────────
//
//   Unified 5-bit effective exponent + 5-bit bias-select subtractor:
//     ae_a = {1'b0, e_a_eff[3:0]}  (E3M6: zero-padded 3-bit; E4M3: 4-bit)
//     ae_b = same for b
//     bias_sel = mode_r ? 5'd7 : 5'd4
//     e_sum_p = ae_a + ae_b + P_msb  (+ rnd_carry for E4M3)
//     e_r = (signed)(e_sum_p - bias_sel)
//
// ── Python source of truth ────────────────────────────────────────────────────
//   sim/dual_core_model.py dual_core_mul (mode=0: _dual_mul_e3m6, mode=1: _fp8_mul_ref)
//   RTL golden vectors: sim/DUAL_CORE_E3M6_GOLDEN.hex, sim/DUAL_CORE_E4M3_GOLDEN.hex

`default_nettype none

module horus_dual_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        mode,      // 0=E3M6 (accumulation), 1=E4M3 (inference)
    input  wire [9:0]  op_a,      // E3M6: [9:s][8:6:e3][5:0:f6]; E4M3: [7:s][6:3:e4][2:0:f3]
    input  wire [9:0]  op_b,      // same layout as op_a
    output reg  [9:0]  result     // same layout: E3M6 10-bit / E4M3 8-bit (upper 2b unused)
);

    // ── Registered mode (K3 gating boundary must be clean) ────────────────────
    reg mode_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) mode_r <= 1'b0;
        else        mode_r <= mode;

    // ── Explicit gating enable ─────────────────────────────────────────────────
    // hi_en = ~mode_r: HIGH in E3M6 mode (enables upper mantissa bits).
    // Synthesis must preserve these AND cells — they form the K3 gating boundary.
    wire hi_en = ~mode_r;

    // ══════════════════════════════════════════════════════════════════════════
    // FIELD EXTRACTION (mode-dependent)
    // ══════════════════════════════════════════════════════════════════════════

    // ── Signs ──────────────────────────────────────────────────────────────────
    wire s_a = mode_r ? op_a[7]   : op_a[9];
    wire s_b = mode_r ? op_b[7]   : op_b[9];
    wire s_r = s_a ^ s_b;

    // ── E3M6 fields ────────────────────────────────────────────────────────────
    wire [2:0] e3_a  = op_a[8:6];
    wire [2:0] e3_b  = op_b[8:6];
    wire [5:0] f6_a  = op_a[5:0];
    wire [5:0] f6_b  = op_b[5:0];

    // ── E4M3 fields ────────────────────────────────────────────────────────────
    wire [3:0] e4_a  = op_a[6:3];
    wire [3:0] e4_b  = op_b[6:3];
    wire [2:0] f3_a  = op_a[2:0];
    wire [2:0] f3_b  = op_b[2:0];

    // ── E4M3 special-value detection ──────────────────────────────────────────
    wire nan_a  = mode_r & (e4_a == 4'hF) & (&f3_a);  // s.1111.111
    wire nan_b  = mode_r & (e4_b == 4'hF) & (&f3_b);
    wire zero_a = mode_r ? (op_a[6:0] == 7'd0) : (op_a[8:0] == 9'd0);
    wire zero_b = mode_r ? (op_b[6:0] == 7'd0) : (op_b[8:0] == 9'd0);
    wire sub_a  = mode_r & (e4_a == 4'd0) & ~zero_a;
    wire sub_b  = mode_r & (e4_b == 4'd0) & ~zero_b;

    // ── E3M6 flush: e_stored=0 → treat as zero ────────────────────────────────
    wire e3_flush = (~mode_r) & ((e3_a == 3'd0) | (e3_b == 3'd0));

    // ── Effective exponent (5-bit, both modes) ─────────────────────────────────
    // E3M6: ae = {2'b00, e3}  (range 0..7; flush handled separately)
    // E4M3: ae = sub ? 5'd1 : {1'b0, e4}  (subnormal effective exp = 1)
    wire [4:0] ae_a = mode_r ? (sub_a ? 5'd1 : {1'b0, e4_a}) : {2'b00, e3_a};
    wire [4:0] ae_b = mode_r ? (sub_b ? 5'd1 : {1'b0, e4_b}) : {2'b00, e3_b};

    // ══════════════════════════════════════════════════════════════════════════
    // SHARED 7×7 MANTISSA ARRAY WITH EXPLICIT GATING
    // ══════════════════════════════════════════════════════════════════════════
    //
    // Operand bit layout (7 bits):
    //   [6] = hi_en               (E3M6 hidden=1 / E4M3 gated=0)
    //   [5] = f6_a[5] & hi_en    (E3M6 f[5]  / E4M3 gated=0)
    //   [4] = f6_a[4] & hi_en    (E3M6 f[4]  / E4M3 gated=0)
    //   [3] = mux(mode_r, H_e4m3, f6_a[3])  (E4M3 hidden / E3M6 f[3])
    //   [2:0] = op_a[2:0]        (shared: E3M6 f[2:0] = E4M3 f3)

    // Bit[6]: E3M6 hidden=1 (when non-flush); E4M3 gated=0
    wire mant_a6 = hi_en & ~zero_a;    // hi_en ensures E4M3=0; ~zero_a for safety
    wire mant_b6 = hi_en & ~zero_b;

    // Bits[5:4]: E3M6 upper fraction; E4M3 gated to 0
    wire mant_a5 = f6_a[5] & hi_en;
    wire mant_b5 = f6_b[5] & hi_en;
    wire mant_a4 = f6_a[4] & hi_en;
    wire mant_b4 = f6_b[4] & hi_en;

    // Bit[3]: E4M3 hidden bit (H=0 for sub/zero, H=1 for normal); E3M6 f[3]
    wire H_a4m3 = ~sub_a & ~zero_a;   // E4M3 hidden bit for operand A
    wire H_b4m3 = ~sub_b & ~zero_b;
    wire mant_a3 = mode_r ? H_a4m3 : f6_a[3];
    wire mant_b3 = mode_r ? H_b4m3 : f6_b[3];

    // Bits[2:0]: shared (E3M6 f[2:0] = op_a[2:0]; E4M3 f3 = op_a[2:0])
    // (Both formats store their low fraction bits at positions [2:0])

    // Full 7-bit mantissas
    wire [6:0] mant_a = {mant_a6, mant_a5, mant_a4, mant_a3, op_a[2:0]};
    wire [6:0] mant_b = {mant_b6, mant_b5, mant_b4, mant_b3, op_b[2:0]};

    // 14-bit product
    wire [13:0] P = mant_a * mant_b;

    // ══════════════════════════════════════════════════════════════════════════
    // E3M6 NORMALIZATION PATH (mode_r = 0)
    // ══════════════════════════════════════════════════════════════════════════

    wire P_msb_e3m6 = P[13];   // Normalization bit for E3M6

    // 6-bit mantissa — truncation
    wire [5:0] fr_e3m6 = P_msb_e3m6 ? P[12:7] : P[11:6];

    // Exponent sum (5-bit): ea + eb + P_msb, bias=4
    wire [4:0] e_sum_e3m6 = ae_a + ae_b + {4'b0, P_msb_e3m6};

    wire sat_e3m6      = (e_sum_e3m6 > 5'd11);          // e_r > 7
    wire sub_out_e3m6  = ~sat_e3m6 & (e_sum_e3m6 <= 5'd4); // e_r ≤ 0

    // Denormalization for subnormal E3M6 output:
    //   f_sub = {1'b1, fr_e3m6} >> (5 - e_sum_e3m6)
    //   shift ∈ {1, 2, 3} for e_sum ∈ {4, 3, 2}
    wire [6:0] sub_mant_e3m6 = {1'b1, fr_e3m6};
    reg  [5:0] f_sub_e3m6;
    always @(*) begin
        case (5'd5 - e_sum_e3m6)
            5'd1:    f_sub_e3m6 = sub_mant_e3m6[6:1];
            5'd2:    f_sub_e3m6 = {1'b0, sub_mant_e3m6[6:2]};
            default: f_sub_e3m6 = {2'b00, sub_mant_e3m6[6:3]};
        endcase
    end

    wire [2:0] e_r_e3m6  = e_sum_e3m6[2:0] - 3'd4;   // valid when normal
    wire [2:0] e_out_e3m6 = sat_e3m6 ? 3'd7 : (sub_out_e3m6 ? 3'd0 : e_r_e3m6);
    wire [5:0] f_out_e3m6 = sat_e3m6 ? 6'h3F : (sub_out_e3m6 ? f_sub_e3m6 : fr_e3m6);

    // ══════════════════════════════════════════════════════════════════════════
    // E4M3 NORMALIZATION PATH (mode_r = 1)
    // ══════════════════════════════════════════════════════════════════════════
    //
    // P[7:0] holds the 4×4 subarray result (bits [13:8] are 0 since mant[6:4]=0).
    // Leading-zero normalization brings the product MSB to P_shifted[7] or P_shifted[6].

    wire P_msb_e4m3 = P[7];

    // Leading-zero detection: shift left until MSB reaches bit[7] or bit[6].
    reg  [2:0] norm_shift_e4m3;
    always @(*) begin
        if (P[7])      norm_shift_e4m3 = 3'd0;
        else if (P[6]) norm_shift_e4m3 = 3'd0;
        else if (P[5]) norm_shift_e4m3 = 3'd1;
        else if (P[4]) norm_shift_e4m3 = 3'd2;
        else if (P[3]) norm_shift_e4m3 = 3'd3;
        else           norm_shift_e4m3 = 3'd4;   // P=0; guarded by zero check
    end

    wire [7:0] P_shifted_e4m3 = P[7:0] << norm_shift_e4m3;

    // After shift: ps_msb=P_shifted[7] indicates leading-1 at bit 7 (else bit 6).
    wire       ps_msb  = P_shifted_e4m3[7];

    // ── Normal-path mantissa extraction (RNE) ─────────────────────────────────
    wire [2:0] man_raw_e4m3   = ps_msb ? P_shifted_e4m3[6:4] : P_shifted_e4m3[5:3];
    wire       rnd_e4m3       = ps_msb ? P_shifted_e4m3[3]   : P_shifted_e4m3[2];
    wire       sty_e4m3       = ps_msb ? |P_shifted_e4m3[2:0]: |P_shifted_e4m3[1:0];
    wire       do_rnd_e4m3    = rnd_e4m3 & (sty_e4m3 | man_raw_e4m3[0]);
    wire [3:0] man_rd_e4m3    = {1'b0, man_raw_e4m3} + {3'b0, do_rnd_e4m3};
    wire       rnd_carry_e4m3 = man_rd_e4m3[3];
    wire [2:0] f3_out_e4m3    = man_rd_e4m3[2:0];

    // ── Pre-rounding exponent (no rnd_carry) ──────────────────────────────────
    // Used for path selection; avoids rnd_carry inflating e_r from -1→0 or 0→1
    // and sending subnormal products down the normal path.
    wire signed [5:0] e_r_pre_e4m3 = $signed({1'b0, ae_a}) + $signed({1'b0, ae_b})
                                      + {5'b0, ps_msb}
                                      - {3'b0, norm_shift_e4m3}
                                      - 6'sd7;

    // Post-rounding exponent (includes rnd_carry) — used by normal path only.
    wire signed [5:0] e_r_e4m3_s = e_r_pre_e4m3 + {5'b0, rnd_carry_e4m3};

    // ── Special-value flags ────────────────────────────────────────────────────
    wire overflow_e4m3  = (e_r_e4m3_s > 6'sd15);
    wire nan_out_e4m3   = nan_a | nan_b;
    wire zero_out_e4m3  = zero_a | zero_b;
    wire would_nan_e4m3 = (e_r_e4m3_s == 6'sd15) & (&f3_out_e4m3); // avoid NaN codeword

    wire [3:0] e4_out = (overflow_e4m3 | would_nan_e4m3) ? 4'hF : e_r_e4m3_s[3:0];
    wire [2:0] f3_out = (overflow_e4m3 | would_nan_e4m3) ? 3'h6 : f3_out_e4m3;

    // ── Path selection ─────────────────────────────────────────────────────────
    // e_r_pre ≥ 1 → normal output  (uses normal-path rounding above)
    // e_r_pre ∈ {0,-1,-2} → subnormal output (P-based computation below)
    // e_r_pre ≤ -3 → flush to signed zero
    //
    // Python fp8_e4m3_enc reference rule:
    //   if av < 2^(-9) (min subnormal): return s<<7  (flush, NOT RNE)
    //   if 2^(-9) ≤ av < 2^(-6): subnormal with int(round(m_f))
    //
    // Products with e_r_pre ≤ -3 always have magnitude < 2^(-9) → flush.
    // Products with e_r_pre ≥ -2 always have magnitude ≥ 2^(-9) → subnormal or normal.
    wire e4m3_normal_path = (e_r_pre_e4m3 >= 6'sd1);
    wire e4m3_sub_path    = (e_r_pre_e4m3 >= -6'sd2) & (e_r_pre_e4m3 <= 6'sd0);
    wire e4m3_flush_path  = (e_r_pre_e4m3 <= -6'sd3);

    // ── Subnormal output: direct extraction from P_shifted_e4m3 ──────────────
    //
    // Rationale: use P_shifted directly (not the rounded f3_out_e4m3) to get
    // the full mantissa precision needed for correct subnormal rounding.
    //
    // 4-bit normalized mantissa from P_shifted:
    //   ps_msb=1: sub_mant_4 = P_shifted[7:4]  (leading 1 at bit[7])
    //   ps_msb=0: sub_mant_4 = P_shifted[6:3]  (leading 1 at bit[6])
    // sub_low_bits: remaining lower bits of P_shifted for sticky.
    wire [3:0] sub_mant_4  = ps_msb ? P_shifted_e4m3[7:4] : P_shifted_e4m3[6:3];
    wire [3:0] sub_low_4   = ps_msb ? P_shifted_e4m3[3:0] : {1'b0, P_shifted_e4m3[2:0]};

    // Shift amount: sub_sft = 1 - e_r_pre (right shift of sub_mant_4 to get f_sub)
    // e_r_pre=0 → sub_sft=1; e_r_pre=-1 → sub_sft=2; e_r_pre=-2 → sub_sft=3.
    reg  [2:0] e4m3_fsub_raw;
    reg        e4m3_fsub_rnd;
    reg        e4m3_fsub_sty;
    always @(*) begin
        if (e_r_pre_e4m3 == 6'sd0) begin
            // sub_sft = 1
            e4m3_fsub_raw = sub_mant_4[3:1];
            e4m3_fsub_rnd = sub_mant_4[0];
            e4m3_fsub_sty = |sub_low_4;
        end else if (e_r_pre_e4m3 == -6'sd1) begin
            // sub_sft = 2
            e4m3_fsub_raw = {1'b0, sub_mant_4[3:2]};
            e4m3_fsub_rnd = sub_mant_4[1];
            e4m3_fsub_sty = sub_mant_4[0] | (|sub_low_4);
        end else begin
            // sub_sft = 3  (e_r_pre = -2)
            e4m3_fsub_raw = {2'b00, sub_mant_4[3]};
            e4m3_fsub_rnd = sub_mant_4[2];
            e4m3_fsub_sty = |sub_mant_4[1:0] | (|sub_low_4);
        end
    end

    // Python flush rule: if fsub_raw == 0 → flush (no RNE rounding up).
    // This matches fp8_e4m3_enc: values below the minimum representable subnormal
    // (2^(-9)) are truncated to zero, not rounded up.
    wire e4m3_fsub_is_flush = (e4m3_fsub_raw == 3'd0);

    // RNE rounding for non-flush subnormals
    wire       e4m3_fsub_drnd = e4m3_fsub_rnd & (e4m3_fsub_sty | e4m3_fsub_raw[0]);
    wire [3:0] e4m3_fsub_rd   = {1'b0, e4m3_fsub_raw} + {3'b0, e4m3_fsub_drnd};
    // e4m3_fsub_rd[3]: subnormal rounds up to smallest normal (e=1, f=0)

    // ══════════════════════════════════════════════════════════════════════════
    // OUTPUT MUX (registered)
    // ══════════════════════════════════════════════════════════════════════════

    reg [9:0] computed;

    always @(*) begin
        if (!mode_r) begin
            // E3M6 mode
            if (e3_flush)
                computed = {s_r, 9'd0};   // flush subnormal/zero inputs
            else
                computed = {s_r, e_out_e3m6, f_out_e3m6};
        end else begin
            // E4M3 mode
            if (nan_out_e4m3)
                computed = 10'h07F;                          // canonical NaN (positive)
            else if (zero_out_e4m3)
                computed = 10'h000;                          // zero input → always +0
            else if (e4m3_flush_path | (e4m3_sub_path & e4m3_fsub_is_flush))
                computed = {2'b00, s_r, 7'd0};               // signed zero (below min_sub)
            else if (e4m3_sub_path & e4m3_fsub_rd[3])
                computed = {2'b00, s_r, 4'd1, 3'd0};        // subnormal rounded up to smallest normal
            else if (e4m3_sub_path)
                computed = {2'b00, s_r, 4'd0, e4m3_fsub_rd[2:0]};  // subnormal
            else
                computed = {2'b00, s_r, e4_out, f3_out};    // normal / overflow / saturation
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) result <= 10'd0;
        else        result <= computed;
    end

endmodule

`default_nettype wire

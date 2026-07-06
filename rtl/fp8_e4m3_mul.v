// rtl/fp8_e4m3_mul.v — FP8-E4M3FN combinational multiplier.
//
// Spec: OCP 8-Bit Floating Point Specification v1.0 (OCP Alliance, 2023);
//       "FP8 Formats for Deep Learning" (Micikevicius et al., NeurIPS 2022), §3.
//
// Format: 8 bits — [7]=sign, [6:3]=exponent (bias 7), [2:0]=mantissa.
//   Subnormal:  e=0000, value = (-1)^s × (0.mmm) × 2^(1-7).
//   Normal:     e=0001..1111, value = (-1)^s × (1.mmm) × 2^(e-7).
//   NaN:        s.1111.111 only (both signs).  No Inf representation.
//   Max finite: 0.1111.110 = 1.75 × 2^8 = 448.
//
// Multiply semantics:
//   - NaN in → NaN out (0x7F).
//   - Zero × anything → zero.
//   - Subnormal × anything: handled via hidden-bit logic.
//   - Overflow → clamp to max finite ±448 (codeword 0x7E / 0xFE).
//   - Rounding: round-to-nearest-even on the 3-bit mantissa result.
//
// Implementation note: two subnormal inputs are treated correctly by
// extending hidden-bit concatenation to include the subnormal case
// (hidden bit = 0 when e=0, 1 otherwise).

`default_nettype none

module fp8_e4m3_mul (
    input  wire [7:0] a,       // FP8-E4M3FN operand A
    input  wire [7:0] b,       // FP8-E4M3FN operand B
    output reg  [7:0] result   // FP8-E4M3FN product
);

    localparam BIAS     = 4'd7;
    localparam EXP_MASK = 4'hF;   // all-ones exponent
    localparam NAN_CW   = 8'h7F;  // canonical positive NaN
    localparam MAX_CW   = 8'h7E;  // max positive finite 448

    // ── Unpack ────────────────────────────────────────────────────────────────
    wire        s_a = a[7];
    wire [3:0]  e_a = a[6:3];
    wire [2:0]  f_a = a[2:0];
    wire        s_b = b[7];
    wire [3:0]  e_b = b[6:3];
    wire [2:0]  f_b = b[2:0];

    // ── Special value detection ───────────────────────────────────────────────
    wire nan_a  = (e_a == EXP_MASK) & (&f_a);   // s.1111.111
    wire nan_b  = (e_b == EXP_MASK) & (&f_b);
    wire zero_a = (a[6:0] == 7'd0);
    wire zero_b = (b[6:0] == 7'd0);
    wire sub_a  = (e_a == 4'd0) & ~zero_a;       // subnormal (non-zero)
    wire sub_b  = (e_b == 4'd0) & ~zero_b;

    // ── Result sign ───────────────────────────────────────────────────────────
    wire s_r = s_a ^ s_b;

    // ── Mantissa with hidden bit (4 bits: [3]=hidden, [2:0]=fraction) ────────
    wire [3:0] m_a = {~sub_a & ~zero_a, f_a};   // 0 for zero/sub, 1 for normal
    wire [3:0] m_b = {~sub_b & ~zero_b, f_b};

    // 4-bit × 4-bit = 8-bit product
    wire [7:0] P = m_a * m_b;

    // ── Normalisation shift ───────────────────────────────────────────────────
    // Determine how many bits to left-shift P so its leading 1 is at P[6].
    // Normal×Normal: leading 1 always at P[7] or P[6]; shift ∈ {0,1}.
    // Subnormal×Normal: product may have leading 1 as low as P[3] when both
    //   hidden bits are 0 and mantissas are small.  Full leading-zero detection
    //   is required for bit-exact agreement with fp8_e4m3_enc(a*b).
    reg [2:0] norm_shift;
    always @(*) begin
        casez (P[7:0])
            8'b1???????: norm_shift = 3'd0;  // leading 1 at P[7] → right-shift 1
            8'b01??????: norm_shift = 3'd0;  // leading 1 at P[6] → no shift
            8'b001?????: norm_shift = 3'd1;
            8'b0001????: norm_shift = 3'd2;
            8'b00001???: norm_shift = 3'd3;
            8'b000001??: norm_shift = 3'd4;
            8'b0000001?: norm_shift = 3'd5;
            8'b00000001: norm_shift = 3'd6;
            default:     norm_shift = 3'd7;  // P = 0 (zero × zero)
        endcase
    end

    // After shift: leading 1 is at P_sh[6] (or P_sh[7] when P[7]=1)
    wire [7:0] P_sh = P << norm_shift;  // left-shift to normalise

    // For P[7]=1: product was already ≥ 2.0 in 2.6 fixed-point → right-shift 1
    // Unified: P_msb indicates whether the MSB was set before normalisation.
    wire P_msb = P[7];   // set when P ≥ 128 (right-shift needed)

    // ── Exponent arithmetic ───────────────────────────────────────────────────
    // effective biased exponent (subnormal → 1, normal → e)
    wire [4:0] ae_a = sub_a ? 5'd1 : {1'b0, e_a};
    wire [4:0] ae_b = sub_b ? 5'd1 : {1'b0, e_b};

    // e_r_s accounts for: normal exp sum − bias + right-shift(P_msb) − left-shift
    // Range: [1+1-7-6, 15+15-7+1-0] = [-11, 24] → need signed 7-bit, clamp to 6.
    wire signed [6:0] e_r_s7 = $signed({2'b00, ae_a}) + $signed({2'b00, ae_b})
                                - 7'sd7
                                + {6'd0, P_msb}
                                - {4'd0, norm_shift};
    wire signed [5:0] e_r_s  = e_r_s7[5:0];

    // ── Mantissa rounding ─────────────────────────────────────────────────────
    // After normalisation, leading 1 is at P_sh[6] (or P_sh[7] when P_msb=1).
    //   P_msb=1: mantissa[2:0] = P_sh[6:4], round bit = P_sh[3]
    //   P_msb=0: mantissa[2:0] = P_sh[5:3], round bit = P_sh[2]
    wire [2:0] man_raw = P_msb ? P_sh[6:4] : P_sh[5:3];
    wire       rnd_bit = P_msb ? P_sh[3]   : P_sh[2];
    wire       sticky  = P_msb ? |P_sh[2:0] : |P_sh[1:0];

    // Round-to-nearest-even
    wire do_round = rnd_bit & (sticky | man_raw[0]);
    wire [3:0] man_rounded = {1'b0, man_raw} + {3'd0, do_round};

    // Round carry: man_rounded[3] set → mantissa overflowed to 1.000
    wire rnd_carry = man_rounded[3];
    wire [2:0] f_r = man_rounded[2:0];
    wire signed [5:0] e_r_adj = e_r_s + {5'd0, rnd_carry};

    // ── Special cases ─────────────────────────────────────────────────────────
    wire is_nan   = nan_a | nan_b;
    wire is_zero  = zero_a | zero_b;
    wire overflow    = (e_r_adj > 6'sd15);
    wire would_be_nan = (e_r_adj == 6'sd15) & (&f_r);
    // Subnormal result path (e_r_adj == 0):
    //   The product represents 1.f_r × 2^(-7) which falls in the E4M3FN subnormal
    //   range.  The hidden bit must be made explicit by right-shifting 1 position:
    //   f3_sub = { 1, P_sh[5], P_sh[4] }, round = P_sh[3], sticky = |P_sh[2:0]
    //   (for P_msb=0 case where leading 1 is at P_sh[6]; same after P_msb=1 shift).
    wire       sub_result  = (e_r_adj == 6'sd0) & ~is_zero & ~is_nan;
    wire [2:0] f3_sub_raw  = P_msb ? {1'b1, P_sh[6], P_sh[5]}
                                    : {1'b1, P_sh[5], P_sh[4]};
    wire       rnd_sub     = P_msb ? P_sh[4] : P_sh[3];
    wire       sticky_sub  = P_msb ? |P_sh[3:0] : |P_sh[2:0];
    wire       drnd_sub    = rnd_sub & (sticky_sub | f3_sub_raw[0]);
    wire [3:0] f3_sub_rnd  = {1'b0, f3_sub_raw} + {3'd0, drnd_sub};
    wire       sub_to_norm = f3_sub_rnd[3];   // carry → promote to min normal
    wire [2:0] f3_sub      = f3_sub_rnd[2:0];
    // Flush: e_r_adj < 0 and not subnormal boundary
    wire uflow = (e_r_adj < 6'sd0) | is_zero;

    // ── Output mux ────────────────────────────────────────────────────────────
    always @(*) begin
        if (is_nan)
            result = NAN_CW;
        else if (uflow)
            result = {s_r, 7'd0};
        else if (sub_result) begin
            if (sub_to_norm)
                result = {s_r, 4'd1, 3'd0};   // promote to min normal
            else
                result = {s_r, 4'd0, f3_sub};  // subnormal
        end
        else if (overflow | would_be_nan)
            result = {s_r, MAX_CW[6:0]};       // ±448
        else
            result = {s_r, e_r_adj[3:0], f_r};
    end

endmodule

`default_nettype wire

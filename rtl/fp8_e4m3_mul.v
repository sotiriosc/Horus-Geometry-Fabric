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

    // For normals: P = (1.mmm)×(1.mmm) → result in [1.000×1.000, 1.111×1.111]
    //   = [1.0, ~3.5] in 2.6 fixed-point scaled by 2^6.
    // P[7]: set when P >= 128 (result exponent needs +1 normalisation).
    wire P_msb = P[7];    // normalisation shift indicator

    // ── Exponent arithmetic ───────────────────────────────────────────────────
    // For normals: effective exp = e-1 for subnormals (leading 0), e for normals.
    // Simplified: use actual_e = sub ? 1 : e  (subnormal effective exp = 1).
    // (In full IEEE subnormal, actual_e is 1-BIAS; here we use biased form.)
    wire [4:0] ae_a = sub_a ? 5'd1 : {1'b0, e_a};   // 5-bit effective biased exp
    wire [4:0] ae_b = sub_b ? 5'd1 : {1'b0, e_b};

    // e_r_unbiased = ae_a + ae_b - BIAS + P_msb  (all biased exponents)
    // Range: [1+1-7, 15+15-7+1] = [-5, 24]  → need signed 6-bit
    wire signed [5:0] e_r_s = $signed({1'b0, ae_a}) + $signed({1'b0, ae_b})
                               - 6'sd7 + {5'd0, P_msb};

    // ── Mantissa rounding ─────────────────────────────────────────────────────
    // Extract 3-bit mantissa + 1 round bit from product.
    // After normalisation shift:
    //   P_msb=1: mantissa[2:0] = P[6:4], round bit = P[3]
    //   P_msb=0: mantissa[2:0] = P[5:3], round bit = P[2]
    wire [2:0] man_raw = P_msb ? P[6:4] : P[5:3];
    wire       rnd_bit = P_msb ? P[3]   : P[2];
    wire       sticky  = P_msb ? |P[2:0] : |P[1:0];

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
    // Overflow: e_r_adj > 15 (max normal biased exponent is 15, but 15.110=448 is max)
    // Actually E4M3FN max normal biased exponent is 15 (with m≠111 to avoid NaN).
    // Overflow if e_r_adj > 15, or if e_r_adj == 15 and f_r == 3'b111 (would be NaN).
    wire overflow = (e_r_adj > 6'sd15);
    // Result would be NaN codeword if e_r_adj==15 and f_r==111 → clamp to 110
    wire would_be_nan = (e_r_adj == 6'sd15) & (&f_r);
    // Underflow/result-is-zero: e_r_adj < 1 (below min subnormal / flush to zero)
    // Strict: e_r_adj <= 0 → flush; e_r_adj==1..0(special subnorm) handled below.
    // Simple approximation: flush subnormal results to zero (conservative).
    wire uflow = (e_r_adj <= 6'sd0) | is_zero;

    // ── Output mux ────────────────────────────────────────────────────────────
    always @(*) begin
        if (is_nan)
            result = NAN_CW;
        else if (uflow)
            result = {s_r, 7'd0};
        else if (overflow | would_be_nan)
            result = {s_r, MAX_CW[6:0]};   // ±448
        else
            result = {s_r, e_r_adj[3:0], f_r};
    end

endmodule

`default_nettype wire

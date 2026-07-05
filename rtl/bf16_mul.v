// rtl/bf16_mul.v — BF16 (bfloat16) combinational multiplier.
//
// Spec: Google Brain Float16; IEEE 754-2019 single-precision subset;
//       ARM ACLE §6.1.6; defined as upper 16 bits of IEEE 754 float32.
//
// Format: 16 bits — [15]=sign, [14:7]=exponent (bias 127), [6:0]=mantissa.
//   Subnormal: e=00000000, value = (-1)^s × (0.mmmmmmm) × 2^(1-127).
//   Normal:    e=00000001..11111110, value = (-1)^s × (1.mmmmmmm) × 2^(e-127).
//   ±Inf:      e=11111111, m=0000000.
//   NaN:       e=11111111, m≠0000000.
//   Max finite: ~3.39×10^38.
//
// Multiply semantics (IEEE 754 round-to-nearest-even):
//   - NaN × anything  → NaN.
//   - Inf × 0         → NaN.
//   - Inf × finite    → Inf.
//   - 0   × anything  → 0.
//   - Overflow        → ±Inf.
//   - Underflow       → flush to 0 (no subnormal output; BF16 hardware typically
//                       flushes subnormal results to zero).
//   Rounding: round-to-nearest-even on the 7-bit mantissa.
//
// Core multiply: 8-bit × 8-bit unsigned (hidden-bit mantissas) = 16-bit product.
// Exponent add: 8-bit + 8-bit - 127 + normalisation_shift.

`default_nettype none

module bf16_mul (
    input  wire [15:0] a,       // BF16 operand A
    input  wire [15:0] b,       // BF16 operand B
    output reg  [15:0] result   // BF16 product
);

    localparam [7:0] BIAS    = 8'd127;
    localparam [7:0] EXP_MAX = 8'hFF;  // all-ones exponent
    localparam [7:0] EXP_INF = 8'hFF;

    // ── Unpack ────────────────────────────────────────────────────────────────
    wire        s_a = a[15];
    wire [7:0]  e_a = a[14:7];
    wire [6:0]  f_a = a[6:0];
    wire        s_b = b[15];
    wire [7:0]  e_b = b[14:7];
    wire [6:0]  f_b = b[6:0];

    // ── Special value detection ───────────────────────────────────────────────
    wire inf_a   = (e_a == EXP_MAX) & (f_a == 7'd0);
    wire inf_b   = (e_b == EXP_MAX) & (f_b == 7'd0);
    wire nan_a   = (e_a == EXP_MAX) & (f_a != 7'd0);
    wire nan_b   = (e_b == EXP_MAX) & (f_b != 7'd0);
    wire zero_a  = (a[14:0] == 15'd0);
    wire zero_b  = (b[14:0] == 15'd0);
    wire sub_a   = (e_a == 8'd0) & ~zero_a;
    wire sub_b   = (e_b == 8'd0) & ~zero_b;

    // ── Result sign ───────────────────────────────────────────────────────────
    wire s_r = s_a ^ s_b;

    // ── Mantissa with hidden bit (8 bits: [7]=hidden, [6:0]=fraction) ────────
    wire [7:0] m_a = {~sub_a & ~zero_a, f_a};   // 0 for zero/sub, 1 for normal
    wire [7:0] m_b = {~sub_b & ~zero_b, f_b};

    // 8-bit × 8-bit = 16-bit product
    wire [15:0] P = m_a * m_b;

    // For normals: P ∈ [128×128, 255×255] = [16384, 65025].
    // P[15] set when P >= 32768 (need normalisation shift).
    wire P_msb = P[15];

    // ── Exponent arithmetic ───────────────────────────────────────────────────
    wire [8:0] ae_a = sub_a ? 9'd1 : {1'b0, e_a};   // effective biased exponent
    wire [8:0] ae_b = sub_b ? 9'd1 : {1'b0, e_b};

    // e_r = ae_a + ae_b - BIAS + P_msb  (biased)
    // Range: [1+1-127, 254+254-127+1] = [-125, 383]  → 10-bit signed
    wire signed [9:0] e_r_s = $signed({1'b0, ae_a}) + $signed({1'b0, ae_b})
                               - 10'sd127 + {9'd0, P_msb};

    // ── Mantissa rounding (round-to-nearest-even) ─────────────────────────────
    // Extract 7-bit mantissa + 1 round bit + sticky from 16-bit product.
    //   P_msb=1: man[6:0] = P[14:8], round = P[7], sticky = |P[6:0]
    //   P_msb=0: man[6:0] = P[13:7], round = P[6], sticky = |P[5:0]
    wire [6:0] man_raw  = P_msb ? P[14:8] : P[13:7];
    wire       rnd_bit  = P_msb ? P[7]    : P[6];
    wire       sticky   = P_msb ? |P[6:0] : |P[5:0];

    wire do_round = rnd_bit & (sticky | man_raw[0]);
    wire [7:0] man_rounded = {1'b0, man_raw} + {7'd0, do_round};

    wire rnd_carry = man_rounded[7];   // mantissa overflow → 1.000
    wire [6:0] f_r = man_rounded[6:0];
    wire signed [9:0] e_r_adj = e_r_s + {9'd0, rnd_carry};

    // ── Special case logic ────────────────────────────────────────────────────
    wire is_nan      = nan_a | nan_b | (inf_a & zero_b) | (inf_b & zero_a);
    wire is_inf_out  = (inf_a | inf_b) & ~is_nan;
    wire is_zero_out = (zero_a | zero_b) & ~is_nan;
    // Overflow: e_r_adj >= 255 (biased, reserved for Inf/NaN)
    wire overflow    = (e_r_adj >= 10'sd255);
    // Underflow: e_r_adj <= 0 → flush to zero (no subnormal output)
    wire uflow       = (e_r_adj <= 10'sd0) | is_zero_out;

    // ── Output mux ────────────────────────────────────────────────────────────
    always @(*) begin
        if (is_nan)
            result = {s_r, EXP_MAX, 7'b1000000};   // canonical quiet NaN
        else if (is_inf_out | overflow)
            result = {s_r, EXP_MAX, 7'd0};          // ±Inf
        else if (uflow)
            result = {s_r, 15'd0};                   // ±0
        else
            result = {s_r, e_r_adj[7:0], f_r};
    end

endmodule

`default_nettype wire

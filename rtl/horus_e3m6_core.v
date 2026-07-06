// rtl/horus_e3m6_core.v — Standalone E3M6 compact multiplier.
//
// Format: 10 bits — [9]=sign, [8:6]=exponent (bias 4), [5:0]=mantissa.
//   Bias = 4  (= 2^(3-1)).  Max exponent = 7.
//   Normal:    e=1..7, value = (−1)^s × (1 + f/64) × 2^(e−4).
//   Subnormal: e=0, f≠0, value = (−1)^s × (f/64) × 2^(1−4).
//   Zero:      e=0, f=0.
//   Sat:       e=7, f=63 = max finite ≈ 15.875.
//   No NaN, no Inf.
//
// Multiply semantics (mirrors sim/dual_core_model.py _dual_mul_e3m6):
//   - Flush-subnormal-input convention: if either operand has e=0,
//     result is (sr, 0, 0) — signed zero.  Matches NFE-13 floor convention.
//   - Normal × Normal: 7×7 hidden-bit product, 6-bit truncation (no RNE),
//     matching nfe13_mul.v.
//   - Subnormal outputs: products that fall below min_normal (e_r ≤ 0 after
//     bias subtraction) are represented as subnormals, not flushed to zero.
//     f_sub = (64 + fr_normal) >> (1 − e_r); flush only when f_sub rounds to 0
//     (which cannot occur for non-flushed inputs — min f_sub ≥ 8).
//   - Overflow (e_r > 7): saturation to (sr, 7, 63).
//
// Combinational module (no clock/reset), analogous to nfe13_mul.v / fp8_e4m3_mul.v.
// Synthesized as the standalone K1/K2 baseline for the dual-core comparison.
//
// Python source of truth: sim/dual_core_model.py _dual_mul_e3m6 and
//   sim/compact_nfe.py enm6_enc / enm6_dec (n=3).

`default_nettype none

module horus_e3m6_core (
    input  wire [9:0] a,        // E3M6 operand A
    input  wire [9:0] b,        // E3M6 operand B
    output wire [9:0] result    // E3M6 product
);

    localparam [2:0] BIAS    = 3'd4;
    localparam [2:0] EXP_MAX = 3'd7;
    localparam [5:0] FRAC_MAX = 6'h3F;

    // ── Unpack ────────────────────────────────────────────────────────────────
    wire        s_a = a[9];
    wire [2:0]  e_a = a[8:6];
    wire [5:0]  f_a = a[5:0];
    wire        s_b = b[9];
    wire [2:0]  e_b = b[8:6];
    wire [5:0]  f_b = b[5:0];

    // ── Sign ──────────────────────────────────────────────────────────────────
    wire s_r = s_a ^ s_b;

    // ── Flush-subnormal input check ───────────────────────────────────────────
    // If either operand has e=0 (zero or subnormal), result is zero.
    wire flush_in = (e_a == 3'd0) | (e_b == 3'd0);

    // ── 7×7 hidden-bit mantissa product ──────────────────────────────────────
    // Full 7-bit mantissas: {1, f[5:0]}  (value = 64 + f).
    wire [6:0]  m_a = {1'b1, f_a};
    wire [6:0]  m_b = {1'b1, f_b};
    wire [13:0] P   = m_a * m_b;   // product in [4096, 16129]

    wire P_msb = P[13];   // 1 iff P ≥ 8192

    // ── 6-bit mantissa extraction — truncation (no rounding) ─────────────────
    wire [5:0] fr_full = P_msb ? P[12:7] : P[11:6];

    // ── Exponent computation ──────────────────────────────────────────────────
    // e_r = e_a + e_b − 4 + P_msb
    // Using 5-bit arithmetic; e_sum_p ∈ [0, 15].
    wire [4:0] e_sum_p = {2'b00, e_a} + {2'b00, e_b} + {4'b0000, P_msb};

    // Overflow: e_r > 7  →  e_sum_p > 11
    wire sat = (e_sum_p > 5'd11);

    // ── Subnormal output path ─────────────────────────────────────────────────
    // When e_sum_p ≤ 4 (e_r ≤ 0), produce a subnormal result.
    // denorm_shift = 1 − e_r = 5 − e_sum_p  (1, 2, or 3 for e_sum_p 4..2)
    // f_sub = (64 + fr_full) >> denorm_shift
    //
    // Proof that f_sub ≥ 8 for non-flushed inputs (both e ≥ 1):
    //   min e_sum_p = 2 (ea=eb=1, P_msb=0) → denorm_shift=3
    //   min fr_full = 0 → f_sub_min = 64>>3 = 8  ≥ 1 → always non-zero.
    // Therefore no additional flush-to-zero check is needed.
    //
    // Implementation: 3-to-1 shift mux.  Only e_sum_p ∈ {2,3,4} reach here
    // (5 ≤ e_sum_p ≤ 11 is normal; ≥ 12 is sat; < 2 impossible for e≥1).
    wire is_sub_out = ~flush_in & ~sat & (e_sum_p <= 5'd4);
    wire is_normal  = ~flush_in & ~sat & (e_sum_p  > 5'd4);

    // Denormalization shift mux (shift = 5 - e_sum_p)
    wire [6:0] sub_mant_in = {1'b1, fr_full};   // 64 + fr_full
    reg  [5:0] f_sub;
    always @(*) begin
        case (5'd5 - e_sum_p)
            5'd1:    f_sub = sub_mant_in[6:1];    // >> 1
            5'd2:    f_sub = {1'b0, sub_mant_in[6:2]};  // >> 2
            default: f_sub = {2'b00, sub_mant_in[6:3]}; // >> 3
        endcase
    end

    // ── Normal result mantissa + exponent ─────────────────────────────────────
    wire [2:0] e_r_normal = e_sum_p[2:0] - BIAS;   // valid for is_normal

    // ── Output mux ────────────────────────────────────────────────────────────
    wire [2:0] e_out = sat        ? EXP_MAX       :
                       is_normal  ? e_r_normal    :
                       is_sub_out ? 3'd0          : 3'd0;

    wire [5:0] f_out = sat        ? FRAC_MAX      :
                       is_normal  ? fr_full       :
                       is_sub_out ? f_sub         : 6'd0;

    assign result = {s_r, e_out, f_out};

endmodule

`default_nettype wire

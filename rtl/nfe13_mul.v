// rtl/nfe13_mul.v — NFE-13 combinational multiplier.
//
// Implements exactly the nfe_mul_fields() Python function from
// sim/mlp_infer_nfe.py (lines 78-87) and sim/second_source_chain.py
// (lines 100-114).  No pipeline registers; purely combinational.
//
// Format (NFE v3):
//   13 bits: [12]=sign, [11:6]=exponent (bias 32, EXP_MAX 63), [5:0]=mantissa.
//   Sentinel: e=0  → floor (underflow, decodes to 0).
//             e=63 → saturated (max finite value).
//
// Multiply rule (mirrors RTL horus_nfe.v MUL path):
//   P = (64 + f_a) * (64 + f_b)   // 7-bit × 7-bit = 14-bit product
//   If P[13]=1: e_r = e_a + e_b - 32 + 1; f_r = P[12:7]   (truncate, not round)
//   Else:       e_r = e_a + e_b - 32;     f_r = P[11:6]
//   If either operand has e=0: result is floor (s_r, 0, 0).
//   If e_r <= 0:  floor sentinel (s_r, 0, 0).
//   If e_r >= 63: sat  sentinel (s_r, 63, 63).

`default_nettype none

module nfe13_mul (
    input  wire [12:0] a,      // NFE-13 operand A
    input  wire [12:0] b,      // NFE-13 operand B
    output wire [12:0] result  // NFE-13 product
);

    // ── Unpack ────────────────────────────────────────────────────────────────
    wire        s_a = a[12];
    wire [5:0]  e_a = a[11:6];
    wire [5:0]  f_a = a[5:0];
    wire        s_b = b[12];
    wire [5:0]  e_b = b[11:6];
    wire [5:0]  f_b = b[5:0];

    // ── Sign ──────────────────────────────────────────────────────────────────
    wire s_r = s_a ^ s_b;

    // ── Floor input check ─────────────────────────────────────────────────────
    wire is_floor_in = (e_a == 6'd0) | (e_b == 6'd0);

    // ── Mantissa product (7-bit × 7-bit → 14-bit) ────────────────────────────
    wire [6:0]  m_a = {1'b1, f_a};      // 64..127
    wire [6:0]  m_b = {1'b1, f_b};
    wire [13:0] P   = m_a * m_b;        // 4096..16129

    wire        P_msb = P[13];          // 1 iff P >= 8192

    // ── Mantissa result (truncate to 6 bits) ──────────────────────────────────
    wire [5:0]  f_r_raw = P_msb ? P[12:7] : P[11:6];

    // ── Exponent result ───────────────────────────────────────────────────────
    // e_r = e_a + e_b - 32 + P_msb
    // Using 8-bit unsigned arithmetic; underflow iff e_sum_p <= 32, sat iff > 95.
    wire [7:0]  e_sum = {2'b00, e_a} + {2'b00, e_b};
    wire [7:0]  e_sum_p = e_sum + {7'd0, P_msb};

    wire uflow = is_floor_in | (e_sum_p <= 8'd32);   // e_r <= 0
    wire sat   = (e_sum_p > 8'd95);                   // e_r >= 64 (> EXP_MAX)

    wire [5:0]  e_r_raw = e_sum_p[5:0] - 6'd32;       // valid when !uflow && !sat

    // ── Pack result ───────────────────────────────────────────────────────────
    wire [5:0]  e_r = sat   ? 6'h3F :
                      uflow ? 6'h00 : e_r_raw;
    wire [5:0]  f_r = sat   ? 6'h3F :
                      uflow ? 6'h00 : f_r_raw;

    assign result = {s_r, e_r, f_r};

endmodule

`default_nettype wire

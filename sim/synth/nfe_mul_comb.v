// nfe_mul_comb.v — Standard NFE MUL, combinational-only
// Mirrors horus_nfe.v lines 494-533 (2'b10 case), clocks removed.
// Inputs: two 13-bit NFE operands {s[12], e[11:6], m[5:0]}
// Outputs: 13-bit NFE result, underflow_flag, exp_ovf_flag
//
// Three-mux output path:
//   1) 7×7 hidden-bit multiply  →  14-bit product  (P)
//   2) 8-bit exponent summation →  underflow / overflow guards
//   3) Result mux:  underflow → zero;  overflow → sat;  else → normal

module nfe_mul_comb (
    input  wire [12:0] op_a,
    input  wire [12:0] op_b,
    output wire [12:0] result,
    output wire        underflow_flag,
    output wire        exp_ovf_flag
);
    localparam [5:0] EXP_BIAS = 6'd32;
    localparam [5:0] EXP_MAX  = 6'h3F;
    localparam [5:0] MANT_MAX = 6'h3F;

    wire       s_a = op_a[12];
    wire [5:0] e_a = op_a[11:6];
    wire [5:0] m_a = op_a[5:0];
    wire       s_b = op_b[12];
    wire [5:0] e_b = op_b[11:6];
    wire [5:0] m_b = op_b[5:0];

    // Step 1 — sign
    wire res_sign = s_a ^ s_b;

    // Step 2 — hidden-bit 7×7 mantissa multiply → 14-bit product
    // P[13]=1 means MSB of product is at bit 13 (product ≥ 8192)
    wire [13:0] P = {1'b1, m_a} * {1'b1, m_b};

    // Step 3 — biased exponent sum (8-bit, guard bits[7:6])
    //   underflow:  exp_sum[7]=1  (wrapped below 0)
    //   overflow:   exp_sum[6]=1  (stored_E > 63)
    //   normal:     exp_sum[7:6]=00
    wire [7:0] exp_sum = {2'b0, e_a} + {2'b0, e_b}
                         - {2'b0, EXP_BIAS}
                         + (P[13] ? 8'd1 : 8'd0);

    // Step 4 — guard checks
    assign underflow_flag = exp_sum[7];
    assign exp_ovf_flag   = ~exp_sum[7] & exp_sum[6];

    // Fractional bits: adjacent to whichever hidden-1 fired
    wire [5:0] f_result = P[13] ? P[12:7] : P[11:6];

    // Step 5 — result mux (three-way)
    assign result = underflow_flag ? {res_sign, 6'd0,    6'd0   } :
                    exp_ovf_flag   ? {res_sign, EXP_MAX, MANT_MAX} :
                                     {res_sign, exp_sum[5:0], f_result};
endmodule

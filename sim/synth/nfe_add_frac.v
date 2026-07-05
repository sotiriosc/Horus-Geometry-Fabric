// nfe_add_frac.v — Standard NFE ADD_FRAC combinational logic
// Mirrors horus_nfe.v lines 318-340 exactly.
// Inputs:
//   e_a[5:0]  stored exponent of op_a
//   m_a[5:0]  fraction field of op_a
//   s_a       sign bit of op_a
//   m_b[5:0]  fractional delta Δ (raw, no hidden bit)
// Outputs:
//   result[12:0]  NFE-encoded result
//   rollover_flag  1 = Thoth Rollover fired
//   exp_ovf_flag   1 = exponent overflowed to saturation

module nfe_add_frac (
    input  wire [5:0]  e_a,
    input  wire [5:0]  m_a,
    input  wire        s_a,
    input  wire [5:0]  m_b,
    output wire [12:0] result,
    output wire        rollover_flag,
    output wire        exp_ovf_flag
);
    localparam [5:0] EXP_MAX  = 6'b111111;
    localparam [5:0] MANT_MAX = 6'b111111;

    // 8-bit adder: {0, 1, m_a} + {00, m_b}
    // bit[7] = overflow into bit above hidden-bit position = Thoth Rollover
    wire [7:0] mant_sum;
    assign mant_sum = {1'b0, 1'b1, m_a} + {2'b0, m_b};

    wire rollover = mant_sum[7];

    // Exponent increment (7-bit to detect overflow)
    wire [6:0] exp_next = {1'b0, e_a} + 7'd1;
    wire exp_ovf = rollover & exp_next[6];

    // Fraction result: rollover -> sum[6:1], no rollover -> sum[5:0]
    wire [5:0] f_out = rollover ? mant_sum[6:1] : mant_sum[5:0];

    // Exponent result: rollover -> exp_next[5:0], no rollover -> e_a
    wire [5:0] e_out = rollover ? exp_next[5:0] : e_a;

    // Saturate if exponent overflowed
    wire [5:0] e_final = exp_ovf ? EXP_MAX  : e_out;
    wire [5:0] f_final = exp_ovf ? MANT_MAX : f_out;

    assign result       = {s_a, e_final, f_final};
    assign rollover_flag = rollover;
    assign exp_ovf_flag  = exp_ovf;

endmodule

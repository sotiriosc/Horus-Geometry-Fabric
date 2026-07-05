// synth_add_isolated.v
// Combinational extracts for Yosys gate-count synthesis.
// Standard NFE ADD_FRAC logic mirrors horus_nfe.v lines 318-340 (2'b00 case).

module nfe_add_frac_comb (
    input  wire [5:0] m_a,
    input  wire [5:0] m_b,      // raw fractional delta (op_b[5:0])
    input  wire       s_a,
    input  wire [5:0] e_a,
    output wire       rollover_flag,
    output wire       exp_ovf_flag,
    output wire [12:0] result
);
    localparam EXP_W    = 6;
    localparam [5:0] EXP_MAX  = 6'd63;
    localparam [5:0] MANT_MAX = 6'd63;

    wire [7:0] mant_sum;
    wire [6:0] exp_next;
    wire [12:0] computed_noroll;
    wire [12:0] computed_roll;
    wire [12:0] computed_sat;
    wire [12:0] computed;

    // 8-bit mantissa add: (64 + f_a) + delta
    assign mant_sum = {1'b0, 1'b1, m_a} + {2'b0, m_b};

    assign rollover_flag = mant_sum[7];
    assign exp_next      = {1'b0, e_a} + 7'd1;
    assign exp_ovf_flag  = mant_sum[7] && exp_next[6];

    assign computed_noroll = {s_a, e_a, mant_sum[5:0]};
    assign computed_roll   = {s_a, exp_next[EXP_W-1:0], mant_sum[6:1]};
    assign computed_sat    = {s_a, EXP_MAX, MANT_MAX};

    assign computed = mant_sum[7]
                    ? (exp_next[6] ? computed_sat : computed_roll)
                    : computed_noroll;

    assign result = computed;
endmodule

// Block-scaled intra-block accumulator add (no rollover / exponent logic)
module blk_add9_comb (
    input  wire [8:0]  acc,
    input  wire [8:0]  operand,
    output wire [8:0]  sum
);
    assign sum = acc + operand;
endmodule

module blk_add17_comb (
    input  wire [16:0] acc,
    input  wire [16:0] operand,
    output wire [16:0] sum
);
    assign sum = acc + operand;
endmodule

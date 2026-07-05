// blk_add_17.v — Block-scaled 17-bit accumulator adder
// Pure CPA: no rollover, no exponent, no saturation.
// Adds one 14-bit mantissa product to a 17-bit running accumulator.
// (17 bits holds max 16 * 16129 = 258064, needs 18 bits;
//  using 17 here per prior derivation; also synthesize 18-bit variant.)
module blk_add_17 (
    input  wire [16:0] acc_in,
    input  wire [13:0] mant_in,
    output wire [16:0] acc_out
);
    assign acc_out = acc_in + {3'b0, mant_in};
endmodule

// 18-bit variant (exact capacity for 16 * 127*127 = 258064)
module blk_add_18 (
    input  wire [17:0] acc_in,
    input  wire [13:0] mant_in,
    output wire [17:0] acc_out
);
    assign acc_out = acc_in + {4'b0, mant_in};
endmodule

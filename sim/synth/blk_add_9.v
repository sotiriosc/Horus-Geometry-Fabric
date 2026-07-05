// blk_add_9.v — Block-scaled 9-bit accumulator adder
// Pure CPA: no rollover, no exponent, no saturation.
// Adds one 7-bit mantissa product to a 9-bit running accumulator.
// (9 bits holds max 16 * 127 = 2032, which fits in 11 bits;
//  for the strict chain intra-block case with 7-bit inputs.)
module blk_add_9 (
    input  wire [8:0] acc_in,
    input  wire [6:0] mant_in,
    output wire [8:0] acc_out
);
    assign acc_out = acc_in + {2'b0, mant_in};
endmodule

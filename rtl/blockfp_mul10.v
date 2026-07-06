// rtl/blockfp_mul10.v — 10×10 signed mantissa multiplier (E0M9 element datapath).
//
// K3 iso-silicon probe for docs/BLOCKFP_HYPOTHESIS.md: an E0M9 block-FP
// element is 1 sign + 9 mantissa bits; its element-wise product is a
// 10-bit signed × 10-bit signed multiply. This is the quadratic-growth
// price of E0M9's 3 extra mantissa bits — synthesized under the identical
// flow so any E0M9 quality win is priced.

`default_nettype none

module blockfp_mul10 (
    input  wire signed [9:0]  a,
    input  wire signed [9:0]  b,
    output wire signed [19:0] p
);

    assign p = a * b;

endmodule

`default_nettype wire

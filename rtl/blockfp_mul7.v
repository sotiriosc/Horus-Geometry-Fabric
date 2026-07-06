// rtl/blockfp_mul7.v — 7×7 signed mantissa multiplier (E0M6 element datapath).
//
// K3 iso-silicon probe for docs/BLOCKFP_HYPOTHESIS.md: an E0M6 block-FP
// element is 1 sign + 6 mantissa bits; its element-wise product is a 7-bit
// signed × 7-bit signed multiply (block exponents add as small integers at
// block level and are excluded here, exactly as the per-element exponent
// path is included in horus_e3m6_core for the float comparison point).
//
// Combinational, no rounding/normalization — block FP products feed an
// integer accumulator at the shared scale.

`default_nettype none

module blockfp_mul7 (
    input  wire signed [6:0]  a,
    input  wire signed [6:0]  b,
    output wire signed [13:0] p
);

    assign p = a * b;

endmodule

`default_nettype wire

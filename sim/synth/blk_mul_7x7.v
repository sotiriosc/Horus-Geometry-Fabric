// blk_mul_7x7.v — Block-scaled mantissa multiply
// Pure 7×7 unsigned multiply; no exponent, no normalization, no saturation.
// Inputs:  man_a[6:0]  = {1, frac_a}  (hidden-bit mantissa, range 64–127)
//          man_b[6:0]  = {1, frac_b}  (hidden-bit mantissa, range 64–127)
// Output: product[13:0] = man_a × man_b  (14-bit, range 4096–16129)

module blk_mul_7x7 (
    input  wire [6:0]  man_a,
    input  wire [6:0]  man_b,
    output wire [13:0] product
);
    assign product = man_a * man_b;
endmodule

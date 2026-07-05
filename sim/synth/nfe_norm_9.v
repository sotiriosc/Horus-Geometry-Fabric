// nfe_norm_9.v — Block-scaling NORM for 9-bit chain accumulator
//
// Applied once per block (every 16 additions) on the deep-chain path.
//
// Hardware sub-circuits:
//   1. CLZ (priority encoder): 9-bit unsigned input → 4-bit leading-zero count
//      (lz=0 → MSB at bit 8; lz=8 → MSB at bit 0; lz=9 → all zeros)
//   2. Barrel-shifter: left-align acc so MSB reaches bit 8, extract bits[7:2]
//      as the 6-bit fractional mantissa
//   3. Exponent adder:  E_out = E_block_in + (8 - lz) - 6
//                             = E_block_in + 2 - lz    (7-bit signed intermediate)
//   4. Saturation mux: clamp to EXP_MAX / MANT_MAX if exponent overflows
//
// Inputs:
//   acc[8:0]        unsigned integer accumulator (sum of up to 16 seven-bit mantissa values)
//   E_block_in[5:0] shared block reference exponent
// Outputs:
//   result[12:0]    NFE-encoded {sign=0, E_out[5:0], mantissa[5:0]}
//   zero_flag       acc = 0 → output is arithmetic zero
//   sat_flag        exponent overflowed → output saturated

module nfe_norm_9 (
    input  wire [8:0]  acc,
    input  wire [5:0]  E_block_in,
    output wire [12:0] result,
    output wire        zero_flag,
    output wire        sat_flag
);
    localparam [5:0] EXP_MAX  = 6'h3F;
    localparam [5:0] MANT_MAX = 6'h3F;

    // ── 1. Priority encoder (CLZ) ─────────────────────────────────────────────
    // Synthesises as a 9-input priority mux chain
    wire [3:0] lz =  acc[8] ? 4'd0 :
                     acc[7] ? 4'd1 :
                     acc[6] ? 4'd2 :
                     acc[5] ? 4'd3 :
                     acc[4] ? 4'd4 :
                     acc[3] ? 4'd5 :
                     acc[2] ? 4'd6 :
                     acc[1] ? 4'd7 :
                     acc[0] ? 4'd8 : 4'd9;  // 9 = all-zero

    assign zero_flag = (lz == 4'd9);

    // ── 2. Barrel shifter ─────────────────────────────────────────────────────
    // Left-shift acc by lz positions so MSB lands on bit 8
    // mantissa = shifted[7:2]  (6 fractional bits after the implied leading-1 at bit 8)
    wire [8:0] shifted   = acc << lz;
    wire [5:0] mantissa  = shifted[7:2];

    // ── 3. Exponent computation ───────────────────────────────────────────────
    // MSB of acc is at bit (8 - lz); NFE exponent formula:
    //   E_out = E_block_in + (8 - lz) - 6
    //         = E_block_in + 2 - lz
    // Use 8-bit arithmetic to detect overflow and underflow:
    //   exp_raw[7]   = borrow (underflow: E_out < 0)
    //   exp_raw[6]   = overflow beyond 6-bit range
    wire [7:0] exp_raw   = {2'b0, E_block_in} + 8'd2 - {4'b0, lz};
    wire exp_underflow   = exp_raw[7];            // E_out wrapped negative
    wire exp_overflow    = ~exp_raw[7] & (exp_raw[6:0] > 7'd63);

    // ── 4. Saturation ─────────────────────────────────────────────────────────
    assign sat_flag = exp_overflow & ~zero_flag;

    wire [5:0] E_final = sat_flag   ? EXP_MAX  :
                         zero_flag  ? 6'd0      :
                         exp_underflow ? 6'd0   : exp_raw[5:0];
    wire [5:0] f_final = sat_flag   ? MANT_MAX :
                         (zero_flag | exp_underflow) ? 6'd0 : mantissa;

    assign result = {1'b0, E_final, f_final};
endmodule

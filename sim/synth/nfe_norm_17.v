// nfe_norm_17.v — Block-scaling NORM for 17-bit matvec row accumulator
//
// Applied once per row (every 8 MACs on the 8×8 matvec path, block_size=8).
//
// Identical structure to nfe_norm_9, scaled to 17-bit input:
//   1. CLZ:  17-bit input → 5-bit leading-zero count
//   2. Barrel-shifter:  left-align to bit 16, extract bits[15:10] as mantissa
//   3. Exponent adder:  E_out = E_block_in + (16 - lz) - 6
//                             = E_block_in + 10 - lz
//   4. Saturation mux
//
// Inputs:
//   acc[16:0]       unsigned integer accumulator (sum of up to 8 fourteen-bit mantissa products)
//   E_block_in[5:0] shared block reference exponent
// Outputs:
//   result[12:0]    NFE-encoded {sign=0, E_out[5:0], mantissa[5:0]}
//   zero_flag
//   sat_flag

module nfe_norm_17 (
    input  wire [16:0] acc,
    input  wire [5:0]  E_block_in,
    output wire [12:0] result,
    output wire        zero_flag,
    output wire        sat_flag
);
    localparam [5:0] EXP_MAX  = 6'h3F;
    localparam [5:0] MANT_MAX = 6'h3F;

    // ── 1. Priority encoder (CLZ) — 17-input priority mux chain ──────────────
    wire [4:0] lz =  acc[16] ? 5'd0  :
                     acc[15] ? 5'd1  :
                     acc[14] ? 5'd2  :
                     acc[13] ? 5'd3  :
                     acc[12] ? 5'd4  :
                     acc[11] ? 5'd5  :
                     acc[10] ? 5'd6  :
                     acc[ 9] ? 5'd7  :
                     acc[ 8] ? 5'd8  :
                     acc[ 7] ? 5'd9  :
                     acc[ 6] ? 5'd10 :
                     acc[ 5] ? 5'd11 :
                     acc[ 4] ? 5'd12 :
                     acc[ 3] ? 5'd13 :
                     acc[ 2] ? 5'd14 :
                     acc[ 1] ? 5'd15 :
                     acc[ 0] ? 5'd16 : 5'd17;  // 17 = all-zero

    assign zero_flag = (lz == 5'd17);

    // ── 2. Barrel shifter — 17-bit left, 5-bit shift amount ──────────────────
    // Left-shift acc by lz so MSB lands on bit 16
    // mantissa = shifted[15:10]  (6 fractional bits after leading-1 at bit 16)
    wire [16:0] shifted  = acc << lz;
    wire [5:0]  mantissa = shifted[15:10];

    // ── 3. Exponent computation ───────────────────────────────────────────────
    // MSB at bit (16 - lz); NFE exponent:
    //   E_out = E_block_in + (16 - lz) - 6
    //         = E_block_in + 10 - lz
    wire [7:0] exp_raw    = {2'b0, E_block_in} + 8'd10 - {3'b0, lz};
    wire exp_underflow    = exp_raw[7];
    wire exp_overflow     = ~exp_raw[7] & (exp_raw[6:0] > 7'd63);

    // ── 4. Saturation ─────────────────────────────────────────────────────────
    assign sat_flag = exp_overflow & ~zero_flag;

    wire [5:0] E_final = sat_flag      ? EXP_MAX  :
                         zero_flag     ? 6'd0      :
                         exp_underflow ? 6'd0      : exp_raw[5:0];
    wire [5:0] f_final = sat_flag      ? MANT_MAX  :
                         (zero_flag | exp_underflow) ? 6'd0 : mantissa;

    assign result = {1'b0, E_final, f_final};
endmodule

// rtl/horus_tile.v — Heterogeneous E4M3/E3M6 compute tile.
//
// Architecture mandated by DUAL_CORE_RESULTS.md (K1/K2 FAIL → fallback):
//   fp8_e4m3_mul    — inference multiplier (combinational, 8-bit)
//   horus_e3m6_core — accumulation multiplier (combinational, 10-bit)
//   horus_norm_v2   — shared block-exponent normalizer (1-cycle latency)
//   shim_e4m3       — E4M3→NFE-13 format adapter (lossless, no rounding)
//   shim_e3m6       — E3M6→NFE-13 format adapter (lossless, no rounding)
//   8-deep buffer + 3-bit counter + fire_pending register
//
// Operation (single-pair interface):
//   - valid_in asserted: one (op_a, op_b) pair is multiplied and the
//     result shimmed to NFE-13 is written to the internal buffer.
//   - After 8 consecutive valid_in cycles the buffer is full.
//   - fire_pending is registered one cycle after the 8th write.
//   - On the cycle when fire_pending is set, norm_v2 is triggered.
//   - One cycle later: norm_valid pulses and norm_out_0..7 carry the
//     block-normalized NFE-13 outputs alongside norm_e_max.
//
// Constraints:
//   - No combinational paths cross between fp8_e4m3_mul and horus_e3m6_core.
//   - Both cores receive operands simultaneously; mode_r routes their outputs.
//   - The norm_v2 instance is the ONLY normalizer in this module (K3).
//   - Power statements: none — area only.
//
// K2: bit-exact multiply per mode — fp8_e4m3_mul and horus_e3m6_core are
//     instantiated verbatim; tile adds zero arithmetic deviation.
// K3: single horus_norm_v2 instance; mode_r routes the shim output only.
//
// Python source of truth: sim/tile_model.py
// Golden vectors: sim/TILE_E4M3_GOLDEN.hex, sim/TILE_E3M6_GOLDEN.hex

`default_nettype none

module horus_tile (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        mode,      // 0=E3M6 accumulation, 1=E4M3 inference
    input  wire [9:0]  op_a,      // E4M3: [7:0]; E3M6: [9:0]
    input  wire [9:0]  op_b,      // E4M3: [7:0]; E3M6: [9:0]
    input  wire        valid_in,  // one multiply pair per asserted cycle

    output wire        norm_valid,    // pulses 1 cycle after 8-pair block completes
    output wire [5:0]  norm_e_max,    // block exponent (from norm_v2)
    output wire [12:0] norm_out_0,    // 8 normalized NFE-13 outputs
    output wire [12:0] norm_out_1,
    output wire [12:0] norm_out_2,
    output wire [12:0] norm_out_3,
    output wire [12:0] norm_out_4,
    output wire [12:0] norm_out_5,
    output wire [12:0] norm_out_6,
    output wire [12:0] norm_out_7
);

    // ── Registered mode (clean pipeline boundary) ─────────────────────────────
    reg mode_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) mode_r <= 1'b0;
        else        mode_r <= mode;

    // ══════════════════════════════════════════════════════════════════════════
    // E4M3 CORE (fp8_e4m3_mul, combinational, 8-bit)
    // ══════════════════════════════════════════════════════════════════════════
    wire [7:0] e4m3_result;
    fp8_e4m3_mul u_e4m3 (
        .a      (op_a[7:0]),
        .b      (op_b[7:0]),
        .result (e4m3_result)
    );

    // ══════════════════════════════════════════════════════════════════════════
    // E3M6 CORE (horus_e3m6_core, combinational, 10-bit)
    // ══════════════════════════════════════════════════════════════════════════
    wire [9:0] e3m6_result;
    horus_e3m6_core u_e3m6 (
        .a      (op_a),
        .b      (op_b),
        .result (e3m6_result)
    );

    // ══════════════════════════════════════════════════════════════════════════
    // SHIM: E4M3 → NFE-13 (lossless, no rounding; K2 preserved)
    // ══════════════════════════════════════════════════════════════════════════
    //
    // Bias shift: E4M3 bias 7 → NFE-13 bias 32: +25
    // Fraction:   E4M3 3-bit f3 → 6-bit NFE by zero-padding 3 LSBs
    // Special:    zero (e4=0, f3=0), subnormal (e4=0, f3≠0), NaN (e4=15,f3=7)
    //             → NFE floor (zero for accumulation safety)
    //
    function [12:0] shim_e4m3_to_nfe13;
        input [7:0] cw;
        reg         s;
        reg  [3:0]  e4;
        reg  [2:0]  f3;
        reg  [5:0]  e6;
        begin
            s  = cw[7];
            e4 = cw[6:3];
            f3 = cw[2:0];
            if (e4 == 4'b0 || (e4 == 4'hF && (&f3)))
                shim_e4m3_to_nfe13 = {s, 12'b0};   // zero / sub / NaN → floor
            else begin
                e6 = e4 + 6'd25;                    // bias 7 → 32
                shim_e4m3_to_nfe13 = {s, e6, f3, 3'b0};  // f3 zero-padded to 6 bits
            end
        end
    endfunction

    wire [12:0] nfe_e4m3 = shim_e4m3_to_nfe13(e4m3_result);

    // ══════════════════════════════════════════════════════════════════════════
    // SHIM: E3M6 → NFE-13 (lossless; K2 preserved)
    // ══════════════════════════════════════════════════════════════════════════
    //
    // Bias shift: E3M6 bias 4 → NFE-13 bias 32: +28
    // Fraction:   E3M6 6-bit f6 = NFE-13 6-bit f6 — direct copy
    // Special:    zero/subnormal (e3=0) → NFE floor
    //
    function [12:0] shim_e3m6_to_nfe13;
        input [9:0] cw;
        reg         s;
        reg  [2:0]  e3;
        reg  [5:0]  f6;
        reg  [5:0]  e6;
        begin
            s  = cw[9];
            e3 = cw[8:6];
            f6 = cw[5:0];
            if (e3 == 3'b0)
                shim_e3m6_to_nfe13 = {s, 12'b0};   // zero or flushed sub → floor
            else begin
                e6 = {3'b0, e3} + 6'd28;            // bias 4 → 32
                shim_e3m6_to_nfe13 = {s, e6, f6};
            end
        end
    endfunction

    wire [12:0] nfe_e3m6 = shim_e3m6_to_nfe13(e3m6_result);

    // ── Mode-steered shim output ───────────────────────────────────────────────
    // mode_r selects which shim output enters the buffer.
    // No combinational path between the two cores; only the output mux crosses.
    wire [12:0] shim_out = mode_r ? nfe_e4m3 : nfe_e3m6;

    // ══════════════════════════════════════════════════════════════════════════
    // 8-DEEP BUFFER + COUNTER + FIRE LOGIC
    // ══════════════════════════════════════════════════════════════════════════
    // 8 individual registers (Verilog port-connect compatible)

    reg [12:0] buf_0, buf_1, buf_2, buf_3;
    reg [12:0] buf_4, buf_5, buf_6, buf_7;
    reg  [2:0] cnt;          // next-write slot (0..7); wraps 7→0
    reg        fire_pending; // set when 8th slot is written

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_0 <= 13'd0; buf_1 <= 13'd0;
            buf_2 <= 13'd0; buf_3 <= 13'd0;
            buf_4 <= 13'd0; buf_5 <= 13'd0;
            buf_6 <= 13'd0; buf_7 <= 13'd0;
            cnt          <= 3'd0;
            fire_pending <= 1'b0;
        end else begin
            fire_pending <= 1'b0;
            if (valid_in) begin
                case (cnt)
                    3'd0: buf_0 <= shim_out;
                    3'd1: buf_1 <= shim_out;
                    3'd2: buf_2 <= shim_out;
                    3'd3: buf_3 <= shim_out;
                    3'd4: buf_4 <= shim_out;
                    3'd5: buf_5 <= shim_out;
                    3'd6: buf_6 <= shim_out;
                    3'd7: buf_7 <= shim_out;
                endcase
                if (cnt == 3'd7)
                    fire_pending <= 1'b1;
                cnt <= cnt + 3'd1;
            end
        end
    end

    // ══════════════════════════════════════════════════════════════════════════
    // SHARED NORMALIZER: horus_norm_v2 (one instance, both modes — K3)
    // ══════════════════════════════════════════════════════════════════════════
    horus_norm_v2 #(.E_TARGET(6'd32)) u_norm (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (fire_pending),
        .in_0        (buf_0),
        .in_1        (buf_1),
        .in_2        (buf_2),
        .in_3        (buf_3),
        .in_4        (buf_4),
        .in_5        (buf_5),
        .in_6        (buf_6),
        .in_7        (buf_7),
        .offset_mode (1'b0),
        .offset_in   (7'd0),
        .valid_out   (norm_valid),
        .e_max_out   (norm_e_max),
        .out_0       (norm_out_0),
        .out_1       (norm_out_1),
        .out_2       (norm_out_2),
        .out_3       (norm_out_3),
        .out_4       (norm_out_4),
        .out_5       (norm_out_5),
        .out_6       (norm_out_6),
        .out_7       (norm_out_7)
    );

endmodule

`default_nettype wire

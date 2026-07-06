// rtl/horus_tile_v2.v — Respecified heterogeneous E4M3/E3M6 compute tile.
//
// Respecification mandated by docs/TILE_RESULTS.md (K1 FAIL at 45.1% glue):
// the v1 tile's 8×13-bit serial buffer (104 DFFs = 2,602 µm²) alone exceeded
// the entire K1 glue budget. The buffer and the norm_v2 instance are
// block-level machinery and are hoisted to system level. What remains in
// the tile is exactly the per-pair datapath:
//
//   fp8_e4m3_mul    — inference multiplier (combinational, 8-bit)
//   horus_e3m6_core — accumulation multiplier (combinational, 10-bit)
//   shim_e4m3       — E4M3→NFE-13 format adapter (lossless, no rounding)
//   shim_e3m6       — E3M6→NFE-13 format adapter (lossless, no rounding)
//   mode_r          — registered mode select (the tile's only state)
//
// Operation (single-pair, single-cycle):
//   - Both cores receive (op_a, op_b) combinationally every cycle.
//   - mode_r selects which core's shimmed output drives nfe_out.
//   - nfe_out is combinational: one NFE-13 product per cycle, ready to
//     feed an external block accumulator + horus_norm_v2 at system level.
//
// Constraints (carried from v1):
//   - No combinational paths cross between the two cores; only the output
//     mux joins them.
//   - fp8_e4m3_mul and horus_e3m6_core are instantiated verbatim; the tile
//     adds zero arithmetic deviation (K2).
//   - No buffer, no normalizer instance — those costs move to system level
//     and are NOT eliminated (stated plainly in docs/TILE_V2_RESULTS.md).
//
// Python source of truth: sim/tile_model.py (shims), sim/tile_v2_golden.py
// Golden vectors: sim/TILE_V2_E4M3_OUT.hex, sim/TILE_V2_E3M6_OUT.hex

`default_nettype none

module horus_tile_v2 (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        mode,      // 0=E3M6 accumulation, 1=E4M3 inference
    input  wire [9:0]  op_a,      // E4M3: [7:0]; E3M6: [9:0]
    input  wire [9:0]  op_b,      // E4M3: [7:0]; E3M6: [9:0]

    output wire [12:0] nfe_out    // shimmed NFE-13 product (combinational)
);

    // ── Registered mode (clean pipeline boundary; the tile's only DFF) ────────
    reg mode_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) mode_r <= 1'b0;
        else        mode_r <= mode;

    // ══════════════════════════════════════════════════════════════════════════
    // E4M3 CORE (fp8_e4m3_mul, combinational, 8-bit) — verbatim instance
    // ══════════════════════════════════════════════════════════════════════════
    wire [7:0] e4m3_result;
    fp8_e4m3_mul u_e4m3 (
        .a      (op_a[7:0]),
        .b      (op_b[7:0]),
        .result (e4m3_result)
    );

    // ══════════════════════════════════════════════════════════════════════════
    // E3M6 CORE (horus_e3m6_core, combinational, 10-bit) — verbatim instance
    // ══════════════════════════════════════════════════════════════════════════
    wire [9:0] e3m6_result;
    horus_e3m6_core u_e3m6 (
        .a      (op_a),
        .b      (op_b),
        .result (e3m6_result)
    );

    // ══════════════════════════════════════════════════════════════════════════
    // SHIM: E4M3 → NFE-13 (identical to v1; verified in sim/tile_model.py)
    // ══════════════════════════════════════════════════════════════════════════
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
                shim_e4m3_to_nfe13 = {s, e6, f3, 3'b0};
            end
        end
    endfunction

    wire [12:0] nfe_e4m3 = shim_e4m3_to_nfe13(e4m3_result);

    // ══════════════════════════════════════════════════════════════════════════
    // SHIM: E3M6 → NFE-13 (identical to v1; verified in sim/tile_model.py)
    // ══════════════════════════════════════════════════════════════════════════
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
                shim_e3m6_to_nfe13 = {s, 12'b0};   // zero / flushed sub → floor
            else begin
                e6 = {3'b0, e3} + 6'd28;            // bias 4 → 32
                shim_e3m6_to_nfe13 = {s, e6, f6};
            end
        end
    endfunction

    wire [12:0] nfe_e3m6 = shim_e3m6_to_nfe13(e3m6_result);

    // ── Mode-steered output mux (only point where the two paths join) ─────────
    assign nfe_out = mode_r ? nfe_e4m3 : nfe_e3m6;

endmodule

`default_nettype wire

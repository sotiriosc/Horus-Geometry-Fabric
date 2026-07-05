`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_norm_v2
// File     : rtl/horus_norm_v2.v
// Date     : 2026-07-05
//
// Purpose  : 8-element block-exponent normalizer — version 2.
//
//            Extends horus_norm (rtl/horus_norm.v) with two additions:
//
//   // V2: e_max_out — exposes the internal max-tree result so the harness
//   //     can compute the maximum across multiple blocks and supply a shared
//   //     offset back via mode=1.  Root cause: per-block independent offsets
//   //     in horus_norm v1 destroyed inter-block relative magnitudes for the
//   //     64→16→10 MLP hidden layer (docs/MLP_INFERENCE_DEMO.md gate failure,
//   //     2026-07-05).
//
//   // V2: offset_mode / offset_in — external-offset mode enables N>8
//   //     normalization by composition:
//   //       Pass 1 (offset_mode=0): query e_max_out from each block.
//   //       Harness: shared_offset = E_TARGET − max(e_max_out_A, e_max_out_B).
//   //       Pass 2 (offset_mode=1): apply shared offset to all blocks.
//   //     mode=0 is byte-for-byte identical to horus_norm v1 behavior.
//
// NFE v3 format (13-bit, bias-32): identical to horus_norm.v header.
//
// Algorithm (registered output, 1-cycle latency):
//
//   (a) 3-level max-exponent tree — unchanged from horus_norm.v lines 92-104.
//   (b) Offset mux (V2 addition):
//          mode=0: offset = E_TARGET − E_max  (internal, v1 behavior)
//          mode=1: offset = offset_in          (external, supplied by harness)
//          Special case (both modes): E_max = 0 → offset = 0 in mode 0 only;
//          mode 1 always uses offset_in even if E_max = 0, so the harness must
//          guard against all-floor inputs if needed.
//   (c) Per-element exponent add — unchanged from horus_norm.v lines 123-130.
//   (d) Clamp function — unchanged from horus_norm.v lines 134-147.
//   (e) Registered outputs — unchanged from horus_norm.v lines 158-181,
//       plus e_max_out registered from max-tree result.
//
// Parameters:
//   E_TARGET [6-bit] — target anchor exponent, default 32 (HBS-12D).
// ============================================================================

module horus_norm_v2 #(
    parameter [5:0] E_TARGET = 6'd32
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        valid_in,
    input  wire [12:0] in_0,
    input  wire [12:0] in_1,
    input  wire [12:0] in_2,
    input  wire [12:0] in_3,
    input  wire [12:0] in_4,
    input  wire [12:0] in_5,
    input  wire [12:0] in_6,
    input  wire [12:0] in_7,

    // V2: external-offset control
    input  wire        offset_mode,    // 0 = internal (v1 behavior), 1 = external
    input  wire [6:0]  offset_in,      // external offset (7-bit signed, used when mode=1)

    output reg         valid_out,
    output reg  [5:0]  e_max_out,      // V2: registered max exponent from tree
    output reg  [12:0] out_0,
    output reg  [12:0] out_1,
    output reg  [12:0] out_2,
    output reg  [12:0] out_3,
    output reg  [12:0] out_4,
    output reg  [12:0] out_5,
    output reg  [12:0] out_6,
    output reg  [12:0] out_7
);

    // ── Exponent field constants (from horus_nfe.v lines 148-149) ────────────
    localparam [5:0] EXP_MAX  = 6'b111111;
    localparam [5:0] MANT_MAX = 6'b111111;

    // ── (a) Extract 6-bit stored exponents — unchanged from horus_norm.v ─────
    wire [5:0] e0 = in_0[11:6];
    wire [5:0] e1 = in_1[11:6];
    wire [5:0] e2 = in_2[11:6];
    wire [5:0] e3 = in_3[11:6];
    wire [5:0] e4 = in_4[11:6];
    wire [5:0] e5 = in_5[11:6];
    wire [5:0] e6 = in_6[11:6];
    wire [5:0] e7 = in_7[11:6];

    // ── (a) 3-level max-exponent tree — unchanged from horus_norm.v L94-L104 ─
    wire [5:0] lv1_01   = (e0   >= e1  ) ? e0   : e1;
    wire [5:0] lv1_23   = (e2   >= e3  ) ? e2   : e3;
    wire [5:0] lv1_45   = (e4   >= e5  ) ? e4   : e5;
    wire [5:0] lv1_67   = (e6   >= e7  ) ? e6   : e7;

    wire [5:0] lv2_0123 = (lv1_01 >= lv1_23) ? lv1_01 : lv1_23;
    wire [5:0] lv2_4567 = (lv1_45 >= lv1_67) ? lv1_45 : lv1_67;

    wire [5:0] e_max    = (lv2_0123 >= lv2_4567) ? lv2_0123 : lv2_4567;

    // ── (b) Offset mux — V2: selects internal or external offset ─────────────
    // Internal offset: E_TARGET − e_max, 0 if e_max=0 (unchanged from v1).
    wire signed [6:0] int_offset;
    assign int_offset = (e_max == 6'b0)
                        ? 7'sd0
                        : ($signed({1'b0, E_TARGET}) - $signed({1'b0, e_max}));

    // V2: effective offset mux — mode 0 uses int_offset; mode 1 uses offset_in.
    wire signed [6:0] offset;
    assign offset = offset_mode ? $signed(offset_in) : int_offset;

    // ── (c) Per-element exponent add — unchanged from horus_norm.v L123-L130 ─
    wire signed [7:0] ne0 = $signed({2'b00, e0}) + $signed({offset[6], offset});
    wire signed [7:0] ne1 = $signed({2'b00, e1}) + $signed({offset[6], offset});
    wire signed [7:0] ne2 = $signed({2'b00, e2}) + $signed({offset[6], offset});
    wire signed [7:0] ne3 = $signed({2'b00, e3}) + $signed({offset[6], offset});
    wire signed [7:0] ne4 = $signed({2'b00, e4}) + $signed({offset[6], offset});
    wire signed [7:0] ne5 = $signed({2'b00, e5}) + $signed({offset[6], offset});
    wire signed [7:0] ne6 = $signed({2'b00, e6}) + $signed({offset[6], offset});
    wire signed [7:0] ne7 = $signed({2'b00, e7}) + $signed({offset[6], offset});

    // ── (d) Clamp function — unchanged from horus_norm.v L134-L147 ───────────
    function [12:0] clamp_nfe;
        input        sgn;
        input [5:0]  frac;
        input [7:0]  ne;
        begin
            if (ne[7]) begin
                clamp_nfe = {sgn, 6'b000000, 6'b000000};
            end else if (ne[6]) begin
                clamp_nfe = {sgn, EXP_MAX, MANT_MAX};
            end else begin
                clamp_nfe = {sgn, ne[5:0], frac};
            end
        end
    endfunction

    wire [12:0] cw0 = clamp_nfe(in_0[12], in_0[5:0], ne0);
    wire [12:0] cw1 = clamp_nfe(in_1[12], in_1[5:0], ne1);
    wire [12:0] cw2 = clamp_nfe(in_2[12], in_2[5:0], ne2);
    wire [12:0] cw3 = clamp_nfe(in_3[12], in_3[5:0], ne3);
    wire [12:0] cw4 = clamp_nfe(in_4[12], in_4[5:0], ne4);
    wire [12:0] cw5 = clamp_nfe(in_5[12], in_5[5:0], ne5);
    wire [12:0] cw6 = clamp_nfe(in_6[12], in_6[5:0], ne6);
    wire [12:0] cw7 = clamp_nfe(in_7[12], in_7[5:0], ne7);

    // ── (e) Registered outputs — data unchanged from horus_norm.v L159-L181 ──
    // V2 addition: e_max_out registered alongside data outputs.
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            e_max_out <= 6'b0;          // V2: reset
            out_0     <= 13'h0000;
            out_1     <= 13'h0000;
            out_2     <= 13'h0000;
            out_3     <= 13'h0000;
            out_4     <= 13'h0000;
            out_5     <= 13'h0000;
            out_6     <= 13'h0000;
            out_7     <= 13'h0000;
        end else begin
            valid_out <= valid_in;
            e_max_out <= e_max;         // V2: expose max-tree result
            out_0     <= cw0;
            out_1     <= cw1;
            out_2     <= cw2;
            out_3     <= cw3;
            out_4     <= cw4;
            out_5     <= cw5;
            out_6     <= cw6;
            out_7     <= cw7;
        end
    end

endmodule

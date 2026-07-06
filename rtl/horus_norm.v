`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_norm
// File     : rtl/horus_norm.v
// Author   : Sotirios Chortogiannos
// Date     : 2026-07-05
//
// Purpose  : 8-element block-exponent normalizer.  Re-centers a vector of
//            8 NFE v3 codewords to the anchor zone by adding a shared power-of-2
//            offset to every element's stored exponent; mantissas are untouched
//            (lossless per-element, power-of-2 quantized scale).
//
//            Design rationale: docs/NORM_VS_PF18.md — expnorm rescale matches
//            exact FP64 unit-norm break-evens (SSC k=∞, PI k=8) at an
//            estimated fraction of the PF-W18 accumulator cost.
//
// NFE v3 format (13-bit, bias-32):
//   [12]   sign bit
//   [11:6] stored exponent E   (actual exponent = E − 32)
//   [5:0]  mantissa fraction f (value = (1 + f/64) × 2^(E−32))
//
// Algorithm (combinational logic, registered output):
//
//   (a) 3-level max-exponent tree (7 × 6-bit comparator)
//          L1: max(E0,E1) max(E2,E3) max(E4,E5) max(E6,E7)  — 4 comparators
//          L2: max(L1_01, L1_23) max(L1_45, L1_67)          — 2 comparators
//          L3: max(L2_0123, L2_4567)                          — 1 comparator
//
//   (b) Offset computation (7-bit signed subtraction)
//          offset = E_TARGET − E_max   range [−31, +32] for E_TARGET=32
//          Special case: E_max = 0 (all at floor sentinel) → offset = 0,
//          outputs mirror inputs unchanged.
//
//   (c) Per-element exponent add (8-bit signed, detects UF/OVF)
//          new_e[i] = {2'b00, E[i]} + {offset[6], offset}   (8-bit signed)
//          new_e[i][7]   = 1  →  underflow:  {sign, 6'd0,      6'd0     }
//          new_e[i][7:6] = 01 →  overflow:   {sign, 6'b111111, 6'b111111}
//          else               →  normal:     {sign, new_e[5:0], f[i]    }
//
//          UF sentinel : horus_nfe.v line 521  ({res_sign, {EXP_W{0}}, {MANT_W{0}}})
//          OVF sentinel: horus_nfe.v line 524  ({res_sign, EXP_MAX, MANT_MAX})
//
// Latency : 1 clock cycle (valid_in → valid_out registered on posedge clk).
//           Fires once per k matvecs (k from docs/NORM_VS_PF18.md sweep).
//
// Parameters:
//   E_TARGET [6-bit unsigned] — target anchor exponent.
//                               Default 32 = mid-anchor (HBS-12D, nfe_matvec2.c lines 67-68).
// ============================================================================

module horus_norm #(
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

    output reg         valid_out,
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
    localparam [5:0] EXP_MAX  = 6'b111111;   // stored 63 → actual +31
    localparam [5:0] MANT_MAX = 6'b111111;   // maximum fraction field

    // ── (a) Extract 6-bit stored exponents ───────────────────────────────────
    wire [5:0] e0 = in_0[11:6];
    wire [5:0] e1 = in_1[11:6];
    wire [5:0] e2 = in_2[11:6];
    wire [5:0] e3 = in_3[11:6];
    wire [5:0] e4 = in_4[11:6];
    wire [5:0] e5 = in_5[11:6];
    wire [5:0] e6 = in_6[11:6];
    wire [5:0] e7 = in_7[11:6];

    // ── (a) 3-level max-exponent tree ─────────────────────────────────────────
    // Level 1: four pairwise maxima
    wire [5:0] lv1_01   = (e0   >= e1  ) ? e0   : e1;
    wire [5:0] lv1_23   = (e2   >= e3  ) ? e2   : e3;
    wire [5:0] lv1_45   = (e4   >= e5  ) ? e4   : e5;
    wire [5:0] lv1_67   = (e6   >= e7  ) ? e6   : e7;

    // Level 2: two pairwise maxima
    wire [5:0] lv2_0123 = (lv1_01 >= lv1_23) ? lv1_01 : lv1_23;
    wire [5:0] lv2_4567 = (lv1_45 >= lv1_67) ? lv1_45 : lv1_67;

    // Level 3: final maximum
    wire [5:0] e_max    = (lv2_0123 >= lv2_4567) ? lv2_0123 : lv2_4567;

    // ── (b) Offset computation ────────────────────────────────────────────────
    // offset = E_TARGET − E_max  (7-bit signed).
    // If E_max = 0 (all inputs at floor sentinel), output offset = 0.
    wire signed [6:0] offset;
    assign offset = (e_max == 6'b0)
                    ? 7'sd0
                    : ($signed({1'b0, E_TARGET}) - $signed({1'b0, e_max}));

    // ── (c) Per-element exponent add: 8-bit signed arithmetic ─────────────────
    // e[i] is 6-bit unsigned → zero-extend to 8-bit: {2'b00, e[i]}
    // offset is 7-bit signed → sign-extend to 8-bit: {offset[6], offset}
    // new_e result range: [0−31=−31, 63+32=95] → fits 8-bit signed (−128..+127).
    //
    // Overflow detection on 8-bit signed result:
    //   bit[7] = 1              → negative  → underflow  (below format floor)
    //   bit[7] = 0, bit[6] = 1 → 64..127   → overflow   (above format ceiling)
    //   bit[7] = 0, bit[6] = 0 → 0..63     → normal     (valid exponent field)
    wire signed [7:0] ne0 = $signed({2'b00, e0}) + $signed({offset[6], offset});
    wire signed [7:0] ne1 = $signed({2'b00, e1}) + $signed({offset[6], offset});
    wire signed [7:0] ne2 = $signed({2'b00, e2}) + $signed({offset[6], offset});
    wire signed [7:0] ne3 = $signed({2'b00, e3}) + $signed({offset[6], offset});
    wire signed [7:0] ne4 = $signed({2'b00, e4}) + $signed({offset[6], offset});
    wire signed [7:0] ne5 = $signed({2'b00, e5}) + $signed({offset[6], offset});
    wire signed [7:0] ne6 = $signed({2'b00, e6}) + $signed({offset[6], offset});
    wire signed [7:0] ne7 = $signed({2'b00, e7}) + $signed({offset[6], offset});

    // ── Combinational clamp mux (pure function) ──────────────────────────────
    // Returns clamped 13-bit NFE codeword.
    function [12:0] clamp_nfe;
        input        sgn;         // sign bit (preserved through all cases)
        input [5:0]  frac;        // mantissa (unchanged when normal)
        input [7:0]  ne;          // new exponent (8-bit signed)
        begin
            if (ne[7]) begin                        // negative → UF floor sentinel
                clamp_nfe = {sgn, 6'b000000, 6'b000000};
            end else if (ne[6]) begin               // ≥ 64 → OVF saturation sentinel
                clamp_nfe = {sgn, EXP_MAX, MANT_MAX};
            end else begin                          // normal: 0..63
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

    // ── Stage 1: registered outputs (1-cycle latency) ────────────────────────
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
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

`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_mlp_inference
// File     : tb/tb_mlp_inference.v
// Date     : 2026-07-05
//
// Purpose  : RTL inference testbench for the 64→16→10 handwritten-digit MLP
//            using the verified baseline horus_nfe + horus_norm_v2 datapaths.
//
// Division of labour:
//   DUT horus_nfe       : all 8×8-block multiply-accumulate arithmetic.
//   DUT horus_norm_v2   : between-layer block-exponent re-grounding via two-pass
//                         shared-offset composition (mode 0 / mode 1).
//   Harness (this tb)   : block sequencing, max-of-two-e_max computation,
//                         shared-offset computation, bias add, ReLU, argmax,
//                         NFE encode/decode, CSV logging, ASCII visualisation.
//
// Architecture:
//   Input:   64 features (8×8 digit image)
//   Layer 1: W1 (16×64) → ReLU → 16 hidden neurons
//            Tiles as 2 output blocks × 8 input blocks (8×8 each).
//   Expnorm: Two-pass horus_norm_v2 composition over 16 hidden neurons.
//            Pass 1 (mode=0): query e_max from each 8-element block.
//            Harness: shared_offset = E_TARGET − max(e_max_A, e_max_B).
//            Pass 2 (mode=1): apply shared_offset to both blocks.
//   Layer 2: W2 (16×16 padded, 10 real + 6 dead) → argmax
//            Tiles as 2 output blocks × 2 input blocks (8×8 each).
//
// Dataset:
//   sklearn load_digits (1797 samples, 8×8 grayscale 0-16, 10 classes).
//   80/20 split, seed=42: 360 test images.
//
// Inputs (from sim/):
//   MLP_W1.hex          — W1[i][j] at row i*64+j  (1024 entries, 4-hex-digit)
//   MLP_B1.hex          — b1[i]                   (16 entries)
//   MLP_W2.hex          — W2[i][j] at row i*16+j  (256 entries, padded 16×16)
//   MLP_B2.hex          — b2[i]                   (16 entries, padded)
//   MLP_TEST_IMAGES.hex — image i, pixel j at i*64+j (360×64 entries)
//   MLP_TEST_LABELS.dat — true label per image (one decimal integer per line)
//   MLP_SHOWCASE.dat    — indices of 3 showcase images
//
// Outputs (to sim/):
//   MLP_RTL_TRACE.csv   — per-image: img_idx, true_lbl, pred_c,
//                          h1_b0_0..7, h1_b1_0..7 (hex NFE after expnorm),
//                          z2_0..9 (decoded real output scores).
// ============================================================================

module tb_mlp_inference;

    localparam CLK_HALF  = 5;          // 100 MHz
    localparam integer EXP_BIAS = 32;
    localparam integer EXP_MAX  = 63;
    localparam integer E_TARGET = 32;
    localparam [1:0]   OP_MUL   = 2'b10;
    localparam integer N_TEST   = 360;

    // ── Clock ─────────────────────────────────────────────────────────────────
    reg clk = 0;
    always #CLK_HALF clk = ~clk;

    // ── horus_nfe DUT ─────────────────────────────────────────────────────────
    reg         rst_n;
    reg  [12:0] nfe_op_a, nfe_op_b;
    reg  [1:0]  nfe_op_sel;
    reg  [2:0]  nfe_mode_tag;
    reg         nfe_accum_en, nfe_accum_clr;
    wire [12:0] nfe_result;
    wire [31:0] nfe_accum_out;

    horus_nfe NFE_DUT (
        .clk(clk), .rst_n(rst_n),
        .op_a(nfe_op_a), .op_b(nfe_op_b),
        .op_sel(nfe_op_sel), .mode_tag(nfe_mode_tag),
        .accum_en(nfe_accum_en), .accum_clr(nfe_accum_clr),
        .result(nfe_result), .accum_out(nfe_accum_out),
        .rollover_flag(), .underflow_flag(), .exp_ovf_flag()
    );

    // ── horus_norm_v2 DUT ─────────────────────────────────────────────────────
    reg         norm_valid_in;
    reg  [12:0] norm_in_0, norm_in_1, norm_in_2, norm_in_3;
    reg  [12:0] norm_in_4, norm_in_5, norm_in_6, norm_in_7;
    reg         norm_offset_mode;
    reg  [6:0]  norm_offset_in;
    wire        norm_valid_out;
    wire [5:0]  norm_e_max_out;
    wire [12:0] norm_out_0, norm_out_1, norm_out_2, norm_out_3;
    wire [12:0] norm_out_4, norm_out_5, norm_out_6, norm_out_7;

    horus_norm_v2 #(.E_TARGET(6'd32)) NORM_DUT (
        .clk(clk), .rst_n(rst_n),
        .valid_in(norm_valid_in),
        .in_0(norm_in_0), .in_1(norm_in_1),
        .in_2(norm_in_2), .in_3(norm_in_3),
        .in_4(norm_in_4), .in_5(norm_in_5),
        .in_6(norm_in_6), .in_7(norm_in_7),
        .offset_mode(norm_offset_mode),
        .offset_in(norm_offset_in),
        .valid_out(norm_valid_out),
        .e_max_out(norm_e_max_out),
        .out_0(norm_out_0), .out_1(norm_out_1),
        .out_2(norm_out_2), .out_3(norm_out_3),
        .out_4(norm_out_4), .out_5(norm_out_5),
        .out_6(norm_out_6), .out_7(norm_out_7)
    );

    // ── NFE helpers (mirrors tb_horus_norm.v lines 102-143) ───────────────────
    function real nfe_decode;
        input [12:0] cw; integer s, e, f; real mag;
        begin
            s = cw[12]; e = cw[11:6]; f = cw[5:0];
            mag = (1.0 + $itor(f)/64.0) * $pow(2.0, $itor(e) - $itor(EXP_BIAS));
            nfe_decode = s ? -mag : mag;
        end
    endfunction

    function [12:0] nfe_encode;
        input real v; integer s, aE, eS, f; real av, m, l2;
        begin
            s = (v < 0.0) ? 1 : 0; av = (v < 0.0) ? -v : v;
            if (av == 0.0) nfe_encode = 13'd0;
            else begin
                l2 = $ln(av) / $ln(2.0); aE = $rtoi(l2);
                if (l2 < 0.0 && l2 != $itor(aE)) aE = aE - 1;
                m = av * $pow(2.0, $itor(-aE));
                if (m < 1.0)  begin aE = aE - 1; m = m * 2.0; end
                if (m >= 2.0) begin aE = aE + 1; m = m * 0.5; end
                if (aE < -EXP_BIAS)
                    nfe_encode = s[0] ? 13'h1000 : 13'd0;
                else if (aE > (EXP_MAX - EXP_BIAS))
                    nfe_encode = s[0] ? 13'h1FFF : 13'h0FFF;
                else begin
                    eS = aE + EXP_BIAS; f = $rtoi((m - 1.0) * 64.0 + 0.5);
                    if (f < 0) f = 0;
                    if (f >= 64) begin
                        f = 0; eS = eS + 1;
                        nfe_encode = (eS > EXP_MAX) ?
                            (s[0] ? 13'h1FFF : 13'h0FFF) : {s[0], eS[5:0], 6'd0};
                    end else nfe_encode = {s[0], eS[5:0], f[5:0]};
                end
            end
        end
    endfunction

    // ASCII grayscale character for display (pixel decoded to [0,1])
    function [7:0] pixel_char;
        input real v;
        begin
            if      (v <= 0.0)  pixel_char = " ";
            else if (v <= 0.10) pixel_char = ".";
            else if (v <= 0.30) pixel_char = ":";
            else if (v <= 0.50) pixel_char = "+";
            else if (v <= 0.70) pixel_char = "*";
            else if (v <= 0.90) pixel_char = "#";
            else                pixel_char = "@";
        end
    endfunction

    // ── Weight and data memory ────────────────────────────────────────────────
    reg [12:0] W1_mem[0:1023];     // W1[i*64+j] for i=0..15, j=0..63
    reg [12:0] B1_mem[0:15];
    reg [12:0] W2_mem[0:255];      // W2[i*16+j] for i=0..15, j=0..15 (padded)
    reg [12:0] B2_mem[0:15];
    reg [15:0] img_raw[0:N_TEST*64-1];   // 16-bit from hex file

    // ── Per-image intermediates ───────────────────────────────────────────────
    real     z1[0:15];        // layer-1 accumulated dot products
    real     h1_real[0:15];   // post-ReLU activations
    reg [12:0] h1_nfe_raw[0:15];   // NFE-encoded post-ReLU (before expnorm)
    reg [12:0] h1_nfe_norm[0:15];  // NFE after shared-offset expnorm
    real     z2[0:15];        // layer-2 accumulated dot products

    // ── Loop counters / misc ──────────────────────────────────────────────────
    integer img_idx, ob, ib, ii, jj;
    integer true_label, pred_label;
    integer n_correct, n_total;
    integer lbl_fd, csv_fd, showcase_fd;
    integer r_emax_a, r_emax_b, shared_emax, shared_off_int;
    reg [6:0] shared_off_7b;
    integer showcase_idx[0:2];

    // ── Task: one MAC via horus_nfe ───────────────────────────────────────────
    // Drives negedge setup, reads result on posedge + 1ns.
    task do_mac;
        input [12:0] wa;
        input [12:0] wb;
        output real  product;
        begin
            @(negedge clk);
            nfe_op_a     = wa;
            nfe_op_b     = wb;
            nfe_op_sel   = OP_MUL;
            nfe_mode_tag = 3'd0;
            nfe_accum_en = 0;
            nfe_accum_clr= 0;
            @(posedge clk); #1;
            product = nfe_decode(nfe_result);
        end
    endtask

    // ── Task: drive one 8-element block to horus_norm_v2 ─────────────────────
    task apply_norm_block;
        input  [12:0] i0,i1,i2,i3,i4,i5,i6,i7;
        input         mode;
        input  [6:0]  ext_off;
        output [12:0] o0,o1,o2,o3,o4,o5,o6,o7;
        output [5:0]  emax_out;
        begin
            @(negedge clk);
            norm_in_0 = i0; norm_in_1 = i1;
            norm_in_2 = i2; norm_in_3 = i3;
            norm_in_4 = i4; norm_in_5 = i5;
            norm_in_6 = i6; norm_in_7 = i7;
            norm_offset_mode = mode;
            norm_offset_in   = ext_off;
            norm_valid_in    = 1;
            @(posedge clk); #1;
            o0 = norm_out_0; o1 = norm_out_1;
            o2 = norm_out_2; o3 = norm_out_3;
            o4 = norm_out_4; o5 = norm_out_5;
            o6 = norm_out_6; o7 = norm_out_7;
            emax_out = norm_e_max_out;
            norm_valid_in = 0;
        end
    endtask

    // ── Print 8×8 ASCII digit ─────────────────────────────────────────────────
    task print_digit;
        input integer img_i;
        integer r, c; real pv;
        begin
            $display("  +--------+");
            for (r = 0; r < 8; r = r+1) begin
                $write("  |");
                for (c = 0; c < 8; c = c+1) begin
                    pv = nfe_decode(img_raw[img_i*64 + r*8 + c][12:0]);
                    $write("%s", pixel_char(pv));
                end
                $display("|");
            end
            $display("  +--------+");
        end
    endtask

    // ── Main ──────────────────────────────────────────────────────────────────
    integer max_idx; real max_val;

    initial begin
        $display("================================================================");
        $display("tb_mlp_inference: MLP digit classification via horus_nfe + horus_norm_v2");
        $display("================================================================");

        // Reset
        rst_n = 0; norm_valid_in = 0; norm_offset_mode = 0; norm_offset_in = 0;
        nfe_op_a = 0; nfe_op_b = 0; nfe_op_sel = 2'b11;
        nfe_mode_tag = 0; nfe_accum_en = 0; nfe_accum_clr = 0;
        #(CLK_HALF*4); rst_n = 1; #(CLK_HALF*2);

        // Load weights
        $readmemh("../sim/MLP_W1.hex", W1_mem);
        $readmemh("../sim/MLP_B1.hex", B1_mem);
        $readmemh("../sim/MLP_W2.hex", W2_mem);
        $readmemh("../sim/MLP_B2.hex", B2_mem);
        $readmemh("../sim/MLP_TEST_IMAGES.hex", img_raw);

        // Load showcase indices
        showcase_fd = $fopen("../sim/MLP_SHOWCASE.dat", "r");
        $fscanf(showcase_fd, "%d\n", showcase_idx[0]);
        $fscanf(showcase_fd, "%d\n", showcase_idx[1]);
        $fscanf(showcase_fd, "%d\n", showcase_idx[2]);
        $fclose(showcase_fd);
        $display("  Showcase images: easy=%0d  close=%0d  misc=%0d",
                 showcase_idx[0], showcase_idx[1], showcase_idx[2]);

        // Open labels file and CSV output
        lbl_fd = $fopen("../sim/MLP_TEST_LABELS.dat", "r");
        csv_fd = $fopen("../sim/MLP_RTL_TRACE.csv", "w");
        // CSV header (must match MLP_PY_TRACE.csv column names for analyze_mlp.py)
        $fwrite(csv_fd, "img_idx,true_lbl,pred_c,");
        $fwrite(csv_fd, "h1_b0_0,h1_b0_1,h1_b0_2,h1_b0_3,h1_b0_4,h1_b0_5,h1_b0_6,h1_b0_7,");
        $fwrite(csv_fd, "h1_b1_0,h1_b1_1,h1_b1_2,h1_b1_3,h1_b1_4,h1_b1_5,h1_b1_6,h1_b1_7,");
        $fwrite(csv_fd, "z2_0,z2_1,z2_2,z2_3,z2_4,z2_5,z2_6,z2_7,z2_8,z2_9\n");

        n_correct = 0; n_total = 0;

        // ── Per-image inference loop ─────────────────────────────────────────
        for (img_idx = 0; img_idx < N_TEST; img_idx = img_idx+1) begin
            $fscanf(lbl_fd, "%d\n", true_label);

            // ── Layer 1: 2 output blocks × 8 input blocks × 8×8 MACs ─────────
            for (ob = 0; ob < 2; ob = ob+1) begin
                for (ii = 0; ii < 8; ii = ii+1) z1[ob*8+ii] = 0.0;
                for (ib = 0; ib < 8; ib = ib+1) begin
                    for (ii = 0; ii < 8; ii = ii+1) begin
                        for (jj = 0; jj < 8; jj = jj+1) begin : mac_l1
                            real prod;
                            do_mac(W1_mem[(ob*8+ii)*64 + ib*8+jj],
                                   img_raw[img_idx*64 + ib*8+jj][12:0],
                                   prod);
                            z1[ob*8+ii] = z1[ob*8+ii] + prod;
                        end
                    end
                end
                // Bias add + ReLU + NFE encode (harness)
                for (ii = 0; ii < 8; ii = ii+1) begin
                    z1[ob*8+ii] = z1[ob*8+ii] + nfe_decode(B1_mem[ob*8+ii]);
                    h1_real[ob*8+ii] = (z1[ob*8+ii] > 0.0) ? z1[ob*8+ii] : 0.0;
                    h1_nfe_raw[ob*8+ii] = nfe_encode(h1_real[ob*8+ii]);
                end
            end

            // ── Between-layer: two-pass shared-offset expnorm via horus_norm_v2 ──
            // Pass 1, block A (neurons 0–7): mode=0 → capture e_max_A
            begin : pass1_a
                reg [5:0] em; reg [12:0] d0,d1,d2,d3,d4,d5,d6,d7;
                apply_norm_block(h1_nfe_raw[0],h1_nfe_raw[1],h1_nfe_raw[2],h1_nfe_raw[3],
                                 h1_nfe_raw[4],h1_nfe_raw[5],h1_nfe_raw[6],h1_nfe_raw[7],
                                 1'b0, 7'b0,
                                 d0,d1,d2,d3,d4,d5,d6,d7, em);
                r_emax_a = em;
            end

            // Pass 1, block B (neurons 8–15): mode=0 → capture e_max_B
            begin : pass1_b
                reg [5:0] em; reg [12:0] d0,d1,d2,d3,d4,d5,d6,d7;
                apply_norm_block(h1_nfe_raw[8], h1_nfe_raw[9], h1_nfe_raw[10],h1_nfe_raw[11],
                                 h1_nfe_raw[12],h1_nfe_raw[13],h1_nfe_raw[14],h1_nfe_raw[15],
                                 1'b0, 7'b0,
                                 d0,d1,d2,d3,d4,d5,d6,d7, em);
                r_emax_b = em;
            end

            // Harness: compute shared offset
            shared_emax    = (r_emax_a >= r_emax_b) ? r_emax_a : r_emax_b;
            shared_off_int = (shared_emax == 0) ? 0 : (E_TARGET - shared_emax);
            shared_off_7b  = shared_off_int[6:0];   // 7-bit signed representation

            // Pass 2, block A: mode=1 → apply shared_offset, capture outputs
            begin : pass2_a
                reg [5:0] em;
                apply_norm_block(h1_nfe_raw[0],h1_nfe_raw[1],h1_nfe_raw[2],h1_nfe_raw[3],
                                 h1_nfe_raw[4],h1_nfe_raw[5],h1_nfe_raw[6],h1_nfe_raw[7],
                                 1'b1, shared_off_7b,
                                 h1_nfe_norm[0],h1_nfe_norm[1],h1_nfe_norm[2],h1_nfe_norm[3],
                                 h1_nfe_norm[4],h1_nfe_norm[5],h1_nfe_norm[6],h1_nfe_norm[7],
                                 em);
            end

            // Pass 2, block B: mode=1 → apply shared_offset, capture outputs
            begin : pass2_b
                reg [5:0] em;
                apply_norm_block(h1_nfe_raw[8], h1_nfe_raw[9], h1_nfe_raw[10],h1_nfe_raw[11],
                                 h1_nfe_raw[12],h1_nfe_raw[13],h1_nfe_raw[14],h1_nfe_raw[15],
                                 1'b1, shared_off_7b,
                                 h1_nfe_norm[8], h1_nfe_norm[9], h1_nfe_norm[10],h1_nfe_norm[11],
                                 h1_nfe_norm[12],h1_nfe_norm[13],h1_nfe_norm[14],h1_nfe_norm[15],
                                 em);
            end

            // ── Layer 2: 2 output blocks × 2 input blocks × 8×8 MACs ─────────
            for (ob = 0; ob < 2; ob = ob+1) begin
                for (ii = 0; ii < 8; ii = ii+1) z2[ob*8+ii] = 0.0;
                for (ib = 0; ib < 2; ib = ib+1) begin
                    for (ii = 0; ii < 8; ii = ii+1) begin
                        for (jj = 0; jj < 8; jj = jj+1) begin : mac_l2
                            real prod;
                            do_mac(W2_mem[(ob*8+ii)*16 + ib*8+jj],
                                   h1_nfe_norm[ib*8+jj],
                                   prod);
                            z2[ob*8+ii] = z2[ob*8+ii] + prod;
                        end
                    end
                end
                // Bias add (harness — no ReLU on output layer)
                for (ii = 0; ii < 8; ii = ii+1)
                    z2[ob*8+ii] = z2[ob*8+ii] + nfe_decode(B2_mem[ob*8+ii]);
            end

            // ── Argmax over first 10 outputs (harness) ────────────────────────
            max_idx = 0; max_val = z2[0];
            for (ii = 1; ii < 10; ii = ii+1)
                if (z2[ii] > max_val) begin max_val = z2[ii]; max_idx = ii; end
            pred_label = max_idx;

            if (pred_label == true_label) n_correct = n_correct + 1;
            n_total = n_total + 1;

            // ── CSV row ───────────────────────────────────────────────────────
            $fwrite(csv_fd, "%0d,%0d,%0d,", img_idx, true_label, pred_label);
            $fwrite(csv_fd, "%04h,%04h,%04h,%04h,%04h,%04h,%04h,%04h,",
                    h1_nfe_norm[0],h1_nfe_norm[1],h1_nfe_norm[2],h1_nfe_norm[3],
                    h1_nfe_norm[4],h1_nfe_norm[5],h1_nfe_norm[6],h1_nfe_norm[7]);
            $fwrite(csv_fd, "%04h,%04h,%04h,%04h,%04h,%04h,%04h,%04h,",
                    h1_nfe_norm[8], h1_nfe_norm[9], h1_nfe_norm[10],h1_nfe_norm[11],
                    h1_nfe_norm[12],h1_nfe_norm[13],h1_nfe_norm[14],h1_nfe_norm[15]);
            $fwrite(csv_fd, "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
                    z2[0],z2[1],z2[2],z2[3],z2[4],z2[5],z2[6],z2[7],z2[8],z2[9]);

            // ── Showcase ASCII output ─────────────────────────────────────────
            if (img_idx == showcase_idx[0] || img_idx == showcase_idx[1] ||
                img_idx == showcase_idx[2]) begin
                begin : sc_block
                    reg [63:0] kind;
                    if      (img_idx == showcase_idx[0]) kind = "EASY    ";
                    else if (img_idx == showcase_idx[1]) kind = "CLOSE   ";
                    else                                  kind = "MISC    ";
                    $display("");
                    $display("━━━ SHOWCASE [%s]  img=%0d ━━━", kind, img_idx);
                    $display("  What the chip was shown (true class: %0d):", true_label);
                    print_digit(img_idx);
                    $display("  Output scores (0..9):");
                    $display("    [0]%+.3f [1]%+.3f [2]%+.3f [3]%+.3f [4]%+.3f",
                             z2[0],z2[1],z2[2],z2[3],z2[4]);
                    $display("    [5]%+.3f [6]%+.3f [7]%+.3f [8]%+.3f [9]%+.3f",
                             z2[5],z2[6],z2[7],z2[8],z2[9]);
                    if (pred_label == true_label)
                        $display("  Verdict: CORRECT  (predicted=%0d)", pred_label);
                    else
                        $display("  Verdict: WRONG    (predicted=%0d  true=%0d)",
                                 pred_label, true_label);
                end
            end
        end

        $fclose(lbl_fd);
        $fclose(csv_fd);

        // ── Final summary ─────────────────────────────────────────────────────
        $display("");
        $display("================================================================");
        $display("INFERENCE SUMMARY");
        $display("  Images run:    %0d", n_total);
        $display("  Correct:       %0d", n_correct);
        $display("  Wrong:         %0d", n_total - n_correct);
        $display("  RTL accuracy:  %.2f%%", 100.0*n_correct/n_total);
        $display("  Python (c):    96.39%%  (347/360)  — expected match");
        $display("  CSV:           sim/MLP_RTL_TRACE.csv");
        $display("================================================================");
        $finish;
    end

endmodule

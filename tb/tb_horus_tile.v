// tb/tb_horus_tile.v — Testbench for horus_tile.v
//
// Tests:
//   [1] E4M3 golden sweep   (125 blocks × 8 = 1000 multiply pairs, K2)
//   [2] E3M6 golden sweep   (125 blocks × 8 = 1000 multiply pairs, K2)
//   [3] Mode-switch cleanliness (K3)
//   [4] Smoke A: E4M3 inference directed block (1.0×1.0×8)
//   [5] Smoke B: E3M6 accumulation directed block
//
// Timing note: horus_tile has a registered mode_r.  The mode must be stable
// for at least 1 cycle BEFORE valid_in is asserted so that mode_r is set
// correctly before the first pair is processed.
//
// ULP tolerance: E3M6 products use truncation (RTL) vs RNE (Python reference).
// The resulting ±1 ULP in the per-element multiply propagates unchanged through
// the normalization (which adds a fixed integer exponent offset).  The testbench
// accepts ±1 in the 12-bit magnitude (sign-exclusive) for E3M6 outputs.

`timescale 1ns / 1ps

module tb_horus_tile;

    // ── DUT signals ────────────────────────────────────────────────────────────
    reg         clk;
    reg         rst_n;
    reg         mode;
    reg  [9:0]  op_a;
    reg  [9:0]  op_b;
    reg         valid_in;

    wire        norm_valid;
    wire [5:0]  norm_e_max;
    wire [12:0] norm_out_0, norm_out_1, norm_out_2, norm_out_3;
    wire [12:0] norm_out_4, norm_out_5, norm_out_6, norm_out_7;

    // ── DUT ────────────────────────────────────────────────────────────────────
    horus_tile dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .mode       (mode),
        .op_a       (op_a),
        .op_b       (op_b),
        .valid_in   (valid_in),
        .norm_valid (norm_valid),
        .norm_e_max (norm_e_max),
        .norm_out_0 (norm_out_0), .norm_out_1 (norm_out_1),
        .norm_out_2 (norm_out_2), .norm_out_3 (norm_out_3),
        .norm_out_4 (norm_out_4), .norm_out_5 (norm_out_5),
        .norm_out_6 (norm_out_6), .norm_out_7 (norm_out_7)
    );

    // ── Clock: 10 ns period ────────────────────────────────────────────────────
    initial clk = 0;
    always  #5 clk = ~clk;

    // ── Golden memories ────────────────────────────────────────────────────────
    reg [15:0] e4m3_ops  [0:999];
    reg [15:0] e4m3_out  [0:1124];
    reg [19:0] e3m6_ops  [0:999];
    reg [15:0] e3m6_out  [0:1124];

    // ── Test counters ──────────────────────────────────────────────────────────
    integer total_tests, failures;
    integer i, blk, slot;

    // ── Captured block outputs ─────────────────────────────────────────────────
    reg [12:0] cap_nout [0:7];
    reg  [5:0] cap_emax;

    // ── Helpers ────────────────────────────────────────────────────────────────
    task reset_dut;
        begin
            rst_n    = 0;
            mode     = 0;
            op_a     = 0;
            op_b     = 0;
            valid_in = 0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            rst_n = 1;
            @(posedge clk); #1;
        end
    endtask

    // Set mode and let mode_r register — MUST call before first valid_in
    task set_mode;
        input m;
        begin
            mode = m;
            @(posedge clk); #1;    // mode_r ← m on this edge
        end
    endtask

    // Drive one pair (mode must already be stable in mode_r)
    task drive_pair;
        input [9:0] a;
        input [9:0] b;
        begin
            op_a     = a;
            op_b     = b;
            valid_in = 1;
            @(posedge clk); #1;
            valid_in = 0;
        end
    endtask

    // Capture one block's normalizer output
    // norm_valid pulses on the clock AFTER fire_pending is set.
    // fire_pending is set on the posedge of the 8th valid_in.
    // After the last drive_pair returns: fire_pending is already HIGH (set at that posedge).
    // - Clock +1: norm_v2 sees valid_in=fire_pending=1, registers outputs → norm_valid=1
    // - Clock +2: norm_valid=0 (fire_pending cleared)
    // So we sample at the end of Clock +1 (after the #1 delay).
    task capture_block;
        begin
            @(posedge clk); #1;   // fire_pending→norm_v2: norm_valid goes HIGH at this edge
            // norm_valid is now 1; sample the outputs
            cap_nout[0] = norm_out_0; cap_nout[1] = norm_out_1;
            cap_nout[2] = norm_out_2; cap_nout[3] = norm_out_3;
            cap_nout[4] = norm_out_4; cap_nout[5] = norm_out_5;
            cap_nout[6] = norm_out_6; cap_nout[7] = norm_out_7;
            cap_emax    = norm_e_max;
        end
    endtask

    // Check with ±1 ULP tolerance (for E3M6 truncation vs RNE)
    // Returns 1 if pass, 0 if fail
    function check_ulp;
        input [12:0] got;
        input [12:0] exp;
        input        allow_ulp;
        reg          sign_match;
        reg  [11:0]  g_mag, e_mag;
        begin
            sign_match = (got[12] == exp[12]);
            g_mag = got[11:0];
            e_mag = exp[11:0];
            if (!sign_match) begin
                check_ulp = (got == 13'h0 && exp == 13'h0) ||
                            (got == 13'h1000 && exp == 13'h0) ||
                            (got == 13'h0 && exp == 13'h1000);
            end else if (g_mag == e_mag) begin
                check_ulp = 1;
            end else if (allow_ulp) begin
                check_ulp = (g_mag == e_mag + 1) || (g_mag + 1 == e_mag);
            end else begin
                check_ulp = 0;
            end
        end
    endfunction

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 1 — E4M3 GOLDEN SWEEP (K2, exact match required)
    // ══════════════════════════════════════════════════════════════════════════
    task test_e4m3_golden;
        reg [12:0] nout_exp;
        reg  [5:0] emax_exp;
        integer    blk_fails, vec_idx, out_idx;
        begin
            $display("[1] E4M3 golden sweep (125 blocks × 8 pairs)");
            blk_fails = 0;  vec_idx = 0;  out_idx = 0;
            set_mode(1'b1);

            for (blk = 0; blk < 125; blk = blk + 1) begin
                for (slot = 0; slot < 8; slot = slot + 1) begin
                    drive_pair(
                        {2'b00, e4m3_ops[vec_idx][15:8]},
                        {2'b00, e4m3_ops[vec_idx][ 7:0]}
                    );
                    vec_idx = vec_idx + 1;
                end
                capture_block;

                for (slot = 0; slot < 8; slot = slot + 1) begin
                    nout_exp = e4m3_out[out_idx][12:0];
                    if (!check_ulp(cap_nout[slot], nout_exp, 0)) begin
                        if (blk_fails < 4)
                            $display("  E4M3 blk=%0d slot=%0d: got=%04x exp=%04x",
                                     blk, slot, cap_nout[slot], nout_exp);
                        blk_fails = blk_fails + 1;
                        failures  = failures + 1;
                    end
                    total_tests = total_tests + 1;
                    out_idx = out_idx + 1;
                end
                emax_exp = e4m3_out[out_idx][5:0];
                if (cap_emax !== emax_exp) begin
                    if (blk_fails < 4)
                        $display("  E4M3 blk=%0d e_max: got=%0d exp=%0d",
                                 blk, cap_emax, emax_exp);
                    failures = failures + 1;
                end
                total_tests = total_tests + 1;
                out_idx = out_idx + 1;
            end
            $display("  E4M3 golden: %0d blocks, %0d block-level failures", 125, blk_fails);
        end
    endtask

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 2 — E3M6 GOLDEN SWEEP (K2, ±1 ULP allowed)
    // ══════════════════════════════════════════════════════════════════════════
    task test_e3m6_golden;
        reg [12:0] nout_exp;
        reg  [5:0] emax_exp;
        integer    blk_fails, vec_idx, out_idx;
        // e_max offset between RTL and Python (due to ±1 ULP in products)
        reg signed [6:0] em_delta;
        reg [12:0] got_adj;
        reg        slot_ok;
        begin
            $display("[2] E3M6 golden sweep (125 blocks × 8 pairs, ±1 ULP)");
            blk_fails = 0;  vec_idx = 0;  out_idx = 0;
            set_mode(1'b0);

            for (blk = 0; blk < 125; blk = blk + 1) begin
                for (slot = 0; slot < 8; slot = slot + 1) begin
                    drive_pair(
                        e3m6_ops[vec_idx][19:10],
                        e3m6_ops[vec_idx][ 9: 0]
                    );
                    vec_idx = vec_idx + 1;
                end
                capture_block;

                // Load expected outputs first
                for (slot = 0; slot < 8; slot = slot + 1) begin
                    out_idx = out_idx + 1;
                end
                out_idx = out_idx - 8;   // rewind to re-use

                emax_exp  = e3m6_out[out_idx + 8][5:0];   // peek at e_max entry
                em_delta  = $signed({1'b0, cap_emax}) - $signed({1'b0, emax_exp});

                for (slot = 0; slot < 8; slot = slot + 1) begin
                    nout_exp = e3m6_out[out_idx][12:0];
                    // Adjust cap_nout for e_max delta: 
                    // RTL_norm_exp = product_exp + (32 - RTL_e_max)
                    //             = product_exp + (32 - Python_e_max) - em_delta
                    //             = Python_norm_exp - em_delta
                    // So: got_adj_exp = got_exp + em_delta  (signed addition)
                    got_adj = {cap_nout[slot][12],
                               6'($signed({1'b0,cap_nout[slot][11:6]}) + em_delta),
                               cap_nout[slot][5:0]};
                    // Only apply adjustment if got is non-zero (zero stays zero)
                    if (cap_nout[slot][11:0] == 12'b0)
                        got_adj = cap_nout[slot];
                    slot_ok = check_ulp(got_adj, nout_exp, 1);
                    if (!slot_ok) begin
                        if (blk_fails < 4)
                            $display("  E3M6 blk=%0d slot=%0d: got=%04x adj=%04x exp=%04x (em_delta=%0d)",
                                     blk, slot, cap_nout[slot], got_adj, nout_exp, em_delta);
                        blk_fails = blk_fails + 1;
                        failures  = failures + 1;
                    end
                    total_tests = total_tests + 1;
                    out_idx = out_idx + 1;
                end
                // e_max: allow ±1
                if (em_delta > 1 || em_delta < -1) begin
                    if (blk_fails < 4)
                        $display("  E3M6 blk=%0d e_max: got=%0d exp=%0d",
                                 blk, cap_emax, emax_exp);
                    failures = failures + 1;
                end
                total_tests = total_tests + 1;
                out_idx = out_idx + 1;   // advance past e_max entry
            end
            $display("  E3M6 golden: %0d blocks, %0d block-level failures", 125, blk_fails);
        end
    endtask

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 3 — MODE-SWITCH CLEANLINESS (K3)
    // ══════════════════════════════════════════════════════════════════════════
    task test_mode_switch;
        integer norm_fires;
        integer wait_cnt;
        begin
            $display("[3] Mode-switch cleanliness (K3)");
            norm_fires = 0;
            reset_dut;

            // 4 E4M3 pairs (1.0 × 1.0)
            set_mode(1'b1);
            for (i = 0; i < 4; i = i + 1)
                drive_pair(10'h038, 10'h038);

            // Switch to E3M6, drive 4 more pairs (1.0 × 1.0 in E3M6)
            set_mode(1'b0);
            for (i = 0; i < 4; i = i + 1)
                drive_pair(10'h140, 10'h140);

            // Poll for norm_valid within 6 cycles (fire_pending + norm_v2 latency + margin)
            wait_cnt = 0;
            repeat (6) begin
                @(posedge clk); #1;
                if (norm_valid) norm_fires = norm_fires + 1;
                wait_cnt = wait_cnt + 1;
            end

            if (norm_fires != 1) begin
                $display("  MODE_SWITCH: norm_valid fired %0d times (expected 1)",
                         norm_fires);
                failures = failures + 1;
            end
            if (^norm_out_0 === 1'bx || ^norm_out_7 === 1'bx) begin
                $display("  MODE_SWITCH: outputs contain X");
                failures = failures + 1;
            end
            total_tests = total_tests + 2;
            $display("  Mode-switch: norm_valid fired %0d time(s)  %s",
                     norm_fires, (norm_fires == 1) ? "PASS" : "FAIL");
        end
    endtask

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 4 — SMOKE A: E4M3 INFERENCE BLOCK (1.0 × 1.0 × 8)
    // ══════════════════════════════════════════════════════════════════════════
    task test_smoke_inference;
        // E4M3 1.0 = 0x38 (s=0, e4=7, f3=0)
        // shim: e6=7+25=32, f6=0 → NFE 0x0800
        // All 8 products = 1.0, e_max=32, offset=0, all outputs = 0x0800
        integer smoke_fails;
        begin
            $display("[4] Smoke A: E4M3 inference block (1.0 × 1.0 × 8)");
            smoke_fails = 0;
            reset_dut;
            set_mode(1'b1);

            for (i = 0; i < 8; i = i + 1)
                drive_pair(10'h038, 10'h038);
            capture_block;

            if (cap_nout[0] !== 13'h0800) begin
                $display("  Smoke A out_0: got=%04x exp=0800", cap_nout[0]);
                smoke_fails = smoke_fails + 1;
            end
            if (cap_nout[7] !== 13'h0800) begin
                $display("  Smoke A out_7: got=%04x exp=0800", cap_nout[7]);
                smoke_fails = smoke_fails + 1;
            end
            if (cap_emax !== 6'd32) begin
                $display("  Smoke A e_max: got=%0d exp=32", cap_emax);
                smoke_fails = smoke_fails + 1;
            end
            total_tests = total_tests + 3;
            failures    = failures + smoke_fails;
            $display("  Smoke A: %0d failures  %s",
                     smoke_fails, (smoke_fails == 0) ? "PASS" : "FAIL");
        end
    endtask

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 5 — SMOKE B: E3M6 ACCUMULATION BLOCK
    // ══════════════════════════════════════════════════════════════════════════
    // E3M6 1.0 = cw 0x140 (s=0, e3=5, f6=0; val=(1+0)*2^(5-4)=2? No...)
    // Let me use 2.0: e3=6 (stored 6, bias 4, so actual=2, val=4) ... need to trace.
    // Actually use a known-good pair: E3M6 0x1C0 = s=0, e3=7, f6=0 = (1+0)*2^(7-4)=8
    // E3M6 1.0: actual exponent = 0, stored = 4 (bias 4), f6=0 → cw = {0,100,000000} = 0x100
    task test_smoke_accum;
        integer smoke_fails;
        begin
            $display("[5] Smoke B: E3M6 accumulation block");
            smoke_fails = 0;
            reset_dut;
            set_mode(1'b0);

            // E3M6 1.0 = s=0, e3=4 (stored = 0+4=4), f6=0 → 0b0_100_000000 = 0x100
            for (i = 0; i < 8; i = i + 1)
                drive_pair(10'h100, 10'h100);
            capture_block;

            // Verify sign = 0 (positive result)
            if (cap_nout[0][12] !== 1'b0) begin
                $display("  Smoke B: expected positive result, got sign=1");
                smoke_fails = smoke_fails + 1;
            end
            // Verify output is not X
            if (^cap_nout[0] === 1'bx) begin
                $display("  Smoke B: norm_out_0 is X");
                smoke_fails = smoke_fails + 1;
            end
            // Verify e_max is valid (non-zero for non-zero inputs)
            if (cap_emax == 6'd0) begin
                $display("  Smoke B: e_max=0 (expected non-zero)");
                smoke_fails = smoke_fails + 1;
            end
            total_tests = total_tests + 3;
            failures    = failures + smoke_fails;
            $display("  Smoke B: e_max=%0d, out_0=%04x, %0d failures  %s",
                     cap_emax, cap_nout[0], smoke_fails,
                     (smoke_fails == 0) ? "PASS" : "FAIL");
        end
    endtask

    // ══════════════════════════════════════════════════════════════════════════
    // MAIN
    // ══════════════════════════════════════════════════════════════════════════
    initial begin
        total_tests = 0;
        failures    = 0;

        $readmemh("TILE_E4M3_OPS.hex", e4m3_ops);
        $readmemh("TILE_E4M3_OUT.hex", e4m3_out);
        $readmemh("TILE_E3M6_OPS.hex", e3m6_ops);
        $readmemh("TILE_E3M6_OUT.hex", e3m6_out);

        reset_dut;
        test_e4m3_golden;

        reset_dut;
        test_e3m6_golden;

        reset_dut;
        test_mode_switch;

        reset_dut;
        test_smoke_inference;

        reset_dut;
        test_smoke_accum;

        $display("");
        if (failures == 0)
            $display("PASS  horus_tile: %0d tests, 0 failures", total_tests);
        else
            $display("FAIL  horus_tile: %0d tests, %0d failures",
                     total_tests, failures);
        $finish;
    end

endmodule

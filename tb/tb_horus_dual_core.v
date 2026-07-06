`timescale 1ns / 1ps
// tb/tb_horus_dual_core.v — Testbench for the dual-mode E4M3/E3M6 multiplier.
//
// Tests:
//   1. E3M6 golden vectors (1000) from sim/DUAL_CORE_E3M6_GOLDEN.hex
//   2. E4M3 golden vectors (1000) from sim/DUAL_CORE_E4M3_GOLDEN.hex
//   3. Directed edge cases per format
//   4. Mode-switch cleanliness: alternating E3M6/E4M3 with independent results
//
// Registered mode: mode is applied at posedge clk.  Result appears one cycle later.
//
// Usage (from sim/):
//   iverilog -g2012 -Wall -o sim_dual_core \
//       tb/tb_horus_dual_core.v rtl/horus_dual_core.v
//   vvp sim_dual_core

module tb_horus_dual_core;

    reg        clk, rst_n;
    reg        mode;
    reg  [9:0] op_a, op_b;
    wire [9:0] result;

    horus_dual_core dut (
        .clk(clk), .rst_n(rst_n),
        .mode(mode), .op_a(op_a), .op_b(op_b),
        .result(result)
    );

    always #5 clk = ~clk;

    integer fail_count;
    integer pass_count;

    // ── Tasks ─────────────────────────────────────────────────────────────────
    // Apply inputs, clock, check result after 2 cycles
    // (mode registered on cycle 1; result registered on cycle 2).
    task apply_and_check;
        input        mode_in;
        input [9:0]  a_in, b_in, want;
        input [255:0] label;
        reg   [9:0]  got;
        reg   [9:0]  diff;
        begin
            mode = mode_in;
            op_a = a_in;
            op_b = b_in;
            @(posedge clk); #1;   // mode registered
            @(posedge clk); #1;   // result registered
            got = result;

            if (mode_in == 1'b0) begin
                // E3M6: accept ±1 ULP via 9-bit magnitude code comparison
                // (handles exponent-carry boundary: e.g. (e=1,f=63) vs (e=2,f=0))
                if (got === want) begin
                    pass_count = pass_count + 1;
                end else if (got[9] === want[9]) begin
                    diff = (got[8:0] >= want[8:0]) ? (got[8:0] - want[8:0])
                                                    : (want[8:0] - got[8:0]);
                    if (diff <= 1) begin
                        pass_count = pass_count + 1;
                    end else begin
                        fail_count = fail_count + 1;
                        $display("FAIL E3M6 %0s: A=0x%03X B=0x%03X got=0x%03X want=0x%03X",
                                 label, a_in, b_in, got, want);
                    end
                end else begin
                    fail_count = fail_count + 1;
                    $display("FAIL E3M6 %0s: A=0x%03X B=0x%03X got=0x%03X want=0x%03X",
                             label, a_in, b_in, got, want);
                end
            end else begin
                // E4M3: exact match required (RNE rounding in RTL)
                if (got[7:0] === want[7:0]) begin
                    pass_count = pass_count + 1;
                end else begin
                    fail_count = fail_count + 1;
                    $display("FAIL E4M3 %0s: A=0x%02X B=0x%02X got=0x%02X want=0x%02X",
                             label, a_in[7:0], b_in[7:0], got[7:0], want[7:0]);
                end
            end
        end
    endtask

    // ── Initialize ────────────────────────────────────────────────────────────
    initial begin
        clk        = 0;
        rst_n      = 0;
        mode       = 0;
        op_a       = 0;
        op_b       = 0;
        fail_count = 0;
        pass_count = 0;

        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;

        // ═════════════════════════════════════════════════════════════════════
        // DIRECTED EDGE CASES — E3M6 MODE
        // ═════════════════════════════════════════════════════════════════════
        $display("--- E3M6 directed edge cases ---");

        // Zero × anything
        apply_and_check(0, 10'h000, 10'h100, 10'h000, "zero×1");

        // Flush subnormal input × normal = zero
        apply_and_check(0, 10'h001, 10'h100, 10'h000, "sub×1=0");

        // 1.0 × 1.0 = 1.0
        apply_and_check(0, 10'h100, 10'h100, 10'h100, "1×1=1");

        // 2.0 × 2.0 = 4.0
        apply_and_check(0, 10'h140, 10'h140, 10'h180, "2×2=4");

        // 8.0 × 2.0 → saturation
        apply_and_check(0, 10'h1C0, 10'h140, 10'h1FF, "8×2=sat");

        // −1.0 × +1.0 = −1.0
        apply_and_check(0, 10'h300, 10'h100, 10'h300, "-1×1=-1");

        // −1.0 × −1.0 = +1.0
        apply_and_check(0, 10'h300, 10'h300, 10'h100, "-1×-1=+1");

        // Subnormal output: 0.25 × 0.25 = 0.0625 (e=0, f=32)
        apply_and_check(0, 10'h080, 10'h080, 10'h020, "0.25×0.25=sub");

        // ═════════════════════════════════════════════════════════════════════
        // DIRECTED EDGE CASES — E4M3 MODE
        // ═════════════════════════════════════════════════════════════════════
        $display("--- E4M3 directed edge cases ---");

        // NaN × anything = NaN (0x7F)
        apply_and_check(1, 10'h07F, 10'h038, 10'h07F, "NaN×1=NaN");

        // Zero × anything = positive zero (0x00)
        apply_and_check(1, 10'h000, 10'h0E6, 10'h000, "+0×(-56)=0");
        apply_and_check(1, 10'h055, 10'h080, 10'h000, "13×(-0)=0");

        // 1.0 × 1.0 = 1.0  (0x38)
        apply_and_check(1, 10'h038, 10'h038, 10'h038, "1×1=1");

        // 2.0 × 2.0 = 4.0  (E4M3: 4.0 = e=9, f=0 = 0x48)
        apply_and_check(1, 10'h040, 10'h040, 10'h048, "2×2=4");

        // Overflow → max finite 448 (0x7E)
        apply_and_check(1, 10'h07E, 10'h040, 10'h07E, "448×2=sat");

        // −1.0 × −1.0 = +1.0
        apply_and_check(1, 10'h0B8, 10'h0B8, 10'h038, "-1×-1=+1");

        // Max × max = overflow
        apply_and_check(1, 10'h07E, 10'h07E, 10'h07E, "max×max=sat");

        // ═════════════════════════════════════════════════════════════════════
        // MODE-SWITCH CLEANLINESS (alternating E3M6/E4M3)
        // ═════════════════════════════════════════════════════════════════════
        $display("--- Mode-switch cleanliness ---");
        begin : switch_test
            integer k;
            reg [9:0] r_e3m6, r_e4m3;

            for (k = 0; k < 20; k = k + 1) begin
                // E3M6: 1.0 × 1.0 must give 1.0 regardless of prior E4M3 op
                mode = 0; op_a = 10'h100; op_b = 10'h100;
                @(posedge clk); #1;
                @(posedge clk); #1;
                if (result !== 10'h100) begin
                    fail_count = fail_count + 1;
                    $display("FAIL mode-switch[%0d]: E3M6 contaminated, got=0x%03X want=0x100", k, result);
                end else
                    pass_count = pass_count + 1;

                // E4M3: 1.0 × 1.0 must give 1.0 regardless of prior E3M6 op
                mode = 1; op_a = 10'h038; op_b = 10'h038;
                @(posedge clk); #1;
                @(posedge clk); #1;
                if (result[7:0] !== 8'h38) begin
                    fail_count = fail_count + 1;
                    $display("FAIL mode-switch[%0d]: E4M3 contaminated, got=0x%02X want=0x38", k, result[7:0]);
                end else
                    pass_count = pass_count + 1;
            end
        end

        // ═════════════════════════════════════════════════════════════════════
        // GOLDEN VECTOR SWEEP — E3M6
        // ═════════════════════════════════════════════════════════════════════
        $display("--- E3M6 golden sweep ---");
        begin : e3m6_golden
            integer fd, ret, n;
            reg [31:0] va, vb, ve;
            fd = $fopen("DUAL_CORE_E3M6_GOLDEN.hex", "r");
            if (fd == 0) begin
                $display("WARNING: DUAL_CORE_E3M6_GOLDEN.hex not found");
            end else begin
                n = 0;
                while (!$feof(fd) && n < 1000) begin
                    ret = $fscanf(fd, "%h %h %h\n", va, vb, ve);
                    if (ret == 3) begin
                        apply_and_check(0, va[9:0], vb[9:0], ve[9:0], "golden_e3m6");
                        n = n + 1;
                    end
                end
                $fclose(fd);
                $display("E3M6 golden: %0d vectors", n);
            end
        end

        // ═════════════════════════════════════════════════════════════════════
        // GOLDEN VECTOR SWEEP — E4M3
        // ═════════════════════════════════════════════════════════════════════
        $display("--- E4M3 golden sweep ---");
        begin : e4m3_golden
            integer fd, ret, n;
            reg [31:0] va, vb, ve;
            fd = $fopen("DUAL_CORE_E4M3_GOLDEN.hex", "r");
            if (fd == 0) begin
                $display("WARNING: DUAL_CORE_E4M3_GOLDEN.hex not found");
            end else begin
                n = 0;
                while (!$feof(fd) && n < 1000) begin
                    ret = $fscanf(fd, "%h %h %h\n", va, vb, ve);
                    if (ret == 3) begin
                        apply_and_check(1, {2'b00, va[7:0]}, {2'b00, vb[7:0]}, {2'b00, ve[7:0]}, "golden_e4m3");
                        n = n + 1;
                    end
                end
                $fclose(fd);
                $display("E4M3 golden: %0d vectors", n);
            end
        end

        // ═════════════════════════════════════════════════════════════════════
        // SUMMARY
        // ═════════════════════════════════════════════════════════════════════
        $display("");
        if (fail_count == 0)
            $display("PASS  horus_dual_core: %0d tests, 0 failures", pass_count + fail_count);
        else
            $display("FAIL  horus_dual_core: %0d failures / %0d tests",
                     fail_count, pass_count + fail_count);
        $finish;
    end

endmodule

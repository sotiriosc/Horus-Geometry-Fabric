`timescale 1ns / 1ps
// tb/tb_horus_e3m6_core.v — Testbench for the standalone E3M6 multiplier.
//
// Tests:
//   1. Golden vector sweep: 1000 vectors from sim/DUAL_CORE_E3M6_GOLDEN.hex
//   2. Directed edge cases: zero, flush-sub, sat, neg sign, normal products
//
// Usage (from sim/):
//   iverilog -g2012 -Wall -o sim_e3m6_core tb/tb_horus_e3m6_core.v rtl/horus_e3m6_core.v
//   vvp sim_e3m6_core

module tb_horus_e3m6_core;

    reg  [9:0] a, b;
    wire [9:0] result;

    horus_e3m6_core dut (.a(a), .b(b), .result(result));

    integer fail_count;
    integer pass_count;
    integer i;

    // Golden vector arrays
    reg [9:0] gold_a   [0:1023];
    reg [9:0] gold_b   [0:1023];
    reg [9:0] gold_exp [0:1023];
    integer   gold_n;

    // ── Task: check one result ────────────────────────────────────────────────
    // Tolerance: accept ±1 ULP difference (truncation RTL vs RNE Python ref).
    // E3M6 codewords are magnitude-monotonic within each sign group:
    //   positive: bits [8:0] = 0..511, monotonically increasing with value
    //   negative: bits [8:0] = 0..511, monotonically increasing with |value|
    // Therefore: same sign + |bit[8:0] difference| ≤ 1 is a valid ±1 ULP check
    // that correctly handles the exponent-carry boundary (e.g., (e=1,f=63) vs (e=2,f=0)).
    task check;
        input [9:0] a_in, b_in, got, want;
        input [255:0] label;
        reg   [9:0]  diff;
        begin
            if (got === want) begin
                pass_count = pass_count + 1;
            end else if (got[9] === want[9]) begin
                // Same sign: check if 9-bit magnitude codes differ by ≤ 1
                diff = (got[8:0] >= want[8:0]) ? (got[8:0] - want[8:0])
                                                : (want[8:0] - got[8:0]);
                if (diff <= 1) begin
                    pass_count = pass_count + 1;
                end else begin
                    fail_count = fail_count + 1;
                    $display("FAIL %0s: A=0x%03X B=0x%03X got=0x%03X want=0x%03X",
                             label, a_in, b_in, got, want);
                end
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL %0s: A=0x%03X B=0x%03X got=0x%03X want=0x%03X",
                         label, a_in, b_in, got, want);
            end
        end
    endtask

    initial begin
        fail_count = 0;
        pass_count = 0;

        // ── Directed edge cases ───────────────────────────────────────────────

        // Zero × anything = signed zero
        a = 10'h000; b = 10'h100; #1;
        check(a, b, result, {1'b0, 9'd0}, "zero+×neg");
        a = 10'h000; b = 10'h1C0; #1;
        check(a, b, result, {1'b0, 9'd0}, "zero×any");

        // Flush subnormal input (e=0, f≠0) × normal = zero
        a = 10'h001; b = 10'h100; #1;  // sub × 1.0 = zero
        check(a, b, result, 10'h000, "sub×1=0");

        // 1.0 × 1.0 = 1.0  (e=4, f=0 → codeword 0x100)
        a = 10'h100; b = 10'h100; #1;
        check(a, b, result, 10'h100, "1×1=1");

        // 2.0 × 2.0 = 4.0  (e=5 → 2.0; e=6 → 4.0)
        a = 10'h140; b = 10'h140; #1;  // 0x140 = e=5, f=0
        check(a, b, result, 10'h180, "2×2=4");  // 0x180 = e=6, f=0

        // 8.0 × 2.0 = sat (8×2=16 > max≈15.875)
        a = 10'h1C0; b = 10'h140; #1;  // 0x1C0 = e=7, f=0
        check(a, b, result, 10'h1FF, "8×2=sat");  // 0x1FF = sat

        // −1.0 × +1.0 = −1.0
        a = 10'h300; b = 10'h100; #1;  // neg sign bit set: 0x300 = s=1,e=4,f=0
        check(a, b, result, 10'h300, "-1×1=-1");

        // −1.0 × −1.0 = +1.0
        a = 10'h300; b = 10'h300; #1;
        check(a, b, result, 10'h100, "-1×-1=+1");

        // Subnormal output: 0.25 × 0.25 = 0.0625 (e_stored=0, f=32 = 0x020)
        a = 10'h080; b = 10'h080; #1;  // 0x080 = e=2, f=0 → 2^(2-4)=0.25
        check(a, b, result, 10'h020, "0.25×0.25=sub");

        // ── Golden vector sweep ───────────────────────────────────────────────
        $readmemh("DUAL_CORE_E3M6_GOLDEN.hex", gold_a);

        // File format: "cw_a cw_b expected" per line (space-separated hex)
        // Since $readmemh reads one word per address, we need a custom approach.
        // We packed the golden file as 3×10-bit groups → stored as two 32-bit words.
        // Actually, re-read the file format: "AAAA BBBB EEEE" per line.
        // We use $fopen/$fscanf for this.
        begin
            integer fd;
            integer ret;
            reg [31:0] va, vb, ve;
            fd = $fopen("DUAL_CORE_E3M6_GOLDEN.hex", "r");
            if (fd == 0) begin
                $display("WARNING: DUAL_CORE_E3M6_GOLDEN.hex not found; skipping golden sweep");
            end else begin
                gold_n = 0;
                while (!$feof(fd) && gold_n < 1000) begin
                    ret = $fscanf(fd, "%h %h %h\n", va, vb, ve);
                    if (ret == 3) begin
                        a = va[9:0]; b = vb[9:0]; #1;
                        check(va[9:0], vb[9:0], result, ve[9:0], "golden");
                        gold_n = gold_n + 1;
                    end
                end
                $fclose(fd);
                $display("E3M6 golden: %0d vectors checked", gold_n);
            end
        end

        // ── Summary ───────────────────────────────────────────────────────────
        $display("");
        if (fail_count == 0)
            $display("PASS  horus_e3m6_core: %0d tests, 0 failures", pass_count + fail_count);
        else
            $display("FAIL  horus_e3m6_core: %0d failures / %0d tests",
                     fail_count, pass_count + fail_count);
        $finish;
    end

endmodule

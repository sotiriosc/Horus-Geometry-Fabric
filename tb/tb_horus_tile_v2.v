// tb/tb_horus_tile_v2.v — Testbench for the respecified tile.
//
// Tests:
//  [1] E4M3 golden sweep: 1000 operand pairs through v2 ports (K2).
//      Expected outputs are per-pair shimmed NFE-13 products from
//      sim/tile_v2_golden.py (sources of truth unchanged).
//  [2] E3M6 golden sweep: 1000 operand pairs (K2).
//  [3] Mode-switch cleanliness: with fixed operands on the ports, the
//      output must equal the E3M6 path exactly one cycle after mode
//      drops (mode_r is registered) and the E4M3 path one cycle after
//      mode rises — no stale or mixed output.
//
// Tolerances (identical to the pre-registered v1 conventions in
// tb/tb_horus_tile.v):
//   - E4M3: exact match, with signed-zero floor equivalence (0x0000 ≡
//     0x1000) — the RTL shim preserves the product sign on the zero floor
//     while the Python encoder canonicalizes −0 to +0.
//   - E3M6: ±1 ULP in the 12-bit magnitude — the RTL core truncates the
//     product mantissa while the Python reference rounds to nearest-even.
// Both tolerances are structural properties of the cores, documented in
// docs/TILE_RESULTS.md; the v2 tile adds zero deviation on top of them.

`timescale 1ns/1ps
`default_nettype none

module tb_horus_tile_v2;

    reg         clk;
    reg         rst_n;
    reg         mode;
    reg  [9:0]  op_a;
    reg  [9:0]  op_b;
    wire [12:0] nfe_out;

    horus_tile_v2 dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .mode    (mode),
        .op_a    (op_a),
        .op_b    (op_b),
        .nfe_out (nfe_out)
    );

    always #5 clk = ~clk;

    // ── Golden memories ────────────────────────────────────────────────────────
    reg [15:0] e4m3_ops [0:999];   // {a[7:0], b[7:0]}
    reg [19:0] e3m6_ops [0:999];   // {a[9:0], b[9:0]}
    reg [15:0] e4m3_exp [0:999];   // 13-bit NFE-13 in 16-bit words
    reg [15:0] e3m6_exp [0:999];

    integer total_tests;
    integer failures;
    integer i;

    task reset_dut;
        begin
            rst_n = 1'b0;
            mode  = 1'b0;
            op_a  = 10'd0;
            op_b  = 10'd0;
            @(posedge clk); @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // Set mode and wait for mode_r to latch it.
    task set_mode;
        input m;
        begin
            mode = m;
            @(posedge clk);
            #1;
        end
    endtask

    // Comparison with v1 tolerance conventions (see header).
    // allow_ulp=0: exact match with signed-zero floor equivalence.
    // allow_ulp=1: additionally ±1 ULP in the 12-bit magnitude.
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

    // ── [1] E4M3 golden sweep ──────────────────────────────────────────────────
    task test_e4m3_golden;
        integer fail0;
        begin
            $display("[1] E4M3 golden sweep (1000 pairs through v2 ports)");
            fail0 = failures;
            set_mode(1'b1);
            for (i = 0; i < 1000; i = i + 1) begin
                op_a = {2'b00, e4m3_ops[i][15:8]};
                op_b = {2'b00, e4m3_ops[i][7:0]};
                #2;   // combinational settle
                total_tests = total_tests + 1;
                if (!check_ulp(nfe_out, e4m3_exp[i][12:0], 0)) begin
                    failures = failures + 1;
                    if (failures - fail0 <= 5)
                        $display("  FAIL [%0d]: a=%02x b=%02x got=%04x exp=%04x",
                                 i, e4m3_ops[i][15:8], e4m3_ops[i][7:0],
                                 nfe_out, e4m3_exp[i][12:0]);
                end
            end
            $display("  E4M3 golden: %0d failures", failures - fail0);
        end
    endtask

    // ── [2] E3M6 golden sweep ──────────────────────────────────────────────────
    task test_e3m6_golden;
        integer fail0;
        begin
            $display("[2] E3M6 golden sweep (1000 pairs through v2 ports)");
            fail0 = failures;
            set_mode(1'b0);
            for (i = 0; i < 1000; i = i + 1) begin
                op_a = e3m6_ops[i][19:10];
                op_b = e3m6_ops[i][9:0];
                #2;
                total_tests = total_tests + 1;
                if (!check_ulp(nfe_out, e3m6_exp[i][12:0], 1)) begin
                    failures = failures + 1;
                    if (failures - fail0 <= 5)
                        $display("  FAIL [%0d]: a=%03x b=%03x got=%04x exp=%04x",
                                 i, e3m6_ops[i][19:10], e3m6_ops[i][9:0],
                                 nfe_out, e3m6_exp[i][12:0]);
                end
            end
            $display("  E3M6 golden: %0d failures", failures - fail0);
        end
    endtask

    // ── [3] Mode-switch cleanliness ────────────────────────────────────────────
    // Fixed operand pattern held on the ports; verify the output tracks
    // mode_r exactly (one-cycle latency, no stale/mixed output).
    task test_mode_switch;
        reg [12:0] out_e4m3_path;
        reg [12:0] out_e3m6_path;
        integer fail0;
        begin
            $display("[3] Mode-switch cleanliness");
            fail0 = failures;

            // Operands valid in BOTH formats: use 1.5 × 2.0.
            // E4M3: 1.5=0x3C (e=7,f=4), 2.0=0x40 (e=8,f=0) → {a,b}={0x3C,0x40}
            // E3M6: 1.5=0x120 (e=4,f=32), 2.0=0x140 (e=5,f=0)
            // But ports are shared; drive an E3M6 pattern whose low 8 bits
            // are also a legal E4M3 pattern, and capture each path's output
            // through the DUT itself (reference = DUT in settled state).

            // Settle in E4M3 mode, capture reference
            set_mode(1'b1);
            op_a = 10'h03C; op_b = 10'h040;
            #2 out_e4m3_path = nfe_out;

            // Settle in E3M6 mode, capture reference (same port bits)
            set_mode(1'b0);
            #2 out_e3m6_path = nfe_out;

            if (out_e4m3_path === out_e3m6_path) begin
                failures = failures + 1;
                $display("  FAIL: paths indistinguishable (out=%04x) — test vector invalid",
                         out_e4m3_path);
            end
            total_tests = total_tests + 1;

            // Now toggle mode and check one-cycle tracking:
            // Immediately after raising mode (before clk edge), output must
            // still be the E3M6 path (mode_r not yet updated).
            mode = 1'b1;
            #2;
            total_tests = total_tests + 1;
            if (nfe_out !== out_e3m6_path) begin
                failures = failures + 1;
                $display("  FAIL: output switched before mode_r latched (got %04x)", nfe_out);
            end

            // After the clock edge, output must be the E4M3 path.
            @(posedge clk); #2;
            total_tests = total_tests + 1;
            if (nfe_out !== out_e4m3_path) begin
                failures = failures + 1;
                $display("  FAIL: output not E4M3 path after latch (got %04x exp %04x)",
                         nfe_out, out_e4m3_path);
            end

            // Switch back: same discipline.
            mode = 1'b0;
            #2;
            total_tests = total_tests + 1;
            if (nfe_out !== out_e4m3_path) begin
                failures = failures + 1;
                $display("  FAIL: output switched before mode_r latched (got %04x)", nfe_out);
            end
            @(posedge clk); #2;
            total_tests = total_tests + 1;
            if (nfe_out !== out_e3m6_path) begin
                failures = failures + 1;
                $display("  FAIL: output not E3M6 path after latch (got %04x exp %04x)",
                         nfe_out, out_e3m6_path);
            end

            $display("  Mode-switch: %0d failures  %s",
                     failures - fail0, (failures == fail0) ? "PASS" : "FAIL");
        end
    endtask

    // ── Main ───────────────────────────────────────────────────────────────────
    initial begin
        clk         = 1'b0;
        total_tests = 0;
        failures    = 0;

        $readmemh("TILE_E4M3_OPS.hex",    e4m3_ops);
        $readmemh("TILE_V2_E4M3_OUT.hex", e4m3_exp);
        $readmemh("TILE_E3M6_OPS.hex",    e3m6_ops);
        $readmemh("TILE_V2_E3M6_OUT.hex", e3m6_exp);

        reset_dut;
        test_e4m3_golden;
        test_e3m6_golden;
        test_mode_switch;

        $display("");
        if (failures == 0)
            $display("PASS  horus_tile_v2: %0d tests, 0 failures", total_tests);
        else
            $display("FAIL  horus_tile_v2: %0d tests, %0d failures", total_tests, failures);
        $finish;
    end

endmodule

`default_nettype wire

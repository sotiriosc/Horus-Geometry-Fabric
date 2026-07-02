`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_hbs13_boundary_gap
// Project  : Horus Engine
// File     : tb/tb_hbs13_boundary_gap.v
//
// Purpose  : HBS-13 Boundary Gap Characterization Suite.
//            Maps information behavior near the two arithmetic phase
//            boundaries discovered by HBS-12:
//
//              Collapse boundary  : stored_E = 15 ↔ 16
//              Saturation boundary: stored_E = 47 ↔ 48
//
//            ALL tests use mode_tag = 3'b000 (Standard — no policy).
//            DO NOT modify RTL, encoding, or LUTs.
//
// Tests:
//   HBS-13A (test_id=13)  Collapse Edge Scan      E=12..20, f=0..63
//   HBS-13B (test_id=14)  Saturation Edge Scan    E=44..52, f=0..63
//   HBS-13C (test_id=15)  Information Migration   scale-up / scale-down chains
//   HBS-13D (test_id=16)  Recovery Test           near-boundary + floor round-trips
//   HBS-13E (test_id=17)  Fraction Survival       f-field uniqueness near boundaries
//
// CSV schema (same as HBS-12):
//   test_id, subtest, cyc, stored_E, f_val, op_code, result,
//   uf, ovf, rollover, extra
//
//   op_code: 1=ADD  2=SUB  3=MUL
//   extra  : test-dependent (input codeword, seed_E, original codeword, …)
// ============================================================================

module tb_hbs13_boundary_gap;

    // =========================================================================
    // Constants
    // =========================================================================
    localparam CLK_HALF  = 5;                // 10 ns period

    localparam [12:0] NFE_ONE   = 13'h800;   // 1.0   E=32  f=0
    localparam [12:0] NFE_HALF  = 13'h7C0;   // 0.5   E=31  f=0   scale-down MUL
    localparam [12:0] NFE_TWO   = 13'h840;   // 2.0   E=33  f=0   scale-up   MUL
    localparam [12:0] NFE_FLOOR = 13'h000;   // floor sentinel
    localparam [2:0]  MODE_STD  = 3'b000;    // Standard — no policy

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg         clk, rst_n;
    reg  [12:0] op_a, op_b;
    reg  [1:0]  op_sel;
    reg  [2:0]  mode_tag;
    reg         accum_en, accum_clr;
    reg  [5:0]  host_tile_depth;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag, underflow_flag, exp_ovf_flag;
    wire [15:0] op_count;
    wire        accum_full;

    // =========================================================================
    // Module-level variables (Verilog-2001: all declared at module scope)
    // =========================================================================
    integer csv_fd;
    integer g_n, g_m, g_d, g_s;   // loop iterators
    reg [5:0]  t_E, t_f;           // current exponent / fraction under test
    reg [12:0] t_x;                // composed test operand
    reg [12:0] chain_st;           // running chain state

    // Edge E tables for 13A / 13B
    integer collapse_E [0:8];      // E = 12..20
    integer sat_E      [0:8];      // E = 44..52

    // Boundary E tables for 13E
    integer frac_cE    [0:4];      // E = 14..18
    integer frac_sE    [0:4];      // E = 46..50

    // 13C / 13D anchor parameters
    integer d13_anchor_E   [0:2];  // E = 24, 32, 40
    integer d13_near_steps;        // fixed 20-step near-boundary round-trip
    integer d13_floor_steps[0:2];  // floor_steps[i] for each anchor

    // 13D state
    reg [12:0] d13_orig;
    reg [12:0] d13_bottom;
    reg [12:0] d13_recovered;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // DUT
    // =========================================================================
    horus_system u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .op_a            (op_a),
        .op_b            (op_b),
        .op_sel          (op_sel),
        .mode_tag        (mode_tag),
        .accum_en        (accum_en),
        .accum_clr       (accum_clr),
        .host_tile_depth (host_tile_depth),
        .result          (result),
        .accum_out       (accum_out),
        .rollover_flag   (rollover_flag),
        .underflow_flag  (underflow_flag),
        .exp_ovf_flag    (exp_ovf_flag),
        .op_count        (op_count),
        .accum_full      (accum_full)
    );

    // =========================================================================
    // Tasks
    // =========================================================================

    task do_reset;
        begin
            rst_n           = 1'b0;
            op_a            = 13'd0;
            op_b            = 13'd0;
            op_sel          = 2'b11;   // NOP
            mode_tag        = MODE_STD;
            accum_en        = 1'b0;
            accum_clr       = 1'b0;
            host_tile_depth = 6'd0;    // unlimited
            repeat(5) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // Single 1-cycle operation.  accum_en is always 0 — pure arithmetic.
    task exec_op;
        input [12:0] a, b;
        input [1:0]  sel;
        begin
            @(negedge clk);
            op_a     = a;
            op_b     = b;
            op_sel   = sel;
            mode_tag = MODE_STD;
            accum_en = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // Write one CSV row.
    task log_csv;
        input integer tid, sub, cyc;
        input [5:0]   sE, fv;
        input integer opc;
        input [12:0]  res;
        input integer luf, lovf, lro, lextra;
        begin
            $fwrite(csv_fd,
                "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                tid, sub, cyc, sE, fv, opc,
                res, luf, lovf, lro, lextra);
        end
    endtask

    // =========================================================================
    // Watchdog
    // =========================================================================
    initial begin : WATCHDOG
        #10_000_000;
        $display("*** HBS-13 WATCHDOG TIMEOUT ***");
        $finish;
    end

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin : MAIN

        $display("");
        $display("==============================================================");
        $display("  HBS-13: Boundary Gap Characterization Suite");
        $display("  mode_tag = 3'b000 (Standard)  —  no policy effects");
        $display("==============================================================");

        // ── Table initialisation ─────────────────────────────────────────────
        collapse_E[0]=12; collapse_E[1]=13; collapse_E[2]=14;
        collapse_E[3]=15; collapse_E[4]=16; collapse_E[5]=17;
        collapse_E[6]=18; collapse_E[7]=19; collapse_E[8]=20;

        sat_E[0]=44; sat_E[1]=45; sat_E[2]=46;
        sat_E[3]=47; sat_E[4]=48; sat_E[5]=49;
        sat_E[6]=50; sat_E[7]=51; sat_E[8]=52;

        frac_cE[0]=14; frac_cE[1]=15; frac_cE[2]=16;
        frac_cE[3]=17; frac_cE[4]=18;

        frac_sE[0]=46; frac_sE[1]=47; frac_sE[2]=48;
        frac_sE[3]=49; frac_sE[4]=50;

        d13_anchor_E[0] = 24;
        d13_anchor_E[1] = 32;
        d13_anchor_E[2] = 40;

        // Near-boundary: 20 down+up — no anchor floors (E goes to 4/12/20)
        d13_near_steps = 20;

        // Floor-descent: anchor_E + 2 steps — two steps past floor
        d13_floor_steps[0] = 26;  // 24+2
        d13_floor_steps[1] = 34;  // 32+2
        d13_floor_steps[2] = 42;  // 40+2

        // ── Open CSV ─────────────────────────────────────────────────────────
        csv_fd = $fopen("HBS13_BOUNDARY_GAP.csv", "w");
        $fwrite(csv_fd, "test_id,subtest,cyc,stored_E,f_val,op_code,result,uf,ovf,rollover,extra\n");

        do_reset;

        // =================================================================
        // HBS-13A  COLLAPSE EDGE SCAN  (E = 12..20, f = 0..63)
        // ─────────────────────────────────────────────────────────────────
        // Four operations per (E, f) pair:
        //   sub=0  MUL(x, x)      self-product — maps exact UF cliff at E=16
        //   sub=1  MUL(x, ONE)    identity     — expected: result == x always
        //   sub=2  ADD(x, x)      fraction add — rollover at E=15, f≥32 crosses
        //                                        into the stable zone (E→16)
        //   sub=3  MUL(x, HALF)   scale-down   — fraction preserved, E−1
        // =================================================================
        $display("  [HBS-13A] Collapse Edge Scan (E=12..20, f=0..63)...");
        for (g_n = 0; g_n < 9; g_n = g_n + 1) begin
            t_E = collapse_E[g_n][5:0];
            for (g_m = 0; g_m < 64; g_m = g_m + 1) begin
                t_f = g_m[5:0];
                t_x = {1'b0, t_E, t_f};

                exec_op(t_x, t_x, 2'b10);       // sub=0: MUL(x,x)
                log_csv(13, 0, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, 0);

                exec_op(t_x, NFE_ONE, 2'b10);   // sub=1: MUL(x, 1.0)
                log_csv(13, 1, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, t_x);

                exec_op(t_x, t_x, 2'b00);       // sub=2: ADD(x, x)
                log_csv(13, 2, g_n*64+g_m,
                        t_E, t_f, 1, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, 0);

                exec_op(t_x, NFE_HALF, 2'b10);  // sub=3: MUL(x, 0.5)
                log_csv(13, 3, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, 0);
            end
        end
        $display("  [HBS-13A] %0d rows logged.", 9*64*4);

        // =================================================================
        // HBS-13B  SATURATION EDGE SCAN  (E = 44..52, f = 0..63)
        // ─────────────────────────────────────────────────────────────────
        //   sub=0  MUL(x, x)      self-product — maps OVF cliff at E=48
        //   sub=1  MUL(x, ONE)    identity     — expected: result == x
        //   sub=2  ADD(x, x)      fraction add — rollover at E=47, f≥32 crosses
        //                                        into saturation zone (E→48)
        //   sub=3  MUL(x, TWO)    scale-up     — fraction preserved, E+1
        // =================================================================
        $display("  [HBS-13B] Saturation Edge Scan (E=44..52, f=0..63)...");
        for (g_n = 0; g_n < 9; g_n = g_n + 1) begin
            t_E = sat_E[g_n][5:0];
            for (g_m = 0; g_m < 64; g_m = g_m + 1) begin
                t_f = g_m[5:0];
                t_x = {1'b0, t_E, t_f};

                exec_op(t_x, t_x, 2'b10);       // sub=0: MUL(x,x)
                log_csv(14, 0, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, 0);

                exec_op(t_x, NFE_ONE, 2'b10);   // sub=1: MUL(x, 1.0)
                log_csv(14, 1, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, t_x);

                exec_op(t_x, t_x, 2'b00);       // sub=2: ADD(x, x)
                log_csv(14, 2, g_n*64+g_m,
                        t_E, t_f, 1, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, 0);

                exec_op(t_x, NFE_TWO, 2'b10);   // sub=3: MUL(x, 2.0)
                log_csv(14, 3, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, 0);
            end
        end
        $display("  [HBS-13B] %0d rows logged.", 9*64*4);

        // =================================================================
        // HBS-13C  INFORMATION MIGRATION TEST
        // ─────────────────────────────────────────────────────────────────
        // For each seed E ∈ {24, 32, 40}:
        //   Direction 0 (subtest = g_s*2):     scale DOWN 32 × MUL(state, HALF)
        //   Direction 1 (subtest = g_s*2 + 1): scale UP   32 × MUL(state, TWO)
        //
        // Key algebraic properties (verified analytically):
        //   MUL(x, HALF): stored_E ← E−1, fraction PRESERVED (f_b=0 → f_result=f_a)
        //   MUL(x, TWO ): stored_E ← E+1, fraction PRESERVED
        //   → Information migration is purely in the exponent channel.
        //   → Fraction is inert until floor (f=0 forced) or OVF (f=63 forced).
        //
        // Column mapping:
        //   cyc     = step index (0..31)
        //   stored_E, f_val = E and f of state AFTER the step
        //   extra   = seed E
        // =================================================================
        $display("  [HBS-13C] Information Migration...");
        begin : C13_LOOP
            integer s_E;
            for (g_s = 0; g_s < 3; g_s = g_s + 1) begin
                s_E = d13_anchor_E[g_s];

                // Scale DOWN
                chain_st = {1'b0, s_E[5:0], 6'd0};
                for (g_d = 0; g_d < 32; g_d = g_d + 1) begin
                    exec_op(chain_st, NFE_HALF, 2'b10);
                    chain_st = result;
                    log_csv(15, g_s*2, g_d,
                            chain_st[11:6], chain_st[5:0], 3, chain_st,
                            underflow_flag, exp_ovf_flag, rollover_flag, s_E);
                end

                // Scale UP
                chain_st = {1'b0, s_E[5:0], 6'd0};
                for (g_d = 0; g_d < 32; g_d = g_d + 1) begin
                    exec_op(chain_st, NFE_TWO, 2'b10);
                    chain_st = result;
                    log_csv(15, g_s*2+1, g_d,
                            chain_st[11:6], chain_st[5:0], 3, chain_st,
                            underflow_flag, exp_ovf_flag, rollover_flag, s_E);
                end
            end
        end
        $display("  [HBS-13C] %0d rows logged.", 3*2*32);

        // =================================================================
        // HBS-13D  RECOVERY TEST
        // ─────────────────────────────────────────────────────────────────
        // For each anchor E ∈ {24, 32, 40}, fraction f = 31:
        //
        //   Scenario A (subtests 0,1,2) — Near-boundary descent:
        //     20 × MUL(state, HALF) → E drops to 4/12/20 (never floors)
        //     20 × MUL(state, TWO ) → should recover exactly
        //
        //   Scenario B (subtests 3,4,5) — Through-floor descent:
        //     (anchor_E+2) × MUL(state, HALF) → through floor, absorbing
        //     (anchor_E+2) × MUL(state, TWO ) → partial E recovery, f=0 lost
        //
        // CSV layout per scenario:
        //   cyc=0: state at BOTTOM of descent (after all down steps)
        //   cyc=1: state after full recovery attempt (after all up steps)
        //   extra: original codeword (for comparison)
        // =================================================================
        $display("  [HBS-13D] Recovery Test...");
        begin : D13_LOOP
            integer s_E, anch_f;
            anch_f = 31;

            for (g_s = 0; g_s < 3; g_s = g_s + 1) begin
                s_E      = d13_anchor_E[g_s];
                d13_orig = {1'b0, s_E[5:0], anch_f[5:0]};

                // ── Scenario A: near-boundary ────────────────────────────
                chain_st = d13_orig;
                for (g_d = 0; g_d < d13_near_steps; g_d = g_d + 1) begin
                    exec_op(chain_st, NFE_HALF, 2'b10);
                    chain_st = result;
                end
                d13_bottom = chain_st;
                log_csv(16, g_s, 0,
                        d13_bottom[11:6], d13_bottom[5:0], 3, d13_bottom,
                        underflow_flag, exp_ovf_flag, rollover_flag, d13_orig);

                for (g_d = 0; g_d < d13_near_steps; g_d = g_d + 1) begin
                    exec_op(chain_st, NFE_TWO, 2'b10);
                    chain_st = result;
                end
                d13_recovered = chain_st;
                log_csv(16, g_s, 1,
                        d13_recovered[11:6], d13_recovered[5:0], 3, d13_recovered,
                        underflow_flag, exp_ovf_flag, rollover_flag, d13_orig);

                // ── Scenario B: through-floor ────────────────────────────
                chain_st = d13_orig;
                for (g_d = 0; g_d < d13_floor_steps[g_s]; g_d = g_d + 1) begin
                    exec_op(chain_st, NFE_HALF, 2'b10);
                    chain_st = result;
                end
                d13_bottom = chain_st;
                log_csv(16, g_s+3, 0,
                        d13_bottom[11:6], d13_bottom[5:0], 3, d13_bottom,
                        underflow_flag, exp_ovf_flag, rollover_flag, d13_orig);

                for (g_d = 0; g_d < d13_floor_steps[g_s]; g_d = g_d + 1) begin
                    exec_op(chain_st, NFE_TWO, 2'b10);
                    chain_st = result;
                end
                d13_recovered = chain_st;
                log_csv(16, g_s+3, 1,
                        d13_recovered[11:6], d13_recovered[5:0], 3, d13_recovered,
                        underflow_flag, exp_ovf_flag, rollover_flag, d13_orig);
            end
        end
        $display("  [HBS-13D] 12 rows logged.");

        // =================================================================
        // HBS-13E  FRACTION SURVIVAL ANALYSIS
        // ─────────────────────────────────────────────────────────────────
        // Collapse boundary zone: E = 14..18
        //   sub=0: MUL(x, x)   — result fraction survives only at E≥16
        //   sub=1: MUL(x, ONE) — identity always preserved (E, f unchanged)
        //
        // Saturation boundary zone: E = 46..50
        //   sub=2: MUL(x, x)   — result fraction survives only at E≤47
        //   sub=3: MUL(x, ONE) — identity always preserved
        //
        // extra = input codeword (for identity comparison)
        // =================================================================
        $display("  [HBS-13E] Fraction Survival Analysis...");

        // Collapse side
        for (g_n = 0; g_n < 5; g_n = g_n + 1) begin
            t_E = frac_cE[g_n][5:0];
            for (g_m = 0; g_m < 64; g_m = g_m + 1) begin
                t_f = g_m[5:0];
                t_x = {1'b0, t_E, t_f};

                exec_op(t_x, t_x, 2'b10);
                log_csv(17, 0, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, t_x);

                exec_op(t_x, NFE_ONE, 2'b10);
                log_csv(17, 1, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, t_x);
            end
        end

        // Saturation side
        for (g_n = 0; g_n < 5; g_n = g_n + 1) begin
            t_E = frac_sE[g_n][5:0];
            for (g_m = 0; g_m < 64; g_m = g_m + 1) begin
                t_f = g_m[5:0];
                t_x = {1'b0, t_E, t_f};

                exec_op(t_x, t_x, 2'b10);
                log_csv(17, 2, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, t_x);

                exec_op(t_x, NFE_ONE, 2'b10);
                log_csv(17, 3, g_n*64+g_m,
                        t_E, t_f, 3, result,
                        underflow_flag, exp_ovf_flag, rollover_flag, t_x);
            end
        end
        $display("  [HBS-13E] %0d rows logged.", 5*64*2 + 5*64*2);

        // ── Close CSV ────────────────────────────────────────────────────
        $fclose(csv_fd);
        $display("");
        $display("  CSV  → HBS13_BOUNDARY_GAP.csv");
        $display("  Next → python3 analyze_hbs13.py");
        $display("==============================================================");
        $finish;

    end // MAIN

endmodule

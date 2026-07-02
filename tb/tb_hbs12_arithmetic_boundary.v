`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_hbs12_arithmetic_boundary
// Project  : Horus Engine
// File     : tb/tb_hbs12_arithmetic_boundary.v
//
// Purpose  : HBS-12 Arithmetic Boundary Mapping Suite.
//            Maps the exact operating envelope of the HORUS v3 arithmetic
//            core.  ALL tests run with mode_tag = 3'b000 (Standard) to
//            isolate pure arithmetic behaviour — NO policy effects.
//
// Tests:
//   HBS-12A  (test_id=12) Exponent Envelope Scan     — MUL(x,x) for E=0..63
//   HBS-12B  (test_id=13) Fraction Resolution Map    — MUL(x,x) + identity
//   HBS-12C  (test_id=14) Normalization Stress Test  — ADD/MUL at boundaries
//   HBS-12D  (test_id=15) Information Retention Test — MUL chain depth 1..64
//   HBS-12E  (test_id=16) Regime Transition Detector — UF/OVF/floor sweep
//   HBS-12F  (test_id=17) Reversibility Test         — ADD→SUB round-trip
//
// CSV columns:
//   test_id, subtest, cyc, stored_E, f_val, op_code, result,
//   uf, ovf, rollover, extra
//
//   op_code:  0=NOP  1=ADD  2=SUB  3=MUL
//   extra:    test-specific integer (depth, delta, seed, etc.)
// ============================================================================

module tb_hbs12_arithmetic_boundary;

    // =========================================================================
    // Constants
    // =========================================================================
    localparam CLK_HALF = 5;    // 10 ns period

    // Canonical NFE codewords
    localparam [12:0] NFE_ONE    = 13'h800;  // 1.0   S=0 E=32 f=0
    localparam [12:0] NFE_HALF   = 13'h7C0;  // 0.5   S=0 E=31 f=0  (chain mult)
    localparam [12:0] NFE_FLOOR  = 13'h000;  // floor S=0 E=0  f=0
    localparam [12:0] NFE_MAXPOS = 13'h1FFF; // max   S=0 E=63 f=63

    // All tests use Standard mode (no policy decoder interaction)
    localparam [2:0] MODE_STD = 3'b000;

    // Operation codes (match op_sel encoding in NFE; stored in CSV op_code field)
    localparam OP_ADD = 2'b00;
    localparam OP_SUB = 2'b01;
    localparam OP_MUL = 2'b10;
    localparam OP_NOP = 2'b11;

    // HBS-12D chain multiplier: E=31 f=0 (value=0.5). Each MUL subtracts 1 from E.
    localparam [12:0] CHAIN_Y = 13'h7C0;    // NFE_HALF

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
    // Module-level utility registers
    // =========================================================================
    integer     csv_fd;
    reg [15:0]  lfsr_r;

    // Loop indices (all module-level — Verilog-2001)
    integer g_n;          // outer loop (E or seed index)
    integer g_m;          // inner loop (f or delta index)
    integer g_d;          // depth counter
    integer g_s;          // strategy / sample index

    // Operand construction helpers
    reg [5:0]  a12_E;      // stored exponent being tested
    reg [5:0]  a12_f;      // fraction being tested
    reg [12:0] a12_x;      // primary operand
    reg [12:0] a12_y;      // secondary operand / multiplier
    reg [12:0] a12_delta;  // ADD/SUB delta operand (only [5:0] matters)

    // Chain and reversibility state
    reg [12:0]  chain_st;   // running chain state
    reg [12:0]  add_result; // saved ADD result for reversibility
    reg [12:0]  recovered;  // recovered operand
    integer     floor_cnt, uf_cnt_d, unique_cnt;

    // Guard-B pipeline handling
    reg guard_b_active;

    // Depth array for 12D (as parameters)
    localparam D0 = 1;
    localparam D1 = 2;
    localparam D2 = 4;
    localparam D3 = 8;
    localparam D4 = 16;
    localparam D5 = 32;
    localparam D6 = 64;

    // 12D depth schedule as integer variables
    integer d12_depth_vals [0:6];

    // LFSR
    function [15:0] lfsr_step;
        input [15:0] s;
        begin lfsr_step = {s[14:0], s[15]^s[13]^s[12]^s[10]}; end
    endfunction

    // Generate seed codeword: E in [28..36], f random — avoids immediate floor
    function [12:0] mk_seed;
        input [15:0] s;
        reg [5:0] e;
        begin
            e = 6'd28 + {3'b0, s[12:10]};  // E in [28..35] (8 values)
            if (e > 6'd35) e = 6'd35;
            mk_seed = {1'b0, e, s[5:0]};
        end
    endfunction

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // DUT instantiation
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
            op_sel          = OP_NOP;
            mode_tag        = MODE_STD;
            accum_en        = 1'b0;
            accum_clr       = 1'b0;
            host_tile_depth = 6'd0;   // unlimited (tile gate disabled)
            repeat(5) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // Execute one 1-cycle operation (MUL / ADD / Guard-A SUB / NOP)
    // accum_en is always 0 — pure arithmetic scan
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
            accum_en = 1'b0;
        end
    endtask

    // Execute SUB, handling Guard-B 2-cycle pipeline automatically.
    // Guard-B fires when op_a[5:0] < op_b[5:0] AND op_a[11:6] != 0.
    // For E=0 + Guard-B: immediate floor (1 cycle, no pipeline).
    // After task: result wire holds the final SUB output.
    task exec_sub;
        input [12:0] a, b;
        begin
            guard_b_active = (a[5:0] < b[5:0]) && (a[11:6] != 6'd0);

            @(negedge clk);
            op_a     = a;
            op_b     = b;
            op_sel   = OP_SUB;
            mode_tag = MODE_STD;
            accum_en = 1'b0;
            @(posedge clk); #1;
            accum_en = 1'b0;

            if (guard_b_active) begin
                // Cycle 2 NOP: Stage-2 writes result AFTER the NOP write
                // (Stage-2 block is placed after the case statement in horus_nfe.v;
                //  its NBA write wins over the NOP's NBA write by source order).
                @(negedge clk);
                op_sel   = OP_NOP;
                op_a     = 13'h1FFF;  // Sentinel — will be overwritten by Stage-2
                @(posedge clk); #1;
                // result now = Guard-B Stage-2 output
            end
            // result now valid for both Guard-A and Guard-B
        end
    endtask

    // NOP flush: allow any pending pipeline writes to complete without
    // issuing a new arithmetic operation.
    task nop_flush;
        begin
            @(negedge clk); op_sel = OP_NOP; op_a = NFE_FLOOR; accum_en = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // Log one CSV row.
    task log_csv;
        input integer tid, sub, cyc;
        input [5:0]  sE;
        input [5:0]  fv;
        input integer opc;
        input [12:0] res;
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
    initial begin
        #5_000_000;
        $display("*** WATCHDOG TIMEOUT ***");
        $finish;
    end

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin : MAIN

        $display("");
        $display("==============================================================");
        $display("  HBS-12: Arithmetic Boundary Mapping Suite");
        $display("  Horus NFE v3  —  mode_tag=000 (Standard, no policy)");
        $display("==============================================================");

        d12_depth_vals[0] = D0;
        d12_depth_vals[1] = D1;
        d12_depth_vals[2] = D2;
        d12_depth_vals[3] = D3;
        d12_depth_vals[4] = D4;
        d12_depth_vals[5] = D5;
        d12_depth_vals[6] = D6;

        csv_fd = $fopen("HBS12_ARITHMETIC_BOUNDARY.csv", "w");
        $fwrite(csv_fd,
            "test_id,subtest,cyc,stored_E,f_val,op_code,result,uf,ovf,rollover,extra\n");

        do_reset;

        // =================================================================
        // HBS-12A: EXPONENT ENVELOPE SCAN
        // ─────────────────────────────────────────────────────────────────
        // MUL(x, x) for every stored_E = 0..63, f ∈ {0, 31, 63}.
        // Maps the complete UF/OVF landscape of self-multiplication.
        //
        // Expected zones (from algebra):
        //   UF  : stored_E < 16  (exp_sum = 2E−32 < 0 → bit[7] set)
        //   NORM: 16 ≤ E ≤ 47
        //   OVF : E > 47  (2E−32 > 63 → bit[6] set)
        //
        // Measurement also runs ADD(x, delta=f) and SUB(x, delta=0)
        // to expose rollover and minimum-floor boundaries.
        // =================================================================
        $display("  [HBS-12A] Exponent Envelope Scan...");
        begin : A12_LOOP
            integer fi;
            integer f_tbl [0:2];
            f_tbl[0] = 0;
            f_tbl[1] = 31;
            f_tbl[2] = 63;

            for (g_n = 0; g_n < 64; g_n = g_n + 1) begin
                for (fi = 0; fi < 3; fi = fi + 1) begin
                    a12_E = g_n[5:0];
                    a12_f = f_tbl[fi][5:0];
                    a12_x = {1'b0, a12_E, a12_f};   // Positive operand

                    // Op 0: MUL(x, x)
                    exec_op(a12_x, a12_x, OP_MUL);
                    log_csv(12, g_n*3+fi, 0, a12_E, a12_f, 3, result,
                            underflow_flag, exp_ovf_flag, rollover_flag, 0);

                    // Op 1: ADD(x, x) — op_b[5:0]=a12_f used as delta
                    exec_op(a12_x, a12_x, OP_ADD);
                    log_csv(12, g_n*3+fi, 1, a12_E, a12_f, 1, result,
                            underflow_flag, exp_ovf_flag, rollover_flag, a12_f);

                    // Op 2: SUB(x, 0) — delta=0, Guard-A always; UF if E=0
                    a12_delta = {1'b0, a12_E, 6'd0};  // op_b with m_b=0
                    exec_sub(a12_x, a12_delta);
                    log_csv(12, g_n*3+fi, 2, a12_E, a12_f, 2, result,
                            underflow_flag, exp_ovf_flag, rollover_flag, 0);
                end
            end
        end
        $display("  [HBS-12A] 576 rows logged.");

        // =================================================================
        // HBS-12B: FRACTION RESOLUTION MAP
        // ─────────────────────────────────────────────────────────────────
        // Pass 1: E=0..63, f=0 — MUL(x,x).
        //   How does result exponent vary across the full E range?
        //
        // Pass 2: E=32, f=0..63 — MUL(x,x).
        //   How does result fraction vary across the full f range?
        //   Reveals fraction-level collision / quantization at E=32.
        //
        // Pass 3: E=32, f=0..63 — MUL(x, NFE_ONE).
        //   Identity test: MUL(x, ONE) must = x for all x.
        //   Any deviation exposes arithmetic identity failure.
        // =================================================================
        $display("  [HBS-12B] Fraction Resolution Map...");

        // Pass 1: f=0 fixed, sweep E
        for (g_n = 0; g_n < 64; g_n = g_n + 1) begin
            a12_E = g_n[5:0];
            a12_x = {1'b0, a12_E, 6'd0};
            exec_op(a12_x, a12_x, OP_MUL);
            log_csv(13, 0, g_n, a12_E, 6'd0, 3, result,
                    underflow_flag, exp_ovf_flag, rollover_flag, 0);
        end

        // Pass 2: E=32 fixed, sweep f; MUL(x,x)
        for (g_n = 0; g_n < 64; g_n = g_n + 1) begin
            a12_f = g_n[5:0];
            a12_x = {1'b0, 6'd32, a12_f};
            exec_op(a12_x, a12_x, OP_MUL);
            log_csv(13, 1, g_n, 6'd32, a12_f, 3, result,
                    underflow_flag, exp_ovf_flag, rollover_flag, a12_x);
        end

        // Pass 3: E=32 fixed, sweep f; MUL(x, ONE) — identity test
        for (g_n = 0; g_n < 64; g_n = g_n + 1) begin
            a12_f = g_n[5:0];
            a12_x = {1'b0, 6'd32, a12_f};
            exec_op(a12_x, NFE_ONE, OP_MUL);
            log_csv(13, 2, g_n, 6'd32, a12_f, 3, result,
                    underflow_flag, exp_ovf_flag, rollover_flag, a12_x);
        end
        $display("  [HBS-12B] 192 rows logged.");

        // =================================================================
        // HBS-12C: NORMALIZATION STRESS TEST
        // ─────────────────────────────────────────────────────────────────
        // Focuses on 6 critical exponent bands:
        //   E=0  : minimum stored exponent (floor sentinel territory)
        //   E=1  : 1 above floor (SUB Guard-B may FTZ)
        //   E=31 : 1 below 1.0 point
        //   E=32 : 1.0 reference point
        //   E=62 : 1 below maximum
        //   E=63 : maximum stored exponent (overflow territory)
        //
        // For each: MUL(x,x), ADD(x, delta_max=63), SUB(x, delta_max=63).
        // SUB uses exec_sub which handles Guard-B pipeline automatically.
        // =================================================================
        $display("  [HBS-12C] Normalization Stress Test...");
        begin : C12_LOOP
            integer e_tbl [0:5];
            integer fi;
            integer f_tbl2 [0:2];
            e_tbl[0] = 0;
            e_tbl[1] = 1;
            e_tbl[2] = 31;
            e_tbl[3] = 32;
            e_tbl[4] = 62;
            e_tbl[5] = 63;
            f_tbl2[0] = 0;
            f_tbl2[1] = 31;
            f_tbl2[2] = 63;

            for (g_n = 0; g_n < 6; g_n = g_n + 1) begin
                for (fi = 0; fi < 3; fi = fi + 1) begin
                    a12_E = e_tbl[g_n][5:0];
                    a12_f = f_tbl2[fi][5:0];
                    a12_x = {1'b0, a12_E, a12_f};
                    // delta operand: op_b[5:0] = 63 (max fraction delta)
                    a12_delta = {1'b0, a12_E, 6'd63};

                    // Op 0: MUL(x, x)
                    exec_op(a12_x, a12_x, OP_MUL);
                    log_csv(14, g_n*3+fi, 0, a12_E, a12_f, 3, result,
                            underflow_flag, exp_ovf_flag, rollover_flag, 0);

                    // Op 1: ADD(x, delta_max) — delta = 63 maximum fraction
                    exec_op(a12_x, a12_delta, OP_ADD);
                    log_csv(14, g_n*3+fi, 1, a12_E, a12_f, 1, result,
                            underflow_flag, exp_ovf_flag, rollover_flag, 63);

                    // Op 2: SUB(x, delta_max) — Guard-B likely for f < 63
                    exec_sub(a12_x, a12_delta);
                    log_csv(14, g_n*3+fi, 2, a12_E, a12_f, 2, result,
                            underflow_flag, exp_ovf_flag, rollover_flag, 63);
                end
            end
        end
        $display("  [HBS-12C] 162 rows logged.");

        // =================================================================
        // HBS-12D: INFORMATION RETENTION TEST
        // ─────────────────────────────────────────────────────────────────
        // Chains CHAIN_Y = NFE_HALF (E=31, f=0) multiplications.
        // Each MUL subtracts 1 from E_stored (via exp_sum = E−1).
        // Starting seeds have E ∈ [28..35]; floor reached at depth ≈ E_seed.
        //
        // For each (depth, seed): log the final result after 'depth' MULs.
        // Python computes:
        //   unique_count(depth) — information entropy proxy
        //   floor_rate(depth)   — collapse fraction
        //
        // 32 seeds × 7 depths × 1 result/row = 224 rows.
        // =================================================================
        $display("  [HBS-12D] Information Retention Test...");
        lfsr_r = 16'hD00D;

        for (g_d = 0; g_d < 7; g_d = g_d + 1) begin
            floor_cnt   = 0;
            uf_cnt_d    = 0;
            lfsr_r      = 16'hD00D;   // Reset seed per depth pass for reproducibility

            for (g_s = 0; g_s < 32; g_s = g_s + 1) begin
                lfsr_r    = lfsr_step(lfsr_r);
                chain_st  = mk_seed(lfsr_r);
                uf_cnt_d  = 0;

                // Run chain of d12_depth_vals[g_d] MUL operations
                for (g_n = 0; g_n < d12_depth_vals[g_d]; g_n = g_n + 1) begin
                    exec_op(chain_st, CHAIN_Y, OP_MUL);
                    if (underflow_flag) uf_cnt_d = uf_cnt_d + 1;
                    chain_st = result;
                end

                if (chain_st == NFE_FLOOR) floor_cnt = floor_cnt + 1;

                // Log one summary row per (depth, seed)
                // subtest = depth index, cyc = seed index
                // stored_E and f_val from the FINAL state
                log_csv(15, g_d, g_s,
                        chain_st[11:6], chain_st[5:0],
                        3, chain_st,
                        (chain_st == NFE_FLOOR) ? 1 : 0,
                        0, 0, uf_cnt_d);
            end

            $display("    depth=%0d: floor=%0d/32  uf_ops=%0d",
                     d12_depth_vals[g_d], floor_cnt, uf_cnt_d);
        end
        $display("  [HBS-12D] 224 rows logged.");

        // =================================================================
        // HBS-12E: REGIME TRANSITION DETECTOR
        // ─────────────────────────────────────────────────────────────────
        // Systematically sweeps the (E, f) space to identify exact phase
        // boundaries.
        //
        // Pass 1: E=0..63, f=0 — MUL(x,x) vertical slice.
        //   Identifies UF/OVF transition E values.
        //
        // Pass 2: E=32, f=0..63 — MUL(x,x) horizontal slice.
        //   Shows how f affects result in the stable band.
        //
        // Pass 3: Cross-E MUL(x_low, x_high) — asymmetric pair test.
        //   x_low  = {0, E,    0}  E = 0..31
        //   x_high = {0, 63-E, 0}
        //   Probes the transition at exp_sum = E + (63-E) - 32 = 31 (constant).
        // =================================================================
        $display("  [HBS-12E] Regime Transition Detector...");

        // Pass 1: Vertical E sweep
        for (g_n = 0; g_n < 64; g_n = g_n + 1) begin
            a12_E = g_n[5:0];
            a12_x = {1'b0, a12_E, 6'd0};
            exec_op(a12_x, a12_x, OP_MUL);
            log_csv(16, 0, g_n, a12_E, 6'd0, 3, result,
                    underflow_flag, exp_ovf_flag, rollover_flag, 0);
        end

        // Pass 2: Horizontal f sweep (E=32 fixed)
        for (g_n = 0; g_n < 64; g_n = g_n + 1) begin
            a12_f = g_n[5:0];
            a12_x = {1'b0, 6'd32, a12_f};
            exec_op(a12_x, a12_x, OP_MUL);
            log_csv(16, 1, g_n, 6'd32, a12_f, 3, result,
                    underflow_flag, exp_ovf_flag, rollover_flag, 0);
        end

        // Pass 3: Asymmetric cross-E pairs — MUL(x_low, x_high)
        for (g_n = 0; g_n < 32; g_n = g_n + 1) begin
            a12_E  = g_n[5:0];
            a12_x  = {1'b0, a12_E, 6'd0};          // low operand
            a12_y  = {1'b0, 6'd63 - a12_E, 6'd0};  // high operand (complement)
            exec_op(a12_x, a12_y, OP_MUL);
            // extra = complement E
            log_csv(16, 2, g_n, a12_E, 6'd0, 3, result,
                    underflow_flag, exp_ovf_flag, rollover_flag, 63 - g_n);
        end
        $display("  [HBS-12E] 160 rows logged.");

        // =================================================================
        // HBS-12F: REVERSIBILITY TEST
        // ─────────────────────────────────────────────────────────────────
        // Test 1 — ADD → SUB round-trip (small delta, no rollover):
        //   ADD(x, delta) → x_add
        //   SUB(x_add, delta) → x_recovered
        //   Recovery error = |result_E - x.E| + |result_f - x.f|
        //   Expected: 0 when f + delta < 64 (no rollover, no Guard-B borrow).
        //
        // Test 2 — ADD → SUB with rollover (delta forces E increment):
        //   delta = 63, f = 63 → ADD causes rollover.
        //   Recovery via SUB(x_add, delta) traverses Guard-B pipeline.
        //   Expected: non-zero recovery error (information lost in rollover).
        //
        // Test 3 — MUL identity: MUL(x, NFE_ONE) = x
        //   Perfect identity preservation expected for all x.
        //   Any failure is a critical arithmetic bug.
        //
        // Operands: E ∈ {8,16,24,32,40,48,56}, f ∈ {0,31,63}.
        // =================================================================
        $display("  [HBS-12F] Reversibility Test...");
        begin : F12_LOOP
            integer e_tbl3 [0:6];
            integer fi;
            integer f_tbl3 [0:2];
            integer delta_val;
            reg [12:0] x_orig, x_add_result, x_recov;
            integer recov_err;

            e_tbl3[0] = 8;
            e_tbl3[1] = 16;
            e_tbl3[2] = 24;
            e_tbl3[3] = 32;
            e_tbl3[4] = 40;
            e_tbl3[5] = 48;
            e_tbl3[6] = 56;
            f_tbl3[0] = 0;
            f_tbl3[1] = 31;
            f_tbl3[2] = 63;

            for (g_n = 0; g_n < 7; g_n = g_n + 1) begin
                for (fi = 0; fi < 3; fi = fi + 1) begin
                    a12_E    = e_tbl3[g_n][5:0];
                    a12_f    = f_tbl3[fi][5:0];
                    a12_x    = {1'b0, a12_E, a12_f};

                    // ── Test 1: Small delta (≤ 63 - f_val → no rollover) ──
                    delta_val = 63 - a12_f;    // Maximum safe delta for no rollover
                    a12_delta = {1'b0, a12_E, delta_val[5:0]};

                    exec_op(a12_x, a12_delta, OP_ADD);
                    x_add_result = result;

                    // SUB(x_add_result, delta): m_a = f+delta, m_b = delta.
                    // f+delta < 64 (no rollover) → m_a = f+delta ≥ delta = m_b → Guard-A.
                    exec_sub(x_add_result, a12_delta);
                    x_recov    = result;
                    recov_err  = (x_recov == a12_x) ? 0 : 1;

                    log_csv(17, 0, g_n*3+fi, a12_E, a12_f, 1, x_recov,
                            underflow_flag, exp_ovf_flag, rollover_flag, recov_err);

                    // ── Test 2: Max delta (f=63, delta=63 → rollover) ──
                    if (a12_f == 6'd63) begin
                        a12_delta = {1'b0, a12_E, 6'd63};
                        exec_op(a12_x, a12_delta, OP_ADD);  // Rollover fires
                        x_add_result = result;

                        // Attempt recovery: SUB(x_add, delta=63). May be Guard-B.
                        exec_sub(x_add_result, a12_delta);
                        x_recov = result;
                        recov_err = (x_recov == a12_x) ? 0 : 1;

                        log_csv(17, 1, g_n*3+fi, a12_E, a12_f, 2, x_recov,
                                underflow_flag, exp_ovf_flag, rollover_flag, recov_err);
                    end

                    // ── Test 3: MUL identity MUL(x, ONE) == x ──
                    exec_op(a12_x, NFE_ONE, OP_MUL);
                    x_recov   = result;
                    recov_err = (x_recov == a12_x) ? 0 : 1;

                    log_csv(17, 2, g_n*3+fi, a12_E, a12_f, 3, x_recov,
                            underflow_flag, exp_ovf_flag, rollover_flag, recov_err);
                end
            end
        end
        $display("  [HBS-12F] ~147 rows logged.");

        $fclose(csv_fd);

        $display("");
        $display("  CSV  → HBS12_ARITHMETIC_BOUNDARY.csv");
        $display("  Next → python3 analyze_hbs12.py");
        $display("==============================================================");
        $finish;

    end // MAIN

endmodule

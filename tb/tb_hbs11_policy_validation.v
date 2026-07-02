`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_hbs11_policy_validation
// Project  : Horus Engine
// File     : tb/tb_hbs11_policy_validation.v
//
// Purpose  : HBS-11 Execution Policy Validation Suite.
//            Measures whether the four compute policy modes (000-011) and the
//            Depth-Monitor controller provide measurable improvement over the
//            Standard baseline.  No RTL is modified; all observations are
//            logged to HBS11_POLICY_VALIDATION.csv for Python analysis.
//
// DUTs:
//   horus_system     — primary MAC/accumulator target (modes 000-011)
//   horus_controller — Depth-Monitor observation (HBS-11D)
//
// Tests:
//   HBS-11A  (test_id=11) Cancellation Mitigation  mode 000 vs 001 (W01)
//   HBS-11B  (test_id=12) Floor Collapse Comparison mode 000 vs 010 (W03/W06)
//   HBS-11C  (test_id=13) Saturation Control        mode 000 vs 011 (W04)
//   HBS-11D  (test_id=14) Depth-Monitor Validation  max_depth 4/8/16/32/0
//   HBS-11E  (test_id=15) Mixed Policy Scheduler    static vs depth-aware
//
// CSV columns:
//   test_id, subtest, cycle, mode, op_a, op_b, result, accum_out,
//   uf, ovf, depth_reset, extra
// ============================================================================

module tb_hbs11_policy_validation;

    // =========================================================================
    // Constants
    // =========================================================================
    localparam CLK_HALF = 5;   // 10 ns → 100 MHz

    // NFE canonical codewords (Bias-32, v3)
    localparam [12:0] NFE_ONE    = 13'h800;  // 1.0  S=0 E=32 f=0
    localparam [12:0] NFE_HALF   = 13'h7C0;  // 0.5  S=0 E=31 f=0
    localparam [12:0] NFE_MAX    = 13'h1FFF; // Max S=0 E=63 f=63
    localparam [12:0] NFE_FLOOR  = 13'h000;  // Floor sentinel

    // Deep-chain Y: E_stored=28, actual_E=-4.  Each MUL(state,DEEP_Y) decrements
    // E_stored by 4.  Chain collapses to floor after 8 MUL operations.
    localparam [12:0] NFE_DEEP_Y = 13'h700;  // S=0 E=28 f=0

    // Compute Policy modes
    localparam [2:0] MODE_STD = 3'b000;
    localparam [2:0] MODE_BC  = 3'b001;
    localparam [2:0] MODE_PS  = 3'b010;
    localparam [2:0] MODE_SA  = 3'b011;

    // Operation selects
    localparam [1:0] OP_MUL = 2'b10;
    localparam [1:0] OP_NOP = 2'b11;

    // =========================================================================
    // DUT port signals
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

    // Controller DUT signals
    reg        ctrl_start, ctrl_ack;
    reg  [5:0] ctrl_max_depth;
    wire       ctrl_accum_clr, ctrl_accum_en, ctrl_depth_reset, ctrl_data_valid;

    // =========================================================================
    // Module-level utility variables (Verilog-2001: all declared here)
    // =========================================================================
    integer csv_fd;
    reg [15:0] lfsr_r;

    // Loop counters
    integer g_n;    // outer pair/chain loop
    integer g_d;    // chain depth loop
    integer g_m;    // mode loop (0=STD,1=alt)
    integer g_cy;   // cycle loop
    integer g_s;    // strategy loop (HBS-11E)
    integer g_dc;   // depth-config loop (HBS-11D)
    integer g_dw;   // window loop (HBS-11D)
    integer g_wi;   // wait-index (HBS-11D)

    // State variables
    reg [12:0] chain_st;   // running state for depth chain
    reg [12:0] y_pos;      // positive operand
    reg [12:0] y_neg;      // negated operand (sign bit flipped)
    reg [12:0] stim_a;     // general stimulus operand
    reg [2:0]  cur_mode;   // current mode selection
    integer    uf_cnt;     // underflow counter per chain
    integer    ovf_cnt;    // exp_ovf counter
    integer    floor_cnt;  // floor-result counter
    integer    dr_cnt;     // depth_reset count per window
    integer    dr_total;   // depth_reset total per config
    integer    sched_dep;  // scheduler depth counter (HBS-11E)
    reg        wait_done;  // termination flag for wait loops

    // HBS-11D max_depth config array
    reg [5:0]  md_vals [0:4];

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // DUT instantiations
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

    horus_controller u_ctrl (
        .clk           (clk),
        .rst_n         (rst_n),
        .start_compute (ctrl_start),
        .result_ack    (ctrl_ack),
        .max_depth     (ctrl_max_depth),
        .accum_clr     (ctrl_accum_clr),
        .accum_en      (ctrl_accum_en),
        .depth_reset   (ctrl_depth_reset),
        .data_valid    (ctrl_data_valid)
    );

    // =========================================================================
    // LFSR and codeword generator
    // =========================================================================
    function [15:0] lfsr_step;
        input [15:0] s;
        begin lfsr_step = {s[14:0], s[15] ^ s[13] ^ s[12] ^ s[10]}; end
    endfunction

    // Generate positive NFE codeword with E_stored in [24..39].
    // actual_E = E_stored - 32 ∈ [-8..+7].  MUL(ONE, y) = y.
    // Range avoids both deep underflow and saturation for single MUL chains.
    function [12:0] mk_nfe;
        input [15:0] s;
        reg [5:0] e;
        begin
            e = 6'd24 + {2'b0, s[9:6]};   // E in [24..39] (4-bit span from LFSR)
            mk_nfe = {1'b0, e, s[5:0]};
        end
    endfunction

    // =========================================================================
    // Tasks
    // =========================================================================

    // Full DUT reset
    task do_reset;
        begin
            rst_n           = 1'b0;
            op_a            = 13'd0;
            op_b            = 13'd0;
            op_sel          = OP_NOP;
            mode_tag        = MODE_STD;
            accum_en        = 1'b0;
            accum_clr       = 1'b0;
            host_tile_depth = 6'd63;   // 63-MAC tile budget
            ctrl_start      = 1'b0;
            ctrl_ack        = 1'b0;
            ctrl_max_depth  = 6'd0;
            repeat(5) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // Synchronous accumulator clear (also resets op_count_reg in horus_system)
    task do_clr;
        begin
            @(negedge clk); accum_clr = 1'b1;
            @(posedge clk); #1;
            accum_clr = 1'b0;
        end
    endtask

    // Execute one MAC cycle with accumulation enabled.
    // After return: result wire holds the registered output; accum_en=0.
    task exec_mac;
        input [12:0] a, b;
        input [1:0]  sel;
        input [2:0]  mode;
        begin
            @(negedge clk);
            op_a     = a;
            op_b     = b;
            op_sel   = sel;
            mode_tag = mode;
            accum_en = 1'b1;
            @(posedge clk); #1;
            accum_en = 1'b0;
        end
    endtask

    // NOP cycle: allows accum_out <= accum_reg to commit
    task nop_flush;
        begin
            @(negedge clk); op_sel = OP_NOP; accum_en = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // Log one CSV row.
    // Fields: test_id, subtest, cycle, mode, op_a, op_b, result, accum_out,
    //         uf, ovf, depth_reset, extra
    task log_csv;
        input integer tid, sub, cyc, mode_int;
        input [12:0] la, lb, lr;
        input [31:0] lacc;
        input integer luf, lovf, ldr, lextra;
        begin
            $fwrite(csv_fd,
                    "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    tid, sub, cyc, mode_int,
                    la, lb, lr, lacc,
                    luf, lovf, ldr, lextra);
        end
    endtask

    // =========================================================================
    // Watchdog
    // =========================================================================
    initial begin
        #2_000_000;  // 2 ms hard limit
        $display("*** WATCHDOG TIMEOUT — simulation exceeded 2 ms ***");
        $finish;
    end

    // =========================================================================
    // Main stimulus block
    // =========================================================================
    initial begin : MAIN

        $display("");
        $display("=============================================================");
        $display("  HBS-11: Execution Policy Validation Suite");
        $display("  Horus NFE v3.1  —  Policy Decoder + Depth-Monitor");
        $display("=============================================================");

        csv_fd = $fopen("HBS11_POLICY_VALIDATION.csv", "w");
        $fwrite(csv_fd,
                "test_id,subtest,cycle,mode,op_a,op_b,result,accum_out,uf,ovf,depth_reset,extra\n");

        do_reset;

        // =====================================================================
        // HBS-11A: CANCELLATION MITIGATION (W01)
        // ─────────────────────────────────────────────────────────────────────
        // Stimulus: MUL(NFE_ONE, y) then MUL(NFE_ONE, -y)  ×200 pairs
        // Modes: 000 (Standard) vs 001 (Bias-Corrected)
        // Metric: accum_out after both MACs = cancel-pair residual in accum_reg
        //         Expected: identical for both modes (BIAS_LUT=0 → no correction)
        // =====================================================================
        $display("  [HBS-11A] Cancellation Mitigation (200 pairs × 2 modes)...");
        lfsr_r = 16'hACE1;

        for (g_n = 0; g_n < 200; g_n = g_n + 1) begin
            lfsr_r = lfsr_step(lfsr_r);
            y_pos  = mk_nfe(lfsr_r);
            y_neg  = {1'b1, y_pos[11:0]};   // Negate: flip sign bit

            // Mode 000 — Standard
            do_clr;
            exec_mac(NFE_ONE, y_pos, OP_MUL, MODE_STD);
            log_csv(11, g_n, 0, 0, NFE_ONE, y_pos, result, accum_out,
                    underflow_flag, exp_ovf_flag, 1'b0, 0);
            exec_mac(NFE_ONE, y_neg, OP_MUL, MODE_STD);
            nop_flush;
            log_csv(11, g_n, 1, 0, NFE_ONE, y_neg, result, accum_out,
                    underflow_flag, exp_ovf_flag, 1'b0, 0);

            // Mode 001 — Bias-Corrected (BIAS_LUT=0 → same accumulation word)
            do_clr;
            exec_mac(NFE_ONE, y_pos, OP_MUL, MODE_BC);
            log_csv(11, g_n, 0, 1, NFE_ONE, y_pos, result, accum_out,
                    underflow_flag, exp_ovf_flag, 1'b0, 0);
            exec_mac(NFE_ONE, y_neg, OP_MUL, MODE_BC);
            nop_flush;
            log_csv(11, g_n, 1, 1, NFE_ONE, y_neg, result, accum_out,
                    underflow_flag, exp_ovf_flag, 1'b0, 0);
        end
        $display("  [HBS-11A] 800 rows logged.");

        // =====================================================================
        // HBS-11B: FLOOR COLLAPSE COMPARISON (W03/W06)
        // ─────────────────────────────────────────────────────────────────────
        // Stimulus: 30-deep MUL chain using NFE_DEEP_Y (E_stored=28).
        //   Each MUL decrements E by 4.  Floor reached at step 8 (E→0);
        //   underflow on step 9+ (E+28-32=-4 → exp_sum[7]=1).
        // Modes: 000 (Standard) vs 010 (Pre-Scaled)
        // Metrics: final chain_state, accum_out, uf_cnt per chain
        //   'uf' in the log = floor_reached (chain_state == NFE_FLOOR)
        //   extra = uf_cnt (underflow_flag pulses during chain)
        // =====================================================================
        $display("  [HBS-11B] Floor Collapse Comparison (100 chains × 2 modes)...");

        for (g_n = 0; g_n < 100; g_n = g_n + 1) begin
            for (g_m = 0; g_m < 2; g_m = g_m + 1) begin
                cur_mode = (g_m == 0) ? MODE_STD : MODE_PS;
                do_clr;
                chain_st = NFE_ONE;
                uf_cnt   = 0;

                for (g_d = 0; g_d < 30; g_d = g_d + 1) begin
                    exec_mac(chain_st, NFE_DEEP_Y, OP_MUL, cur_mode);
                    if (underflow_flag) uf_cnt = uf_cnt + 1;
                    chain_st = result;   // Feed output back as next input
                end
                nop_flush;

                // Log summary: one row per chain per mode
                log_csv(12, g_n, 29, g_m, NFE_ONE, NFE_DEEP_Y,
                        chain_st, accum_out,
                        (chain_st == NFE_FLOOR) ? 1 : 0,
                        0, 1'b0, uf_cnt);
            end
        end
        $display("  [HBS-11B] 200 rows logged.");

        // =====================================================================
        // HBS-11C: SATURATION CONTROL VALIDATION (W04)
        // ─────────────────────────────────────────────────────────────────────
        // Stimulus: 200-cycle mixed workload per mode:
        //   cycles   0–99 : Normal  — MUL(NFE_HALF, NFE_HALF) = 0.25 result
        //   cycles 100–149: Spike   — MUL(NFE_MAX,  NFE_MAX)  = OVF  result
        //   cycles 150–199: Noise   — MUL(rand_y, rand_y)
        // Modes: 000 (Standard) vs 011 (Safe-Accum)
        // Metric: exp_ovf_flag count (arithmetic saturation), accum_out growth
        //   extra = running OVF count
        // =====================================================================
        $display("  [HBS-11C] Saturation Control (200cy × 2 modes)...");
        lfsr_r = 16'hDEAD;

        for (g_m = 0; g_m < 2; g_m = g_m + 1) begin
            cur_mode = (g_m == 0) ? MODE_STD : MODE_SA;
            do_clr;
            ovf_cnt = 0;

            for (g_cy = 0; g_cy < 200; g_cy = g_cy + 1) begin
                // Select stimulus by phase
                if      (g_cy < 100) stim_a = NFE_HALF;
                else if (g_cy < 150) stim_a = NFE_MAX;
                else begin
                    lfsr_r = lfsr_step(lfsr_r);
                    stim_a = mk_nfe(lfsr_r);
                end

                exec_mac(stim_a, stim_a, OP_MUL, cur_mode);
                if (exp_ovf_flag) ovf_cnt = ovf_cnt + 1;
                nop_flush;
                log_csv(13, g_m, g_cy, g_m, stim_a, stim_a, result, accum_out,
                        underflow_flag, exp_ovf_flag, 1'b0, ovf_cnt);

                // Reset tile budget every 60 MACs so gate stays open
                if ((g_cy % 60) == 59) do_clr;
            end
        end
        $display("  [HBS-11C] 400 rows logged.");

        // =====================================================================
        // HBS-11D: DEPTH-MONITOR VALIDATION
        // ─────────────────────────────────────────────────────────────────────
        // Drive horus_controller through 10 FSM windows per max_depth config.
        // Observe ctrl_depth_reset pulses during each STREAM phase.
        //
        // Controller STREAM = 7 cycles (FILL_CYCLES=6, cycle_cnt 0–6).
        // Depth-Monitor fires when depth_counter == max_depth during STREAM.
        // depth_counter increments each STREAM cycle → fires for max_depth ≤ 6.
        //
        // Configs: 4, 8, 16, 32, 0(disabled).
        // 'mode' column encodes max_depth value; extra = cumulative dr_total.
        // =====================================================================
        $display("  [HBS-11D] Depth-Monitor (5 configs × 10 windows)...");

        md_vals[0] = 6'd4;
        md_vals[1] = 6'd8;
        md_vals[2] = 6'd16;
        md_vals[3] = 6'd32;
        md_vals[4] = 6'd0;

        for (g_dc = 0; g_dc < 5; g_dc = g_dc + 1) begin
            ctrl_max_depth = md_vals[g_dc];
            dr_total       = 0;

            for (g_dw = 0; g_dw < 10; g_dw = g_dw + 1) begin
                dr_cnt    = 0;
                wait_done = 1'b0;

                // Initiate one FSM window
                @(negedge clk); ctrl_start = 1'b1;
                @(negedge clk); ctrl_start = 1'b0;

                // Poll until data_valid; count depth_reset pulses
                g_wi = 0;
                while (!wait_done && g_wi < 25) begin
                    @(posedge clk); #1;
                    if (ctrl_depth_reset) dr_cnt = dr_cnt + 1;
                    if (ctrl_data_valid)  wait_done = 1'b1;
                    g_wi = g_wi + 1;
                end

                // Acknowledge
                @(negedge clk); ctrl_ack = 1'b1;
                @(negedge clk); ctrl_ack = 1'b0;
                dr_total = dr_total + dr_cnt;

                log_csv(14, g_dc, g_dw, md_vals[g_dc],
                        13'd0, 13'd0, 13'd0, 32'd0,
                        0, 0, dr_cnt, dr_total);
            end
            $display("    max_depth=%0d: %0d depth_reset pulses in 10 windows",
                     md_vals[g_dc], dr_total);
        end
        $display("  [HBS-11D] 50 rows logged.");

        // =====================================================================
        // HBS-11E: MIXED POLICY SCHEDULER TEST
        // ─────────────────────────────────────────────────────────────────────
        // Compares 5 dispatch strategies over 200 MUL(NFE_ONE, rand_y) ops.
        // Stimulus: rand_y in mid-range (no underflow, no overflow expected).
        // MUL(NFE_ONE, y) = y so result equals the operand — clean baseline.
        //
        //   Strategy 0: MODE_STD throughout
        //   Strategy 1: MODE_BC  throughout
        //   Strategy 2: MODE_PS  throughout
        //   Strategy 3: MODE_SA  throughout
        //   Strategy 4: Depth-aware scheduler
        //     depth 1–8   → MODE_STD
        //     depth 9–16  → MODE_BC
        //     depth 17–24 → MODE_PS
        //     depth ≥ 25  → manual depth_reset (do_clr) + MODE_STD
        //
        // Metric: uf_cnt, ovf_cnt, floor_cnt, accum_out per strategy.
        //   extra = scheduler depth counter (sched_dep) for strategy 4.
        // =====================================================================
        $display("  [HBS-11E] Mixed Policy Scheduler (5 strategies × 200 ops)...");

        for (g_s = 0; g_s < 5; g_s = g_s + 1) begin
            do_clr;
            uf_cnt    = 0;
            ovf_cnt   = 0;
            floor_cnt = 0;
            sched_dep = 0;
            lfsr_r    = 16'hF00D;  // Identical seed per strategy for fair comparison

            for (g_cy = 0; g_cy < 200; g_cy = g_cy + 1) begin
                lfsr_r = lfsr_step(lfsr_r);
                y_pos  = mk_nfe(lfsr_r);

                // Mode selection based on strategy
                case (g_s)
                    0: cur_mode = MODE_STD;
                    1: cur_mode = MODE_BC;
                    2: cur_mode = MODE_PS;
                    3: cur_mode = MODE_SA;
                    4: begin
                        sched_dep = sched_dep + 1;
                        if      (sched_dep <= 8)  cur_mode = MODE_STD;
                        else if (sched_dep <= 16) cur_mode = MODE_BC;
                        else if (sched_dep <= 24) cur_mode = MODE_PS;
                        else begin
                            do_clr;          // Depth-Monitor simulated reset
                            sched_dep = 0;
                            cur_mode  = MODE_STD;
                        end
                    end
                    default: cur_mode = MODE_STD;
                endcase

                exec_mac(NFE_ONE, y_pos, OP_MUL, cur_mode);
                if (underflow_flag)      uf_cnt    = uf_cnt + 1;
                if (exp_ovf_flag)        ovf_cnt   = ovf_cnt + 1;
                if (result == NFE_FLOOR) floor_cnt = floor_cnt + 1;
                nop_flush;

                log_csv(15, g_s, g_cy, g_s, NFE_ONE, y_pos, result, accum_out,
                        underflow_flag, exp_ovf_flag, 1'b0, sched_dep);

                // Reset tile budget every 60 MACs (strategies 0–3 only)
                if ((g_cy % 60) == 59 && g_s != 4) do_clr;
            end
            $display("    Strategy %0d: uf=%0d ovf=%0d floor=%0d",
                     g_s, uf_cnt, ovf_cnt, floor_cnt);
        end
        $display("  [HBS-11E] 1000 rows logged.");

        $fclose(csv_fd);

        $display("");
        $display("  CSV output  → HBS11_POLICY_VALIDATION.csv");
        $display("  Next step   → python3 analyze_hbs11.py");
        $display("=============================================================");
        $finish;

    end // MAIN

endmodule

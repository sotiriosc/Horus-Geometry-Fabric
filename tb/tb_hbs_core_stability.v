`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_hbs_core_stability
// Project  : Horus Engine — HBS Core Stability / Failure Mapping Suite
// File     : tb_hbs_core_stability.v
//
// Purpose
//   Observe-only numerical stability, failure modes, and representational
//   limits for Horus NFE v3 via horus_system (single PE tile).
//   DO NOT modify RTL. DO NOT fix behavior. Log and classify only.
//
// Global rules
//   DUT          : horus_system
//   host_tile_depth = 63 (gate open)
//   accum_en     = 1 for all MAC cycles
//   Per-cycle log + per-test SUMMARY appended to master index
//
// Run (from sim/):
//   make hbs_stability
// ============================================================================

module tb_hbs_core_stability;

    localparam CLK_PERIOD = 10;
    localparam CLK_HALF   = CLK_PERIOD / 2;

    localparam [12:0] NFE_ZERO  = 13'h000;
    localparam [12:0] NFE_HALF  = 13'h7C0;   // 0.5
    localparam [12:0] NFE_ONE   = 13'h800;   // 1.0
    localparam [12:0] NFE_TWO   = 13'h840;   // 2.0
    localparam [12:0] NFE_FOUR  = 13'h880;   // 4.0
    localparam [12:0] NFE_TINY  = 13'h582;
    localparam [12:0] NFE_SMALL = 13'h304;   // tiny MUL output class
    localparam [12:0] NFE_LARGE = 13'h9A4;   // large MUL output class
    localparam [12:0] NFE_SPIKE = 13'h8D0;   // ~10.0
    localparam [12:0] NFE_MAX   = 13'hFFF;

    localparam [1:0] OP_ADD = 2'b00;
    localparam [1:0] OP_SUB = 2'b01;
    localparam [1:0] OP_MUL = 2'b10;
    localparam [1:0] OP_NOP = 2'b11;

    reg         clk, rst_n;
    reg  [12:0] op_a, op_b;
    reg  [1:0]  op_sel;
    reg         accum_en, accum_clr;
    reg  [5:0]  host_tile_depth;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag;
    wire        underflow_flag;
    wire        exp_ovf_flag;
    wire [15:0] op_count;
    wire        accum_full;
    wire [31:0] pe_accum = dut.u_nfe.accum_reg;

    integer      g_cycle;
    integer      g_case;
    integer      log_fd;
    reg  [31:0]  lfsr;

    // Per-test anomaly counters
    integer uf_cnt, ovf_cnt, sat_cnt, floor_res_cnt, ghost_cnt, rollover_cnt;

    horus_system dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .op_a            (op_a),
        .op_b            (op_b),
        .op_sel          (op_sel),
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

    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    function [12:0] flip_sign;
        input [12:0] cw;
        begin flip_sign = cw ^ 13'h1000; end
    endfunction

    task reset_counters;
        begin
            uf_cnt = 0; ovf_cnt = 0; sat_cnt = 0;
            floor_res_cnt = 0; ghost_cnt = 0; rollover_cnt = 0;
        end
    endtask

    task classify_cycle;
        input expect_nonzero;
        begin
            if (underflow_flag)  uf_cnt       = uf_cnt + 1;
            if (exp_ovf_flag)    ovf_cnt      = ovf_cnt + 1;
            if (rollover_flag)   rollover_cnt = rollover_cnt + 1;
            if (result == NFE_MAX) sat_cnt = sat_cnt + 1;
            if (result == NFE_ZERO) begin
                floor_res_cnt = floor_res_cnt + 1;
                if (expect_nonzero && !underflow_flag)
                    ghost_cnt = ghost_cnt + 1;
            end
        end
    endtask

    task log_cycle;
        input [1:0]  sel;
        input [12:0] a, b;
        input        expect_nz;
        begin
            classify_cycle(expect_nz);
            case (sel)
                OP_ADD: $fwrite(log_fd,
                    "CYCL %4d CASE=%0d OP=ADD A=0x%04h B=0x%04h RESULT=0x%04h ACC=0x%08h PE_ACC=0x%08h ACC_OUT=0x%08h UF=%0d OVF=%0d ROL=%0d\n",
                    g_cycle, g_case, a, b, result, pe_accum, pe_accum, accum_out,
                    underflow_flag, exp_ovf_flag, rollover_flag);
                OP_SUB: $fwrite(log_fd,
                    "CYCL %4d CASE=%0d OP=SUB A=0x%04h B=0x%04h RESULT=0x%04h ACC=0x%08h PE_ACC=0x%08h ACC_OUT=0x%08h UF=%0d OVF=%0d ROL=%0d\n",
                    g_cycle, g_case, a, b, result, pe_accum, pe_accum, accum_out,
                    underflow_flag, exp_ovf_flag, rollover_flag);
                OP_MUL: $fwrite(log_fd,
                    "CYCL %4d CASE=%0d OP=MUL A=0x%04h B=0x%04h RESULT=0x%04h ACC=0x%08h PE_ACC=0x%08h ACC_OUT=0x%08h UF=%0d OVF=%0d ROL=%0d\n",
                    g_cycle, g_case, a, b, result, pe_accum, pe_accum, accum_out,
                    underflow_flag, exp_ovf_flag, rollover_flag);
                default: $fwrite(log_fd,
                    "CYCL %4d CASE=%0d OP=NOP A=0x%04h B=0x%04h RESULT=0x%04h ACC=0x%08h PE_ACC=0x%08h ACC_OUT=0x%08h UF=%0d OVF=%0d ROL=%0d\n",
                    g_cycle, g_case, a, b, result, pe_accum, pe_accum, accum_out,
                    underflow_flag, exp_ovf_flag, rollover_flag);
            endcase
            g_cycle = g_cycle + 1;
        end
    endtask

    task mac_op;
        input [12:0] a, b;
        input [1:0]  sel;
        input        expect_nz;
        begin
            @(negedge clk);
            op_a = a; op_b = b; op_sel = sel;
            accum_en = 1'b1; accum_clr = 1'b0;
            @(posedge clk); #1;
            if (sel == OP_SUB && (a[5:0] < b[5:0]) && (a[11:6] != 6'd0))
                @(posedge clk); #1;
            log_cycle(sel, a, b, expect_nz);
        end
    endtask

    task pulse_clr;
        begin
            @(negedge clk);
            op_a = NFE_ONE; op_b = NFE_ONE; op_sel = OP_NOP;
            accum_en = 1'b0; accum_clr = 1'b1;
            @(posedge clk); #1;
            accum_clr = 1'b0;
            g_cycle = g_cycle + 1;
        end
    endtask

    task write_summary;
        input [255:0] test_name;
        input [255:0] failure_modes;
        input [255:0] stability;
        input [255:0] collapse_pts;
        input [255:0] anomalies;
        input integer confidence;
        integer mfd;
        begin
            $fwrite(log_fd, "\nSUMMARY\n");
            $fwrite(log_fd, "test: %s\n", test_name);
            $fwrite(log_fd, "failure modes: %s\n", failure_modes);
            $fwrite(log_fd, "stability: %s\n", stability);
            $fwrite(log_fd, "collapse points: %s\n", collapse_pts);
            $fwrite(log_fd, "anomalies: %s\n", anomalies);
            $fwrite(log_fd, "uf_events=%0d ovf_events=%0d sat_results=%0d floor_results=%0d ghost_zero_like=%0d rollover=%0d\n",
                    uf_cnt, ovf_cnt, sat_cnt, floor_res_cnt, ghost_cnt, rollover_cnt);
            $fwrite(log_fd, "confidence rating (0-100 system stability): %0d\n", confidence);
            $fclose(log_fd);

            mfd = $fopen("HBS_CORE_MASTER_INDEX.log", "a");
            $fwrite(mfd, "=== %s ===\n", test_name);
            $fwrite(mfd, "failure modes: %s\n", failure_modes);
            $fwrite(mfd, "stability: %s\n", stability);
            $fwrite(mfd, "collapse points: %s\n", collapse_pts);
            $fwrite(mfd, "anomalies: %s\n", anomalies);
            $fwrite(mfd, "confidence: %0d/100  uf=%0d ovf=%0d ghost=%0d\n\n",
                    confidence, uf_cnt, ovf_cnt, ghost_cnt);
            $fclose(mfd);
        end
    endtask

    function integer clamp_conf;
        input integer raw;
        begin
            if (raw < 0)   clamp_conf = 0;
            else if (raw > 100) clamp_conf = 100;
            else clamp_conf = raw;
        end
    endfunction

    function [31:0] lfsr_step;
        input [31:0] s;
        begin lfsr_step = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]}; end
    endfunction

    // =========================================================================
    // TEST 1 — UNDERFLOW COLLAPSE BOUNDARY SCAN
    // =========================================================================
    task test01_underflow_scan;
        integer f, first_collapse, first_ghost;
        reg [12:0] cw, sq, after_floor;
        reg        saw_discontinuous;
        begin
            g_case = 1;
            reset_counters();
            first_collapse = -1;
            first_ghost    = -1;
            saw_discontinuous = 0;
            log_fd = $fopen("HBS_CORE_TEST_01_UNDERFLOW_SCAN.log", "w");
            $fwrite(log_fd, "HBS CORE TEST 01 — UNDERFLOW COLLAPSE BOUNDARY SCAN\n");
            $fwrite(log_fd, "DUT=horus_system host_tile_depth=63 accum_en=1\n\n");

            pulse_clr();

            for (f = 1; f <= 63; f = f + 1) begin
                cw = {1'b0, 6'd0, f[5:0]};
                mac_op(cw, cw, OP_MUL, 1'b1);
                sq = result;
                if (sq == NFE_ZERO && first_collapse < 0) first_collapse = f;

                mac_op(sq, NFE_ZERO, OP_MUL, 1'b0);
                after_floor = result;
                if (after_floor == NFE_ZERO && first_collapse < 0)
                    first_collapse = f;
                if (after_floor == NFE_ZERO && !underflow_flag && first_ghost < 0)
                    first_ghost = f;
                if (sq != NFE_ZERO && after_floor == NFE_ZERO && !underflow_flag)
                    saw_discontinuous = 1;
            end

            if (first_collapse >= 0)
                $fwrite(log_fd, "first_collapse_f=%0d first_ghost_f=%0d discontinuous=%0d\n",
                        first_collapse, first_ghost, saw_discontinuous);

            if (first_collapse < 0)
                write_summary("TEST_01_UNDERFLOW_SCAN",
                    "underflow floor at E=0 operands; post-multiply floor sentinel collapse",
                    "no full collapse in f=1..63 self-MUL scan",
                    "none in scan range",
                    "see ghost_zero_like counter",
                    clamp_conf(100 - uf_cnt*2 - ghost_cnt*15 - (saw_discontinuous ? 20 : 0)));
            else
                write_summary("TEST_01_UNDERFLOW_SCAN",
                    "underflow floor at E=0 operands; post-multiply floor sentinel collapse",
                    "collapse observed at boundary f",
                    "first collapse index logged above",
                    "see ghost_zero_like counter",
                    clamp_conf(100 - uf_cnt*2 - ghost_cnt*15 - (saw_discontinuous ? 20 : 0)));
        end
    endtask

    // =========================================================================
    // TEST 2 — EXPONENT CHAOS LOOP (DRIFT TEST) — 200 cycles
    // =========================================================================
    task test02_exponent_chaos;
        integer n;
        reg [12:0] state, prev;
        integer sat_streak, floor_streak, max_sat, max_floor;
        integer e_count, e_idx;
        reg [5:0] e;
        reg [5:0] unique_e [0:63];
        begin
            g_case = 2;
            reset_counters();
            sat_streak = 0; floor_streak = 0; max_sat = 0; max_floor = 0;
            e_count = 0;
            log_fd = $fopen("HBS_CORE_TEST_02_EXPONENT_CHAOS.log", "w");
            $fwrite(log_fd, "HBS CORE TEST 02 — EXPONENT CHAOS LOOP (200 cycles)\n\n");
            pulse_clr();
            state = NFE_ONE;

            for (n = 0; n < 200; n = n + 1) begin
                prev = state;
                if ((n & 1) == 0)
                    mac_op(NFE_ONE, NFE_HALF, OP_MUL, 1'b1);
                else begin
                    mac_op(state, NFE_ONE, OP_MUL, 1'b1);
                    state = result;
                end
                if (result == NFE_MAX) begin
                    sat_streak = sat_streak + 1;
                    if (sat_streak > max_sat) max_sat = sat_streak;
                end else sat_streak = 0;
                if (result == NFE_ZERO) begin
                    floor_streak = floor_streak + 1;
                    if (floor_streak > max_floor) max_floor = floor_streak;
                end else floor_streak = 0;

                e = result[11:6];
                e_idx = 0;
                while (e_idx < e_count && unique_e[e_idx] != e) e_idx = e_idx + 1;
                if (e_idx == e_count && e_count < 64) begin
                    unique_e[e_count] = e;
                    e_count = e_count + 1;
                end
            end

            $fwrite(log_fd, "max_sat_streak=%0d max_floor_streak=%0d unique_stored_E=%0d\n",
                    max_sat, max_floor, e_count);

            if (max_sat > 3)
                write_summary("TEST_02_EXPONENT_CHAOS",
                    "alternating scale MUL pressure; saturation and floor streaks",
                    "divergent saturation bursts detected",
                    "saturation streak dominates",
                    "wide exponent dispersion possible",
                    clamp_conf(100 - ovf_cnt*3 - uf_cnt*3 - max_sat*5));
            else if (max_floor > 3)
                write_summary("TEST_02_EXPONENT_CHAOS",
                    "alternating scale MUL pressure; saturation and floor streaks",
                    "floor lock-in detected",
                    "floor streak dominates",
                    "see unique_stored_E count",
                    clamp_conf(100 - ovf_cnt*3 - uf_cnt*3 - max_sat*5));
            else if (e_count > 20)
                write_summary("TEST_02_EXPONENT_CHAOS",
                    "alternating scale MUL pressure; saturation and floor streaks",
                    "exponent drift wide E dispersion",
                    "multiple stored_E bands",
                    "see cycle log",
                    clamp_conf(100 - ovf_cnt*3 - uf_cnt*3 - max_sat*5));
            else
                write_summary("TEST_02_EXPONENT_CHAOS",
                    "alternating scale MUL pressure; saturation and floor streaks",
                    "bounded oscillation or convergence",
                    "no long sat/floor lock-in",
                    "see unique_stored_E count",
                    clamp_conf(100 - ovf_cnt*3 - uf_cnt*3 - max_sat*5));
        end
    endtask

    // =========================================================================
    // TEST 3 — ACCUMULATOR BIAS DRIFT — 500 cycles
    // =========================================================================
    task test03_accum_bias;
        integer n, pick;
        reg [12:0] a, b;
        reg [31:0] acc_prev;
        integer non_monotonic, sat_hits;
        begin
            g_case = 3;
            reset_counters();
            non_monotonic = 0; sat_hits = 0;
            lfsr = 32'hC0FFEE01;
            log_fd = $fopen("HBS_CORE_TEST_03_ACCUM_BIAS.log", "w");
            $fwrite(log_fd, "HBS CORE TEST 03 — ACCUMULATOR BIAS DRIFT (500 cycles)\n\n");
            pulse_clr();
            acc_prev = pe_accum;

            for (n = 0; n < 500; n = n + 1) begin
                lfsr = lfsr_step(lfsr);
                pick = lfsr[7:0] % 100;
                if (pick < 70) begin a = NFE_SMALL; b = NFE_SMALL; end
                else begin a = NFE_LARGE; b = NFE_LARGE; end
                mac_op(a, b, OP_MUL, 1'b1);
                if (pe_accum < acc_prev) non_monotonic = non_monotonic + 1;
                acc_prev = pe_accum;
                if (result == NFE_MAX) sat_hits = sat_hits + 1;
            end

            $fwrite(log_fd, "non_monotonic_steps=%0d sat_hits=%0d\n", non_monotonic, sat_hits);

            if (non_monotonic > 0) begin
                if (sat_hits > 50)
                    write_summary("TEST_03_ACCUM_BIAS",
                        "long-horizon tiny large MUL mix integer codeword accumulation",
                        "non-monotonic pe_accum observed",
                        "overflow regime dominant",
                        "integer codeword sum not float partial sum",
                        clamp_conf(100 - (non_monotonic > 100 ? 25 : 0) - ovf_cnt - uf_cnt));
                else if (uf_cnt > 50)
                    write_summary("TEST_03_ACCUM_BIAS",
                        "long-horizon tiny large MUL mix integer codeword accumulation",
                        "non-monotonic pe_accum observed",
                        "floor regime dominant",
                        "integer codeword sum not float partial sum",
                        clamp_conf(100 - (non_monotonic > 100 ? 25 : 0) - ovf_cnt - uf_cnt));
                else
                    write_summary("TEST_03_ACCUM_BIAS",
                        "long-horizon tiny large MUL mix integer codeword accumulation",
                        "non-monotonic pe_accum observed",
                        "mixed growth band",
                        "see non_monotonic counter",
                        clamp_conf(100 - ovf_cnt - uf_cnt));
            end else begin
                if (sat_hits > 50)
                    write_summary("TEST_03_ACCUM_BIAS",
                        "long-horizon tiny large MUL mix integer codeword accumulation",
                        "monotonic pe_accum growth",
                        "overflow regime dominant",
                        "see non_monotonic counter",
                        clamp_conf(100 - ovf_cnt - uf_cnt));
                else if (uf_cnt > 50)
                    write_summary("TEST_03_ACCUM_BIAS",
                        "long-horizon tiny large MUL mix integer codeword accumulation",
                        "monotonic pe_accum growth",
                        "floor regime dominant",
                        "see non_monotonic counter",
                        clamp_conf(100 - ovf_cnt - uf_cnt));
                else
                    write_summary("TEST_03_ACCUM_BIAS",
                        "long-horizon tiny large MUL mix integer codeword accumulation",
                        "monotonic pe_accum growth",
                        "mixed growth band",
                        "see non_monotonic counter",
                        clamp_conf(100 - ovf_cnt - uf_cnt));
            end
        end
    endtask

    // =========================================================================
    // TEST 4 — ADVERSARIAL CANCELLATION
    // =========================================================================
    task test04_cancellation;
        integer k;
        reg [12:0] x, nx, y, p1, p2;
        reg [31:0] acc_before;
        begin
            g_case = 4;
            reset_counters();
            x  = NFE_ONE;
            nx = flip_sign(NFE_ONE);
            y  = NFE_HALF;
            log_fd = $fopen("HBS_CORE_TEST_04_CANCELLATION.log", "w");
            $fwrite(log_fd, "HBS CORE TEST 04 — ADVERSARIAL CANCELLATION\n\n");
            pulse_clr();

            // x + (-x) via paired MUL accumulation (symmetric product pairs)
            mac_op(x, y, OP_MUL, 1'b1);
            p1 = result;
            mac_op(nx, y, OP_MUL, 1'b1);
            p2 = result;

            // (x×y) accumulated with (nx×y) — codeword sum symmetry probe
            acc_before = pe_accum;
            mac_op(x, y, OP_MUL, 1'b1);
            mac_op(nx, y, OP_MUL, 1'b1);

            // ADD_FRAC delta cancellation: add then subtract same delta
            mac_op(NFE_ONE, 13'd32, OP_ADD, 1'b1);   // +32/64
            mac_op(NFE_ONE, 13'd32, OP_SUB, 1'b1);   // -32/64

            // Alternating sign chain depth 50
            for (k = 0; k < 50; k = k + 1) begin
                if ((k & 1) == 0)
                    mac_op(x, NFE_HALF, OP_MUL, 1'b1);
                else
                    mac_op(nx, NFE_HALF, OP_MUL, 1'b1);
            end

            $fwrite(log_fd, "pe_accum_final=0x%08h acc_before_pair=0x%08h p1=0x%04h p2=0x%04h\n",
                    pe_accum, acc_before, p1, p2);

            if (pe_accum == acc_before) begin
                if (p1 == flip_sign(p2))
                    write_summary("TEST_04_CANCELLATION",
                        "sign symmetry paired-product accumulation ADD SUB delta cancel",
                        "accum unchanged after symmetric pair codeword sum",
                        "MUL sign symmetry in codewords",
                        "ghost_zero_like counter in log",
                        clamp_conf(100 - ghost_cnt*20 - uf_cnt*2));
                else
                    write_summary("TEST_04_CANCELLATION",
                        "sign symmetry paired-product accumulation ADD SUB delta cancel",
                        "accum unchanged after symmetric pair codeword sum",
                        "MUL sign asymmetry in codewords",
                        "ghost_zero_like counter in log",
                        clamp_conf(100 - ghost_cnt*20 - uf_cnt*2));
            end else begin
                if (p1 == flip_sign(p2))
                    write_summary("TEST_04_CANCELLATION",
                        "sign symmetry paired-product accumulation ADD SUB delta cancel",
                        "quantization broke cancellation symmetry in pe_accum",
                        "MUL sign symmetry in codewords",
                        "ghost_zero_like counter in log",
                        clamp_conf(100 - ghost_cnt*20 - uf_cnt*2));
                else
                    write_summary("TEST_04_CANCELLATION",
                        "sign symmetry paired-product accumulation ADD SUB delta cancel",
                        "quantization broke cancellation symmetry in pe_accum",
                        "MUL sign asymmetry in codewords",
                        "ghost_zero_like counter in log",
                        clamp_conf(100 - ghost_cnt*20 - uf_cnt*2));
            end
        end
    endtask

    // =========================================================================
    // TEST 5 — DISTRIBUTION SHIFT SHOCK — 300 cycles
    // =========================================================================
    task test05_distribution_shock;
        integer n, phase;
        reg [12:0] a, b;
        integer sat_dom, floor_dom, recover;
        begin
            g_case = 5;
            reset_counters();
            sat_dom = 0; floor_dom = 0; recover = 0;
            lfsr = 32'hBADA5500;
            log_fd = $fopen("HBS_CORE_TEST_05_DISTRIBUTION_SHOCK.log", "w");
            $fwrite(log_fd, "HBS CORE TEST 05 — DISTRIBUTION SHIFT SHOCK (300 cycles)\n\n");
            pulse_clr();

            for (n = 0; n < 300; n = n + 1) begin
                phase = n / 100;
                lfsr = lfsr_step(lfsr);
                case (phase)
                    0: begin // Group A normal
                        case (n % 4)
                            0: a = NFE_HALF;
                            1: a = NFE_ONE;
                            2: a = NFE_TWO;
                            default: a = NFE_FOUR;
                        endcase
                        b = a;
                    end
                    1: begin // Group B spike
                        case (n % 3)
                            0: a = NFE_SPIKE;
                            1: a = NFE_MAX;
                            default: a = NFE_LARGE;
                        endcase
                        b = a;
                    end
                    default: begin // Group C noise
                        a = {lfsr[12], 6'd32, lfsr[5:0]};
                        b = {lfsr[28], 6'd32, lfsr[11:6]};
                    end
                endcase
                mac_op(a, b, OP_MUL, 1'b1);
                if (result == NFE_MAX)   sat_dom = sat_dom + 1;
                if (result == NFE_ZERO) floor_dom = floor_dom + 1;
                if (phase == 2 && result != NFE_MAX && result != NFE_ZERO)
                    recover = recover + 1;
            end

            $fwrite(log_fd, "sat_dom=%0d floor_dom=%0d recover_noise=%0d\n", sat_dom, floor_dom, recover);

            if (sat_dom > floor_dom && sat_dom > 30)
                write_summary("TEST_05_DISTRIBUTION_SHOCK",
                    "regime shift normal spike noise; saturation vs floor dominance",
                    "saturation-dominated under spikes",
                    "spike group drives OVF band",
                    "see recover_noise counter",
                    clamp_conf(100 - sat_dom/5 - floor_dom/5));
            else if (floor_dom > sat_dom && floor_dom > 30)
                write_summary("TEST_05_DISTRIBUTION_SHOCK",
                    "regime shift normal spike noise; saturation vs floor dominance",
                    "floor-dominated",
                    "underflow band dominates",
                    "see recover_noise counter",
                    clamp_conf(100 - sat_dom/5 - floor_dom/5));
            else
                write_summary("TEST_05_DISTRIBUTION_SHOCK",
                    "regime shift normal spike noise; saturation vs floor dominance",
                    "mixed regime",
                    "balanced sat/floor",
                    "see recover_noise counter",
                    clamp_conf(100 - sat_dom/5 - floor_dom/5));
        end
    endtask

    // =========================================================================
    // TEST 6 — GHOST ZERO REPRODUCIBILITY
    // =========================================================================
    task test06_ghost_zero;
        integer n;
        reg [12:0] small_a, small_b;
        integer silent_zero, flagged_zero;
        begin
            g_case = 6;
            reset_counters();
            silent_zero = 0; flagged_zero = 0;
            small_a = NFE_TINY;
            small_b = NFE_TINY;
            log_fd = $fopen("HBS_CORE_TEST_06_GHOST_ZERO.log", "w");
            $fwrite(log_fd, "HBS CORE TEST 06 — GHOST ZERO REPRODUCIBILITY (100 cycles)\n\n");
            pulse_clr();

            for (n = 0; n < 100; n = n + 1) begin
                mac_op(small_a, small_b, OP_MUL, 1'b1);
                if (result == NFE_ZERO) begin
                    if (underflow_flag) flagged_zero = flagged_zero + 1;
                    else silent_zero = silent_zero + 1;
                end
                small_a = (result == NFE_ZERO) ? NFE_TINY : result;
                small_b = NFE_TINY;
                if ((n & 3) == 3)
                    mac_op(result, NFE_ZERO, OP_MUL, 1'b0);
            end

            $fwrite(log_fd, "silent_zero=%0d flagged_zero=%0d\n", silent_zero, flagged_zero);

            if (silent_zero > 0)
                write_summary("TEST_06_GHOST_ZERO",
                    "SILENT zero collapse detected Ghost Zero-like",
                    "silent collapse present under adversarial MUL chain",
                    "see silent_zero counter",
                    "ghost_zero_like total in summary counters",
                    clamp_conf(100 - silent_zero*25 - ghost_cnt*10));
            else
                write_summary("TEST_06_GHOST_ZERO",
                    "no silent zero collapses flagged or absent",
                    "v3 MUL stable flagged or non-zero propagation",
                    "see flagged_zero counter",
                    "ghost_zero_like total in summary counters",
                    clamp_conf(100 - silent_zero*25 - ghost_cnt*10));
        end
    endtask

    // =========================================================================
    initial begin
        integer master_fd;
        rst_n = 0; accum_en = 0; accum_clr = 0;
        host_tile_depth = 6'd63;
        op_a = 0; op_b = 0; op_sel = OP_NOP;
        g_cycle = 0; lfsr = 32'h1;

        master_fd = $fopen("HBS_CORE_MASTER_INDEX.log", "w");
        $fwrite(master_fd, "HBS CORE STABILITY SUITE — MASTER INDEX\n");
        $fwrite(master_fd, "Horus NFE v3 | horus_system | host_tile_depth=63\n");
        $fwrite(master_fd, "FAILURE MAPPING — observe only, no RTL modification\n\n");
        $fclose(master_fd);

        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1;

        $display("============================================================");
        $display("  HBS CORE STABILITY SUITE — failure mapping (observe only)");
        $display("============================================================");

        test01_underflow_scan();
        $display("  TEST 01 complete → HBS_CORE_TEST_01_UNDERFLOW_SCAN.log");

        test02_exponent_chaos();
        $display("  TEST 02 complete → HBS_CORE_TEST_02_EXPONENT_CHAOS.log");

        test03_accum_bias();
        $display("  TEST 03 complete → HBS_CORE_TEST_03_ACCUM_BIAS.log");

        test04_cancellation();
        $display("  TEST 04 complete → HBS_CORE_TEST_04_CANCELLATION.log");

        test05_distribution_shock();
        $display("  TEST 05 complete → HBS_CORE_TEST_05_DISTRIBUTION_SHOCK.log");

        test06_ghost_zero();
        $display("  TEST 06 complete → HBS_CORE_TEST_06_GHOST_ZERO.log");

        $display("============================================================");
        $display("  ALL TESTS COMPLETE — see HBS_CORE_MASTER_INDEX.log");
        $display("============================================================");
        $finish;
    end

endmodule

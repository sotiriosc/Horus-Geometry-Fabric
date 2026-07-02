`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c2_live_sim
// Project  : HORUS v3 Live System Observation Harness (HBS-C2)
// File     : tb_hbs_c2_live_sim.v
//
// Purpose:
//   Continuous stimulus generator and per-cycle tracer for horus_system.
//   Three interleaved streams drive the DUT every clock cycle.
//   All signals logged to HBS_C2_LIVE_SIM.csv for Python analysis.
//
// NO RTL CHANGES. NO POLICY MODIFICATIONS. NO NEW LOGIC IN DUT.
// This is a probe harness only. Observations only.
//
// Streams (round-robin, one stream per cycle):
//   STREAM_A : Stable-band MAC operations, target product E = 20..40
//   STREAM_B : Boundary oscillation, target product E = 12..18 and 44..50
//   STREAM_C : Deep composition chain, E=32 seed + HALF-scaling + depth gate
//
// CSV columns:
//   cycle, stream, A, B, OP, E_est, MODE, RESULT, ACC, PE_ACC,
//   UF, OVF, RO, REGION
//
// Timing:
//   Inputs applied at negedge clk.
//   Outputs (result, accum_out, flags) sampled at next posedge clk (#1 guard).
//   result and accum_out are registered outputs of horus_nfe (1-cycle latency).
// ============================================================================

module tb_hbs_c2_live_sim;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam TOTAL_CYCLES = 6000;     // 2000 cycles per stream
    localparam CLK_HALF     = 5;        // 10 ns clock period

    // NFE codeword constants (13-bit: {sign[12], E[11:6], f[5:0]})
    localparam [12:0] NFE_ONE   = 13'h0800;  // E=32, f=0  → 1.0
    localparam [12:0] NFE_HALF  = 13'h07C0;  // E=31, f=0  → 0.5
    localparam [12:0] NFE_TWO   = 13'h0840;  // E=33, f=0  → 2.0
    localparam [12:0] NFE_FLOOR = 13'h0000;  // floor sentinel

    // op_sel encoding (matches horus_system)
    localparam [1:0] OP_ADD = 2'b00;
    localparam [1:0] OP_SUB = 2'b01;
    localparam [1:0] OP_MUL = 2'b10;
    localparam [1:0] OP_NOP = 2'b11;

    // mode_tag encoding
    localparam [2:0] MODE_STD  = 3'b000;
    localparam [2:0] MODE_BIAS = 3'b001;
    localparam [2:0] MODE_PRSC = 3'b010;
    localparam [2:0] MODE_SAFE = 3'b011;

    // =========================================================================
    // DUT interface
    // =========================================================================
    reg  clk, rst_n;
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

    horus_system dut (
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
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_HALF) clk = ~clk;

    // =========================================================================
    // Watchdog
    // =========================================================================
    initial begin : WATCHDOG
        #(CLK_HALF * 2 * (TOTAL_CYCLES + 200) * 10);
        $display("*** HBS-C2 WATCHDOG FIRED ***");
        $finish;
    end

    // =========================================================================
    // Region classification function
    // =========================================================================
    function [1:0] region_of;
        input [5:0] e;
        begin
            if      (e <= 6'd15)                   region_of = 2'd0; // COLLAPSE
            else if (e <= 6'd19)                   region_of = 2'd1; // TRANSITION
            else if (e <= 6'd43)                   region_of = 2'd2; // STABLE
            else if (e <= 6'd47)                   region_of = 2'd1; // TRANSITION
            else                                   region_of = 2'd3; // SATURATE
        end
    endfunction

    // =========================================================================
    // Internal harness state
    // =========================================================================
    integer fd;
    integer cyc;
    reg [31:0] prev_accum;
    reg [15:0] lfsr;           // 16-bit Fibonacci LFSR (taps 16,14,13,11)
    reg [5:0]  e_est;
    reg [1:0]  region;

    // STREAM_A state
    integer    sa_idx;         // 0..7 cycling index
    reg [5:0]  sa_E_b [0:7];  // target product exponent via E_b (E_a=32)
    reg [5:0]  sa_F_b [0:7];  // fraction for op_b
    integer    sa_op_phase;    // 0..5: drives MUL×4, ADD×1, SUB×1

    // STREAM_B state
    integer    sb_phase;       // 0=collapse side  1=saturation side
    integer    sb_phase_ctr;   // counter within phase (0..15 → switch)
    integer    sb_idx;         // 0..7 cycling index within phase
    reg [5:0]  sb_E_collapse [0:7]; // target E_b for collapse oscillation
    reg [5:0]  sb_E_saturate [0:7]; // target E_b for saturation oscillation
    integer    sb_mode_idx;    // cycles modes 000→010→011

    // STREAM_C state
    reg [12:0] sc_x;           // current evolving operand
    integer    sc_depth;       // depth counter within epoch
    integer    sc_epoch;       // epoch counter (resets when UF fires or depth=24)

    // =========================================================================
    // LFSR advance task
    // =========================================================================
    task lfsr_step;
        begin
            lfsr = {lfsr[14:0],
                    lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        end
    endtask

    // =========================================================================
    // Reset task
    // =========================================================================
    task do_reset;
        begin
            rst_n          = 1'b0;
            op_a           = NFE_ONE;
            op_b           = NFE_ONE;
            op_sel         = OP_NOP;
            mode_tag       = MODE_STD;
            accum_en       = 1'b0;
            accum_clr      = 1'b0;
            host_tile_depth = 6'd63;
            repeat (5) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            @(posedge clk); #1;
            @(negedge clk); accum_clr = 1'b1; op_sel = OP_NOP;
            @(posedge clk); #1;
            @(negedge clk); accum_clr = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // =========================================================================
    // Main stimulus loop
    // =========================================================================
    initial begin : MAIN

        $display("");
        $display("=================================================================");
        $display("  HBS-C2: HORUS v3 Live System Observation Harness");
        $display("  Streams: A=stable MAC  B=boundary oscillation  C=deep chain");
        $display("  Cycles: %0d  (2000 per stream, round-robin)", TOTAL_CYCLES);
        $display("=================================================================");

        // ── Initialize STREAM_A tables ─────────────────────────────────────
        // op_a always has E=32 (NFE_ONE-family). op_b E determines product E.
        // Target product E values: 20, 24, 28, 32, 36, 40, 36, 28
        sa_E_b[0] = 6'd20; sa_F_b[0] = 6'd0;
        sa_E_b[1] = 6'd24; sa_F_b[1] = 6'd16;
        sa_E_b[2] = 6'd28; sa_F_b[2] = 6'd31;
        sa_E_b[3] = 6'd32; sa_F_b[3] = 6'd0;
        sa_E_b[4] = 6'd36; sa_F_b[4] = 6'd16;
        sa_E_b[5] = 6'd40; sa_F_b[5] = 6'd31;
        sa_E_b[6] = 6'd36; sa_F_b[6] = 6'd48;
        sa_E_b[7] = 6'd28; sa_F_b[7] = 6'd63;

        // ── Initialize STREAM_B tables ─────────────────────────────────────
        // Collapse side: MUL(E_a=32, E_b below) → product E oscillates 12..17
        sb_E_collapse[0] = 6'd12; sb_E_saturate[0] = 6'd44;
        sb_E_collapse[1] = 6'd13; sb_E_saturate[1] = 6'd45;
        sb_E_collapse[2] = 6'd14; sb_E_saturate[2] = 6'd46;
        sb_E_collapse[3] = 6'd15; sb_E_saturate[3] = 6'd47;
        sb_E_collapse[4] = 6'd16; sb_E_saturate[4] = 6'd48;
        sb_E_collapse[5] = 6'd17; sb_E_saturate[5] = 6'd49;
        sb_E_collapse[6] = 6'd15; sb_E_saturate[6] = 6'd47;
        sb_E_collapse[7] = 6'd14; sb_E_saturate[7] = 6'd46;

        // ── Open CSV ──────────────────────────────────────────────────────
        fd = $fopen("HBS_C2_LIVE_SIM.csv", "w");
        $fwrite(fd, "cycle,stream,A,B,OP,E_est,MODE,RESULT,ACC,PE_ACC,UF,OVF,RO,REGION\n");

        // ── Initialize harness state ───────────────────────────────────────
        prev_accum   = 32'd0;
        lfsr         = 16'hBEEF;
        sa_idx       = 0;
        sa_op_phase  = 0;
        sb_phase     = 0;
        sb_phase_ctr = 0;
        sb_idx       = 0;
        sb_mode_idx  = 0;
        sc_x         = NFE_ONE;
        sc_depth     = 0;
        sc_epoch     = 0;

        do_reset;

        // ==================================================================
        // MAIN CYCLE LOOP
        // ==================================================================
        for (cyc = 0; cyc < TOTAL_CYCLES; cyc = cyc + 1) begin

            // ── Advance LFSR ───────────────────────────────────────────────
            lfsr_step;

            // ── Select stream and generate stimulus ────────────────────────
            case (cyc % 3)

                // ──────────────────────────────────────────────────────────
                // STREAM_A: Stable-band MAC operations (target E = 20..40)
                // ──────────────────────────────────────────────────────────
                0: begin
                    // op_a: E=32 with LFSR fraction (stable anchor)
                    op_a = {1'b0, 6'd32, lfsr[5:0]};
                    // op_b: cycling E target with table fraction
                    op_b = {1'b0, sa_E_b[sa_idx], sa_F_b[sa_idx]};

                    // op_sel: MUL×4 ADD×1 SUB×1 per 6-phase cycle
                    case (sa_op_phase)
                        0,1,2,3: op_sel = OP_MUL;
                        4:       op_sel = OP_ADD;
                        5:       op_sel = OP_SUB;
                        default: op_sel = OP_MUL;
                    endcase

                    mode_tag        = MODE_STD;
                    accum_en        = 1'b1;
                    accum_clr       = 1'b0;
                    host_tile_depth = 6'd32;
                end

                // ──────────────────────────────────────────────────────────
                // STREAM_B: Boundary oscillation (E = 12..18 and 44..50)
                // ──────────────────────────────────────────────────────────
                1: begin
                    // op_a: E=32 anchor, LFSR fraction variation
                    op_a = {1'b0, 6'd32, lfsr[11:6]};

                    // op_b: drives product E into boundary zones
                    if (sb_phase == 0) begin
                        // Collapse side: product E = sb_E_collapse[sb_idx]
                        op_b = {1'b0, sb_E_collapse[sb_idx], lfsr[5:0]};
                    end else begin
                        // Saturation side: product E = sb_E_saturate[sb_idx]
                        op_b = {1'b0, sb_E_saturate[sb_idx], lfsr[5:0]};
                    end

                    op_sel = OP_MUL;  // MUL for controlled E targeting

                    // mode_tag cycles 000→010→011→000...
                    case (sb_mode_idx % 3)
                        0: mode_tag = MODE_STD;
                        1: mode_tag = MODE_PRSC;
                        2: mode_tag = MODE_SAFE;
                        default: mode_tag = MODE_STD;
                    endcase

                    accum_en        = 1'b0;  // observe only; no accumulation in boundary zone
                    accum_clr       = 1'b0;
                    host_tile_depth = 6'd63;
                end

                // ──────────────────────────────────────────────────────────
                // STREAM_C: Deep composition chain
                //   E=32 seed, HALF-scaling, depth 0..23, epoch tracking
                // ──────────────────────────────────────────────────────────
                default: begin
                    op_a = sc_x;

                    // Sub-operation schedule within epoch (8-step period):
                    // 0,1,2,4,5,6: MUL(sc_x, HALF) — descend E
                    // 3:           ADD(sc_x, sc_x)  — self-add (Thoth rollover probe)
                    // 7:           MUL(sc_x, NFE_TWO) — one recovery step
                    case (sc_depth % 8)
                        3: begin
                            op_b   = sc_x;
                            op_sel = OP_ADD;
                        end
                        7: begin
                            op_b   = NFE_TWO;
                            op_sel = OP_MUL;
                        end
                        default: begin
                            op_b   = NFE_HALF;
                            op_sel = OP_MUL;
                        end
                    endcase

                    // mode escalates with depth
                    if (sc_depth <= 8)
                        mode_tag = MODE_STD;
                    else
                        mode_tag = MODE_PRSC;

                    // Accumulate only in stable-depth phase
                    accum_en  = (sc_depth <= 16) ? 1'b1 : 1'b0;
                    accum_clr = 1'b0;
                    host_tile_depth = 6'd16;
                end

            endcase

            // ── Apply inputs at negedge, capture outputs at next posedge ──
            @(negedge clk);
            // (inputs driven combinatorially above; Verilog evaluates in initial)

            @(posedge clk); #1;

            // ── Derive E_est and region from registered result ─────────────
            if (underflow_flag)
                e_est = 6'd0;
            else if (exp_ovf_flag)
                e_est = 6'd63;
            else
                e_est = result[11:6];

            region = region_of(e_est);

            // ── Write CSV row ──────────────────────────────────────────────
            $fwrite(fd, "%0d,", cyc);

            // stream label
            case (cyc % 3)
                0: $fwrite(fd, "A,");
                1: $fwrite(fd, "B,");
                2: $fwrite(fd, "C,");
            endcase

            $fwrite(fd, "%04x,%04x,", op_a, op_b);

            // OP string
            case (op_sel)
                OP_ADD: $fwrite(fd, "ADD,");
                OP_SUB: $fwrite(fd, "SUB,");
                OP_MUL: $fwrite(fd, "MUL,");
                OP_NOP: $fwrite(fd, "NOP,");
            endcase

            $fwrite(fd, "%0d,%0d,", e_est, mode_tag);
            $fwrite(fd, "%04x,%08x,%08x,", result, accum_out, prev_accum);
            $fwrite(fd, "%0d,%0d,%0d,", underflow_flag, exp_ovf_flag, rollover_flag);

            // REGION string
            case (region)
                2'd0: $fwrite(fd, "COLLAPSE\n");
                2'd1: $fwrite(fd, "TRANSITION\n");
                2'd2: $fwrite(fd, "STABLE\n");
                2'd3: $fwrite(fd, "SATURATE\n");
            endcase

            // ── Console events (boundary crossings, UF/OVF) ───────────────
            if (underflow_flag)
                $display("[C2] CYCLE %0d  STREAM %0s  UF FIRED   result=%04x  E_est=%0d",
                         cyc, (cyc%3==0) ? "A" : (cyc%3==1) ? "B" : "C",
                         result, e_est);
            if (exp_ovf_flag)
                $display("[C2] CYCLE %0d  STREAM %0s  OVF FIRED  result=%04x  E_est=%0d",
                         cyc, (cyc%3==0) ? "A" : (cyc%3==1) ? "B" : "C",
                         result, e_est);

            // ── Update PE_ACC for next cycle ───────────────────────────────
            prev_accum = accum_out;

            // ── Advance stream state ───────────────────────────────────────

            // STREAM_A: advance index and phase
            if (cyc % 3 == 0) begin
                sa_idx      = (sa_idx + 1) % 8;
                sa_op_phase = (sa_op_phase + 1) % 6;
            end

            // STREAM_B: advance phase and mode cycling
            if (cyc % 3 == 1) begin
                sb_idx       = (sb_idx + 1) % 8;
                sb_phase_ctr = sb_phase_ctr + 1;
                if (sb_phase_ctr >= 16) begin
                    sb_phase     = 1 - sb_phase;  // toggle collapse/saturation
                    sb_phase_ctr = 0;
                end
                sb_mode_idx = sb_mode_idx + 1;
            end

            // STREAM_C: advance depth, capture result, handle epoch resets
            if (cyc % 3 == 2) begin
                sc_x    = result;   // feed result forward into next epoch step
                sc_depth = sc_depth + 1;

                // Reset epoch on UF or depth limit
                if (underflow_flag || sc_depth >= 24) begin
                    sc_x    = NFE_ONE;
                    sc_depth = 0;
                    sc_epoch = sc_epoch + 1;
                    // Pulse accum_clr to reset accumulator for fresh window
                    @(negedge clk);
                    accum_clr = 1'b1; op_sel = OP_NOP;
                    accum_en  = 1'b0;
                    @(posedge clk); #1;
                    @(negedge clk); accum_clr = 1'b0;
                    @(posedge clk); #1;
                end
            end

        end // for cyc

        // ==================================================================
        // Epilogue
        // ==================================================================
        $fclose(fd);

        $display("");
        $display("=================================================================");
        $display("  HBS-C2 COMPLETE: %0d cycles logged.", TOTAL_CYCLES);
        $display("  Output: HBS_C2_LIVE_SIM.csv");
        $display("  Run:    python3 analyze_hbs_c2_live.py");
        $display("=================================================================");
        $display("");
        $finish;

    end // initial MAIN

endmodule

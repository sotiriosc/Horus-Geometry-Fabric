`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c10_predictive_validation
// Project  : HORUS v3 — HBS-C10: Predictive Validation
// File     : tb_hbs_c10_predictive_validation.v
//
// Purpose:
//   Test whether the C8 four-attractor model can predict future system behavior.
//   20 algorithmically-generated unseen workloads are run against the real
//   horus_system RTL. The Python analysis script generates predictions BEFORE
//   loading this simulation CSV. The mismatch between prediction and measurement
//   determines whether the model is SUFFICIENT, INCOMPLETE, or OVERCOMPLETE.
//
// Workload families (5 per attractor + 5 complex):
//   A1-family: WL00-WL03,WL10  (cancellation / SUB-dominant)
//   A2-family: WL02-WL05,WL08  (exponent drift / MUL-chain)
//   A3-family: WL04,WL05,WL09,WL19 (boundary oscillation / ADD at E=15/47)
//   A4-family: WL06,WL12,WL16  (mixed injection / entropy)
//   Novel:     WL11,WL13-WL15,WL17,WL18 (cross-attractor / complex)
//
// Each workload: 300 stress cycles + 50 recovery = 350 cycles
// Total: 20 × 350 = 7,000 cycles
//
// horus_system interface (exact):
//   op_sel: 00=ADD 01=SUB 10=MUL 11=NOP
//   accum_out: 32-bit
// ============================================================================

module tb_hbs_c10_predictive_validation;

    parameter NUM_WL          = 20;
    parameter STRESS_CYCLES   = 300;
    parameter RECOVERY_CYCLES =  50;
    parameter CYCLES_PER_WL   = STRESS_CYCLES + RECOVERY_CYCLES;  // 350
    parameter TOTAL_CYCLES    = NUM_WL * CYCLES_PER_WL;            // 7000
    parameter EPOCH_DEPTH     = 16;

    // =========================================================================
    // DUT
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

    horus_system dut (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a), .op_b(op_b), .op_sel(op_sel), .mode_tag(mode_tag),
        .accum_en(accum_en), .accum_clr(accum_clr),
        .host_tile_depth(host_tile_depth),
        .result(result), .accum_out(accum_out),
        .rollover_flag(rollover_flag), .underflow_flag(underflow_flag),
        .exp_ovf_flag(exp_ovf_flag), .op_count(op_count), .accum_full(accum_full)
    );

    // =========================================================================
    // C4 kernel
    // =========================================================================
    function [1:0] classify;
        input [5:0] e;
        begin
            if      (e <= 6'd15) classify = 2'd0;
            else if (e <= 6'd19) classify = 2'd1;
            else if (e <= 6'd43) classify = 2'd2;
            else if (e <= 6'd47) classify = 2'd1;
            else                 classify = 2'd3;
        end
    endfunction

    function [2:0] c4_mode;
        input [1:0] cls;
        input [5:0] e_in;
        input [7:0] d;
        reg [1:0] rgn;
        begin
            rgn = classify(e_in);
            if (d > 8'd16)
                c4_mode = 3'b010;
            else case (rgn)
                2'd2: c4_mode = 3'b000;
                2'd1: c4_mode = (cls==2'd1||cls==2'd3) ? 3'b010 : 3'b000;
                2'd0: c4_mode = (cls==2'd0) ? 3'b011 : 3'b010;
                2'd3: c4_mode = 3'b011;
                default: c4_mode = 3'b000;
            endcase
        end
    endfunction

    // =========================================================================
    // Operand constants
    // =========================================================================
    localparam [12:0] NEUTRAL  = {1'b0, 6'd32, 6'd0};
    // A1 targets
    localparam [12:0] CSUB_A   = {1'b0, 6'd32, 6'd32};     // SUB base
    // A3 targets
    localparam [12:0] COLL_A   = {1'b0, 6'd15, 6'd32};     // low boundary (Rollover)
    localparam [12:0] SAT_A    = {1'b0, 6'd47, 6'd32};     // high boundary (Rollover)
    // A4 targets
    localparam [12:0] STABLE_P = {1'b0, 6'd32, 6'd32};     // STABLE injection
    localparam [12:0] COLL_INJ = {1'b0, 6'd15, 6'd20};     // COLLAPSE injection
    localparam [12:0] SAT_INJ  = {1'b0, 6'd48, 6'd10};     // SATURATE injection

    // =========================================================================
    // State
    // =========================================================================
    integer fd;
    integer total_cyc, wl_id, wl_cyc, depth_cnt;
    reg [12:0] mulfeed;    // MUL chain feedback (single shared)
    reg [12:0] s1dfeed;    // Coupled feedback for WL18 (S1-D style)
    reg [1:0]  cur_class;
    reg        is_recovery;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // =========================================================================
    // Main
    // =========================================================================
    initial begin : MAIN
        $display("HBS-C10: Predictive Validation — 20 workloads × 350 cycles");

        op_a = NEUTRAL; op_b = NEUTRAL; op_sel = 2'b11;
        mode_tag = 3'b000; accum_en = 1'b0; accum_clr = 1'b0;
        host_tile_depth = 6'd63;
        rst_n = 1'b0;
        depth_cnt = 0;
        mulfeed  = NEUTRAL;
        s1dfeed  = NEUTRAL;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C10_SINGULARITY.csv", "w");
        $fwrite(fd, "total_cycle,wl_id,wl_cycle,depth,op,E_in,E_out,accum,region,UF,OVF\n");

        for (total_cyc = 0; total_cyc < TOTAL_CYCLES; total_cyc = total_cyc + 1) begin

            wl_id  = total_cyc / CYCLES_PER_WL;   // 0..19
            wl_cyc = total_cyc % CYCLES_PER_WL;    // 0..349

            @(negedge clk);

            is_recovery = (wl_cyc >= STRESS_CYCLES);

            // ── Reset at workload start ────────────────────────────────────
            if (wl_cyc == 0) begin
                accum_clr  = 1'b1;
                depth_cnt  = 0;
                mulfeed    = NEUTRAL;
                s1dfeed    = NEUTRAL;
            end else if (depth_cnt >= EPOCH_DEPTH) begin
                accum_clr  = 1'b1;
                depth_cnt  = 0;
            end else begin
                accum_clr  = 1'b0;
            end

            // ── Default ───────────────────────────────────────────────────
            op_sel = 2'b11;  // NOP
            op_a   = NEUTRAL;
            op_b   = NEUTRAL;
            cur_class = 2'd0;

            if (is_recovery) begin
                op_a = NEUTRAL; op_b = NEUTRAL; op_sel = 2'b10; cur_class = 2'd3;
            end else begin

                case (wl_id)

                    // ─── A1 family ───────────────────────────────────────────
                    // WL00: All SUB E=32 jitter=3 (constant small residual)
                    0: begin
                        op_a = CSUB_A; op_b = {1'b0, 6'd32, 6'd35};
                        op_sel = 2'b01; cur_class = 2'd1;
                    end
                    // WL01: All SUB E=32 jitter=8 (medium residual)
                    1: begin
                        op_a = CSUB_A; op_b = {1'b0, 6'd32, 6'd40};
                        op_sel = 2'b01; cur_class = 2'd1;
                    end
                    // WL02: MUL chain ×2 (E_factor=33, ΔE=1/cycle)
                    2: begin
                        op_a = mulfeed; op_b = {1'b0, 6'd33, 6'd0};
                        op_sel = 2'b10; cur_class = 2'd3;
                    end
                    // WL03: MUL chain ×4 (E_factor=34, ΔE=2/cycle)
                    3: begin
                        op_a = mulfeed; op_b = {1'b0, 6'd34, 6'd0};
                        op_sel = 2'b10; cur_class = 2'd3;
                    end
                    // WL04: ADD at low boundary (E=15 Rollover)
                    4: begin
                        op_a = COLL_A; op_b = COLL_A;
                        op_sel = 2'b00; cur_class = 2'd2;
                    end
                    // WL05: ADD at high boundary (E=47 Rollover)
                    5: begin
                        op_a = SAT_A; op_b = SAT_A;
                        op_sel = 2'b00; cur_class = 2'd2;
                    end
                    // WL06: Mixed 40/30/30 injection (pure A4 design)
                    6: begin
                        op_sel = 2'b00; cur_class = 2'd0;
                        case (wl_cyc % 10)
                            0,1,2,3: begin op_a = STABLE_P; op_b = STABLE_P; end
                            4,5,6:   begin op_a = COLL_INJ;  op_b = COLL_INJ; end
                            default: begin op_a = SAT_INJ;   op_b = SAT_INJ;  end
                        endcase
                    end
                    // WL07: SUB burst 100cy + NOP 200cy (sparse A1)
                    7: begin
                        if (wl_cyc < 100) begin
                            op_a = CSUB_A; op_b = {1'b0, 6'd32, 6'd37};
                            op_sel = 2'b01; cur_class = 2'd1;
                        end else begin
                            op_sel = 2'b11; cur_class = 2'd0;
                        end
                    end
                    // WL08: MUL burst 50cy + stable ADD 250cy
                    8: begin
                        if (wl_cyc < 50) begin
                            op_a = mulfeed; op_b = {1'b0, 6'd33, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a = {1'b0, 6'd32, 6'd32}; op_b = {1'b0, 6'd32, 6'd32};
                            op_sel = 2'b00; cur_class = 2'd0;
                        end
                    end
                    // WL09: Alternating ADD at E=15/E=47 (dual boundary)
                    9: begin
                        op_sel = 2'b00; cur_class = 2'd2;
                        if (wl_cyc[0]) begin op_a = COLL_A; op_b = COLL_A; end
                        else           begin op_a = SAT_A;  op_b = SAT_A;  end
                    end
                    // WL10: SUB E=32 with ramp jitter 1..8 cycling
                    10: begin
                        op_a       = CSUB_A;
                        op_b[12]   = 1'b0;
                        op_b[11:6] = 6'd32;
                        op_b[5:0]  = 6'd33 + wl_cyc[2:0]; // 33..40 cycling
                        op_sel = 2'b01; cur_class = 2'd1;
                    end
                    // WL11: MUL+SUB interleaved (independent feeds — S1-B)
                    11: begin
                        if (wl_cyc[0] == 1'b0) begin
                            op_a = mulfeed; op_b = {1'b0, 6'd33, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a = CSUB_A; op_b = {1'b0, 6'd32, 6'd35};
                            op_sel = 2'b01; cur_class = 2'd1;
                        end
                    end
                    // WL12: ADD sweeping STABLE band E=20..43
                    12: begin
                        op_a[12]   = 1'b0;
                        op_a[11:6] = 6'd20 + (wl_cyc % 24);
                        op_a[5:0]  = 6'd32;
                        op_b       = {1'b0, 6'd32, 6'd32};
                        op_sel = 2'b00; cur_class = 2'd0;
                    end
                    // WL13: Sparse MUL (1/10 cycles) + stable ADD
                    13: begin
                        if ((wl_cyc % 10) == 0) begin
                            op_a = mulfeed; op_b = {1'b0, 6'd33, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a = {1'b0, 6'd32, 6'd32}; op_b = {1'b0, 6'd32, 6'd32};
                            op_sel = 2'b00; cur_class = 2'd0;
                        end
                    end
                    // WL14: SUB cascade — jitter doubles every 50 cycles (1→2→4→8→16→32)
                    14: begin
                        op_a       = CSUB_A;
                        op_b[12]   = 1'b0;
                        op_b[11:6] = 6'd32;
                        op_b[5:0]  = 6'd32 + (6'd1 << (wl_cyc / 50));
                        op_sel = 2'b01; cur_class = 2'd1;
                    end
                    // WL15: MUL chain 150cy (A2) → ADD at E=47 150cy (A3)
                    15: begin
                        if (wl_cyc < 150) begin
                            op_a = mulfeed; op_b = {1'b0, 6'd33, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a = SAT_A; op_b = SAT_A;
                            op_sel = 2'b00; cur_class = 2'd2;
                        end
                    end
                    // WL16: ADD uniform sweep E=15..48 (all regions)
                    16: begin
                        op_a[12]   = 1'b0;
                        op_a[11:6] = 6'd15 + (wl_cyc % 34);
                        op_a[5:0]  = 6'd32;
                        op_b       = {1'b0, 6'd32, 6'd32};
                        op_sel = 2'b00; cur_class = 2'd0;
                    end
                    // WL17: SUB at E=16 (TRANSITION zone cancellation)
                    17: begin
                        op_a = {1'b0, 6'd16, 6'd32};
                        op_b = {1'b0, 6'd16, 6'd35};
                        op_sel = 2'b01; cur_class = 2'd1;
                    end
                    // WL18: Coupled MUL+SUB (S1-D style, 60/40)
                    18: begin
                        if (((wl_cyc * 7) % 10) < 6) begin
                            op_a = s1dfeed; op_b = {1'b0, 6'd33, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a = s1dfeed;
                            op_b = {s1dfeed[12], s1dfeed[11:6], s1dfeed[5:0] + 6'd4};
                            op_sel = 2'b01; cur_class = 2'd1;
                        end
                    end
                    // WL19: ADD alternating E=15/E=16 (COLLAPSE↔TRANSITION straddle)
                    default: begin
                        op_sel = 2'b00; cur_class = 2'd2;
                        if (wl_cyc[0]) begin
                            op_a = {1'b0, 6'd15, 6'd0}; op_b = {1'b0, 6'd15, 6'd32};
                        end else begin
                            op_a = {1'b0, 6'd16, 6'd0}; op_b = {1'b0, 6'd16, 6'd0};
                        end
                    end

                endcase
            end // !is_recovery

            // ── C4 kernel ─────────────────────────────────────────────────
            mode_tag = c4_mode(cur_class, op_a[11:6], depth_cnt[7:0]);

            // ── accum_en ──────────────────────────────────────────────────
            if (is_recovery || depth_cnt >= EPOCH_DEPTH || op_sel == 2'b11 ||
                classify(op_a[11:6]) == 2'd0 || classify(op_a[11:6]) == 2'd3)
                accum_en = 1'b0;
            else
                accum_en = 1'b1;

            @(posedge clk); #1;

            // ── Feedback updates ──────────────────────────────────────────
            if (!is_recovery) begin
                case (wl_id)
                    2,3,8,11,13,15: begin
                        if (exp_ovf_flag || op_sel != 2'b10)
                            mulfeed = NEUTRAL;
                        else
                            mulfeed = result;
                    end
                    18: begin
                        if (exp_ovf_flag)
                            s1dfeed = NEUTRAL;
                        else
                            s1dfeed = result;
                    end
                    default: mulfeed = NEUTRAL;
                endcase
            end else begin
                mulfeed = NEUTRAL;
                s1dfeed = NEUTRAL;
            end

            // ── Log ───────────────────────────────────────────────────────
            $fwrite(fd, "%0d,%0d,%0d,", total_cyc, wl_id, wl_cyc);
            $fwrite(fd, "%0d,", depth_cnt);
            case (op_sel)
                2'b00: $fwrite(fd, "ADD,");
                2'b01: $fwrite(fd, "SUB,");
                2'b10: $fwrite(fd, "MUL,");
                2'b11: $fwrite(fd, "NOP,");
            endcase
            $fwrite(fd, "%0d,%0d,", op_a[11:6], result[11:6]);
            $fwrite(fd, "%0d,", accum_out);
            case (classify(result[11:6]))
                2'd0: $fwrite(fd, "COLLAPSE,");
                2'd1: $fwrite(fd, "TRANSITION,");
                2'd2: $fwrite(fd, "STABLE,");
                2'd3: $fwrite(fd, "SATURATE,");
            endcase
            $fwrite(fd, "%0d,%0d\n", underflow_flag, exp_ovf_flag);

            depth_cnt = depth_cnt + 1;
        end

        $fclose(fd);
        $display("  7000 cycles → HBS_C10_SINGULARITY.csv");
        $finish;
    end

endmodule

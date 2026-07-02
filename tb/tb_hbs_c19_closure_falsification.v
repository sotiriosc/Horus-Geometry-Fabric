`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c19_closure_falsification
// Project  : HORUS v3 — HBS-C19: Closure Falsification Under Cross-Domain
//            Coupling
//
// Purpose  : Attempt to falsify the HBS-C18 System Closure Theorem by
//            adversarially injecting cross-domain couplings and measuring
//            whether any causal leakage from the state space S into the
//            computational space C appears.
//
// Method   : Two simultaneous DUT instances (dut_ref / dut_inj) run the
//            same clock.  dut_ref always receives CANONICAL inputs; dut_inj
//            receives adversarially perturbed inputs per regime.
//            Signals of interest are sampled after posedge + 1 ns delta.
//
// Regimes  : R1 — Phantom Feedback Injection    (cycles    0 – 1999)
//            R2 — Mode-Tag Echo Coupling         (cycles 2000 – 3999)
//            R3 — E-Field Perturbation Attack    (cycles 4000 – 5999)
//            R4 — Accumulation Replay Injection  (cycles 6000 – 7999)
//            R5 — Boundary Time Reversal Attack  (cycles 8000 – 9999)
//
// Total    : 10,000 cycles
//
// CSV output: HBS_C19_CLOSURE_RESULTS.csv
// Columns  : cycle, regime, local_cycle,
//            op_a_ref, op_a_inj,
//            mode_tag_ref, mode_tag_inj,
//            op_sel_ref, op_sel_inj,
//            computed_ref, computed_inj,
//            result_ref, result_inj,
//            accum_reg_ref, accum_reg_inj,
//            e_field_ref, e_field_inj,
//            injected_signal,
//            accum_clr_ref, accum_clr_inj
// ============================================================================

module tb_hbs_c19_closure_falsification;

    // =========================================================================
    // Operation constants
    // =========================================================================
    localparam OP_ADD = 2'b00;
    localparam OP_SUB = 2'b01;
    localparam OP_MUL = 2'b10;
    localparam OP_NOP = 2'b11;

    localparam MODE_STANDARD  = 3'b000;
    localparam MODE_BIAS_CORR = 3'b001;
    localparam MODE_PRE_SCALED= 3'b010;
    localparam MODE_SAFE_ACCUM= 3'b011;

    // Locked canonical operands (same as C16/C17)
    localparam [12:0] FIXED_OP_A = {1'b0, 6'd32, 6'd32};  // E=32, f=32
    localparam [12:0] FIXED_OP_B = {1'b0, 6'd0,  6'd16};  // E=0,  f=16
    localparam [1:0]  FIXED_SEL  = OP_ADD;
    localparam [2:0]  FIXED_MODE = MODE_STANDARD;

    // R5 operands — moderate magnitudes for MUL
    localparam [12:0] R5_MUL_A   = {1'b0, 6'd36, 6'd0};   // E=36 → 2^4 = 16
    localparam [12:0] R5_MUL_B   = {1'b0, 6'd36, 6'd0};   // same
    localparam [12:0] R5_ADD_A   = {1'b0, 6'd32, 6'd16};  // E=32, f=16 → ~1.25
    localparam [12:0] R5_ADD_B   = {1'b0, 6'd0,  6'd8};   // E=0,  f=8

    // =========================================================================
    // Clock + reset
    // =========================================================================
    reg clk, rst_n;
    initial clk = 1'b0;
    always  #5 clk = ~clk;  // 100 MHz

    // =========================================================================
    // DUT_REF inputs / outputs
    // =========================================================================
    reg  [12:0] op_a_ref,  op_b_ref;
    reg  [1:0]  op_sel_ref;
    reg  [2:0]  mode_tag_ref;
    reg         accum_en_ref,  accum_clr_ref;
    reg  [5:0]  depth_ref;

    wire [12:0] result_ref;
    wire [31:0] accum_out_ref;
    wire        rollover_ref, uf_ref, ovf_ref;
    wire [15:0] op_count_ref;
    wire        accum_full_ref;

    horus_system dut_ref (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a_ref), .op_b(op_b_ref), .op_sel(op_sel_ref),
        .mode_tag(mode_tag_ref),
        .accum_en(accum_en_ref), .accum_clr(accum_clr_ref),
        .host_tile_depth(depth_ref),
        .result(result_ref), .accum_out(accum_out_ref),
        .rollover_flag(rollover_ref), .underflow_flag(uf_ref), .exp_ovf_flag(ovf_ref),
        .op_count(op_count_ref), .accum_full(accum_full_ref)
    );

    // =========================================================================
    // DUT_INJ inputs / outputs
    // =========================================================================
    reg  [12:0] op_a_inj,  op_b_inj;
    reg  [1:0]  op_sel_inj;
    reg  [2:0]  mode_tag_inj;
    reg         accum_en_inj,  accum_clr_inj;
    reg  [5:0]  depth_inj;

    wire [12:0] result_inj;
    wire [31:0] accum_out_inj;
    wire        rollover_inj, uf_inj, ovf_inj;
    wire [15:0] op_count_inj;
    wire        accum_full_inj;

    horus_system dut_inj (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a_inj), .op_b(op_b_inj), .op_sel(op_sel_inj),
        .mode_tag(mode_tag_inj),
        .accum_en(accum_en_inj), .accum_clr(accum_clr_inj),
        .host_tile_depth(depth_inj),
        .result(result_inj), .accum_out(accum_out_inj),
        .rollover_flag(rollover_inj), .underflow_flag(uf_inj), .exp_ovf_flag(ovf_inj),
        .op_count(op_count_inj), .accum_full(accum_full_inj)
    );

    // =========================================================================
    // Internal signal probes
    // =========================================================================
    wire [12:0] p_computed_ref = dut_ref.u_nfe.computed;
    wire [12:0] p_computed_inj = dut_inj.u_nfe.computed;
    wire [31:0] p_accum_ref    = dut_ref.u_nfe.accum_reg;
    wire [31:0] p_accum_inj    = dut_inj.u_nfe.accum_reg;
    wire [12:0] p_accum_word_ref = dut_ref.u_nfe.accum_word;
    wire [12:0] p_accum_word_inj = dut_inj.u_nfe.accum_word;

    // =========================================================================
    // Logging infrastructure
    // =========================================================================
    integer    fd;
    integer    total_cyc;
    integer    c;

    // Shadow / injected signal registers (computed in TB each cycle)
    reg [31:0] injected_signal;
    reg [5:0]  e_field_ref_log;
    reg [5:0]  e_field_inj_log;

    task log_c19;
        input [2:0]  regime;
        input integer local_cyc;
    begin
        $fwrite(fd,
            "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
            total_cyc, regime, local_cyc,
            op_a_ref,  op_a_inj,
            mode_tag_ref, mode_tag_inj,
            op_sel_ref, op_sel_inj,
            p_computed_ref, p_computed_inj,
            result_ref, result_inj,
            p_accum_ref, p_accum_inj,
            e_field_ref_log, e_field_inj_log,
            injected_signal,
            accum_clr_ref, accum_clr_inj
        );
        total_cyc = total_cyc + 1;
    end
    endtask

    // =========================================================================
    // Hard reset both DUTs simultaneously
    // =========================================================================
    task hard_reset_both;
    begin
        @(negedge clk);
        rst_n = 1'b0;
        accum_clr_ref = 1'b1; accum_en_ref = 1'b0;
        accum_clr_inj = 1'b1; accum_en_inj = 1'b0;
        @(negedge clk); @(negedge clk);
        @(negedge clk); rst_n = 1'b1;
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;
        @(posedge clk); #1;
    end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin : MAIN
        $display("HBS-C19: Closure Falsification Under Cross-Domain Coupling — 10,000 cycles");

        // Initialise all inputs to safe defaults
        op_a_ref = FIXED_OP_A; op_b_ref = FIXED_OP_B;
        op_sel_ref = FIXED_SEL; mode_tag_ref = FIXED_MODE;
        accum_en_ref = 1'b0; accum_clr_ref = 1'b0; depth_ref = 6'd0;

        op_a_inj = FIXED_OP_A; op_b_inj = FIXED_OP_B;
        op_sel_inj = FIXED_SEL; mode_tag_inj = FIXED_MODE;
        accum_en_inj = 1'b0; accum_clr_inj = 1'b0; depth_inj = 6'd0;

        rst_n = 1'b0; total_cyc = 0;
        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C19_CLOSURE_RESULTS.csv", "w");
        $fwrite(fd, "cycle,regime,local_cycle,");
        $fwrite(fd, "op_a_ref,op_a_inj,mode_tag_ref,mode_tag_inj,op_sel_ref,op_sel_inj,");
        $fwrite(fd, "computed_ref,computed_inj,result_ref,result_inj,");
        $fwrite(fd, "accum_reg_ref,accum_reg_inj,e_field_ref,e_field_inj,");
        $fwrite(fd, "injected_signal,accum_clr_ref,accum_clr_inj\n");

        // ─────────────────────────────────────────────────────────────────────
        // REGIME R1 — Phantom Feedback Injection (2000 cycles)
        //
        // dut_ref : op_a = FIXED_OP_A, accum_en=1, depth=63, clr every 64 cy
        // dut_inj : op_a = FIXED_OP_A ^ {7'b0, accum_out_inj[5:0]}
        //           (1-cycle delayed phantom feedback from inj's own accumulator)
        // depth=63 opens the gate for 63 MACs per window; accum_clr every 64
        // cycles resets op_count so the gate re-opens for another 63 MACs.
        // Question: Does computed_ref remain constant despite accum coupling
        //           injected into the parallel inj path?
        // ─────────────────────────────────────────────────────────────────────
        $display("  R1 Phantom Feedback Injection...");
        hard_reset_both;
        op_a_ref = FIXED_OP_A; op_b_ref = FIXED_OP_B;
        op_sel_ref = FIXED_SEL; mode_tag_ref = FIXED_MODE;
        accum_en_ref = 1'b1; depth_ref = 6'd63;

        // inj starts with FIXED inputs; op_a_inj updated each cycle from accum_out_inj
        op_a_inj = FIXED_OP_A; op_b_inj = FIXED_OP_B;
        op_sel_inj = FIXED_SEL; mode_tag_inj = FIXED_MODE;
        accum_en_inj = 1'b1; depth_inj = 6'd63;

        for (c = 0; c < 2000; c = c+1) begin
            // Periodic clear every 64 cycles to re-open the gate
            accum_clr_ref = ((c % 64) == 63) ? 1'b1 : 1'b0;
            accum_clr_inj = ((c % 64) == 63) ? 1'b1 : 1'b0;
            @(posedge clk); #1;
            // Update op_a_inj for NEXT cycle using inj's current accum_out (1-cycle delay)
            op_a_inj = FIXED_OP_A ^ {7'b0, accum_out_inj[5:0]};
            // Derive log values
            e_field_ref_log = result_ref[11:6];
            e_field_inj_log = result_inj[11:6];
            injected_signal = {26'b0, accum_out_inj[5:0]};
            log_c19(3'd0, c);
        end
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;

        // ─────────────────────────────────────────────────────────────────────
        // REGIME R2 — Mode-Tag Echo Coupling (2000 cycles)
        //
        // dut_ref : mode_tag = STANDARD (000) throughout
        // dut_inj : mode_tag cycles 000→001→010→011 every 500 cycles
        // Shadow  : shadow_val (TB register) = FIXED_OP_A[5:0] + mode_tag_inj
        //           (simulates what the ALU would compute IF mode_tag echoed into
        //           the arithmetic path — which the RTL never does)
        // Question: Does computed_inj change when mode_tag changes?
        // ─────────────────────────────────────────────────────────────────────
        $display("  R2 Mode-Tag Echo Coupling...");
        hard_reset_both;
        op_a_ref = FIXED_OP_A; op_b_ref = FIXED_OP_B;
        op_sel_ref = FIXED_SEL; mode_tag_ref = MODE_STANDARD;
        accum_en_ref = 1'b1; accum_clr_ref = 1'b0; depth_ref = 6'd0;

        op_a_inj = FIXED_OP_A; op_b_inj = FIXED_OP_B;
        op_sel_inj = FIXED_SEL;
        accum_en_inj = 1'b1; depth_inj = 6'd63;

        for (c = 0; c < 2000; c = c+1) begin
            // Cycle mode_tag_inj every 500 cycles
            case (c / 500)
                0: mode_tag_inj = MODE_STANDARD;
                1: mode_tag_inj = MODE_BIAS_CORR;
                2: mode_tag_inj = MODE_PRE_SCALED;
                3: mode_tag_inj = MODE_SAFE_ACCUM;
                default: mode_tag_inj = MODE_STANDARD;
            endcase
            // Periodic clear every 64 cycles to re-open the gate
            accum_clr_ref = ((c % 64) == 63) ? 1'b1 : 1'b0;
            accum_clr_inj = ((c % 64) == 63) ? 1'b1 : 1'b0;
            @(posedge clk); #1;
            // Shadow: what would ALU give if mode_tag leaked into arithmetic?
            // shadow = FIXED_OP_A[5:0] + mode_tag_inj  (echo coupling hypothesis)
            injected_signal = {26'b0, FIXED_OP_A[5:0]} + {29'b0, mode_tag_inj};
            e_field_ref_log = result_ref[11:6];
            e_field_inj_log = result_inj[11:6];
            log_c19(3'd1, c);
        end
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;

        // ─────────────────────────────────────────────────────────────────────
        // REGIME R3 — E-Field Perturbation Attack (2000 cycles)
        //
        // Both DUTs use identical locked inputs (same as C17 baseline).
        // Shadow E-field: shadow_E = result_ref[11:6] ^ 6'b101010
        //   (simulates what the observation layer would see if someone
        //    forcibly flipped alternating E-bits)
        // Additionally: uses dut_inj as a pure control duplicate of dut_ref.
        // Question: Even with E-field perturbed in the observation layer,
        //           does the RTL-level computed remain constant?
        //           Does CLI(e_perturb, computed) = 0?
        // ─────────────────────────────────────────────────────────────────────
        $display("  R3 E-Field Perturbation Attack...");
        hard_reset_both;
        op_a_ref = FIXED_OP_A; op_b_ref = FIXED_OP_B;
        op_sel_ref = FIXED_SEL; mode_tag_ref = FIXED_MODE;
        accum_en_ref = 1'b1; accum_clr_ref = 1'b0; depth_ref = 6'd0;

        op_a_inj = FIXED_OP_A; op_b_inj = FIXED_OP_B;
        op_sel_inj = FIXED_SEL; mode_tag_inj = FIXED_MODE;
        accum_en_inj = 1'b1; depth_inj = 6'd63;

        for (c = 0; c < 2000; c = c+1) begin
            // Periodic clear every 64 cycles to re-open the gate
            accum_clr_ref = ((c % 64) == 63) ? 1'b1 : 1'b0;
            accum_clr_inj = ((c % 64) == 63) ? 1'b1 : 1'b0;
            @(posedge clk); #1;
            // Shadow E-field: what an observer would see after E-field XOR injection
            e_field_ref_log = result_ref[11:6];
            e_field_inj_log = result_ref[11:6] ^ 6'b101010;  // perturbed observer
            // Constant injection mask (XOR pattern 0x2A)
            injected_signal = 32'd42;   // 6'b101010 = 42
            log_c19(3'd2, c);
        end
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;

        // ─────────────────────────────────────────────────────────────────────
        // REGIME R4 — Accumulation Replay Injection (2000 cycles)
        //
        // dut_ref : accum_clr every 64 cycles (long replay window)
        // dut_inj : accum_clr every 8 cycles  (rapid short-window replay)
        // Both    : identical locked ADD inputs
        // This creates maximally divergent accum trajectories while keeping
        // all computation inputs identical.
        // Question: Does the divergence in accum history propagate into computed?
        // ─────────────────────────────────────────────────────────────────────
        $display("  R4 Accumulation Replay Injection...");
        hard_reset_both;
        op_a_ref = FIXED_OP_A; op_b_ref = FIXED_OP_B;
        op_sel_ref = FIXED_SEL; mode_tag_ref = FIXED_MODE;
        accum_en_ref = 1'b1; depth_ref = 6'd63;

        op_a_inj = FIXED_OP_A; op_b_inj = FIXED_OP_B;
        op_sel_inj = FIXED_SEL; mode_tag_inj = FIXED_MODE;
        accum_en_inj = 1'b1; depth_inj = 6'd63;

        for (c = 0; c < 2000; c = c+1) begin
            // ref: clr every 64 cycles (re-opens gate for next 63 MACs)
            accum_clr_ref = ((c % 64) == 63) ? 1'b1 : 1'b0;
            // inj: clr every 8 cycles (rapid replay — gate stays open for 8 MACs, then clr)
            accum_clr_inj = ((c % 8)  == 7)  ? 1'b1 : 1'b0;
            @(posedge clk); #1;
            e_field_ref_log = result_ref[11:6];
            e_field_inj_log = result_inj[11:6];
            // injected_signal: difference in clear-schedule (1 when they diverge)
            injected_signal = {31'b0, accum_clr_inj ^ accum_clr_ref};
            log_c19(3'd3, c);
        end
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;

        // ─────────────────────────────────────────────────────────────────────
        // REGIME R5 — Boundary Time Reversal Attack (2000 cycles)
        //
        // Both DUTs: op_a/op_b switch between MUL and ADD operands in 16-cycle
        //            epochs (8 MUL cycles + 8 ADD cycles).
        //
        // Phase 1 (local 0-999): IDENTICAL epoch order for both DUTs
        //   Both: [MUL×8, ADD×8, MUL×8, ADD×8, ...]
        //
        // Phase 2 (local 1000-1999): REVERSED epoch order for dut_inj
        //   ref  : [MUL×8, ADD×8, MUL×8, ADD×8, ...]  (same as phase 1)
        //   inj  : [ADD×8, MUL×8, ADD×8, MUL×8, ...]  (reversed)
        //
        // Question: When inj reverses accumulation order within epochs,
        //           does computed_inj deviate from its expected φ value?
        //           Does accum_reg diverge between ref and inj?
        // ─────────────────────────────────────────────────────────────────────
        $display("  R5 Boundary Time Reversal Attack...");
        hard_reset_both;
        mode_tag_ref = MODE_STANDARD; mode_tag_inj = MODE_STANDARD;
        // depth=16 = epoch size; clr every 16 cycles lets us compare epoch-end
        // accum totals cleanly between forward and reversed order.
        accum_en_ref = 1'b1; depth_ref = 6'd16;
        accum_en_inj = 1'b1; depth_inj = 6'd16;
        op_b_ref = R5_MUL_B; op_b_inj = R5_MUL_B;  // shared operand B

        // Phase 2 starts at c=1008 (= 63 × 16), the first epoch boundary >= 1000.
        // This ensures the injected_signal step-change lands exactly on an epoch
        // boundary, eliminating phase-coincidence correlation with computed_ref.
        for (c = 0; c < 2000; c = c+1) begin
            // REF: forward epoch order [MUL×8, ADD×8, ...]
            if ((c % 16) < 8) begin
                op_a_ref = R5_MUL_A; op_b_ref = R5_MUL_B; op_sel_ref = OP_MUL;
            end else begin
                op_a_ref = R5_ADD_A; op_b_ref = R5_ADD_B; op_sel_ref = OP_ADD;
            end

            // INJ: Phase 1 = same as ref; Phase 2 = reversed
            if (c < 1008) begin
                // Phase 1 (63 complete epochs): identical to ref
                op_a_inj = op_a_ref; op_b_inj = op_b_ref; op_sel_inj = op_sel_ref;
            end else begin
                // Phase 2 (61 complete epochs): reversed epoch order
                if ((c % 16) < 8) begin
                    op_a_inj = R5_ADD_A; op_b_inj = R5_ADD_B; op_sel_inj = OP_ADD;
                end else begin
                    op_a_inj = R5_MUL_A; op_b_inj = R5_MUL_B; op_sel_inj = OP_MUL;
                end
            end

            // Clear at end of each 16-cycle epoch so gate re-opens for next epoch
            accum_clr_ref = ((c % 16) == 15) ? 1'b1 : 1'b0;
            accum_clr_inj = ((c % 16) == 15) ? 1'b1 : 1'b0;
            @(posedge clk); #1;
            e_field_ref_log = result_ref[11:6];
            e_field_inj_log = result_inj[11:6];
            // injected_signal: 1 when epoch order differs between ref and inj
            injected_signal = {31'b0, (op_sel_ref != op_sel_inj) ? 1'b1 : 1'b0};
            log_c19(3'd4, c);
        end
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;

        // ─────────────────────────────────────────────────────────────────────
        // Done
        // ─────────────────────────────────────────────────────────────────────
        $fclose(fd);
        $display("  Done. Total cycles: %0d", total_cyc);
        $display("  Output: HBS_C19_CLOSURE_RESULTS.csv");
        $finish;
    end

endmodule

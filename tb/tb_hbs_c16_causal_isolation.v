`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c16_causal_isolation
// Project  : HORUS v3 — HBS-C16: Control Causality Isolation Suite
//
// Purpose : Determine where in the pipeline mode_tag first causes divergence.
//
// Method  : Run 4 identical pipelines sequentially with reset equivalence.
//           ALL inputs are locked across modes — only mode_tag varies.
//           Internal NFE signals are logged via hierarchical reference.
//
// Fixed constants (locked across all 4 runs):
//   op_a     = {1'b0, 6'd32, 6'd32}   E=32, frac=32 (positive unit)
//   op_b     = {1'b0, 6'd0,  6'd16}   m_b=16 as ADD fraction delta
//   op_sel   = 2'b00 (ADD)             1-cycle, no Guard-B pipeline
//   accum_en = 1'b1
//   host_tile_depth = 6'd63           gate open for 63 MACs per mode run
//
// Mode sweep: mode_tag ∈ {3'b000, 3'b001, 3'b010, 3'b011}
//   Each mode: 2,000 cycles  →  total 8,000 cycles
//
// Pipeline stages traced (all sampled after posedge clk + 1ns):
//   S1 ALU   : mant_sum    (8-bit ADD/SUB intermediate, blocking-reg)
//              scale_reg   (20-bit MUL product, blocking-reg)
//   S2 CMPD  : computed    (13-bit post-ALU result, blocking-reg)
//   S3 AINP  : accum_word  (13-bit policy-decoded accumulation input)
//   S4 AREG  : accum_reg   (32-bit accumulator state, pre- and post-update)
//   S5 OUT   : result       (13-bit registered NFE output)
//              accum_out   (32-bit registered accum, 1-cycle lag)
//
// CSV schema:
//   cycle, mode_id, local_cycle,
//   op_a, op_b, op_sel, mode_tag,
//   mant_sum, scale_reg, computed, accum_word,
//   accum_reg_pre, accum_reg_post,
//   result, accum_out,
//   UF, OVF, rollover, accum_en_active
// ============================================================================

module tb_hbs_c16_causal_isolation;

    localparam RUN_CYCS  = 2000;   // cycles per mode
    localparam N_MODES   = 4;
    localparam TOTAL     = RUN_CYCS * N_MODES;  // 8,000

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
    // Hierarchical probes into horus_nfe internals
    // =========================================================================
    // Blocking-assigned registers: visible after posedge+#1 with current-cycle values
    wire [7:0]  probe_mant_sum   = dut.u_nfe.mant_sum;    // S1 ADD/SUB ALU intermediate
    wire [19:0] probe_scale_reg  = dut.u_nfe.scale_reg;   // S1 MUL ALU intermediate
    wire [12:0] probe_computed   = dut.u_nfe.computed;    // S2 post-ALU NFE result
    wire [12:0] probe_accum_word = dut.u_nfe.accum_word;  // S3 policy-decoded accum input
    wire [31:0] probe_accum_reg  = dut.u_nfe.accum_reg;   // S4 accumulator state

    // =========================================================================
    // Fixed inputs (locked across ALL modes)
    // =========================================================================
    localparam [12:0] FIXED_OP_A = {1'b0, 6'd32, 6'd32};   // E=32, frac=32
    localparam [12:0] FIXED_OP_B = {1'b0, 6'd0,  6'd16};   // m_b=16 (ADD delta)
    localparam [1:0]  FIXED_SEL  = 2'b00;                   // ADD

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // Main
    // =========================================================================
    integer fd;
    integer total_cyc, mode_id, local_cyc;
    reg [31:0] accum_reg_pre;   // sampled at negedge before each posedge

    initial begin : MAIN
        integer m, c;
        $display("HBS-C16: Control Causality Isolation — %0d cycles", TOTAL);

        op_a = FIXED_OP_A; op_b = FIXED_OP_B;
        op_sel = FIXED_SEL; mode_tag = 3'b000;
        accum_en = 1'b1; accum_clr = 1'b0;
        host_tile_depth = 6'd63;
        rst_n = 1'b0;
        total_cyc = 0;

        fd = $fopen("HBS_C16_CAUSAL_TRACE.csv", "w");
        $fwrite(fd, "cycle,mode_id,local_cycle,op_a,op_b,op_sel,mode_tag,");
        $fwrite(fd, "mant_sum,scale_reg,computed,accum_word,");
        $fwrite(fd, "accum_reg_pre,accum_reg_post,result,accum_out,");
        $fwrite(fd, "UF,OVF,rollover,accum_en_active\n");

        // Initial reset
        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        // ── Sweep all 4 modes ────────────────────────────────────────────────
        for (m = 0; m < N_MODES; m = m + 1) begin
            mode_id = m;
            mode_tag = m[2:0];

            // Reset between mode runs (reset equivalence)
            @(negedge clk);
            rst_n = 1'b0; accum_clr = 1'b1;
            @(negedge clk); @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);
            accum_clr = 1'b1;  // one-cycle clear to sync op_count
            @(posedge clk); #1;
            accum_clr = 1'b0;

            // ── 2,000 cycle run for this mode ────────────────────────────────
            for (c = 0; c < RUN_CYCS; c = c + 1) begin
                @(negedge clk);
                local_cyc = c;

                // Lock all non-mode inputs
                op_a     = FIXED_OP_A;
                op_b     = FIXED_OP_B;
                op_sel   = FIXED_SEL;
                accum_en = 1'b1;
                accum_clr = 1'b0;
                // mode_tag already set for this run

                // Sample accum_reg BEFORE posedge (pre-update state)
                accum_reg_pre = probe_accum_reg;

                @(posedge clk); #1;

                // Log full pipeline trace
                $fwrite(fd, "%0d,%0d,%0d,", total_cyc, mode_id, local_cyc);
                $fwrite(fd, "0x%03x,0x%03x,%0d,%0d,",
                        FIXED_OP_A, FIXED_OP_B, FIXED_SEL, mode_tag);

                // S1: ALU intermediates
                $fwrite(fd, "%0d,%0d,",
                        probe_mant_sum, probe_scale_reg);

                // S2: computed (post-ALU result)
                $fwrite(fd, "0x%03x,", probe_computed);

                // S3: accumulation input (policy-decoded)
                $fwrite(fd, "0x%03x,", probe_accum_word);

                // S4: accumulator state (pre and post)
                $fwrite(fd, "%0d,%0d,", accum_reg_pre, probe_accum_reg);

                // S5: registered outputs
                $fwrite(fd, "0x%03x,%0d,", result, accum_out);

                // Flags and gate status
                $fwrite(fd, "%0d,%0d,%0d,%0d\n",
                        underflow_flag, exp_ovf_flag, rollover_flag,
                        (op_count < 6'd63) ? 1 : 0);

                total_cyc = total_cyc + 1;
            end

            $display("  Mode %0d (%03b) complete: %0d cycles logged", m, m, RUN_CYCS);
        end

        $fclose(fd);
        $display("  8,000 cycles → HBS_C16_CAUSAL_TRACE.csv");
        $finish;
    end

endmodule

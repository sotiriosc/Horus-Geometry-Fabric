`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_horus_nfe_pf18
// Project  : Horus Geometry Fabric — PF18 Functional Check
// File     : tb/tb_horus_nfe_pf18.v
//
// Purpose
//   Two-regime functional check of horus_nfe_pf18 (W=18 PATH_FAST accumulator).
//
//   Regime 1 — Neutral (target_rowsum=1.00, SEED=0xCAFEF00D, r=1):
//     Same matrix A and initial vector y as tb_horus_nfe_pf.v so results are
//     directly comparable.
//     Pass criteria:
//       (a) final mean rel err <= 0.5%
//       (b) within 2× of sim/pf_width_sweep.py at W=18 (0.35%), i.e., <= 0.70%
//
//   Regime 2 — Expansive (target_rowsum=1.10, SEED=0xCAFEF00D, r=2):
//     One 256-cycle chain to confirm the saturation guard (PF18 clamp) engages
//     rather than wrapping.  Clamp count = number of rows where pf_accum reached
//     18'h1FFFF (+131071) or 18'h20000 (-131072) before readout.
//
//   PF Protocol per row i (same as tb_horus_nfe_pf.v):
//     1. Issue 8 MUL ops with mode_tag=3'b100, accum_en=0.
//     2. Issue 1 NOP with mode_tag=3'b100.  Result = NFE(pf_accum); pf_accum=0.
//
// Pass summary printed to stdout; sim/Makefile target: pf18_check.
// ============================================================================

module tb_horus_nfe_pf18;

    localparam CLK_PERIOD  = 10;
    localparam CLK_HALF    = CLK_PERIOD / 2;
    localparam DEPTH       = 256;
    localparam N           = 8;
    localparam EXP_BIAS    = 32;
    localparam EXP_MAX     = 63;
    localparam SEED        = 32'hCAFE_F00D;

    localparam [1:0] OP_MUL = 2'b10;
    localparam [1:0] OP_NOP = 2'b11;
    localparam [2:0] MODE_PF = 3'b100;  // mode_tag[2]=1: PATH_FAST mode

    // DUT interface
    reg         clk;
    reg         rst_n;
    reg  [12:0] op_a;
    reg  [12:0] op_b;
    reg  [1:0]  op_sel;
    reg  [2:0]  mode_tag;
    reg         accum_en;
    reg         accum_clr;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag;
    wire        underflow_flag;
    wire        exp_ovf_flag;

    // DUT: horus_nfe_pf18 (W=18 accumulator variant)
    horus_nfe_pf18 dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .op_a           (op_a),
        .op_b           (op_b),
        .op_sel         (op_sel),
        .mode_tag       (mode_tag),
        .accum_en       (accum_en),
        .accum_clr      (accum_clr),
        .result         (result),
        .accum_out      (accum_out),
        .rollover_flag  (rollover_flag),
        .underflow_flag (underflow_flag),
        .exp_ovf_flag   (exp_ovf_flag)
    );

    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // NFE helpers (verbatim from tb_horus_nfe_pf.v)
    function real nfe_decode;
        input [12:0] cw;
        integer s, e, f;
        real    mag;
        begin
            s   = cw[12];
            e   = cw[11:6];
            f   = cw[5:0];
            mag = (1.0 + $itor(f) / 64.0) * $pow(2.0, $itor(e) - $itor(EXP_BIAS));
            nfe_decode = s ? -mag : mag;
        end
    endfunction

    function [12:0] nfe_encode;
        input real v;
        integer s, aE, eS, f;
        real    av, m, log2_av;
        begin
            s  = (v < 0.0) ? 1 : 0;
            av = (v < 0.0) ? -v : v;
            if (av == 0.0) begin
                nfe_encode = 13'd0;
            end else begin
                log2_av = $ln(av) / $ln(2.0);
                aE = $rtoi(log2_av);
                if (log2_av < 0.0 && (log2_av != $itor(aE)))
                    aE = aE - 1;
                m = av * $pow(2.0, $itor(-aE));
                if (m < 1.0)  begin aE = aE - 1; m = m * 2.0; end
                if (m >= 2.0) begin aE = aE + 1; m = m * 0.5; end
                if (aE < -EXP_BIAS) begin
                    nfe_encode = s[0] ? 13'h1000 : 13'd0;
                end else if (aE > (EXP_MAX - EXP_BIAS)) begin
                    nfe_encode = s[0] ? 13'h1FFF : 13'h0FFF;
                end else begin
                    eS = aE + EXP_BIAS;
                    f  = $rtoi((m - 1.0) * 64.0 + 0.5);
                    if (f < 0)  f = 0;
                    if (f >= 64) begin
                        f  = 0;
                        eS = eS + 1;
                        if (eS > EXP_MAX)
                            nfe_encode = s[0] ? 13'h1FFF : 13'h0FFF;
                        else
                            nfe_encode = {s[0], eS[5:0], 6'd0};
                    end else begin
                        nfe_encode = {s[0], eS[5:0], f[5:0]};
                    end
                end
            end
        end
    endfunction

    function [31:0] lfsr_step;
        input [31:0] s;
        begin
            lfsr_step = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
        end
    endfunction

    function real lfsr_frac;
        input [31:0] s;
        begin
            lfsr_frac = ({8'd0, s[31:8]} * 1.0) / 16777216.0;
        end
    endfunction

    // Working storage
    reg  [31:0] lfsr;
    real        A_fp  [0:63];
    reg  [12:0] A_nfe [0:63];
    real        y_g   [0:7];
    reg  [12:0] y_nfe [0:7];
    real        new_g [0:7];
    reg  [12:0] y_nfe_new [0:7];

    integer     i, j, t;
    integer     valid_cnt;
    real        rowsum, fval;
    real        err_sum, mean_err, gi, di, re;
    real        final_err_neutral, final_err_exp;
    integer     onset_cycle;
    integer     clamp_cnt;  // saturation guard clamp events (expansive regime)

    // Task: reset and idle DUT
    task do_reset;
        begin
            rst_n     = 1'b0;
            op_a      = 13'd0;
            op_b      = 13'd0;
            op_sel    = OP_NOP;
            mode_tag  = 3'b000;
            accum_en  = 1'b0;
            accum_clr = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // Task: build matrix A at given regime (r selects seed permutation, rs = target row sum)
    task build_matrix;
        input integer r;
        input real rs;
        begin
            lfsr = SEED ^ (r * 32'h1111_1111 + 32'h5555_AAAA);
            for (i = 0; i < N; i = i + 1) begin
                rowsum = 0.0;
                for (j = 0; j < N; j = j + 1) begin
                    lfsr = lfsr_step(lfsr);
                    A_fp[i*N+j] = lfsr_frac(lfsr) + 1e-3;
                    rowsum = rowsum + A_fp[i*N+j];
                end
                for (j = 0; j < N; j = j + 1) begin
                    A_fp[i*N+j] = A_fp[i*N+j] / rowsum * rs;
                    A_nfe[i*N+j] = nfe_encode(A_fp[i*N+j]);
                end
            end
            // Initial y
            for (j = 0; j < N; j = j + 1) begin
                lfsr     = lfsr_step(lfsr);
                fval     = 1.0 + (lfsr[5:0] * 1.0) / 64.0;
                y_nfe[j] = nfe_encode(fval);
                y_g[j]   = nfe_decode(y_nfe[j]);
            end
        end
    endtask

    initial begin : main

        final_err_neutral = 0.0;
        final_err_exp     = 0.0;
        clamp_cnt         = 0;

        // =====================================================================
        // REGIME 1: NEUTRAL (target_rowsum=1.00, r=1)
        // =====================================================================
        do_reset;
        build_matrix(1, 1.00);
        onset_cycle = DEPTH + 1;

        for (t = 1; t <= DEPTH; t = t + 1) begin

            for (i = 0; i < N; i = i + 1) begin
                // 8 MUL ops accumulate into pf_accum
                for (j = 0; j < N; j = j + 1) begin
                    @(negedge clk);
                    op_a      = A_nfe[i*N+j];
                    op_b      = y_nfe[j];
                    op_sel    = OP_MUL;
                    mode_tag  = MODE_PF;
                    accum_en  = 1'b0;
                    @(posedge clk); #1;
                end
                // NOP readout
                @(negedge clk);
                op_a     = 13'd0;
                op_b     = 13'd0;
                op_sel   = OP_NOP;
                mode_tag = MODE_PF;
                @(posedge clk); #1;
                y_nfe_new[i] = result;
            end

            // Jacobi commit
            for (i = 0; i < N; i = i + 1)
                y_nfe[i] = y_nfe_new[i];

            // Golden step
            for (i = 0; i < N; i = i + 1) begin
                new_g[i] = 0.0;
                for (j = 0; j < N; j = j + 1)
                    new_g[i] = new_g[i] + A_fp[i*N+j] * y_g[j];
            end
            for (i = 0; i < N; i = i + 1) y_g[i] = new_g[i];

            // Mean relative error
            err_sum   = 0.0;
            valid_cnt = 0;
            for (i = 0; i < N; i = i + 1) begin
                gi = y_g[i];
                di = nfe_decode(y_nfe[i]);
                if (gi != 0.0) begin
                    re = di - gi;
                    if (re < 0.0) re = -re;
                    re = re / (gi < 0.0 ? -gi : gi) * 100.0;
                    err_sum   = err_sum + re;
                    valid_cnt = valid_cnt + 1;
                end
            end
            mean_err = (valid_cnt > 0) ? (err_sum / valid_cnt) : 0.0;
            if ((onset_cycle > DEPTH) && (mean_err > 1.0))
                onset_cycle = t;
            final_err_neutral = mean_err;
        end

        // =====================================================================
        // REGIME 2: EXPANSIVE (target_rowsum=1.10, r=2) — saturation guard check
        // =====================================================================
        do_reset;
        build_matrix(2, 1.10);
        clamp_cnt = 0;

        for (t = 1; t <= DEPTH; t = t + 1) begin

            for (i = 0; i < N; i = i + 1) begin
                // 8 MUL ops
                for (j = 0; j < N; j = j + 1) begin
                    @(negedge clk);
                    op_a      = A_nfe[i*N+j];
                    op_b      = y_nfe[j];
                    op_sel    = OP_MUL;
                    mode_tag  = MODE_PF;
                    accum_en  = 1'b0;
                    @(posedge clk); #1;
                end
                // Check pf_accum BEFORE NOP to detect saturation guard state.
                // If pf_accum is at the positive or negative clamp value
                // (18'h1FFFF = +131071 or 18'h20000 = -131072), the guard fired.
                if (dut.pf_accum === 18'h1FFFF || dut.pf_accum === 18'h20000)
                    clamp_cnt = clamp_cnt + 1;
                // NOP readout
                @(negedge clk);
                op_a     = 13'd0;
                op_b     = 13'd0;
                op_sel   = OP_NOP;
                mode_tag = MODE_PF;
                @(posedge clk); #1;
                y_nfe_new[i] = result;
            end

            // Jacobi commit
            for (i = 0; i < N; i = i + 1)
                y_nfe[i] = y_nfe_new[i];

            // Golden step
            for (i = 0; i < N; i = i + 1) begin
                new_g[i] = 0.0;
                for (j = 0; j < N; j = j + 1)
                    new_g[i] = new_g[i] + A_fp[i*N+j] * y_g[j];
            end
            for (i = 0; i < N; i = i + 1) y_g[i] = new_g[i];

            err_sum   = 0.0;
            valid_cnt = 0;
            for (i = 0; i < N; i = i + 1) begin
                gi = y_g[i];
                di = nfe_decode(y_nfe[i]);
                if (gi != 0.0) begin
                    re = di - gi;
                    if (re < 0.0) re = -re;
                    re = re / (gi < 0.0 ? -gi : gi) * 100.0;
                    err_sum   = err_sum + re;
                    valid_cnt = valid_cnt + 1;
                end
            end
            mean_err = (valid_cnt > 0) ? (err_sum / valid_cnt) : 0.0;
            final_err_exp = mean_err;
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("========================================================");
        $display("tb_horus_nfe_pf18  PF18 Functional Check (W=18)");
        $display("--------------------------------------------------------");
        $display("REGIME 1: Neutral (row_sum=1.00, r=1, 256 cycles)");
        $display("  Final mean rel err : %0.4f%%", final_err_neutral);
        if (onset_cycle <= DEPTH)
            $display("  Divergence onset   : cycle %0d", onset_cycle);
        else
            $display("  Divergence onset   : NONE (stayed <= 1%% all 256 cycles)");
        $display("  Pass criteria: <= 0.50%% and <= 0.70%% (2x of 0.35%% sweep)");
        if (final_err_neutral <= 0.50) begin
            $display("  NEUTRAL VERDICT    : PASS  (%.4f%% <= 0.50%%)", final_err_neutral);
            if (final_err_neutral <= 0.70)
                $display("  2x-sweep agreement : PASS  (%.4f%% <= 0.70%%)", final_err_neutral);
            else
                $display("  2x-sweep agreement : FAIL  (%.4f%% > 0.70%%)", final_err_neutral);
        end else begin
            $display("  NEUTRAL VERDICT    : FAIL  (%.4f%% > 0.50%%)", final_err_neutral);
            $display("  W=18 variant fails functional check — do not synthesize.");
        end
        $display("--------------------------------------------------------");
        $display("REGIME 2: Expansive (row_sum=1.10, r=2, 256 cycles)");
        $display("  Final mean rel err : %0.4f%%", final_err_exp);
        $display("  Saturation clamp   : %0d row-accumulations hit clamp boundary", clamp_cnt);
        if (clamp_cnt > 0)
            $display("  SATURATION GUARD   : ENGAGED (clamp_cnt=%0d > 0)", clamp_cnt);
        else
            $display("  SATURATION GUARD   : NOT observed (clamp_cnt=0) — check expansive stimulus");
        $display("========================================================");

        $finish;
    end

endmodule

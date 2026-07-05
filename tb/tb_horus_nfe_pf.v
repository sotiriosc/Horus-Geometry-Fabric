`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_horus_nfe_pf
// Project  : Horus Geometry Fabric — PATH_FAST Functional Check
// File     : tb/tb_horus_nfe_pf.v
//
// Purpose
//   Functional check of the horus_nfe_pf PATH_FAST mode (mode_tag[2]=1).
//   Runs the neutral-regime 256-cycle feedback chain from
//   tb_second_source_chain.v through the PF variant and confirms:
//     final mean relative error vs FP64 golden ≤ 1.0%
//
//   Same matrix A / initial vector y generation as tb_second_source_chain.v
//   (SEED = 32'hCAFE_F00D, r=1, target_rowsum = 1.00).
//
//   PF Protocol per row i:
//     1. Issue 8 MUL ops with mode_tag=3'b100, accum_en=0.
//        Each MUL accumulates into pf_accum (full 14-bit scale_reg product).
//        Standard result port still outputs PATH_NFE quantized product (ignored).
//     2. Issue 1 NOP with mode_tag=3'b100.
//        PF NOP readout: result <- NFE(pf_accum), pf_accum <- 0.
//        Read result at posedge+1ns -> this is y_nfe_new[i].
//
// Pass criterion: final_mean_err <= 1.0%
//   (Python model prediction: 0.38%.  RTL tolerance: <= 1%.)
// ============================================================================

module tb_horus_nfe_pf;

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

    horus_nfe_pf dut (
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

    // NFE helpers (verbatim from tb_second_source_chain.v)
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
    reg  [12:0] y_nfe_new [0:7];  // buffered PF row sums before y_nfe update

    integer     i, j, t;
    integer     valid_cnt;
    real        rowsum, fval;
    real        err_sum, mean_err, gi, di, re;
    real        final_err;
    integer     onset_cycle;
    integer     csv_fd;   // file descriptor for per-cycle trace (Task 3 spot-check)

    initial begin : main

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

        // Matrix A: neutral regime, same seed as tb_second_source_chain.v r=1
        lfsr = SEED ^ (32'd1 * 32'h1111_1111 + 32'h5555_AAAA);
        for (i = 0; i < N; i = i + 1) begin
            rowsum = 0.0;
            for (j = 0; j < N; j = j + 1) begin
                lfsr = lfsr_step(lfsr);
                A_fp[i*N+j] = lfsr_frac(lfsr) + 1e-3;
                rowsum = rowsum + A_fp[i*N+j];
            end
            for (j = 0; j < N; j = j + 1) begin
                A_fp[i*N+j] = A_fp[i*N+j] / rowsum * 1.00;
                A_nfe[i*N+j] = nfe_encode(A_fp[i*N+j]);
            end
        end

        // Initial state vector: same as tb_second_source_chain.v r=1
        for (j = 0; j < N; j = j + 1) begin
            lfsr     = lfsr_step(lfsr);
            fval     = 1.0 + (lfsr[5:0] * 1.0) / 64.0;
            y_nfe[j] = nfe_encode(fval);
            y_g[j]   = nfe_decode(y_nfe[j]);
        end

        onset_cycle = DEPTH + 1;
        final_err   = 0.0;

        // Open per-cycle trace CSV for Task-3 spot-check.
        // Logs: cycle, rtl_mean_err_pct
        // The CSV is read by sim/pf_spotcheck.py.
        csv_fd = $fopen("PF_RTL_TRACE.csv", "w");
        $fwrite(csv_fd, "cycle,rtl_mean_err_pct\n");

        // 256-cycle feedback chain
        for (t = 1; t <= DEPTH; t = t + 1) begin

            // DUT PATH_FAST: per-row pf_accum protocol
            for (i = 0; i < N; i = i + 1) begin
                // 8 MUL ops: accumulate full products into pf_accum
                for (j = 0; j < N; j = j + 1) begin
                    @(negedge clk);
                    op_a      = A_nfe[i*N+j];
                    op_b      = y_nfe[j];
                    op_sel    = OP_MUL;
                    mode_tag  = MODE_PF;
                    accum_en  = 1'b0;
                    @(posedge clk); #1;
                end
                // NOP readout: result <- NFE(pf_accum), pf_accum <- 0
                @(negedge clk);
                op_a     = 13'd0;
                op_b     = 13'd0;
                op_sel   = OP_NOP;
                mode_tag = MODE_PF;
                @(posedge clk); #1;
                y_nfe_new[i] = result;   // PF row sum buffered; y_nfe updated below
            end

            // Commit PF row sums to y_nfe (Jacobi: all rows used OLD y_nfe above)
            for (i = 0; i < N; i = i + 1)
                y_nfe[i] = y_nfe_new[i];

            // Golden path
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
            $fwrite(csv_fd, "%0d,%0.6f\n", t, mean_err);
            if ((onset_cycle > DEPTH) && (mean_err > 1.0))
                onset_cycle = t;
            final_err = mean_err;

        end
        $fclose(csv_fd);

        // Verdict
        $display("========================================================");
        $display("tb_horus_nfe_pf  PATH_FAST Functional Check");
        $display("  Neutral regime, 256-cycle feedback chain");
        $display("  Final mean rel err : %0.4f%%", final_err);
        if (onset_cycle <= DEPTH)
            $display("  Divergence onset   : cycle %0d", onset_cycle);
        else
            $display("  Divergence onset   : NONE (mean err stayed <= 1%% for all 256 cycles)");
        $display("--------------------------------------------------------");
        if (final_err <= 1.0) begin
            $display("  VERDICT: PASS -- final mean rel err <= 1.0%% (Python pred: ~0.38%%)");
        end else begin
            $display("  VERDICT: FAIL -- final mean rel err = %0.4f%% > 1.0%%", final_err);
            $display("  PATH_FAST variant does not reproduce Python model prediction.");
            $display("  Synthesizing this variant would produce meaningless cost numbers.");
        end
        $display("========================================================");

        $finish;
    end

endmodule

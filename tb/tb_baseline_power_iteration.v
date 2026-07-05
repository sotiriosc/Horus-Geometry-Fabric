`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_baseline_power_iteration
// Project  : Horus Geometry Fabric — Baseline (PATH_NFE) Power Iteration
// File     : tb/tb_baseline_power_iteration.v
//
// Purpose
//   Drive the BASELINE horus_nfe (PATH_NFE, no PF mode) through the same
//   power-iteration workload as tb_pf18_power_iteration.v.  Identical matrix
//   A (SEED_PI = 32'hFACE_FEED), identical initial vector, identical harness
//   normalisation so the comparison isolates the datapath.
//
//   Division of labour (DUT vs harness):
//     DUT  — each MUL op quantises the product to 6-bit NFE fraction
//            (horus_nfe.v lines 530-532, scale_reg[12:7] or [11:6]) and
//            outputs result.  8 MUL ops are issued per row; each quantised
//            product is decoded and accumulated in real arithmetic.
//     Harness — accumulates 8 decoded quantised products (real FP64), then
//            normalises the row-sum vector identically to the PF18 harness
//            (‖z‖ via $sqrt, divide each component, re-encode to NFE).
//            The golden path is fully independent (FP64 matvec, no DUT).
//
//   This is the PATH_NFE behaviour confirmed in P2 of SSC validation:
//   each product is truncated to 6-bit NFE before accumulation.
//
//   Output: BASELINE_POWER_ITER.csv
//     columns: t, lambda_dut, lambda_gold, alignment
// ============================================================================

module tb_baseline_power_iteration;

    localparam CLK_PERIOD  = 10;
    localparam CLK_HALF    = CLK_PERIOD / 2;
    localparam DEPTH       = 256;
    localparam N           = 8;
    localparam EXP_BIAS    = 32;
    localparam EXP_MAX     = 63;
    localparam SEED_PI     = 32'hFACE_FEED;  // must match tb_pf18_power_iteration.v

    localparam [1:0] OP_MUL = 2'b10;
    localparam [1:0] OP_NOP = 2'b11;
    localparam [2:0] MODE_STD = 3'b000;  // standard mode — PATH_NFE quantisation

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

    // Baseline DUT: horus_nfe (original, no PATH_FAST mode)
    horus_nfe dut (
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

    // ── NFE helpers (verbatim from tb_pf18_power_iteration.v) ────────────────
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
    real        z_g   [0:7];
    real        z_dut_real [0:7];  // row sums accumulated from quantised products
    real        y_dut_real [0:7];

    integer     i, j, t;
    real        norm, lambda_dut, lambda_gold, dot_p, tmp, row_acc;
    integer     csv_fd;

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

        // ── Same matrix construction as tb_pf18_power_iteration.v ────────────
        lfsr = SEED_PI;
        for (i = 0; i < N; i = i + 1) begin
            for (j = i; j < N; j = j + 1) begin
                lfsr = lfsr_step(lfsr);
                A_fp[i*N+j] = lfsr_frac(lfsr) + 0.25;
                A_fp[j*N+i] = A_fp[i*N+j];
            end
        end
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1)
                A_nfe[i*N+j] = nfe_encode(A_fp[i*N+j]);

        // ── Same initial vector ────────────────────────────────────────────────
        for (j = 0; j < N; j = j + 1) begin
            lfsr  = lfsr_step(lfsr);
            y_g[j] = lfsr_frac(lfsr) + 0.1;
        end
        norm = 0.0;
        for (j = 0; j < N; j = j + 1) norm = norm + y_g[j] * y_g[j];
        norm = $sqrt(norm);
        for (j = 0; j < N; j = j + 1) begin
            y_g[j]        = y_g[j] / norm;
            y_nfe[j]      = nfe_encode(y_g[j]);
            y_g[j]        = nfe_decode(y_nfe[j]);
            y_dut_real[j] = y_g[j];
        end

        csv_fd = $fopen("BASELINE_POWER_ITER.csv", "w");
        $fwrite(csv_fd, "t,lambda_dut,lambda_gold,alignment\n");

        lambda_dut  = 0.0;
        lambda_gold = 0.0;
        dot_p       = 0.0;

        // ── 256 power iterations ─────────────────────────────────────────────
        for (t = 1; t <= DEPTH; t = t + 1) begin

            // Baseline DUT matvec: PATH_NFE — 8 MUL ops, each product is
            // re-quantised to 6-bit NFE; accumulate decoded products in FP64.
            // (Mirrors P2 behaviour from SSC validation, docs/SSC_RTL_VALIDATION.md)
            for (i = 0; i < N; i = i + 1) begin
                row_acc = 0.0;
                for (j = 0; j < N; j = j + 1) begin
                    @(negedge clk);
                    op_a      = A_nfe[i*N+j];
                    op_b      = y_nfe[j];
                    op_sel    = OP_MUL;
                    mode_tag  = MODE_STD;
                    accum_en  = 1'b0;
                    @(posedge clk); #1;
                    row_acc = row_acc + nfe_decode(result);  // decode quantised product
                end
                z_dut_real[i] = row_acc;  // row sum of 8 re-quantised products
            end

            // Golden matvec (FP64, independent of DUT)
            for (i = 0; i < N; i = i + 1) begin
                z_g[i] = 0.0;
                for (j = 0; j < N; j = j + 1)
                    z_g[i] = z_g[i] + A_fp[i*N+j] * y_g[j];
            end

            // Eigenvalue estimates: ‖Ay‖
            lambda_dut = 0.0;
            for (i = 0; i < N; i = i + 1)
                lambda_dut = lambda_dut + z_dut_real[i] * z_dut_real[i];
            lambda_dut = $sqrt(lambda_dut);

            lambda_gold = 0.0;
            for (i = 0; i < N; i = i + 1)
                lambda_gold = lambda_gold + z_g[i] * z_g[i];
            lambda_gold = $sqrt(lambda_gold);

            // Normalise golden
            for (i = 0; i < N; i = i + 1)
                y_g[i] = (lambda_gold > 0.0) ? z_g[i] / lambda_gold : z_g[i];

            // Normalise DUT (harness real arithmetic — identical procedure to PF18)
            if (lambda_dut > 0.0) begin
                for (i = 0; i < N; i = i + 1) begin
                    tmp           = z_dut_real[i] / lambda_dut;
                    y_nfe[i]      = nfe_encode(tmp);
                    y_dut_real[i] = nfe_decode(y_nfe[i]);
                end
            end

            // Alignment: |y_dut · y_gold|
            dot_p = 0.0;
            for (i = 0; i < N; i = i + 1)
                dot_p = dot_p + y_dut_real[i] * y_g[i];
            if (dot_p < 0.0) dot_p = -dot_p;

            $fwrite(csv_fd, "%0d,%0.6f,%0.6f,%0.6f\n",
                    t, lambda_dut, lambda_gold, dot_p);
        end

        $fclose(csv_fd);

        $display("========================================================");
        $display("tb_baseline_power_iteration  Baseline (PATH_NFE) Power Iteration");
        $display("  SEED_PI = 0x%08h   256 iterations", SEED_PI);
        $display("  Final lambda_dut  : %0.4f", lambda_dut);
        $display("  Final lambda_gold : %0.4f", lambda_gold);
        $display("  Final alignment   : %0.4f", dot_p);
        $display("  Output: BASELINE_POWER_ITER.csv");
        $display("========================================================");

        $finish;
    end

endmodule

`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_pf18_power_iteration
// Project  : Horus Geometry Fabric — PF18 Power Iteration
// File     : tb/tb_pf18_power_iteration.v
//
// Purpose
//   Drive horus_nfe_pf18 through the workload  y ← A·y / ‖y‖  for 256
//   iterations and measure convergence to the dominant eigenvector.
//
//   Division of labour (DUT vs harness):
//     DUT  — computes the matrix-vector product A·y using the PF18 protocol
//            (8 MUL ops per row accumulate into pf_accum; 1 NOP readout
//            produces NFE(pf_accum)).  All quantisation happens here.
//     Harness — decodes the 8 DUT outputs, computes ‖z‖ = ‖Ay‖ in FP64,
//            divides each component by ‖z‖ (real arithmetic), and re-encodes
//            the normalised vector to NFE for the next DUT step.
//            The golden path is entirely independent: FP64 matvec + FP64
//            normalisation; the DUT is never consulted for the golden path.
//
//   Eigenvalue estimate: ‖Ay‖ (norm of unnormalised output before
//   renormalisation).  Since ‖y‖=1 after each step, ‖Ay‖ = ‖y_{t+1}‖/‖y_t‖
//   and converges to the dominant eigenvalue λ_max.
//
//   Matrix: 8×8 symmetric positive, constructed from LFSR upper triangle
//   (SEED_PI = 32'hFACE_FEED), values in [0.25, 1.25).  All entries > 0
//   ensures Perron-Frobenius applies (unique positive dominant eigenvector).
//
//   Output: PF18_POWER_ITER.csv
//     columns: t, lambda_dut, lambda_gold, alignment
//     alignment = |normalised_y_dut · normalised_y_gold| ∈ [0, 1]
// ============================================================================

module tb_pf18_power_iteration;

    localparam CLK_PERIOD  = 10;
    localparam CLK_HALF    = CLK_PERIOD / 2;
    localparam DEPTH       = 256;
    localparam N           = 8;
    localparam EXP_BIAS    = 32;
    localparam EXP_MAX     = 63;
    localparam SEED_PI     = 32'hFACE_FEED;  // power-iteration seed (distinct from SSC)

    localparam [1:0] OP_MUL = 2'b10;
    localparam [1:0] OP_NOP = 2'b11;
    localparam [2:0] MODE_PF = 3'b100;  // mode_tag[2]=1: PATH_FAST

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

    // ── NFE helpers (verbatim from tb_horus_nfe_pf.v) ────────────────────────
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
    real        y_g   [0:7];        // golden unit vector
    reg  [12:0] y_nfe [0:7];        // DUT unit vector (NFE encoded)
    real        z_g   [0:7];        // golden unnormalised output (= A·y_g)
    reg  [12:0] z_nfe [0:7];        // DUT unnormalised output (= NOP readout)
    real        y_dut_real [0:7];   // DUT normalised vector decoded to real

    integer     i, j, t;
    real        norm, lambda_dut, lambda_gold, dot_p, tmp;
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

        // ── Build 8×8 symmetric positive matrix from LFSR upper triangle ────
        // Values in [0.25, 1.25).  A[i][j]=A[j][i]; all entries > 0
        // ensures Perron-Frobenius applies (unique dominant positive eigenvector).
        lfsr = SEED_PI;
        for (i = 0; i < N; i = i + 1) begin
            for (j = i; j < N; j = j + 1) begin
                lfsr = lfsr_step(lfsr);
                A_fp[i*N+j] = lfsr_frac(lfsr) + 0.25;
                A_fp[j*N+i] = A_fp[i*N+j];  // symmetric
            end
        end
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1)
                A_nfe[i*N+j] = nfe_encode(A_fp[i*N+j]);

        // ── Initial unit vector: generate from LFSR, normalise ───────────────
        // LFSR state continues from where matrix construction left off.
        for (j = 0; j < N; j = j + 1) begin
            lfsr  = lfsr_step(lfsr);
            y_g[j] = lfsr_frac(lfsr) + 0.1;  // all positive
        end
        norm = 0.0;
        for (j = 0; j < N; j = j + 1) norm = norm + y_g[j] * y_g[j];
        norm = $sqrt(norm);
        for (j = 0; j < N; j = j + 1) begin
            y_g[j]   = y_g[j] / norm;
            y_nfe[j] = nfe_encode(y_g[j]);
            // Both golden and DUT start from the same NFE-quantised initial state
            // so quantisation of the initial vector is shared.
            y_g[j]        = nfe_decode(y_nfe[j]);
            y_dut_real[j] = y_g[j];
        end

        csv_fd = $fopen("PF18_POWER_ITER.csv", "w");
        $fwrite(csv_fd, "t,lambda_dut,lambda_gold,alignment\n");

        lambda_dut  = 0.0;
        lambda_gold = 0.0;
        dot_p       = 0.0;

        // ── 256 power iterations ─────────────────────────────────────────────
        for (t = 1; t <= DEPTH; t = t + 1) begin

            // DUT matvec: PF18 protocol (8 MUL + 1 NOP per row)
            for (i = 0; i < N; i = i + 1) begin
                for (j = 0; j < N; j = j + 1) begin
                    @(negedge clk);
                    op_a      = A_nfe[i*N+j];
                    op_b      = y_nfe[j];
                    op_sel    = OP_MUL;
                    mode_tag  = MODE_PF;
                    accum_en  = 1'b0;
                    @(posedge clk); #1;
                end
                @(negedge clk);
                op_a     = 13'd0;
                op_b     = 13'd0;
                op_sel   = OP_NOP;
                mode_tag = MODE_PF;
                @(posedge clk); #1;
                z_nfe[i] = result;  // NFE(pf_accum) — unnormalised row sum
            end

            // Golden matvec (FP64, never touches DUT)
            for (i = 0; i < N; i = i + 1) begin
                z_g[i] = 0.0;
                for (j = 0; j < N; j = j + 1)
                    z_g[i] = z_g[i] + A_fp[i*N+j] * y_g[j];
            end

            // Eigenvalue estimates: ‖Ay‖ (norm of unnormalised output)
            // ‖Ay‖ = ‖y_{t+1}‖/‖y_t‖ = ‖y_{t+1}‖ since ‖y_t‖=1 → λ_max
            lambda_dut = 0.0;
            for (i = 0; i < N; i = i + 1) begin
                tmp = nfe_decode(z_nfe[i]);
                lambda_dut = lambda_dut + tmp * tmp;
            end
            lambda_dut = $sqrt(lambda_dut);

            lambda_gold = 0.0;
            for (i = 0; i < N; i = i + 1)
                lambda_gold = lambda_gold + z_g[i] * z_g[i];
            lambda_gold = $sqrt(lambda_gold);

            // Normalise golden
            for (i = 0; i < N; i = i + 1)
                y_g[i] = (lambda_gold > 0.0) ? z_g[i] / lambda_gold : z_g[i];

            // Normalise DUT (harness real arithmetic; re-encode to NFE)
            if (lambda_dut > 0.0) begin
                for (i = 0; i < N; i = i + 1) begin
                    tmp          = nfe_decode(z_nfe[i]) / lambda_dut;
                    y_nfe[i]     = nfe_encode(tmp);
                    y_dut_real[i] = nfe_decode(y_nfe[i]);
                end
            end

            // Alignment: |y_dut · y_gold| (both unit vectors after normalisation)
            dot_p = 0.0;
            for (i = 0; i < N; i = i + 1)
                dot_p = dot_p + y_dut_real[i] * y_g[i];
            if (dot_p < 0.0) dot_p = -dot_p;

            $fwrite(csv_fd, "%0d,%0.6f,%0.6f,%0.6f\n", t, lambda_dut, lambda_gold, dot_p);
        end

        $fclose(csv_fd);

        $display("========================================================");
        $display("tb_pf18_power_iteration  PF18 Power Iteration");
        $display("  SEED_PI = 0x%08h   256 iterations", SEED_PI);
        $display("  Final lambda_dut  : %0.4f", lambda_dut);
        $display("  Final lambda_gold : %0.4f", lambda_gold);
        $display("  Final alignment   : %0.4f", dot_p);
        $display("  Output: PF18_POWER_ITER.csv");
        $display("========================================================");

        $finish;
    end

endmodule

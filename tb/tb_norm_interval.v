`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_norm_interval
// Project  : Horus Geometry Fabric — Normalization-Interval RTL Confirmation
// File     : tb/tb_norm_interval.v  (clean rewrite)
//
// Three cells confirmed (LFSR chain 0, SEED_SSC_C0=0x9FAB5AA7, SEED_PI_C0=0x50753230):
//
//   Cell 1: SSC k=128   baseline  Python prediction mre = 0.5417%
//           CONFIRMED if RTL mre ≤ 2.0% (2× tolerance)
//
//   Cell 2: SSC k=∞     baseline  Python prediction mre = 24.6959%
//           CONFIRMED if RTL mre > 5.0% (both in failing regime)
//
//   Cell 3: PI  k=8     baseline  Python prediction alignment = 0.999981
//           CONFIRMED if RTL alignment ≥ 0.99
//
//   Division of labour: DUT (horus_nfe PATH_NFE) computes the matvec;
//   harness normalises in FP64 real arithmetic and never touches DUT internals.
// ============================================================================

module tb_norm_interval;

    localparam CLK_PERIOD = 10;
    localparam CLK_HALF   = CLK_PERIOD / 2;
    localparam DEPTH      = 256;
    localparam N          = 8;
    localparam EXP_BIAS   = 32;
    localparam EXP_MAX    = 63;

    localparam SEED_SSC_C0 = 32'h9FAB5AA7;
    localparam SEED_PI_C0  = 32'h50753230;

    localparam [1:0] OP_MUL  = 2'b10;
    localparam [2:0] MODE_STD = 3'b000;

    reg        clk;
    reg        rst_n;
    reg [12:0] op_a, op_b;
    reg [1:0]  op_sel;
    reg [2:0]  mode_tag;
    reg        accum_en, accum_clr;
    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag, underflow_flag, exp_ovf_flag;

    horus_nfe dut (
        .clk(clk), .rst_n(rst_n), .op_a(op_a), .op_b(op_b),
        .op_sel(op_sel), .mode_tag(mode_tag), .accum_en(accum_en),
        .accum_clr(accum_clr), .result(result), .accum_out(accum_out),
        .rollover_flag(rollover_flag), .underflow_flag(underflow_flag),
        .exp_ovf_flag(exp_ovf_flag)
    );
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    // ── NFE helpers ──────────────────────────────────────────────────────────
    function real nfe_decode;
        input [12:0] cw; integer s, e, f; real mag;
        begin
            s = cw[12]; e = cw[11:6]; f = cw[5:0];
            mag = (1.0 + $itor(f)/64.0) * $pow(2.0, $itor(e) - $itor(EXP_BIAS));
            nfe_decode = s ? -mag : mag;
        end
    endfunction

    function [12:0] nfe_encode;
        input real v; integer s, aE, eS, f; real av, m, l2;
        begin
            s = (v < 0.0) ? 1 : 0; av = (v < 0.0) ? -v : v;
            if (av == 0.0) nfe_encode = 13'd0;
            else begin
                l2 = $ln(av)/$ln(2.0); aE = $rtoi(l2);
                if (l2 < 0.0 && l2 != $itor(aE)) aE = aE - 1;
                m = av * $pow(2.0, $itor(-aE));
                if (m < 1.0)  begin aE = aE-1; m = m*2.0; end
                if (m >= 2.0) begin aE = aE+1; m = m*0.5; end
                if (aE < -EXP_BIAS) nfe_encode = s[0] ? 13'h1000 : 13'd0;
                else if (aE > (EXP_MAX-EXP_BIAS)) nfe_encode = s[0] ? 13'h1FFF : 13'h0FFF;
                else begin
                    eS = aE + EXP_BIAS; f = $rtoi((m-1.0)*64.0+0.5);
                    if (f < 0) f = 0;
                    if (f >= 64) begin f = 0; eS = eS+1;
                        nfe_encode = (eS > EXP_MAX) ?
                            (s[0] ? 13'h1FFF : 13'h0FFF) : {s[0], eS[5:0], 6'd0};
                    end else nfe_encode = {s[0], eS[5:0], f[5:0]};
                end
            end
        end
    endfunction

    function [31:0] lfsr_step;
        input [31:0] s;
        begin lfsr_step = {s[30:0], s[31]^s[21]^s[1]^s[0]}; end
    endfunction
    function real lfsr_frac;
        input [31:0] s;
        begin lfsr_frac = ({8'd0, s[31:8]} * 1.0) / 16777216.0; end
    endfunction

    // Module-level working storage (Verilog-2005 can't declare inside begin blocks)
    reg [31:0] lfsr_r;
    real A_fp [0:63]; reg [12:0] A_nfe [0:63];
    // Separate DUT and golden state arrays for each cell
    real   y_dut [0:7];  // DUT real state
    reg [12:0] y_dut_nfe [0:7];
    real   y_gld [0:7];  // golden state
    real   z_dut [0:7];  // DUT matvec output
    real   z_gld [0:7];  // golden matvec output

    integer ii, jj, tt;
    real nrm_d, nrm_g, mre_v, al_v, dp_v, tmp_v;

    // ── Matrix builders ──────────────────────────────────────────────────────
    task build_ssc;
        input [31:0] seed;
        real rs_v;
        begin
            lfsr_r = seed;
            for (ii = 0; ii < N; ii = ii+1) begin
                rs_v = 0.0;
                for (jj = 0; jj < N; jj = jj+1) begin
                    lfsr_r = lfsr_step(lfsr_r);
                    A_fp[ii*N+jj] = lfsr_frac(lfsr_r) + 0.01;
                    rs_v = rs_v + A_fp[ii*N+jj];
                end
                for (jj = 0; jj < N; jj = jj+1)
                    A_fp[ii*N+jj] = A_fp[ii*N+jj] / rs_v;
            end
            for (ii = 0; ii < N; ii = ii+1)
                for (jj = 0; jj < N; jj = jj+1)
                    A_nfe[ii*N+jj] = nfe_encode(A_fp[ii*N+jj]);
            for (jj = 0; jj < N; jj = jj+1) begin
                lfsr_r = lfsr_step(lfsr_r);
                y_gld[jj]     = lfsr_frac(lfsr_r) + 1.0;
                y_dut_nfe[jj] = nfe_encode(y_gld[jj]);
                y_gld[jj]     = nfe_decode(y_dut_nfe[jj]);   // quantise initial
                y_dut[jj]     = y_gld[jj];
            end
        end
    endtask

    task build_pi;
        input [31:0] seed;
        real norm_i;
        begin
            lfsr_r = seed;
            for (ii = 0; ii < N; ii = ii+1)
                for (jj = ii; jj < N; jj = jj+1) begin
                    lfsr_r = lfsr_step(lfsr_r);
                    A_fp[ii*N+jj] = lfsr_frac(lfsr_r) + 0.25;
                    A_fp[jj*N+ii] = A_fp[ii*N+jj];
                end
            for (ii = 0; ii < N; ii = ii+1)
                for (jj = 0; jj < N; jj = jj+1)
                    A_nfe[ii*N+jj] = nfe_encode(A_fp[ii*N+jj]);
            norm_i = 0.0;
            for (jj = 0; jj < N; jj = jj+1) begin
                lfsr_r = lfsr_step(lfsr_r);
                y_gld[jj] = lfsr_frac(lfsr_r) + 0.1;
                norm_i    = norm_i + y_gld[jj]*y_gld[jj];
            end
            norm_i = $sqrt(norm_i);
            for (jj = 0; jj < N; jj = jj+1) begin
                y_gld[jj]     = y_gld[jj] / norm_i;
                y_dut_nfe[jj] = nfe_encode(y_gld[jj]);
                y_gld[jj]     = nfe_decode(y_dut_nfe[jj]);
                y_dut[jj]     = y_gld[jj];
            end
        end
    endtask

    // ── Harness step: DUT matvec (PATH_NFE) ──────────────────────────────────
    // Issues 8 MUL ops per row; sums decoded products into z_dut[].
    // Uses global A_nfe and y_dut_nfe as inputs.
    task dut_matvec;
        begin
            for (ii = 0; ii < N; ii = ii+1) begin
                z_dut[ii] = 0.0;
                for (jj = 0; jj < N; jj = jj+1) begin
                    @(negedge clk);
                    op_a = A_nfe[ii*N+jj]; op_b = y_dut_nfe[jj];
                    op_sel = OP_MUL; mode_tag = MODE_STD; accum_en = 0;
                    @(posedge clk); #1;
                    z_dut[ii] = z_dut[ii] + nfe_decode(result);
                end
            end
        end
    endtask

    // ── Harness step: golden matvec (FP64) ───────────────────────────────────
    task golden_matvec;
        begin
            for (ii = 0; ii < N; ii = ii+1) begin
                z_gld[ii] = 0.0;
                for (jj = 0; jj < N; jj = jj+1)
                    z_gld[ii] = z_gld[ii] + A_fp[ii*N+jj] * y_gld[jj];
            end
        end
    endtask

    // ── Advance state (without normalisation) ─────────────────────────────────
    task advance_state;
        begin
            for (ii = 0; ii < N; ii = ii+1) begin
                y_dut_nfe[ii] = nfe_encode(z_dut[ii]);
                y_dut[ii]     = nfe_decode(y_dut_nfe[ii]);
                y_gld[ii]     = z_gld[ii];
            end
        end
    endtask

    // ── Harness normalisation ─────────────────────────────────────────────────
    // Normalises BOTH DUT and golden to unit norm in FP64 real arithmetic.
    task normalise;
        begin
            nrm_d = 0.0; nrm_g = 0.0;
            for (ii = 0; ii < N; ii = ii+1) begin
                nrm_d = nrm_d + z_dut[ii]*z_dut[ii];
                nrm_g = nrm_g + z_gld[ii]*z_gld[ii];
            end
            nrm_d = $sqrt(nrm_d); nrm_g = $sqrt(nrm_g);
            for (ii = 0; ii < N; ii = ii+1) begin
                z_dut[ii] = z_dut[ii] / nrm_d;
                z_gld[ii] = z_gld[ii] / nrm_g;
            end
        end
    endtask

    // ── Metric: mean relative error ───────────────────────────────────────────
    task compute_mre;
        begin
            mre_v = 0.0;
            for (ii = 0; ii < N; ii = ii+1) begin
                tmp_v = y_gld[ii]; if (tmp_v < 0.0) tmp_v = -tmp_v; if (tmp_v < 1e-10) tmp_v = 1e-10;
                dp_v  = y_dut[ii] - y_gld[ii]; if (dp_v < 0.0) dp_v = -dp_v;
                mre_v = mre_v + dp_v / tmp_v;
            end
            mre_v = mre_v / N * 100.0;
        end
    endtask

    // ── Metric: alignment ─────────────────────────────────────────────────────
    task compute_align;
        begin
            nrm_d = 0.0; nrm_g = 0.0;
            for (ii = 0; ii < N; ii = ii+1) begin
                nrm_d = nrm_d + y_dut[ii]*y_dut[ii];
                nrm_g = nrm_g + y_gld[ii]*y_gld[ii];
            end
            nrm_d = $sqrt(nrm_d); nrm_g = $sqrt(nrm_g);
            dp_v = 0.0;
            for (ii = 0; ii < N; ii = ii+1)
                dp_v = dp_v + (y_dut[ii]/nrm_d) * (y_gld[ii]/nrm_g);
            al_v = (dp_v < 0.0) ? -dp_v : dp_v;
        end
    endtask

    task dut_reset;
        begin
            rst_n = 0; repeat(4) @(posedge clk); @(negedge clk);
            rst_n = 1; @(posedge clk); #1;
        end
    endtask

    // ════════════════════════════════════════════════════════════════════════
    initial begin

        op_a = 0; op_b = 0; op_sel = 2'b11; mode_tag = 0;
        accum_en = 0; accum_clr = 0; rst_n = 0;

        // ================================================================
        // Cell 2: SSC k=∞  (no normalisation)
        // Python: mre = 24.6959%   CONFIRMED if > 5%
        // ================================================================
        $display("");
        $display("--- Cell 2: SSC k=inf (no normalisation) ---");
        dut_reset;
        build_ssc(SEED_SSC_C0);

        for (tt = 1; tt <= DEPTH; tt = tt+1) begin
            dut_matvec;
            golden_matvec;
            advance_state;   // no normalisation
        end
        compute_mre;
        $display("  DUT mre = %0.4f%%  Python = 24.6959%%  threshold: > 5%%", mre_v);
        if (mre_v > 5.0)
            $display("  CONFIRMED — RTL diverges without normalisation (mre=%0.4f%%)", mre_v);
        else
            $display("  NOT CONFIRMED — mre=%0.4f%% (expected > 5%%)", mre_v);

        // ================================================================
        // Cell 1: SSC k=128  (normalise at t=128)
        // Python: mre = 0.5417%    CONFIRMED if ≤ 2.0%
        // ================================================================
        $display("");
        $display("--- Cell 1: SSC k=128 (one normalisation at t=128) ---");
        dut_reset;
        build_ssc(SEED_SSC_C0);   // same seed as Cell 2 → same chain

        for (tt = 1; tt <= DEPTH; tt = tt+1) begin
            dut_matvec;
            golden_matvec;
            if (tt % 128 == 0) begin
                normalise;            // harness rescale every 128 steps (t=128, t=256)
                advance_state;
            end else begin
                advance_state;
            end
        end
        compute_mre;
        $display("  DUT mre = %0.4f%%  Python = 0.5417%%  threshold: ≤ 2.0%%", mre_v);
        if (mre_v <= 2.0)
            $display("  CONFIRMED — baseline+k=128 norm holds ≤ 2%% (mre=%0.4f%%)", mre_v);
        else
            $display("  NOT CONFIRMED — mre=%0.4f%% (expected ≤ 2.0%%)", mre_v);

        // ================================================================
        // Cell 3: PI k=8  (normalise every 8 steps)
        // Python: alignment = 0.999981   CONFIRMED if ≥ 0.99
        // ================================================================
        $display("");
        $display("--- Cell 3: PI k=8 (normalise every 8 steps) ---");
        dut_reset;
        build_pi(SEED_PI_C0);

        for (tt = 1; tt <= DEPTH; tt = tt+1) begin
            dut_matvec;
            golden_matvec;
            if (tt % 8 == 0) begin
                normalise;
                advance_state;
            end else begin
                advance_state;
            end
        end
        compute_align;
        $display("  DUT alignment = %0.6f  Python = 0.999981  threshold: ≥ 0.99", al_v);
        if (al_v >= 0.99)
            $display("  CONFIRMED — baseline+PI k=8 norm ≥ 0.99 alignment (%0.6f)", al_v);
        else
            $display("  NOT CONFIRMED — alignment=%0.6f (expected ≥ 0.99)", al_v);

        $display("");
        $display("========================================================");
        $display("tb_norm_interval  RTL Confirmation  (3 cells)");
        $display("========================================================");
        $finish;
    end

endmodule

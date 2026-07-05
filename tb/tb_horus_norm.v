`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_horus_norm
// File     : tb/tb_horus_norm.v
// Date     : 2026-07-05
//
// Purpose  : Verification testbench for rtl/horus_norm.v.
//
// Part A — Unit tests (horus_norm DUT only)
//   A1. Directed vectors: all-floor sentinel, near-OVF, max-finding corner cases.
//   A2. 1000 LFSR-random vectors vs Python golden (sim/EXPNORM_GOLDEN.dat).
//       Pass criterion: RTL output codeword == Python golden codeword (bitwise).
//       Report: mismatch count; verdict CONFIRMED (0 mismatches) /
//               NOT CONFIRMED.
//
// Part B — Integration tests (horus_norm + horus_nfe in feedback loop)
//   Division of labour:
//     DUT horus_nfe      : all matvec arithmetic (PATH_NFE).
//     DUT horus_norm     : block-exponent rescale (replaces FP64 unit-norm).
//     Harness            : matrix/vector setup, golden FP64 chain, metrics,
//                          sequencing, loop control.  Never touches DUT internals.
//   Golden computation uses exact FP64 unit-norm rescale (independent of DUT).
//   Metric for all cells: alignment (scale-invariant |ŷ_dut · ŷ_golden|)
//   as required for expnorm (docs/EXPNORM_RESULTS.md).
//
//   B1. SSC k=128: Python prediction alignment = 1.000000 (from EXPNORM_SWEEP.csv)
//       CONFIRMED if alignment ≥ 0.99.
//
//   B2. PI  k=8:   Python prediction alignment = 0.999994 (from EXPNORM_SWEEP.csv)
//       CONFIRMED if alignment ≥ 0.99.
//
//   B3. Hopfield smoke: 8-element Hopfield network (1 stored pattern).
//       Apply horus_norm to matvec output, then sign(). Verify sign() output
//       matches recall without normalisation (sign() is scale-invariant).
//       CONFIRMED if normalised-path matches direct-path exactly.
// ============================================================================

module tb_horus_norm;

    localparam CLK_PERIOD = 10;
    localparam CLK_HALF   = CLK_PERIOD / 2;
    localparam DEPTH      = 256;
    localparam N          = 8;
    localparam EXP_BIAS   = 32;
    localparam EXP_MAX    = 63;
    localparam N_GOLDEN   = 1000;

    localparam SEED_SSC_C0 = 32'h9FAB5AA7;
    localparam SEED_PI_C0  = 32'h50753230;

    localparam [1:0] OP_MUL   = 2'b10;
    localparam [2:0] MODE_STD = 3'b000;

    // ── Clock ──────────────────────────────────────────────────────────────
    reg clk;
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    // ── horus_nfe DUT (for Part B matvec) ────────────────────────────────
    reg  [12:0] nfe_op_a, nfe_op_b;
    reg  [1:0]  nfe_op_sel;
    reg  [2:0]  nfe_mode_tag;
    reg         nfe_accum_en, nfe_accum_clr;
    wire [12:0] nfe_result;
    wire [31:0] nfe_accum_out;
    wire        nfe_rollover, nfe_uf, nfe_ovf;
    reg         rst_n;

    horus_nfe dut_nfe (
        .clk(clk), .rst_n(rst_n),
        .op_a(nfe_op_a), .op_b(nfe_op_b),
        .op_sel(nfe_op_sel), .mode_tag(nfe_mode_tag),
        .accum_en(nfe_accum_en), .accum_clr(nfe_accum_clr),
        .result(nfe_result), .accum_out(nfe_accum_out),
        .rollover_flag(nfe_rollover), .underflow_flag(nfe_uf),
        .exp_ovf_flag(nfe_ovf)
    );

    // ── horus_norm DUT ────────────────────────────────────────────────────
    reg         norm_valid_in;
    reg  [12:0] norm_in_0, norm_in_1, norm_in_2, norm_in_3;
    reg  [12:0] norm_in_4, norm_in_5, norm_in_6, norm_in_7;
    wire        norm_valid_out;
    wire [12:0] norm_out_0, norm_out_1, norm_out_2, norm_out_3;
    wire [12:0] norm_out_4, norm_out_5, norm_out_6, norm_out_7;

    horus_norm #(.E_TARGET(6'd32)) dut_norm (
        .clk(clk), .rst_n(rst_n),
        .valid_in(norm_valid_in),
        .in_0(norm_in_0), .in_1(norm_in_1),
        .in_2(norm_in_2), .in_3(norm_in_3),
        .in_4(norm_in_4), .in_5(norm_in_5),
        .in_6(norm_in_6), .in_7(norm_in_7),
        .valid_out(norm_valid_out),
        .out_0(norm_out_0), .out_1(norm_out_1),
        .out_2(norm_out_2), .out_3(norm_out_3),
        .out_4(norm_out_4), .out_5(norm_out_5),
        .out_6(norm_out_6), .out_7(norm_out_7)
    );

    // ── NFE helpers (mirrors tb_norm_interval.v) ──────────────────────────
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

    // ── Storage ───────────────────────────────────────────────────────────
    reg [31:0] lfsr_r;
    real   A_fp  [0:63];
    reg [12:0] A_nfe [0:63];
    real   y_dut [0:7];
    reg [12:0] y_dut_nfe [0:7];
    real   y_gld [0:7];
    real   z_dut [0:7];
    real   z_gld [0:7];

    integer ii, jj, tt;
    real nrm_d, nrm_g, al_v, dp_v, tmp_v;

    integer mismatches;
    integer pass_count, fail_count;

    // ── Reset ─────────────────────────────────────────────────────────────
    task dut_reset;
        begin
            rst_n = 0; norm_valid_in = 0;
            nfe_op_a = 0; nfe_op_b = 0; nfe_op_sel = 2'b11; nfe_mode_tag = 0;
            nfe_accum_en = 0; nfe_accum_clr = 0;
            repeat(4) @(posedge clk); @(negedge clk);
            rst_n = 1; @(posedge clk); #1;
        end
    endtask

    // ── horus_norm application (drive DUT, wait 1 cycle) ─────────────────
    // Loads y_dut_nfe into normalizer inputs, fires valid_in, then reads
    // outputs on the posedge where valid_out is asserted (1-cycle latency).
    // Result stored back into y_dut_nfe and y_dut.
    task apply_horus_norm;
        begin
            @(negedge clk);
            norm_in_0 = y_dut_nfe[0]; norm_in_1 = y_dut_nfe[1];
            norm_in_2 = y_dut_nfe[2]; norm_in_3 = y_dut_nfe[3];
            norm_in_4 = y_dut_nfe[4]; norm_in_5 = y_dut_nfe[5];
            norm_in_6 = y_dut_nfe[6]; norm_in_7 = y_dut_nfe[7];
            norm_valid_in = 1;
            @(posedge clk); #1;
            // After 1 posedge: valid_out is asserted (registered), outputs valid.
            if (!norm_valid_out)
                $display("  WARNING: norm_valid_out not asserted after 1 cycle");
            // Capture outputs before clearing valid_in
            y_dut_nfe[0] = norm_out_0; y_dut_nfe[1] = norm_out_1;
            y_dut_nfe[2] = norm_out_2; y_dut_nfe[3] = norm_out_3;
            y_dut_nfe[4] = norm_out_4; y_dut_nfe[5] = norm_out_5;
            y_dut_nfe[6] = norm_out_6; y_dut_nfe[7] = norm_out_7;
            for (ii = 0; ii < N; ii = ii+1)
                y_dut[ii] = nfe_decode(y_dut_nfe[ii]);
            norm_valid_in = 0;
        end
    endtask

    // ── DUT matvec (PATH_NFE, mirrors tb_norm_interval.v) ─────────────────
    task dut_matvec;
        begin
            for (ii = 0; ii < N; ii = ii+1) begin
                z_dut[ii] = 0.0;
                for (jj = 0; jj < N; jj = jj+1) begin
                    @(negedge clk);
                    nfe_op_a = A_nfe[ii*N+jj]; nfe_op_b = y_dut_nfe[jj];
                    nfe_op_sel = OP_MUL; nfe_mode_tag = MODE_STD; nfe_accum_en = 0;
                    @(posedge clk); #1;
                    z_dut[ii] = z_dut[ii] + nfe_decode(nfe_result);
                end
            end
        end
    endtask

    task golden_matvec;
        begin
            for (ii = 0; ii < N; ii = ii+1) begin
                z_gld[ii] = 0.0;
                for (jj = 0; jj < N; jj = jj+1)
                    z_gld[ii] = z_gld[ii] + A_fp[ii*N+jj] * y_gld[jj];
            end
        end
    endtask

    // advance state without normalization
    task advance_state;
        begin
            for (ii = 0; ii < N; ii = ii+1) begin
                y_dut_nfe[ii] = nfe_encode(z_dut[ii]);
                y_dut[ii]     = nfe_decode(y_dut_nfe[ii]);
                y_gld[ii]     = z_gld[ii];
            end
        end
    endtask

    // Exact FP64 golden-only rescale (golden never touches DUT)
    task golden_rescale;
        begin
            nrm_g = 0.0;
            for (ii = 0; ii < N; ii = ii+1) nrm_g = nrm_g + y_gld[ii]*y_gld[ii];
            nrm_g = $sqrt(nrm_g);
            for (ii = 0; ii < N; ii = ii+1) y_gld[ii] = y_gld[ii] / nrm_g;
        end
    endtask

    // Alignment metric (scale-invariant)
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

    // ── Matrix builders (mirrors tb_norm_interval.v) ──────────────────────
    task build_ssc;
        input [31:0] seed; real rs_v;
        begin
            lfsr_r = seed;
            for (ii = 0; ii < N; ii = ii+1) begin
                rs_v = 0.0;
                for (jj = 0; jj < N; jj = jj+1) begin
                    lfsr_r = lfsr_step(lfsr_r);
                    A_fp[ii*N+jj] = lfsr_frac(lfsr_r) + 0.01;
                    rs_v = rs_v + A_fp[ii*N+jj];
                end
                for (jj = 0; jj < N; jj = jj+1) A_fp[ii*N+jj] = A_fp[ii*N+jj] / rs_v;
            end
            for (ii = 0; ii < N; ii = ii+1)
                for (jj = 0; jj < N; jj = jj+1)
                    A_nfe[ii*N+jj] = nfe_encode(A_fp[ii*N+jj]);
            for (jj = 0; jj < N; jj = jj+1) begin
                lfsr_r = lfsr_step(lfsr_r);
                y_gld[jj]     = lfsr_frac(lfsr_r) + 1.0;
                y_dut_nfe[jj] = nfe_encode(y_gld[jj]);
                y_gld[jj]     = nfe_decode(y_dut_nfe[jj]);
                y_dut[jj]     = y_gld[jj];
            end
        end
    endtask

    task build_pi;
        input [31:0] seed; real norm_i;
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

    // ══════════════════════════════════════════════════════════════════════
    // Test storage
    reg [12:0] test_in  [0:7];
    reg [12:0] test_out [0:7];
    reg [12:0] expected [0:7];
    integer    golden_idx, golden_emax, golden_off;

    // Directed unit test helpers
    task apply_norm_directed;
        begin
            @(negedge clk);
            norm_in_0 = test_in[0]; norm_in_1 = test_in[1];
            norm_in_2 = test_in[2]; norm_in_3 = test_in[3];
            norm_in_4 = test_in[4]; norm_in_5 = test_in[5];
            norm_in_6 = test_in[6]; norm_in_7 = test_in[7];
            norm_valid_in = 1;
            @(posedge clk); #1;
            norm_valid_in = 0;
            @(posedge clk); #1;
            test_out[0] = norm_out_0; test_out[1] = norm_out_1;
            test_out[2] = norm_out_2; test_out[3] = norm_out_3;
            test_out[4] = norm_out_4; test_out[5] = norm_out_5;
            test_out[6] = norm_out_6; test_out[7] = norm_out_7;
        end
    endtask

    // ── Integer scratch for $fscanf golden file ────────────────────────────
    integer gf_fd;
    integer gf_idx, gf_em, gf_off;
    integer gf_in0,gf_in1,gf_in2,gf_in3,gf_in4,gf_in5,gf_in6,gf_in7;
    integer gf_out0,gf_out1,gf_out2,gf_out3,gf_out4,gf_out5,gf_out6,gf_out7;
    integer gf_scan_n;
    integer gf_mismatch;

    // ── Hopfield smoke test storage ────────────────────────────────────────
    // 8-element Hopfield, 1 stored pattern p = [1,-1,1,-1,1,-1,1,-1]
    real    hop_W [0:63];     // 8×8 weight matrix
    reg [12:0] hop_W_nfe [0:63];
    reg [12:0] hop_s     [0:7];   // current state (NFE, ±1 encoded)
    real    hop_s_real   [0:7];
    real    hop_z_direct [0:7];   // matvec output (no norm path)
    real    hop_z_normed [0:7];   // matvec output (horus_norm path)
    reg [12:0] hop_z_nfe [0:7];   // NFE encoded z (for normalizer input)
    integer hop_sign_dir, hop_sign_nrm;
    integer hop_match;
    real    hop_pat [0:7];
    integer hop_ii, hop_jj;

    // ══════════════════════════════════════════════════════════════════════
    initial begin
        rst_n = 0; norm_valid_in = 0;
        nfe_op_a = 0; nfe_op_b = 0; nfe_op_sel = 2'b11; nfe_mode_tag = 0;
        nfe_accum_en = 0; nfe_accum_clr = 0;
        pass_count = 0; fail_count = 0;

        $display("");
        $display("=======================================================");
        $display("tb_horus_norm  Unit + Integration Tests");
        $display("=======================================================");

        // ════════════════════════════════════════════════════════
        // PART A1 — Directed unit tests
        // ════════════════════════════════════════════════════════
        $display("");
        $display("--- Part A1: Directed unit tests ---");
        dut_reset;

        // --- Test 1: All-floor sentinels (E=0 for all) ---
        // E_max = 0 → offset = 0 → outputs = inputs unchanged
        begin : t1
            integer k;
            for (k = 0; k < 8; k = k+1) test_in[k] = 13'h0000;
            apply_norm_directed;
            begin : chk1
                integer ok; ok = 1;
                for (k = 0; k < 8; k = k+1)
                    if (test_out[k] !== test_in[k]) ok = 0;
                if (ok) begin
                    $display("  T1 PASS: all-floor input → output unchanged");
                    pass_count = pass_count + 1;
                end else begin
                    $display("  T1 FAIL: all-floor input should be unchanged");
                    $display("         out[0]=%h in[0]=%h", test_out[0], test_in[0]);
                    fail_count = fail_count + 1;
                end
            end
        end

        // --- Test 2: All-same exponent E=32 (±1.0 values) ---
        // E_max=32, offset=32-32=0 → outputs = inputs unchanged
        begin : t2
            integer k;
            for (k = 0; k < 8; k = k+1)
                test_in[k] = {1'b0, 6'd32, 6'd0};   // +1.0 (s=0, E=32, f=0)
            apply_norm_directed;
            begin : chk2
                integer ok; ok = 1;
                for (k = 0; k < 8; k = k+1)
                    if (test_out[k] !== test_in[k]) ok = 0;
                if (ok) begin
                    $display("  T2 PASS: all E=32 (±1.0) → no offset → unchanged");
                    pass_count = pass_count + 1;
                end else begin
                    $display("  T2 FAIL: all E=32 → expected unchanged");
                    fail_count = fail_count + 1;
                end
            end
        end

        // --- Test 3: Max-finding — single large exponent ---
        // in[3] has E=50, others E=10; E_max=50, offset=32-50=-18
        // in[3]: E=50+(-18)=32, in[0]: E=10+(-18)=-8 → floor sentinel
        begin : t3
            integer k;
            for (k = 0; k < 8; k = k+1)
                test_in[k] = {1'b0, 6'd10, 6'd15};  // E=10, f=15
            test_in[3] = {1'b0, 6'd50, 6'd7};        // E=50, f=7 (max)
            apply_norm_directed;
            begin : chk3
                integer ok; ok = 1;
                // in[3]: E=50+(-18)=32, f=7 unchanged → {0, 32, 7}
                if (test_out[3] !== {1'b0, 6'd32, 6'd7}) begin
                    $display("  T3 FAIL: out[3]=%h expected={0,32,7}=%h",
                             test_out[3], {1'b0, 6'd32, 6'd7});
                    ok = 0;
                end
                // in[0..7 except 3]: E=10+(-18)=-8 < 0 → floor sentinel
                for (k = 0; k < 8; k = k+1) begin
                    if (k != 3) begin
                        if (test_out[k] !== {1'b0, 6'd0, 6'd0}) begin
                            $display("  T3 FAIL: out[%0d]=%h expected floor {0,0,0}=0",
                                     k, test_out[k]);
                            ok = 0;
                        end
                    end
                end
                if (ok) begin
                    $display("  T3 PASS: max-finding correct (E_max=50, offset=-18)");
                    pass_count = pass_count + 1;
                end else
                    fail_count = fail_count + 1;
            end
        end

        // --- Test 4: Near-OVF — large E_max close to min, causes overflow ---
        // in[7] has E=3 (E_max=3), others have E=1
        // offset = 32 - 3 = +29
        // in[7]: E=3+29=32 → normal
        // in[0..6]: E=1+29=30 → normal
        begin : t4
            integer k;
            for (k = 0; k < 8; k = k+1)
                test_in[k] = {1'b1, 6'd1, 6'd20};   // negative, E=1, f=20
            test_in[7] = {1'b0, 6'd3, 6'd0};         // E_max=3
            apply_norm_directed;
            begin : chk4
                integer ok; ok = 1;
                // in[7]: 3+29=32, f=0 → {0, 32, 0}
                if (test_out[7] !== {1'b0, 6'd32, 6'd0}) begin
                    $display("  T4 FAIL: out[7]=%h expected {0,32,0}=%h",
                             test_out[7], {1'b0, 6'd32, 6'd0});
                    ok = 0;
                end
                // in[0..6]: 1+29=30, f=20, sign=1 → {1, 30, 20}
                for (k = 0; k < 7; k = k+1) begin
                    if (test_out[k] !== {1'b1, 6'd30, 6'd20}) begin
                        $display("  T4 FAIL: out[%0d]=%h expected {1,30,20}=%h",
                                 k, test_out[k], {1'b1, 6'd30, 6'd20});
                        ok = 0;
                    end
                end
                if (ok) begin
                    $display("  T4 PASS: near-OVF offset +29 correct");
                    pass_count = pass_count + 1;
                end else
                    fail_count = fail_count + 1;
            end
        end

        // --- Test 5: UF clamp — E_max=35, offset=-3; elements with E=1 →
        //             new_e = 1+(-3) = -2 < 0 → UF floor sentinel {sign, 0, 0}
        //             Note: new_e=0 (exactly) keeps original f — floor only when strictly negative.
        begin : t5
            integer k;
            test_in[0] = {1'b0, 6'd35, 6'd63};   // E_max=35, f=63
            for (k = 1; k < 8; k = k+1)
                test_in[k] = {1'b0, 6'd1, 6'd5};  // E=1, f=5 → new_e=1-3=-2 → floor
            apply_norm_directed;
            begin : chk5
                integer ok; ok = 1;
                // in[0]: E=35+(-3)=32, f=63 → {0, 32, 63}
                if (test_out[0] !== {1'b0, 6'd32, 6'd63}) begin
                    $display("  T5 FAIL: out[0]=%h expected {0,32,63}=%h",
                             test_out[0], {1'b0, 6'd32, 6'd63});
                    ok = 0;
                end
                // in[1..7]: E=1+(-3)=-2 < 0 → UF floor sentinel {0, 0, 0}
                for (k = 1; k < 8; k = k+1) begin
                    if (test_out[k] !== {1'b0, 6'd0, 6'd0}) begin
                        $display("  T5 FAIL: out[%0d]=%h expected UF floor {0,0,0}=0",
                                 k, test_out[k]);
                        ok = 0;
                    end
                end
                if (ok) begin
                    $display("  T5 PASS: UF clamp (E=1, offset=-3 → new_e=-2 → floor)");
                    pass_count = pass_count + 1;
                end else
                    fail_count = fail_count + 1;
            end
        end

        // --- Test 6: Architectural property — OVF impossible with E_TARGET=32 ---
        // Proof: max new_e = E_max + (32 − E_max) = 32 ≤ 63. OVF is a safety guard.
        // Test: E_max=63, offset=-31; all elements E=63 → new_e=32 → normal (no OVF).
        begin : t6
            integer k;
            for (k = 0; k < 8; k = k+1)
                test_in[k] = {1'b0, 6'd63, 6'd63};   // max saturation input
            apply_norm_directed;
            begin : chk6
                integer ok; ok = 1;
                // E_max=63, offset=-31, all new_e=63-31=32 → {0, 32, 63}
                for (k = 0; k < 8; k = k+1) begin
                    if (test_out[k] !== {1'b0, 6'd32, 6'd63}) begin
                        $display("  T6 FAIL: out[%0d]=%h expected {0,32,63}=%h",
                                 k, test_out[k], {1'b0, 6'd32, 6'd63});
                        ok = 0;
                    end
                end
                if (ok) begin
                    $display("  T6 PASS: all-E=63 input → rescaled to E=32 (max result=32, no OVF)");
                    pass_count = pass_count + 1;
                end else
                    fail_count = fail_count + 1;
            end
        end

        // --- Test 7: Mixed signs, verify sign preservation ---
        // in = [+1.0, -2.0, +0.5, -0.5, +1.0, -1.0, +2.0, -2.0]
        // E = [32, 33, 31, 31, 32, 32, 33, 33]  E_max=33, offset=-1
        // new_e = [31, 32, 30, 30, 31, 31, 32, 32], f unchanged, sign preserved
        begin : t7
            test_in[0] = {1'b0, 6'd32, 6'd0};   // +1.0
            test_in[1] = {1'b1, 6'd33, 6'd0};   // -2.0
            test_in[2] = {1'b0, 6'd31, 6'd0};   // +0.5
            test_in[3] = {1'b1, 6'd31, 6'd0};   // -0.5
            test_in[4] = {1'b0, 6'd32, 6'd0};   // +1.0
            test_in[5] = {1'b1, 6'd32, 6'd0};   // -1.0
            test_in[6] = {1'b0, 6'd33, 6'd0};   // +2.0
            test_in[7] = {1'b1, 6'd33, 6'd0};   // -2.0
            apply_norm_directed;
            begin : chk7
                integer ok; ok = 1;
                // E_max=33, offset=-1; all new_e = original_e - 1; signs preserved
                if (test_out[0] !== {1'b0, 6'd31, 6'd0}) ok = 0;  // +0.5
                if (test_out[1] !== {1'b1, 6'd32, 6'd0}) ok = 0;  // -1.0
                if (test_out[2] !== {1'b0, 6'd30, 6'd0}) ok = 0;  // +0.25
                if (test_out[3] !== {1'b1, 6'd30, 6'd0}) ok = 0;  // -0.25
                if (test_out[4] !== {1'b0, 6'd31, 6'd0}) ok = 0;  // +0.5
                if (test_out[5] !== {1'b1, 6'd31, 6'd0}) ok = 0;  // -0.5
                if (test_out[6] !== {1'b0, 6'd32, 6'd0}) ok = 0;  // +1.0
                if (test_out[7] !== {1'b1, 6'd32, 6'd0}) ok = 0;  // -1.0
                if (ok) begin
                    $display("  T7 PASS: mixed signs preserved; offset=-1 correct");
                    pass_count = pass_count + 1;
                end else begin
                    $display("  T7 FAIL: sign or exponent mismatch");
                    $display("         out={%h %h %h %h %h %h %h %h}",
                             test_out[0],test_out[1],test_out[2],test_out[3],
                             test_out[4],test_out[5],test_out[6],test_out[7]);
                    fail_count = fail_count + 1;
                end
            end
        end

        // ════════════════════════════════════════════════════════
        // PART A2 — 1000 LFSR-random vectors vs Python golden
        // ════════════════════════════════════════════════════════
        $display("");
        $display("--- Part A2: 1000 LFSR-random vectors vs EXPNORM_GOLDEN.dat ---");
        gf_fd = $fopen("EXPNORM_GOLDEN.dat", "r");
        if (gf_fd == 0) begin
            $display("  ERROR: Cannot open EXPNORM_GOLDEN.dat — skipping A2");
            fail_count = fail_count + 1;
        end else begin
            gf_mismatch = 0;
            begin : golden_loop
                integer gi;
                for (gi = 0; gi < N_GOLDEN; gi = gi + 1) begin
                    gf_scan_n = $fscanf(gf_fd,
                        "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                        gf_idx, gf_em, gf_off,
                        gf_in0, gf_in1, gf_in2, gf_in3,
                        gf_in4, gf_in5, gf_in6, gf_in7,
                        gf_out0, gf_out1, gf_out2, gf_out3,
                        gf_out4, gf_out5, gf_out6, gf_out7);
                    if (gf_scan_n != 19) begin
                        $display("  WARNING: $fscanf read %0d fields at idx %0d (expected 19)", gf_scan_n, gi);
                    end else begin
                        test_in[0] = gf_in0[12:0]; test_in[1] = gf_in1[12:0];
                        test_in[2] = gf_in2[12:0]; test_in[3] = gf_in3[12:0];
                        test_in[4] = gf_in4[12:0]; test_in[5] = gf_in5[12:0];
                        test_in[6] = gf_in6[12:0]; test_in[7] = gf_in7[12:0];
                        apply_norm_directed;
                        if (test_out[0] !== gf_out0[12:0] ||
                            test_out[1] !== gf_out1[12:0] ||
                            test_out[2] !== gf_out2[12:0] ||
                            test_out[3] !== gf_out3[12:0] ||
                            test_out[4] !== gf_out4[12:0] ||
                            test_out[5] !== gf_out5[12:0] ||
                            test_out[6] !== gf_out6[12:0] ||
                            test_out[7] !== gf_out7[12:0]) begin
                            if (gf_mismatch < 5) begin
                                $display("  MISMATCH idx=%0d: out={%h %h %h %h %h %h %h %h}",
                                    gf_idx,
                                    test_out[0],test_out[1],test_out[2],test_out[3],
                                    test_out[4],test_out[5],test_out[6],test_out[7]);
                                $display("           exp={%h %h %h %h %h %h %h %h}",
                                    gf_out0[12:0],gf_out1[12:0],gf_out2[12:0],gf_out3[12:0],
                                    gf_out4[12:0],gf_out5[12:0],gf_out6[12:0],gf_out7[12:0]);
                            end
                            gf_mismatch = gf_mismatch + 1;
                        end
                    end
                end
            end
            $fclose(gf_fd);
            if (gf_mismatch == 0) begin
                $display("  A2 CONFIRMED: 0 mismatches in %0d random vectors", N_GOLDEN);
                pass_count = pass_count + 1;
            end else begin
                $display("  A2 NOT CONFIRMED: %0d/%0d vectors mismatched",
                         gf_mismatch, N_GOLDEN);
                fail_count = fail_count + 1;
            end
        end

        // ════════════════════════════════════════════════════════
        // PART B1 — Integration: SSC k=128 with horus_norm DUT
        // Python prediction: alignment = 1.000000 (EXPNORM_SWEEP.csv)
        // CONFIRMED if alignment ≥ 0.99
        // ════════════════════════════════════════════════════════
        $display("");
        $display("--- Part B1: SSC k=128 with horus_norm DUT ---");
        dut_reset;
        build_ssc(SEED_SSC_C0);

        for (tt = 1; tt <= DEPTH; tt = tt+1) begin
            dut_matvec;
            golden_matvec;
            if (tt % 128 == 0) begin
                // horus_norm DUT rescales y_dut_nfe (updates y_dut too)
                for (ii = 0; ii < N; ii = ii+1) begin
                    y_dut_nfe[ii] = nfe_encode(z_dut[ii]);
                    y_dut[ii]     = nfe_decode(y_dut_nfe[ii]);
                end
                apply_horus_norm;
                // Golden: exact FP64 unit-norm rescale (independent)
                for (ii = 0; ii < N; ii = ii+1) y_gld[ii] = z_gld[ii];
                golden_rescale;
            end else begin
                advance_state;
            end
        end
        compute_align;
        $display("  DUT alignment = %0.6f  Python = 1.000000  threshold: >= 0.99", al_v);
        if (al_v >= 0.99) begin
            $display("  B1 CONFIRMED — SSC k=128 expnorm ≥ 0.99 alignment (%0.6f)", al_v);
            pass_count = pass_count + 1;
        end else begin
            $display("  B1 NOT CONFIRMED — alignment=%0.6f (expected ≥ 0.99)", al_v);
            fail_count = fail_count + 1;
        end

        // ════════════════════════════════════════════════════════
        // PART B2 — Integration: PI k=8 with horus_norm DUT
        // Python prediction: alignment = 0.999994 (EXPNORM_SWEEP.csv)
        // CONFIRMED if alignment ≥ 0.99
        // ════════════════════════════════════════════════════════
        $display("");
        $display("--- Part B2: PI k=8 with horus_norm DUT ---");
        dut_reset;
        build_pi(SEED_PI_C0);

        for (tt = 1; tt <= DEPTH; tt = tt+1) begin
            dut_matvec;
            golden_matvec;
            if (tt % 8 == 0) begin
                for (ii = 0; ii < N; ii = ii+1) begin
                    y_dut_nfe[ii] = nfe_encode(z_dut[ii]);
                    y_dut[ii]     = nfe_decode(y_dut_nfe[ii]);
                end
                apply_horus_norm;
                for (ii = 0; ii < N; ii = ii+1) y_gld[ii] = z_gld[ii];
                golden_rescale;
            end else begin
                advance_state;
            end
        end
        compute_align;
        $display("  DUT alignment = %0.6f  Python = 0.999994  threshold: >= 0.99", al_v);
        if (al_v >= 0.99) begin
            $display("  B2 CONFIRMED — PI k=8 expnorm ≥ 0.99 alignment (%0.6f)", al_v);
            pass_count = pass_count + 1;
        end else begin
            $display("  B2 NOT CONFIRMED — alignment=%0.6f (expected ≥ 0.99)", al_v);
            fail_count = fail_count + 1;
        end

        // ════════════════════════════════════════════════════════
        // PART B3 — Hopfield smoke: horus_norm before sign()
        // 8-element Hopfield, pattern p = [1,-1,1,-1,1,-1,1,-1]
        // One update: z = W·s_corrupted; compare sign(z) vs sign(norm(z))
        // sign() is scale-invariant → results must match exactly.
        // CONFIRMED if all 8 neurons agree.
        // ════════════════════════════════════════════════════════
        $display("");
        $display("--- Part B3: Hopfield smoke (horus_norm before sign) ---");
        dut_reset;

        // Build 8-element Hopfield weight matrix W = p·pᵀ / N, zero diagonal
        // p = [1,-1,1,-1,1,-1,1,-1]
        for (hop_ii = 0; hop_ii < 8; hop_ii = hop_ii+1) begin
            hop_pat[hop_ii] = (hop_ii % 2 == 0) ? 1.0 : -1.0;
        end
        for (hop_ii = 0; hop_ii < 8; hop_ii = hop_ii+1)
            for (hop_jj = 0; hop_jj < 8; hop_jj = hop_jj+1) begin
                if (hop_ii == hop_jj)
                    hop_W[hop_ii*8+hop_jj] = 0.0;
                else
                    hop_W[hop_ii*8+hop_jj] = hop_pat[hop_ii] * hop_pat[hop_jj] / 8.0;
                hop_W_nfe[hop_ii*8+hop_jj] = nfe_encode(hop_W[hop_ii*8+hop_jj]);
            end

        // Corrupted state: flip neuron 2 (0→-1 instead of 1)
        // s = [1,-1,-1,-1,1,-1,1,-1]
        hop_s[0] = nfe_encode( 1.0); hop_s[1] = nfe_encode(-1.0);
        hop_s[2] = nfe_encode(-1.0); hop_s[3] = nfe_encode(-1.0);
        hop_s[4] = nfe_encode( 1.0); hop_s[5] = nfe_encode(-1.0);
        hop_s[6] = nfe_encode( 1.0); hop_s[7] = nfe_encode(-1.0);

        // Load hop_W into A_nfe and hop_s into y_dut_nfe
        for (hop_ii = 0; hop_ii < 8; hop_ii = hop_ii+1) begin
            A_fp[hop_ii*8+hop_jj] = 0.0;  // not used for this path
            for (hop_jj = 0; hop_jj < 8; hop_jj = hop_jj+1)
                A_nfe[hop_ii*8+hop_jj] = hop_W_nfe[hop_ii*8+hop_jj];
        end
        for (ii = 0; ii < N; ii = ii+1) begin
            y_dut_nfe[ii] = hop_s[ii];
            y_dut[ii]     = nfe_decode(hop_s[ii]);
        end

        // Path 1 (direct): compute z = W·s via DUT, then sign(z)
        dut_matvec;
        for (hop_ii = 0; hop_ii < 8; hop_ii = hop_ii+1)
            hop_z_direct[hop_ii] = z_dut[hop_ii];

        // Path 2 (normalised): encode z to NFE, apply horus_norm, then sign
        for (ii = 0; ii < N; ii = ii+1) begin
            y_dut_nfe[ii] = nfe_encode(z_dut[ii]);
            y_dut[ii]     = nfe_decode(y_dut_nfe[ii]);
        end
        apply_horus_norm;   // horus_norm applied to z (stored in y_dut after apply)
        for (hop_ii = 0; hop_ii < 8; hop_ii = hop_ii+1)
            hop_z_normed[hop_ii] = y_dut[hop_ii];

        // Compare sign() of both paths
        hop_match = 1;
        for (hop_ii = 0; hop_ii < 8; hop_ii = hop_ii+1) begin
            hop_sign_dir = (hop_z_direct[hop_ii] >= 0.0) ? 1 : -1;
            hop_sign_nrm = (hop_z_normed[hop_ii] >= 0.0) ? 1 : -1;
            if (hop_sign_dir !== hop_sign_nrm) begin
                $display("  B3 sign mismatch at neuron %0d: direct=%0d normed=%0d (z_d=%f z_n=%f)",
                    hop_ii, hop_sign_dir, hop_sign_nrm,
                    hop_z_direct[hop_ii], hop_z_normed[hop_ii]);
                hop_match = 0;
            end
        end
        if (hop_match) begin
            $display("  B3 CONFIRMED — sign(z)==sign(norm(z)) for all 8 neurons");
            pass_count = pass_count + 1;
        end else begin
            $display("  B3 NOT CONFIRMED — sign mismatch after horus_norm");
            fail_count = fail_count + 1;
        end

        // ════════════════════════════════════════════════════════
        // Summary
        // ════════════════════════════════════════════════════════
        $display("");
        $display("=======================================================");
        $display("tb_horus_norm  Summary");
        $display("  Pass: %0d   Fail: %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("  OVERALL: ALL TESTS PASSED");
        else
            $display("  OVERALL: %0d TEST(S) FAILED", fail_count);
        $display("=======================================================");
        $finish;
    end

endmodule

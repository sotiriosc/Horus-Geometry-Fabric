`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_second_source_chain
// Project  : Horus Geometry Fabric — Second-Source RTL Chain Confirmation
// File     : tb/tb_second_source_chain.v
//
// Purpose
//   RTL confirmation of predictions from sim/second_source_chain.py.
//   Runs y ← A·y deep-feedback chains through the ACTUAL horus_nfe.v
//   datapath (not a behavioral re-model) for three spectral regimes ×
//   256 depth cycles each.
//
// RTL Datapath Constraint  ─ ARCHITECTURAL GAP  ─ documented here per spec
// -----------------------------------------------------------------------
// horus_nfe.v exposes four operation codes (lines 72-75):
//   2'b00  ADD_FRAC  fraction-only addition at op_a's exponent
//   2'b01  SUB_FRAC  fraction-only subtraction with normalisation
//   2'b10  MUL       full hidden-bit multiply
//   2'b11  NOP       pass-through
//
// The MUL operation (lines 494-536) computes:
//   P = {1, m_a} × {1, m_b}                               (14-bit product)
//   f_result = P[12:7] (P[13]=1) or P[11:6] (P[13]=0)     (6-BIT QUANTIZED)
//
// This maps EXACTLY to PATH_NFE in second_source_chain.py:
//   nfe_mul() uses the same P[13]/P[12:7]/P[11:6] logic.
//
// PATH_FAST from second_source_chain.py — which keeps the full 14-bit
// mantissa product without intermediate quantization — is NOT implementable
// via any existing op_sel value in horus_nfe.v without RTL modification.
// A full-mantissa path would need to expose the 14-bit scale_reg output
// (horus_nfe.v line 502), which has no corresponding port in the module.
//
// CONSEQUENCE:
//   This testbench exercises ONE path only: PATH_NFE (6-bit-quantized MUL).
//   Prediction 1 (PATH_FAST holds ≤1% error through 256 neutral cycles) is
//   NOT TESTABLE from this RTL and is reported as NOT CONFIRMED
//   (ARCHITECTURAL GAP) by analyze_second_source_chain.py.
//   Predictions 2 and 3 are the only falsifiable claims for this RTL.
//
// DUT: horus_nfe  (MUL op only; accum_en=0 throughout)
//
// CSV output  → sim/SSC_CHAIN_TRACE.csv  (run from sim/ via make ssc_chain)
//   Columns: cycle, regime,
//            dut_y0..dut_y7  (decoded from RTL result),
//            golden_y0..golden_y7  (FP64, never re-encoded),
//            mean_rel_err (%), cum_sat, cum_floor
//
// LFSR: same Galois polynomial as tb_fidelity_benchmark.v (taps 32,22,2,1)
//       but different seed (CAFE_F00D vs DEAD_BEEF) → independent sequences.
//
// Boundary constants (same sources as nfe_matvec2.c):
//   E_ANCHOR_LO = 28  ← HBS-12D log line 171: info-retention seed range low
//   E_ANCHOR_HI = 35  ← HBS-12D log line 171: info-retention seed range high
//
// Run:
//   cd sim && make sim_ssc_chain && vvp sim_ssc_chain
//   python3 analyze_second_source_chain.py
// ============================================================================

module tb_second_source_chain;

    localparam CLK_PERIOD  = 10;
    localparam CLK_HALF    = CLK_PERIOD / 2;
    localparam DEPTH       = 256;        // feedback chain depth per regime
    localparam N           = 8;          // matrix/vector dimension
    localparam EXP_BIAS    = 32;
    localparam EXP_MAX     = 63;
    localparam E_ANCHOR_LO = 28;         // HBS-12D log line 171
    localparam E_ANCHOR_HI = 35;         // HBS-12D log line 171
    localparam SEED        = 32'hCAFE_F00D; // independent from fidelity benchmark

    localparam [1:0] OP_MUL = 2'b10;
    localparam [1:0] OP_NOP = 2'b11;

    // ── DUT interface ────────────────────────────────────────────────────────
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

    // ── Clock ────────────────────────────────────────────────────────────────
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // NFE arithmetic helpers
    // =========================================================================

    // nfe_decode: V = (−1)^S × 2^(E−32) × (1 + f/64)
    // IMPORTANT: exponent argument to $pow must be cast with $itor() to force
    // signed real promotion.  Without it, Icarus passes the negative integer
    // as an unsigned 32-bit value (e.g. -4 → 4294967292) → Inf result.
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

    // nfe_encode: real → 13-bit NFE codeword
    // Uses $ln for O(1) binary-exponent computation — no while loops and no
    // $realtobits (which is unreliable inside functions in Icarus Verilog).
    // Floor correction: $rtoi truncates toward zero, so negative log2 values
    // need a floor adjustment.
    // Matches nfe_enc() in second_source_chain.py; minor rounding difference
    // ($rtoi round-half-up vs Python banker's round) only at exact half-integer
    // mantissa — rare, within tolerance.
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
                // log2(av) via ln — O(1), no loops
                log2_av = $ln(av) / $ln(2.0);
                // Truncation toward zero; correct to floor for negative values
                aE = $rtoi(log2_av);
                if (log2_av < 0.0 && (log2_av != $itor(aE)))
                    aE = aE - 1;
                // m = av / 2^aE should now be in [1, 2)
                m = av * $pow(2.0, $itor(-aE));
                // One-step jitter correction for FP boundary cases
                if (m < 1.0)  begin aE = aE - 1; m = m * 2.0; end
                if (m >= 2.0) begin aE = aE + 1; m = m * 0.5; end
                // NFE range guards
                if (aE < -EXP_BIAS) begin
                    nfe_encode = s[0] ? 13'h1000 : 13'd0;    // floor
                end else if (aE > (EXP_MAX - EXP_BIAS)) begin
                    nfe_encode = s[0] ? 13'h1FFF : 13'h0FFF; // saturate
                end else begin
                    eS = aE + EXP_BIAS;
                    f  = $rtoi((m - 1.0) * 64.0 + 0.5);      // round-to-nearest
                    if (f < 0)  f = 0;                        // FP jitter guard
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

    // ── LFSR-32 Galois (taps 32,22,2,1) — same polynomial as tb_fidelity_benchmark.v
    function [31:0] lfsr_step;
        input [31:0] s;
        begin
            lfsr_step = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
        end
    endfunction

    // Convert upper 24 bits of LFSR state to real in [0, 1)
    function real lfsr_frac;
        input [31:0] s;
        begin
            lfsr_frac = ({8'd0, s[31:8]} * 1.0) / 16777216.0;
        end
    endfunction

    // =========================================================================
    // Working storage (1-D flattened; A[i][j] → A_fp[i*N+j])
    // =========================================================================
    reg  [31:0] lfsr;
    integer     csv_fd;

    real        A_fp  [0:63];   // real-valued A matrix
    reg  [12:0] A_nfe [0:63];   // NFE-encoded A matrix
    real        y_g   [0:7];    // FP64 golden state (never re-encoded)
    reg  [12:0] y_nfe [0:7];    // DUT state (NFE codewords, re-encoded each step)
    real        new_g [0:7];    // scratch for golden step update
    real        acc_dut[0:7];   // per-row FP64 accumulator for decoded MUL outputs

    integer     onset_cycle [0:2];
    real        final_err   [0:2];
    integer     cum_sat     [0:2];
    integer     cum_floor   [0:2];

    // Loop / temp variables (module-level for Verilog-2001)
    integer r, i, j, t;
    integer sat_step, floor_step, valid_cnt;
    real    rowsum, target_rowsum, fval;
    real    err_sum, mean_err, gi, di, re;
    reg [12:0] cw_enc;

    // =========================================================================
    initial begin : main

        // ── Default signal values ─────────────────────────────────────────────
        rst_n     = 1'b0;
        op_a      = 13'd0;
        op_b      = 13'd0;
        op_sel    = OP_NOP;
        mode_tag  = 3'b000;    // MODE_STANDARD
        accum_en  = 1'b0;
        accum_clr = 1'b0;

        // ── Open CSV ──────────────────────────────────────────────────────────
        csv_fd = $fopen("SSC_CHAIN_TRACE.csv", "w");
        if (csv_fd == 0) begin
            $display("ERROR: cannot open SSC_CHAIN_TRACE.csv");
            $finish(1);
        end
        $fdisplay(csv_fd, "cycle,regime,dut_y0,dut_y1,dut_y2,dut_y3,dut_y4,dut_y5,dut_y6,dut_y7,golden_y0,golden_y1,golden_y2,golden_y3,golden_y4,golden_y5,golden_y6,golden_y7,mean_rel_err,cum_sat,cum_floor");

        // ── Reset DUT ─────────────────────────────────────────────────────────
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;  // one idle cycle post-reset

        // =========================================================================
        // Main loop: three spectral regimes
        //   r=0: contractive (row_sum=0.90)
        //   r=1: neutral     (row_sum=1.00)
        //   r=2: expansive   (row_sum=1.10)
        // =========================================================================
        for (r = 0; r < 3; r = r + 1) begin

            case (r)
                0: target_rowsum = 0.90;
                1: target_rowsum = 1.00;
                2: target_rowsum = 1.10;
            endcase

            // Deterministic per-regime seed (independent sequences)
            lfsr = SEED ^ (r * 32'h1111_1111 + 32'h5555_AAAA);

            // ── Generate A matrix ──────────────────────────────────────────────
            // Random values in (0,1), normalized so each row sums to target_rowsum.
            // A_fp: used for FP64 golden path.  A_nfe: encoded for DUT MUL path.
            for (i = 0; i < N; i = i + 1) begin
                rowsum = 0.0;
                for (j = 0; j < N; j = j + 1) begin
                    lfsr = lfsr_step(lfsr);
                    A_fp[i*N+j] = lfsr_frac(lfsr) + 1e-3; // keep strictly > 0
                    rowsum = rowsum + A_fp[i*N+j];
                end
                for (j = 0; j < N; j = j + 1) begin
                    A_fp[i*N+j] = A_fp[i*N+j] / rowsum * target_rowsum;
                    A_nfe[i*N+j] = nfe_encode(A_fp[i*N+j]);
                end
            end

            // ── Generate initial state vector ──────────────────────────────────
            // LFSR-derived fractions at stored_E=32 (actual 2^0 = 1.0 scale).
            // Both golden and DUT start from the same NFE-quantized initial value
            // (golden is seeded from nfe_decode of the initial codeword — the
            // same choice as second_source_chain.py: x_fp then nfe_enc then decode).
            for (j = 0; j < N; j = j + 1) begin
                lfsr       = lfsr_step(lfsr);
                fval       = 1.0 + (lfsr[5:0] * 1.0) / 64.0; // 1.000..1.984
                y_nfe[j]   = nfe_encode(fval);
                y_g[j]     = nfe_decode(y_nfe[j]); // golden starts from quantized state
            end

            // ── Init per-regime tracking ───────────────────────────────────────
            onset_cycle[r] = DEPTH + 1; // sentinel: "never diverged within DEPTH"
            cum_sat[r]     = 0;
            cum_floor[r]   = 0;

            // ── 256-cycle feedback chain ───────────────────────────────────────
            for (t = 1; t <= DEPTH; t = t + 1) begin

                sat_step   = 0;
                floor_step = 0;

                // ── DUT path ───────────────────────────────────────────────────
                // 8 rows × 8 columns = 64 RTL MUL operations.
                // Each op_sel=2'b10 produces a 6-bit-quantized 13-bit result
                // (horus_nfe.v lines 494-536).  Decoded products accumulate in
                // FP64 — same as PATH_NFE in second_source_chain.py.
                // y_nfe[] is NOT updated until after all rows complete, so all
                // rows multiply against the same old state (correct for A·y).
                for (i = 0; i < N; i = i + 1) begin
                    acc_dut[i] = 0.0;
                    for (j = 0; j < N; j = j + 1) begin
                        @(negedge clk);
                        op_a   = A_nfe[i*N+j];
                        op_b   = y_nfe[j];
                        op_sel = OP_MUL;
                        @(posedge clk); #1; // NBA settle
                        acc_dut[i] = acc_dut[i] + nfe_decode(result);
                    end
                end

                // Re-encode DUT state for next step; count sentinels
                for (i = 0; i < N; i = i + 1) begin
                    cw_enc    = nfe_encode(acc_dut[i]);
                    y_nfe[i]  = cw_enc;
                    if (cw_enc[11:6] == 6'd63 && cw_enc[5:0] == 6'd63)
                        sat_step   = sat_step   + 1;
                    if (cw_enc[11:6] == 6'd0  && cw_enc[5:0] == 6'd0)
                        floor_step = floor_step + 1;
                end
                cum_sat[r]   = cum_sat[r]   + sat_step;
                cum_floor[r] = cum_floor[r] + floor_step;

                // ── Golden path ────────────────────────────────────────────────
                // FP64 A_fp × y_g — never re-encoded.  This is the independent
                // second source, must stay free of NFE quantization.
                for (i = 0; i < N; i = i + 1) begin
                    new_g[i] = 0.0;
                    for (j = 0; j < N; j = j + 1)
                        new_g[i] = new_g[i] + A_fp[i*N+j] * y_g[j];
                end
                for (i = 0; i < N; i = i + 1) y_g[i] = new_g[i];

                // ── Mean relative error ────────────────────────────────────────
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

                if ((onset_cycle[r] > DEPTH) && (mean_err > 1.0))
                    onset_cycle[r] = t;
                final_err[r] = mean_err;

                // ── CSV row ────────────────────────────────────────────────────
                $fwrite(csv_fd, "%0d,", t);
                case (r)
                    0: $fwrite(csv_fd, "contractive");
                    1: $fwrite(csv_fd, "neutral");
                    2: $fwrite(csv_fd, "expansive");
                endcase
                for (i = 0; i < N; i = i + 1)
                    $fwrite(csv_fd, ",%.10g", nfe_decode(y_nfe[i]));
                for (i = 0; i < N; i = i + 1)
                    $fwrite(csv_fd, ",%.10g", y_g[i]);
                $fdisplay(csv_fd, ",%.4f,%0d,%0d",
                          mean_err, cum_sat[r], cum_floor[r]);

            end // for t

            // ── Per-regime summary ─────────────────────────────────────────────
            $display("");
            case (r)
                0: $display("=== SSC Chain — contractive (row_sum=0.90) ===");
                1: $display("=== SSC Chain — neutral     (row_sum=1.00) ===");
                2: $display("=== SSC Chain — expansive   (row_sum=1.10) ===");
            endcase
            $display("  Depth  : %0d cycles", DEPTH);
            if (onset_cycle[r] > DEPTH)
                $display("  Divergence onset (mean_rel_err > 1.0%%): NONE within %0d cycles",
                         DEPTH);
            else
                $display("  Divergence onset (mean_rel_err > 1.0%%): cycle %0d",
                         onset_cycle[r]);
            $display("  Final mean rel err      : %.4f%%", final_err[r]);
            $display("  Cumulative sat  (E63f63): %0d", cum_sat[r]);
            $display("  Cumulative floor(E0 f0 ): %0d", cum_floor[r]);
            $display("  RTL path: PATH_NFE (6-bit MUL fraction, horus_nfe.v lines 494-536)");

        end // for r

        $fclose(csv_fd);
        $display("");
        $display("==============================================");
        $display("  Second-source chain benchmark complete");
        $display("  3 regimes × %0d cycles = %0d matvec steps", DEPTH, 3*DEPTH);
        $display("  CSV: SSC_CHAIN_TRACE.csv");
        $display("  Next: python3 analyze_second_source_chain.py");
        $display("==============================================");
        $finish;

    end // initial

endmodule

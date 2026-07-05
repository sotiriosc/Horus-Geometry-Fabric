`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_hopfield_recall
// Project  : Horus Geometry Fabric — Hopfield Associative-Memory Recall Demo
// File     : tb/tb_hopfield_recall.v
//
// Division of labour (stated explicitly per project convention):
//   DUT  (horus_nfe, baseline PATH_NFE):
//        All multiply-accumulate arithmetic — every 8×8 block-matvec.
//        One MUL per clock cycle (op_sel=2'b10); harness reads result after
//        each posedge.
//   Harness:
//        Block sequencing (8×8 grid of 8×8 sub-matvecs per update step);
//        float accumulation of decoded NFE products in real arithmetic;
//        sign() nonlinearity applied after each full 64×64 matvec;
//        state feedback (encodes ±1 → NFE(s,E=32,f=0) before next step);
//        convergence detection; CSV logging; ASCII rendering.
//
// Network parameters:
//   64 neurons, states ±1, Hebbian weights W = Σ p_k p_k^T / N (zero diag).
//   3 stored patterns: H (0x8181_81FF_8181_8181),
//                      T (0xFF10_1010_1010_1010),
//                      X (0x8142_2418_1824_4281).
//   Weight magnitudes: {1/64, 3/64} → NFE E ∈ {26,27} (NORM band [16..47]).
//
// Seeds — must match sim/hopfield_demo.py exactly:
//   Corruption seed for (pat_k, level lv, trial t):
//     seed = (CORRUPT_SEED_BASE ^ (pk*0x11111111) ^ (lv*0x22222222)
//              ^ (t*0x01234567)) & 0xFFFFFFFF
//   Spurious test seed for trial si:
//     seed = (SPURIOUS_SEED_BASE ^ (si*0x01234567)) & 0xFFFFFFFF
//
// Output:
//   HOPFIELD_TRACE.csv  — one row per (source, pat, trial, n_flip, iteration)
//   $display log       — ASCII rendering for one recall case per letter,
//                        per-trial verdict, and overall summary.
// ============================================================================

module tb_hopfield_recall;

    // ── Timing / DUT control ─────────────────────────────────────────────────
    localparam CLK_PERIOD = 10;
    localparam [1:0] OP_MUL = 2'b10;
    localparam EXP_BIAS = 32, EXP_MAX = 63;

    // ── Network parameters ────────────────────────────────────────────────────
    localparam N = 64, NB = 8, K_PATS = 3;
    localparam MAX_ITERS = 32, N_TRIALS = 20, N_SPURIOUS = 8;

    // ── Seeds (must match hopfield_demo.py exactly) ───────────────────────────
    localparam [31:0] CORRUPT_SEED_BASE  = 32'hBEEFCAFE;
    localparam [31:0] SPURIOUS_SEED_BASE = 32'h5A5AA5A5;

    // ── Packed pattern bits (MSB = row0 col0; 1='#', 0='.') ──────────────────
    // PATT_H: rows = 0x81 0x81 0x81 0xFF 0x81 0x81 0x81 0x81
    // PATT_T: rows = 0xFF 0x10 0x10 0x10 0x10 0x10 0x10 0x10
    // PATT_X: rows = 0x81 0x42 0x24 0x18 0x18 0x24 0x42 0x81
    localparam [63:0] PATT_H = 64'h8181_81FF_8181_8181;
    localparam [63:0] PATT_T = 64'hFF10_1010_1010_1010;
    localparam [63:0] PATT_X = 64'h8142_2418_1824_4281;

    // ── DUT ports ─────────────────────────────────────────────────────────────
    reg        clk, rst_n;
    reg [12:0] op_a, op_b;
    reg [1:0]  op_sel;
    reg [2:0]  mode_tag;
    reg        accum_en, accum_clr;
    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag, underflow_flag, exp_ovf_flag;

    horus_nfe dut (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a), .op_b(op_b),
        .op_sel(op_sel), .mode_tag(mode_tag),
        .accum_en(accum_en), .accum_clr(accum_clr),
        .result(result), .accum_out(accum_out),
        .rollover_flag(rollover_flag),
        .underflow_flag(underflow_flag),
        .exp_ovf_flag(exp_ovf_flag)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ── NFE encode / decode (mirrors tb_norm_interval.v) ─────────────────────
    function real nfe_decode;
        input [12:0] cw;
        integer s_b, e_b, f_b; real mag;
        begin
            s_b = cw[12]; e_b = cw[11:6]; f_b = cw[5:0];
            mag = (1.0 + $itor(f_b)/64.0) * $pow(2.0, $itor(e_b) - 32.0);
            nfe_decode = s_b ? -mag : mag;
        end
    endfunction

    function [12:0] nfe_encode;
        input real v;
        integer s_b, aE, eS, f_b; real av, m_v, l2;
        begin
            s_b = (v < 0.0) ? 1 : 0;
            av  = (v < 0.0) ? -v : v;
            if (av == 0.0) nfe_encode = 13'd0;
            else begin
                l2  = $ln(av) / $ln(2.0);
                aE  = $rtoi(l2);
                if (l2 < 0.0 && l2 != $itor(aE)) aE = aE - 1;
                m_v = av * $pow(2.0, $itor(-aE));
                if (m_v < 1.0)  begin aE = aE - 1; m_v = m_v * 2.0; end
                if (m_v >= 2.0) begin aE = aE + 1; m_v = m_v * 0.5; end
                if (aE < -32) nfe_encode = s_b[0] ? 13'h1000 : 13'd0;
                else if (aE > 31) nfe_encode = s_b[0] ? 13'h1FFF : 13'h0FFF;
                else begin
                    eS  = aE + 32;
                    f_b = $rtoi((m_v - 1.0) * 64.0 + 0.5);
                    if (f_b > 63) begin f_b = 0; eS = eS + 1; end
                    if (eS > 63)  nfe_encode = s_b[0] ? 13'h1FFF : 13'h0FFF;
                    else          nfe_encode = {s_b[0], eS[5:0], f_b[5:0]};
                end
            end
        end
    endfunction

    // ── LFSR helpers (mirrors hopfield_demo.py / tb_norm_interval.v) ──────────
    function [31:0] lfsr_step_fn;
        input [31:0] s_in;
        reg b;
        begin
            b = s_in[31] ^ s_in[21] ^ s_in[1] ^ s_in[0];
            lfsr_step_fn = {s_in[30:0], b};
        end
    endfunction

    function real lfsr_frac_fn;
        input [31:0] s_in;
        begin
            lfsr_frac_fn = $itor((s_in >> 8) & 32'h00FFFFFF) / 16777216.0;
        end
    endfunction

    // ── Module-level storage ──────────────────────────────────────────────────
    reg [63:0] patt_bits [0:2];   // packed pattern bit vectors
    integer    p_int [0:2][0:63]; // pattern pixels ±1, indexed [pat][pixel]

    reg [12:0] W_nfe  [0:4095];  // W_nfe[i*64 + j]
    real       W_real [0:4095];  // W_real[i*64 + j]

    integer    s_int  [0:63];    // current state ±1
    integer    s_prev [0:63];    // previous state (for fixed-point detection)
    integer    s_new  [0:63];    // next-state buffer
    reg [12:0] s_nfe  [0:63];   // NFE-encoded current state
    real       z_accum[0:63];   // float row-sum accumulators

    integer    avail  [0:63];    // LFSR corruption scratch

    integer csv_fd;
    integer n_exact_all, n_exact, n_spurious_found;

    // ── Loop / scratch variables (module-level to avoid scoping issues) ───────
    integer pk, lv, trial, it, conv_it, fp, hd_near, k_near;
    integer hd_pat[0:2];
    integer si_idx, n_flip;
    integer ii, jj, kk, rb, cb, ri, ci, rr, cc;
    integer avail_len, pos_v;
    real    psum_v, ov[0:2];
    reg [31:0] lfsr_r, seed_r;

    // ── Helper: encode state from p_int[pat_k] ───────────────────────────────
    task set_state_from_pat;
        input integer pat_k;
        begin
            for (ii = 0; ii < 64; ii = ii + 1) begin
                s_int[ii] = p_int[pat_k][ii];
                s_nfe[ii] = (s_int[ii] > 0) ? 13'h0800 : 13'h1800;
            end
        end
    endtask

    // ── Helper: encode state from LFSR random ────────────────────────────────
    task set_random_state;
        input [31:0] seed;
        begin
            lfsr_r = seed;
            for (ii = 0; ii < 64; ii = ii + 1) begin
                lfsr_r = lfsr_step_fn(lfsr_r);
                s_int[ii] = (lfsr_frac_fn(lfsr_r) >= 0.5) ? 1 : -1;
                s_nfe[ii] = (s_int[ii] > 0) ? 13'h0800 : 13'h1800;
            end
        end
    endtask

    // ── Helper: corrupt s_int with n_flip LFSR-chosen flips ──────────────────
    // Algorithm mirrors hopfield_demo.py corrupt_pattern() exactly:
    //   avail = [0..63]; for each flip: pick pos = int(frac*len); swap out.
    task corrupt_state;
        input [31:0] seed;
        input integer n_f;
        begin
            for (ii = 0; ii < 64; ii = ii + 1) avail[ii] = ii;
            avail_len = 64;
            lfsr_r = seed;
            for (ii = 0; ii < n_f; ii = ii + 1) begin
                lfsr_r = lfsr_step_fn(lfsr_r);
                pos_v  = $rtoi(lfsr_frac_fn(lfsr_r) * $itor(avail_len));
                if (pos_v >= avail_len) pos_v = avail_len - 1;
                s_int[avail[pos_v]] = -s_int[avail[pos_v]];
                avail[pos_v] = avail[avail_len - 1];
                avail_len    = avail_len - 1;
            end
            for (ii = 0; ii < 64; ii = ii + 1)
                s_nfe[ii] = (s_int[ii] > 0) ? 13'h0800 : 13'h1800;
        end
    endtask

    // ── Block matvec: 8×8 grid of 8×8 NFE sub-matvecs via DUT ───────────────
    // Loop order matches hopfield_demo.py hopfield_matvec() exactly.
    // Each MUL: set inputs on negedge, read result after posedge (+1ns).
    task dut_matvec;
        begin
            for (ii = 0; ii < 64; ii = ii + 1) z_accum[ii] = 0.0;
            for (rb = 0; rb < 8; rb = rb + 1) begin
                for (cb = 0; cb < 8; cb = cb + 1) begin
                    for (ri = 0; ri < 8; ri = ri + 1) begin
                        psum_v = 0.0;
                        for (ci = 0; ci < 8; ci = ci + 1) begin
                            ii = rb*8 + ri;
                            jj = cb*8 + ci;
                            @(negedge clk);
                            op_a     = W_nfe[ii*64 + jj];
                            op_b     = s_nfe[jj];
                            op_sel   = OP_MUL;
                            mode_tag = 3'b000;
                            accum_en = 0; accum_clr = 0;
                            @(posedge clk); #1;
                            psum_v = psum_v + nfe_decode(result);
                        end
                        z_accum[rb*8 + ri] = z_accum[rb*8 + ri] + psum_v;
                    end
                end
            end
        end
    endtask

    // ── Apply sign update (synchronous: compute all new states, then commit) ──
    // sign(z) = +1 for z >= 0, -1 for z < 0.  Consistent with hopfield_demo.py.
    task apply_sign_and_commit;
        begin
            for (ii = 0; ii < 64; ii = ii + 1)
                s_new[ii] = (z_accum[ii] >= 0.0) ? 1 : -1;
            for (ii = 0; ii < 64; ii = ii + 1) begin
                s_int[ii] = s_new[ii];
                s_nfe[ii] = (s_int[ii] > 0) ? 13'h0800 : 13'h1800;
            end
        end
    endtask

    // ── Metrics ───────────────────────────────────────────────────────────────
    function integer hamming_to;
        input integer pat_k;
        integer hd, xi;
        begin
            hd = 0;
            for (xi = 0; xi < 64; xi = xi + 1)
                if (s_int[xi] != p_int[pat_k][xi]) hd = hd + 1;
            hamming_to = hd;
        end
    endfunction

    function real overlap_with;
        input integer pat_k;
        integer xi; real ov_r;
        begin
            ov_r = 0.0;
            for (xi = 0; xi < 64; xi = xi + 1)
                ov_r = ov_r + $itor(s_int[xi]) * $itor(p_int[pat_k][xi]);
            overlap_with = ov_r / 64.0;
        end
    endfunction

    // ── ASCII rendering ───────────────────────────────────────────────────────
    task print_state_grid;
        begin
            for (rr = 0; rr < 8; rr = rr + 1) begin
                $write("    ");
                for (cc = 0; cc < 8; cc = cc + 1)
                    $write("%s", (s_int[rr*8+cc] > 0) ? "#" : ".");
                $write("\n");
            end
        end
    endtask

    task print_pat_grid;
        input integer pat_k;
        begin
            for (rr = 0; rr < 8; rr = rr + 1) begin
                $write("    ");
                for (cc = 0; cc < 8; cc = cc + 1)
                    $write("%s", (p_int[pat_k][rr*8+cc] > 0) ? "#" : ".");
                $write("\n");
            end
        end
    endtask

    // ── CSV helpers ───────────────────────────────────────────────────────────
    function [23:0] pat_name_str;
        input integer pk_in;
        begin
            case (pk_in)
                0: pat_name_str = "H  ";
                1: pat_name_str = "T  ";
                2: pat_name_str = "X  ";
                default: pat_name_str = "?  ";
            endcase
        end
    endfunction

    task write_csv_row;
        input integer pk_in, trial_in, nflip_in, iter_in;
        input integer hd_near_in, k_near_in;
        input real ov0, ov1, ov2;
        begin
            $fwrite(csv_fd,
                "rtl,%s,%0d,%0d,%0d,%0d,%s,%0.6f,%0.6f,%0.6f\n",
                pat_name_str(pk_in), trial_in, nflip_in, iter_in,
                hd_near_in, pat_name_str(k_near_in),
                ov0, ov1, ov2);
        end
    endtask

    // ── Initialisation ────────────────────────────────────────────────────────
    task dut_reset;
        begin
            rst_n = 0; op_a = 0; op_b = 0; op_sel = 2'b11;
            mode_tag = 3'b000; accum_en = 0; accum_clr = 0;
            @(posedge clk); #1; @(posedge clk); #1;
            rst_n = 1; @(posedge clk); #1;
        end
    endtask

    task init_patterns;
        begin
            patt_bits[0] = PATT_H;
            patt_bits[1] = PATT_T;
            patt_bits[2] = PATT_X;
            for (ii = 0; ii < 64; ii = ii + 1) begin
                p_int[0][ii] = patt_bits[0][63 - ii] ? 1 : -1;
                p_int[1][ii] = patt_bits[1][63 - ii] ? 1 : -1;
                p_int[2][ii] = patt_bits[2][63 - ii] ? 1 : -1;
            end
        end
    endtask

    task build_weights;
        real acc_w;
        begin
            for (ii = 0; ii < 64; ii = ii + 1)
                for (jj = 0; jj < 64; jj = jj + 1) begin
                    if (ii == jj) begin
                        W_real[ii*64+jj] = 0.0;
                    end else begin
                        acc_w = 0.0;
                        for (kk = 0; kk < 3; kk = kk + 1)
                            acc_w = acc_w + $itor(p_int[kk][ii]) *
                                            $itor(p_int[kk][jj]);
                        W_real[ii*64+jj] = acc_w / 64.0;
                    end
                    W_nfe[ii*64+jj] = nfe_encode(W_real[ii*64+jj]);
                end
        end
    endtask

    // ── Main ─────────────────────────────────────────────────────────────────
    initial begin
        $display("");
        $display("====================================================================");
        $display("tb_hopfield_recall — Hopfield RTL Demo");
        $display("  DUT: horus_nfe (baseline PATH_NFE, no RTL modification)");
        $display("  Division of labour: DUT=matvec, harness=sign+sequencing+CSV");
        $display("====================================================================");

        dut_reset;
        init_patterns;
        build_weights;
        $display("Patterns and weights built. Weight NFE E in {26,27} (NORM band).");

        csv_fd = $fopen("HOPFIELD_TRACE.csv", "w");
        $fwrite(csv_fd, "source,pat_name,trial,n_flip,iteration,hamming_to_nearest,nearest_pat,overlap_H,overlap_T,overlap_X\n");

        n_exact_all    = 0;
        n_spurious_found = 0;

        // ── Corruption recall tests ──────────────────────────────────────────
        $display("");
        $display("── Corruption Recall Tests ──────────────────────────────────────────");

        for (pk = 0; pk < 3; pk = pk + 1) begin
            for (lv = 0; lv <= 1; lv = lv + 1) begin
                n_flip  = (lv == 0) ? 8 : 13;
                n_exact = 0;

                for (trial = 0; trial < N_TRIALS; trial = trial + 1) begin
                    seed_r = (CORRUPT_SEED_BASE  ^ (pk     * 32'h11111111)
                                                 ^ (lv     * 32'h22222222)
                                                 ^ (trial  * 32'h01234567))
                             & 32'hFFFFFFFF;

                    // ── Initialise & corrupt ──────────────────────────────
                    set_state_from_pat(pk);
                    corrupt_state(seed_r, n_flip);

                    // Record iteration 0
                    for (kk = 0; kk < 3; kk = kk + 1) hd_pat[kk] = hamming_to(kk);
                    hd_near = hd_pat[0];  k_near = 0;
                    if (hd_pat[1] < hd_near) begin hd_near = hd_pat[1]; k_near = 1; end
                    if (hd_pat[2] < hd_near) begin hd_near = hd_pat[2]; k_near = 2; end
                    for (kk = 0; kk < 3; kk = kk + 1) ov[kk] = overlap_with(kk);
                    write_csv_row(pk, trial, n_flip, 0, hd_near, k_near,
                                  ov[0], ov[1], ov[2]);

                    // ── Hopfield iterations ───────────────────────────────
                    fp = 0; conv_it = MAX_ITERS;
                    for (it = 1; it <= MAX_ITERS; it = it + 1) begin
                        if (!fp) begin
                            for (ii = 0; ii < 64; ii = ii + 1) s_prev[ii] = s_int[ii];
                            dut_matvec;
                            apply_sign_and_commit;

                            for (kk = 0; kk < 3; kk = kk + 1) hd_pat[kk] = hamming_to(kk);
                            hd_near = hd_pat[0]; k_near = 0;
                            if (hd_pat[1] < hd_near) begin hd_near = hd_pat[1]; k_near = 1; end
                            if (hd_pat[2] < hd_near) begin hd_near = hd_pat[2]; k_near = 2; end
                            for (kk = 0; kk < 3; kk = kk + 1) ov[kk] = overlap_with(kk);
                            write_csv_row(pk, trial, n_flip, it, hd_near, k_near,
                                          ov[0], ov[1], ov[2]);

                            // Fixed-point check: compare new s_int with saved s_prev
                            fp = 1;
                            for (ii = 0; ii < 64; ii = ii + 1)
                                if (s_int[ii] != s_prev[ii]) fp = 0;
                            if (fp) conv_it = it;
                        end
                    end

                    if (hamming_to(pk) == 0) n_exact = n_exact + 1;
                end // trial

                $display("  Pattern %s, %0d/64 corruptions: %0d/%0d exact recall",
                         pat_name_str(pk), n_flip, n_exact, N_TRIALS);
                n_exact_all = n_exact_all + n_exact;
            end // lv
        end // pk

        // ── ASCII rendering: one full recall per pattern (trial 0, 8-flip) ───
        $display("");
        $display("── ASCII Recall Sequences (8/64 corruptions, trial 0) ───────────────");

        for (pk = 0; pk < 3; pk = pk + 1) begin
            seed_r = (CORRUPT_SEED_BASE ^ (pk * 32'h11111111)) & 32'hFFFFFFFF;

            $display("");
            $display("  Pattern %s  seed 0x%08X  8 flips", pat_name_str(pk), seed_r);
            $display("  Stored:");
            print_pat_grid(pk);

            set_state_from_pat(pk);
            corrupt_state(seed_r, 8);
            $display("  Corrupted input (t=0):");
            print_state_grid;

            // t=1
            for (ii = 0; ii < 64; ii = ii + 1) s_prev[ii] = s_int[ii];
            dut_matvec;
            apply_sign_and_commit;
            $display("  t=1:");
            print_state_grid;
            fp = 1;
            for (ii = 0; ii < 64; ii = ii + 1)
                if (s_int[ii] != s_prev[ii]) fp = 0;

            if (!fp) begin
                // t=2
                for (ii = 0; ii < 64; ii = ii + 1) s_prev[ii] = s_int[ii];
                dut_matvec;
                apply_sign_and_commit;
                $display("  t=2:");
                print_state_grid;
            end

            if (hamming_to(pk) == 0)
                $display("  RECALL: EXACT (%s iters)", fp ? "1" : "2");
            else
                $display("  RECALL: PARTIAL (%0d pixels wrong)", hamming_to(pk));
        end

        // ── Spurious attractor tests ──────────────────────────────────────────
        $display("");
        $display("── Spurious Attractor Tests ─────────────────────────────────────────");

        for (si_idx = 0; si_idx < N_SPURIOUS; si_idx = si_idx + 1) begin
            seed_r = (SPURIOUS_SEED_BASE ^ (si_idx * 32'h01234567)) & 32'hFFFFFFFF;
            set_random_state(seed_r);

            // Record t=0
            for (kk = 0; kk < 3; kk = kk + 1) hd_pat[kk] = hamming_to(kk);
            hd_near = hd_pat[0]; k_near = 0;
            if (hd_pat[1] < hd_near) begin hd_near = hd_pat[1]; k_near = 1; end
            if (hd_pat[2] < hd_near) begin hd_near = hd_pat[2]; k_near = 2; end
            for (kk = 0; kk < 3; kk = kk + 1) ov[kk] = overlap_with(kk);
            $fwrite(csv_fd,
                "rtl,spurious_%0d,%0d,-1,0,%0d,%s,%0.6f,%0.6f,%0.6f\n",
                si_idx, si_idx, hd_near, pat_name_str(k_near),
                ov[0], ov[1], ov[2]);

            fp = 0; conv_it = MAX_ITERS;
            for (it = 1; it <= MAX_ITERS; it = it + 1) begin
                if (!fp) begin
                    for (ii = 0; ii < 64; ii = ii + 1) s_prev[ii] = s_int[ii];
                    dut_matvec;
                    apply_sign_and_commit;

                    for (kk = 0; kk < 3; kk = kk + 1) hd_pat[kk] = hamming_to(kk);
                    hd_near = hd_pat[0]; k_near = 0;
                    if (hd_pat[1] < hd_near) begin hd_near = hd_pat[1]; k_near = 1; end
                    if (hd_pat[2] < hd_near) begin hd_near = hd_pat[2]; k_near = 2; end
                    for (kk = 0; kk < 3; kk = kk + 1) ov[kk] = overlap_with(kk);
                    $fwrite(csv_fd,
                        "rtl,spurious_%0d,%0d,-1,%0d,%0d,%s,%0.6f,%0.6f,%0.6f\n",
                        si_idx, si_idx, it, hd_near, pat_name_str(k_near),
                        ov[0], ov[1], ov[2]);

                    fp = 1;
                    for (ii = 0; ii < 64; ii = ii + 1)
                        if (s_int[ii] != s_prev[ii]) fp = 0;
                    if (fp) conv_it = it;
                end
            end

            if (hd_near > 0) begin
                n_spurious_found = n_spurious_found + 1;
                $display("  seed 0x%08X: %0d iter, SPURIOUS — %0d px from %s",
                         seed_r, conv_it, hd_near, pat_name_str(k_near));
            end else begin
                $display("  seed 0x%08X: %0d iter, -> pattern %s (exact)",
                         seed_r, conv_it, pat_name_str(k_near));
            end
        end
        $display("  Spurious attractors found: %0d/%0d", n_spurious_found, N_SPURIOUS);

        // ── Summary ──────────────────────────────────────────────────────────
        $display("");
        $display("====================================================================");
        $display("RTL SUMMARY");
        $display("  Total exact recalls: %0d / %0d  (%0.0f%%)",
                 n_exact_all, 6*N_TRIALS,
                 100.0 * $itor(n_exact_all) / $itor(6*N_TRIALS));
        $display("  Spurious attractors (random init): %0d / %0d",
                 n_spurious_found, N_SPURIOUS);
        $display("  CSV: sim/HOPFIELD_TRACE.csv");
        $display("====================================================================");
        $display("");

        $fclose(csv_fd);
        $finish;
    end

endmodule

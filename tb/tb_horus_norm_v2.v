`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_horus_norm_v2
// File     : tb/tb_horus_norm_v2.v
// Date     : 2026-07-05
//
// Purpose  : Verification testbench for rtl/horus_norm_v2.v.
//
// Part A — Mode-0 regression (1000 vectors)
//   A1. Mode 0 must reproduce the v1 golden file sim/EXPNORM_GOLDEN.dat
//       bit-for-bit.  Pass criterion: 0 mismatches out of 1000.
//   A2. Directed tests confirming e_max_out matches expected values in mode 0.
//
// Part B — Directed mode-1 tests
//   B1. Normal offset: supply known offset_in, verify per-element exponent shift.
//   B2. Offset=0: output equals input.
//   B3. UF clamp: offset_in drives new_e negative for some elements.
//   B4. OVF clamp: offset_in drives new_e above 63.
//   B5. All-floor input (E=0): mode 1 with nonzero offset_in still clamps to UF.
//
// Part C — 16-element composition test (200 two-block trials)
//   Composition protocol (mirrors tb_mlp_inference.v between-layer normalization):
//     Pass 1: feed block_a with mode=0 → capture e_max_out_a.
//     Pass 1: feed block_b with mode=0 → capture e_max_out_b.
//     Harness computes: shared_offset = E_TARGET - max(e_max_a, e_max_b).
//     Pass 2: feed block_a with mode=1, offset=shared_offset → capture out_a.
//     Pass 2: feed block_b with mode=1, offset=shared_offset → capture out_b.
//   Golden: sim/EXPNORM_V2_GOLDEN.dat (200 lines, 36 values each:
//     e_max_a e_max_b shared_e_max shared_offset  in_a0..in_a7  in_b0..in_b7
//     out_a0..out_a7  out_b0..out_b7)
//   Pass criterion: 0 mismatches out of 200×16 = 3200 codewords.
//
// Division of labour:
//   DUT horus_norm_v2 : max-exponent tree, offset mux, per-element clamp.
//   Harness           : mode control, composition sequencing, shared-offset
//                       computation, golden comparison.
// ============================================================================

module tb_horus_norm_v2;

    localparam CLK_HALF = 5;            // 100 MHz clock
    localparam integer EXP_BIAS = 32;
    localparam integer EXP_MAX  = 63;
    localparam integer E_TARGET = 32;
    localparam integer N_GOLDEN = 1000; // v1 golden file entries
    localparam integer N_V2     = 200;  // v2 composition golden entries

    // ── Clock ─────────────────────────────────────────────────────────────────
    reg clk = 0;
    always #CLK_HALF clk = ~clk;

    // ── DUT signals ───────────────────────────────────────────────────────────
    reg         rst_n;
    reg         norm_valid_in;
    reg  [12:0] norm_in_0, norm_in_1, norm_in_2, norm_in_3;
    reg  [12:0] norm_in_4, norm_in_5, norm_in_6, norm_in_7;
    reg         norm_offset_mode;
    reg  [6:0]  norm_offset_in;

    wire        norm_valid_out;
    wire [5:0]  norm_e_max_out;         // V2 addition
    wire [12:0] norm_out_0, norm_out_1, norm_out_2, norm_out_3;
    wire [12:0] norm_out_4, norm_out_5, norm_out_6, norm_out_7;

    horus_norm_v2 #(.E_TARGET(6'd32)) DUT (
        .clk(clk), .rst_n(rst_n),
        .valid_in(norm_valid_in),
        .in_0(norm_in_0), .in_1(norm_in_1),
        .in_2(norm_in_2), .in_3(norm_in_3),
        .in_4(norm_in_4), .in_5(norm_in_5),
        .in_6(norm_in_6), .in_7(norm_in_7),
        .offset_mode(norm_offset_mode),
        .offset_in(norm_offset_in),
        .valid_out(norm_valid_out),
        .e_max_out(norm_e_max_out),
        .out_0(norm_out_0), .out_1(norm_out_1),
        .out_2(norm_out_2), .out_3(norm_out_3),
        .out_4(norm_out_4), .out_5(norm_out_5),
        .out_6(norm_out_6), .out_7(norm_out_7)
    );

    // ── NFE helpers (mirrors tb_horus_norm.v lines 102-143) ───────────────────
    function real nfe_decode;
        input [12:0] cw; integer s, e, f; real mag;
        begin
            s = cw[12]; e = cw[11:6]; f = cw[5:0];
            mag = (1.0 + $itor(f)/64.0) * $pow(2.0, $itor(e) - $itor(EXP_BIAS));
            nfe_decode = s ? -mag : mag;
        end
    endfunction

    // ── Storage ───────────────────────────────────────────────────────────────
    reg [12:0] in_vec  [0:7];
    reg [12:0] out_vec [0:7];
    reg [12:0] golden  [0:7];
    integer    ii;
    integer    mismatches;
    integer    pass_count, fail_count;

    // ── Task: drive one vector, wait one cycle, capture outputs ───────────────
    task apply_norm;
        input        mode;
        input [6:0]  ext_off;
        begin
            @(negedge clk);
            norm_in_0 = in_vec[0]; norm_in_1 = in_vec[1];
            norm_in_2 = in_vec[2]; norm_in_3 = in_vec[3];
            norm_in_4 = in_vec[4]; norm_in_5 = in_vec[5];
            norm_in_6 = in_vec[6]; norm_in_7 = in_vec[7];
            norm_offset_mode = mode;
            norm_offset_in   = ext_off;
            norm_valid_in    = 1;
            @(posedge clk); #1;
            if (!norm_valid_out)
                $display("  WARNING: valid_out not asserted after 1 cycle");
            out_vec[0] = norm_out_0; out_vec[1] = norm_out_1;
            out_vec[2] = norm_out_2; out_vec[3] = norm_out_3;
            out_vec[4] = norm_out_4; out_vec[5] = norm_out_5;
            out_vec[6] = norm_out_6; out_vec[7] = norm_out_7;
            norm_valid_in = 0;
        end
    endtask

    // ── Part A golden-file variables ──────────────────────────────────────────
    integer gfd;
    integer trial_id, e_max_g, offset_g;
    integer in_raw [0:7];
    integer out_raw[0:7];

    // ── Part C golden-file variables ──────────────────────────────────────────
    integer v2fd;
    integer g_emax_a, g_emax_b, g_shared_emax, g_shared_off;
    integer v2_in_a [0:7], v2_in_b [0:7];
    integer v2_out_a[0:7], v2_out_b[0:7];
    integer r_emax_a, r_emax_b;
    integer shared_emax, shared_off;
    integer dut_out_a[0:7], dut_out_b[0:7];

    // ── Main ──────────────────────────────────────────────────────────────────
    integer test_pass, test_fail;

    initial begin
        $display("================================================================");
        $display("tb_horus_norm_v2: horus_norm_v2.v verification");
        $display("================================================================");

        rst_n = 0; norm_valid_in = 0;
        norm_offset_mode = 0; norm_offset_in = 0;
        norm_in_0 = 0; norm_in_1 = 0; norm_in_2 = 0; norm_in_3 = 0;
        norm_in_4 = 0; norm_in_5 = 0; norm_in_6 = 0; norm_in_7 = 0;
        #(CLK_HALF*4); rst_n = 1; #(CLK_HALF*2);

        test_pass = 0; test_fail = 0;

        // ══════════════════════════════════════════════════════════════════════
        // Part A: Mode-0 regression against EXPNORM_GOLDEN.dat (1000 vectors)
        // ══════════════════════════════════════════════════════════════════════
        $display("");
        $display("Part A: Mode-0 regression vs sim/EXPNORM_GOLDEN.dat (%0d vectors)", N_GOLDEN);

        gfd = $fopen("../sim/EXPNORM_GOLDEN.dat", "r");
        if (gfd == 0) begin
            $display("  ERROR: cannot open EXPNORM_GOLDEN.dat"); $finish;
        end

        mismatches = 0;
        for (ii = 0; ii < N_GOLDEN; ii = ii+1) begin
            $fscanf(gfd, "%d %d %d", trial_id, e_max_g, offset_g);
            $fscanf(gfd, "%d %d %d %d %d %d %d %d",
                in_raw[0], in_raw[1], in_raw[2], in_raw[3],
                in_raw[4], in_raw[5], in_raw[6], in_raw[7]);
            $fscanf(gfd, "%d %d %d %d %d %d %d %d",
                out_raw[0], out_raw[1], out_raw[2], out_raw[3],
                out_raw[4], out_raw[5], out_raw[6], out_raw[7]);

            in_vec[0] = in_raw[0][12:0]; in_vec[1] = in_raw[1][12:0];
            in_vec[2] = in_raw[2][12:0]; in_vec[3] = in_raw[3][12:0];
            in_vec[4] = in_raw[4][12:0]; in_vec[5] = in_raw[5][12:0];
            in_vec[6] = in_raw[6][12:0]; in_vec[7] = in_raw[7][12:0];

            apply_norm(1'b0, 7'b0);

            // Check e_max_out
            if (norm_e_max_out !== e_max_g[5:0]) begin
                $display("  A e_max MISMATCH trial=%0d  dut=%0d  golden=%0d",
                         trial_id, norm_e_max_out, e_max_g);
                mismatches = mismatches + 1;
            end
            // Check all 8 output codewords
            golden[0] = out_raw[0][12:0]; golden[1] = out_raw[1][12:0];
            golden[2] = out_raw[2][12:0]; golden[3] = out_raw[3][12:0];
            golden[4] = out_raw[4][12:0]; golden[5] = out_raw[5][12:0];
            golden[6] = out_raw[6][12:0]; golden[7] = out_raw[7][12:0];
            if (out_vec[0] !== golden[0] || out_vec[1] !== golden[1] ||
                out_vec[2] !== golden[2] || out_vec[3] !== golden[3] ||
                out_vec[4] !== golden[4] || out_vec[5] !== golden[5] ||
                out_vec[6] !== golden[6] || out_vec[7] !== golden[7]) begin
                $display("  A data MISMATCH trial=%0d", trial_id);
                mismatches = mismatches + 1;
            end
        end
        $fclose(gfd);

        if (mismatches == 0) begin
            $display("  PASS: 0 mismatches / %0d — mode-0 identical to v1", N_GOLDEN);
            test_pass = test_pass + 1;
        end else begin
            $display("  FAIL: %0d mismatches", mismatches);
            test_fail = test_fail + 1;
        end

        // ══════════════════════════════════════════════════════════════════════
        // Part B: Directed mode-1 tests
        // ══════════════════════════════════════════════════════════════════════
        $display("");
        $display("Part B: Directed mode-1 tests");

        // B1: Normal positive offset (+4): all exponents shift up by 4
        $display("  B1: offset_in=+4, all normal elements");
        in_vec[0]=13'h0840; in_vec[1]=13'h0880; in_vec[2]=13'h08C0; in_vec[3]=13'h0900;
        in_vec[4]=13'h0940; in_vec[5]=13'h0980; in_vec[6]=13'h09C0; in_vec[7]=13'h0A00;
        // E = 33,34,35,36,37,38,39,40 → after +4: 37,38,39,40,41,42,43,44
        apply_norm(1'b1, 7'sd4);
        begin : b1_check
            integer ok; ok = 1;
            if (out_vec[0][11:6] !== 6'd37) ok=0;
            if (out_vec[1][11:6] !== 6'd38) ok=0;
            if (out_vec[2][11:6] !== 6'd39) ok=0;
            if (out_vec[3][11:6] !== 6'd40) ok=0;
            if (out_vec[4][11:6] !== 6'd41) ok=0;
            if (out_vec[5][11:6] !== 6'd42) ok=0;
            if (out_vec[6][11:6] !== 6'd43) ok=0;
            if (out_vec[7][11:6] !== 6'd44) ok=0;
            // mantissas must be unchanged
            if (out_vec[0][5:0] !== in_vec[0][5:0]) ok=0;
            if (ok) begin $display("    PASS"); test_pass=test_pass+1; end
            else    begin $display("    FAIL"); test_fail=test_fail+1; end
        end

        // B2: offset_in=0 → output equals input
        $display("  B2: offset_in=0, no change");
        in_vec[0]=13'h0841; in_vec[1]=13'h10C2; in_vec[2]=13'h18E3; in_vec[3]=13'h0104;
        in_vec[4]=13'h0845; in_vec[5]=13'h0906; in_vec[6]=13'h0107; in_vec[7]=13'h1888;
        apply_norm(1'b1, 7'sd0);
        begin : b2_check
            integer ok; ok = 1;
            for (ii = 0; ii < 8; ii = ii+1)
                if (out_vec[ii] !== in_vec[ii]) ok=0;
            if (ok) begin $display("    PASS"); test_pass=test_pass+1; end
            else    begin $display("    FAIL"); test_fail=test_fail+1; end
        end

        // B3: UF clamp — offset=-5, input E=2 → new_e=-3 <0 → floor sentinel
        $display("  B3: UF clamp — offset=-5, E=2 → new_e < 0");
        in_vec[0] = {1'b0, 6'd2,  6'd10};    // E=2, f=10
        in_vec[1] = {1'b1, 6'd2,  6'd20};    // E=2, negative, f=20
        in_vec[2] = {1'b0, 6'd10, 6'd5};     // E=10 → new_e=5 (normal)
        in_vec[3] = {1'b0, 6'd5,  6'd0};     // E=5 → new_e=0 (normal, not UF)
        in_vec[4] = {1'b0, 6'd4,  6'd0};     // E=4 → new_e=-1 → UF
        in_vec[5] = {1'b0, 6'd3,  6'd0};     // E=3 → new_e=-2 → UF
        in_vec[6] = {1'b0, 6'd2,  6'd0};     // E=2 → new_e=-3 → UF
        in_vec[7] = {1'b0, 6'd1,  6'd0};     // E=1 → new_e=-4 → UF
        apply_norm(1'b1, -7'sd5);
        begin : b3_check
            integer ok; ok = 1;
            // E=2 → new_e=-3: UF floor sentinel (s=0, E=0, f=0)
            if (out_vec[0] !== {1'b0, 6'd0, 6'd0}) ok=0;
            // E=2 negative → floor sentinel preserves sign bit
            if (out_vec[1] !== {1'b1, 6'd0, 6'd0}) ok=0;
            // E=10 → new_e=5: normal
            if (out_vec[2][11:6] !== 6'd5) ok=0;
            if (out_vec[2][5:0]  !== in_vec[2][5:0]) ok=0;
            // E=5 → new_e=0: normal (0 is a valid exponent, not UF)
            if (out_vec[3][11:6] !== 6'd0) ok=0;
            if (out_vec[3][5:0]  !== in_vec[3][5:0]) ok=0;
            // E=4 → new_e=-1: UF
            if (out_vec[4] !== {1'b0, 6'd0, 6'd0}) ok=0;
            if (ok) begin $display("    PASS"); test_pass=test_pass+1; end
            else    begin $display("    FAIL (out: %04h %04h %04h %04h %04h)",
                          out_vec[0],out_vec[1],out_vec[2],out_vec[3],out_vec[4]);
                    test_fail=test_fail+1; end
        end

        // B4: OVF clamp — offset=+30, input E=40 → new_e=70 > 63 → OVF sentinel
        $display("  B4: OVF clamp — offset=+30, E=40 → new_e=70 > 63");
        in_vec[0] = {1'b0, 6'd40, 6'd15};   // E=40 → new_e=70 → OVF
        in_vec[1] = {1'b1, 6'd40, 6'd20};   // negative, OVF
        in_vec[2] = {1'b0, 6'd33, 6'd0};    // E=33 → new_e=63: at ceiling, normal
        in_vec[3] = {1'b0, 6'd32, 6'd10};   // E=32 → new_e=62: normal
        in_vec[4] = {1'b0, 6'd1,  6'd0};    // E=1  → new_e=31: normal
        in_vec[5] = {1'b0, 6'd1,  6'd5};
        in_vec[6] = {1'b0, 6'd0,  6'd0};    // floor sentinel → new_e=30: normal(0+30=30)
        in_vec[7] = {1'b0, 6'd34, 6'd0};    // E=34 → new_e=64 → OVF
        apply_norm(1'b1, 7'd30);
        begin : b4_check
            integer ok; ok = 1;
            if (out_vec[0] !== {1'b0, 6'b111111, 6'b111111}) ok=0;  // OVF
            if (out_vec[1] !== {1'b1, 6'b111111, 6'b111111}) ok=0;  // OVF neg
            if (out_vec[2][11:6] !== 6'd63) ok=0;
            if (out_vec[2][5:0]  !== in_vec[2][5:0]) ok=0;
            if (out_vec[3][11:6] !== 6'd62) ok=0;
            if (out_vec[7] !== {1'b0, 6'b111111, 6'b111111}) ok=0;  // OVF
            if (ok) begin $display("    PASS"); test_pass=test_pass+1; end
            else    begin $display("    FAIL (out: %04h %04h %04h %04h %04h %04h %04h %04h)",
                          out_vec[0],out_vec[1],out_vec[2],out_vec[3],
                          out_vec[4],out_vec[5],out_vec[6],out_vec[7]);
                    test_fail=test_fail+1; end
        end

        // B5: All-floor input with nonzero mode-1 offset: floor sentinel E=0,
        // new_e = 0 + offset. If offset > 0, new_e > 0 → result is NOT floor.
        $display("  B5: all-floor input, mode=1, offset=+5 → new_e=5 (not floor)");
        for (ii = 0; ii < 8; ii = ii+1) in_vec[ii] = 13'h0000;
        apply_norm(1'b1, 7'd5);
        begin : b5_check
            integer ok; ok = 1;
            // E=0, f=0 → new_e=5, f=0 → normal codeword {0, 5, 0}
            for (ii = 0; ii < 8; ii = ii+1)
                if (out_vec[ii] !== {1'b0, 6'd5, 6'd0}) ok=0;
            if (ok) begin $display("    PASS"); test_pass=test_pass+1; end
            else    begin $display("    FAIL"); test_fail=test_fail+1; end
        end

        // ══════════════════════════════════════════════════════════════════════
        // Part C: 16-element two-block composition test (200 trials)
        // ══════════════════════════════════════════════════════════════════════
        $display("");
        $display("Part C: 16-element composition vs sim/EXPNORM_V2_GOLDEN.dat (%0d trials)", N_V2);

        v2fd = $fopen("../sim/EXPNORM_V2_GOLDEN.dat", "r");
        if (v2fd == 0) begin
            $display("  ERROR: cannot open EXPNORM_V2_GOLDEN.dat"); $finish;
        end

        mismatches = 0;
        for (ii = 0; ii < N_V2; ii = ii+1) begin
            // Read golden record: e_max_a e_max_b shared_e_max shared_offset
            //   in_a0..7  in_b0..7  out_a0..7  out_b0..7
            $fscanf(v2fd, "%d %d %d %d",
                g_emax_a, g_emax_b, g_shared_emax, g_shared_off);
            $fscanf(v2fd, "%d %d %d %d %d %d %d %d",
                v2_in_a[0], v2_in_a[1], v2_in_a[2], v2_in_a[3],
                v2_in_a[4], v2_in_a[5], v2_in_a[6], v2_in_a[7]);
            $fscanf(v2fd, "%d %d %d %d %d %d %d %d",
                v2_in_b[0], v2_in_b[1], v2_in_b[2], v2_in_b[3],
                v2_in_b[4], v2_in_b[5], v2_in_b[6], v2_in_b[7]);
            $fscanf(v2fd, "%d %d %d %d %d %d %d %d",
                v2_out_a[0], v2_out_a[1], v2_out_a[2], v2_out_a[3],
                v2_out_a[4], v2_out_a[5], v2_out_a[6], v2_out_a[7]);
            $fscanf(v2fd, "%d %d %d %d %d %d %d %d",
                v2_out_b[0], v2_out_b[1], v2_out_b[2], v2_out_b[3],
                v2_out_b[4], v2_out_b[5], v2_out_b[6], v2_out_b[7]);

            // ── Pass 1, block A: mode=0, capture e_max_out ────────────────────
            in_vec[0]=v2_in_a[0][12:0]; in_vec[1]=v2_in_a[1][12:0];
            in_vec[2]=v2_in_a[2][12:0]; in_vec[3]=v2_in_a[3][12:0];
            in_vec[4]=v2_in_a[4][12:0]; in_vec[5]=v2_in_a[5][12:0];
            in_vec[6]=v2_in_a[6][12:0]; in_vec[7]=v2_in_a[7][12:0];
            apply_norm(1'b0, 7'b0);
            r_emax_a = norm_e_max_out;

            // ── Pass 1, block B: mode=0, capture e_max_out ────────────────────
            in_vec[0]=v2_in_b[0][12:0]; in_vec[1]=v2_in_b[1][12:0];
            in_vec[2]=v2_in_b[2][12:0]; in_vec[3]=v2_in_b[3][12:0];
            in_vec[4]=v2_in_b[4][12:0]; in_vec[5]=v2_in_b[5][12:0];
            in_vec[6]=v2_in_b[6][12:0]; in_vec[7]=v2_in_b[7][12:0];
            apply_norm(1'b0, 7'b0);
            r_emax_b = norm_e_max_out;

            // ── Harness: shared offset ─────────────────────────────────────────
            shared_emax = (r_emax_a >= r_emax_b) ? r_emax_a : r_emax_b;
            if (shared_emax == 0)
                shared_off = 0;
            else
                shared_off = E_TARGET - shared_emax;  // signed subtract (integer)

            // ── Check e_max values match golden ───────────────────────────────
            if (r_emax_a !== g_emax_a) begin
                $display("  C e_max_a MISMATCH trial=%0d  dut=%0d  golden=%0d",
                         ii, r_emax_a, g_emax_a);
                mismatches = mismatches + 1;
            end
            if (r_emax_b !== g_emax_b) begin
                $display("  C e_max_b MISMATCH trial=%0d  dut=%0d  golden=%0d",
                         ii, r_emax_b, g_emax_b);
                mismatches = mismatches + 1;
            end

            // ── Pass 2, block A: mode=1, shared_off ───────────────────────────
            in_vec[0]=v2_in_a[0][12:0]; in_vec[1]=v2_in_a[1][12:0];
            in_vec[2]=v2_in_a[2][12:0]; in_vec[3]=v2_in_a[3][12:0];
            in_vec[4]=v2_in_a[4][12:0]; in_vec[5]=v2_in_a[5][12:0];
            in_vec[6]=v2_in_a[6][12:0]; in_vec[7]=v2_in_a[7][12:0];
            apply_norm(1'b1, shared_off[6:0]);
            dut_out_a[0]=out_vec[0]; dut_out_a[1]=out_vec[1];
            dut_out_a[2]=out_vec[2]; dut_out_a[3]=out_vec[3];
            dut_out_a[4]=out_vec[4]; dut_out_a[5]=out_vec[5];
            dut_out_a[6]=out_vec[6]; dut_out_a[7]=out_vec[7];

            // ── Pass 2, block B: mode=1, shared_off ───────────────────────────
            in_vec[0]=v2_in_b[0][12:0]; in_vec[1]=v2_in_b[1][12:0];
            in_vec[2]=v2_in_b[2][12:0]; in_vec[3]=v2_in_b[3][12:0];
            in_vec[4]=v2_in_b[4][12:0]; in_vec[5]=v2_in_b[5][12:0];
            in_vec[6]=v2_in_b[6][12:0]; in_vec[7]=v2_in_b[7][12:0];
            apply_norm(1'b1, shared_off[6:0]);
            dut_out_b[0]=out_vec[0]; dut_out_b[1]=out_vec[1];
            dut_out_b[2]=out_vec[2]; dut_out_b[3]=out_vec[3];
            dut_out_b[4]=out_vec[4]; dut_out_b[5]=out_vec[5];
            dut_out_b[6]=out_vec[6]; dut_out_b[7]=out_vec[7];

            // ── Compare outputs against golden ────────────────────────────────
            begin : cmp_a
                integer jj;
                for (jj = 0; jj < 8; jj = jj+1) begin
                    if (dut_out_a[jj] !== v2_out_a[jj][12:0]) begin
                        if (mismatches < 5)
                            $display("  C out_a MISMATCH trial=%0d elem=%0d  dut=%04h  golden=%04h",
                                     ii, jj, dut_out_a[jj], v2_out_a[jj][12:0]);
                        mismatches = mismatches + 1;
                    end
                end
            end
            begin : cmp_b
                integer jj;
                for (jj = 0; jj < 8; jj = jj+1) begin
                    if (dut_out_b[jj] !== v2_out_b[jj][12:0]) begin
                        if (mismatches < 5)
                            $display("  C out_b MISMATCH trial=%0d elem=%0d  dut=%04h  golden=%04h",
                                     ii, jj, dut_out_b[jj], v2_out_b[jj][12:0]);
                        mismatches = mismatches + 1;
                    end
                end
            end
        end
        $fclose(v2fd);

        if (mismatches == 0) begin
            $display("  PASS: 0 mismatches / %0d trials — composition exact", N_V2);
            test_pass = test_pass + 1;
        end else begin
            $display("  FAIL: %0d mismatches", mismatches);
            test_fail = test_fail + 1;
        end

        // ── Summary ───────────────────────────────────────────────────────────
        $display("");
        $display("================================================================");
        $display("tb_horus_norm_v2 SUMMARY: %0d PASS, %0d FAIL", test_pass, test_fail);
        if (test_fail == 0)
            $display("STATUS: ALL PASS");
        else
            $display("STATUS: FAIL");
        $display("================================================================");
        $finish;
    end

endmodule

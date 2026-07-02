`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c12_adversarial_reality
// Project  : HORUS v3 — HBS-C12: Adversarial Reality Collapse Suite
// File     : tb_hbs_c12_adversarial_reality.v
//
// Purpose:
//   Test whether the C8 four-attractor model remains stable, predictable and
//   interpretable under conditions that violate its implicit assumptions:
//     C12A — Noise Injection (bit flips, E±1 jitter, sign inversion)
//     C12B — Long-Horizon Distribution Drift (10,000 cycles, no reset)
//     C12C — Adversarial Cancellation Chains (interleaved noise + mismatch)
//     C12D — Semantic Mismatch Stress (INT / PROB / ENERGY / MIXED modes)
//     C12E — Failure Boundary Expansion (SAT/COLL chains, deep bounce)
//
// Total: 14,600 cycles  |  No RTL, compiler or policy changes.
// ============================================================================

module tb_hbs_c12_adversarial_reality;

    // Suite boundaries
    localparam C12A_START = 0;      localparam C12A_CYCS = 1800;
    localparam C12B_START = 1800;   localparam C12B_CYCS = 10000;
    localparam C12C_START = 11800;  localparam C12C_CYCS = 1000;
    localparam C12D_START = 12800;  localparam C12D_CYCS = 800;
    localparam C12E_START = 13600;  localparam C12E_CYCS = 1000;
    localparam TOTAL      = 14600;

    localparam EPOCH_DEPTH = 16;

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
    // C4 kernel (unchanged from C9/C10)
    // =========================================================================
    function [1:0] classify;
        input [5:0] e;
        begin
            if      (e <= 6'd15) classify = 2'd0;
            else if (e <= 6'd19) classify = 2'd1;
            else if (e <= 6'd43) classify = 2'd2;
            else if (e <= 6'd47) classify = 2'd1;
            else                 classify = 2'd3;
        end
    endfunction

    function [2:0] c4_mode;
        input [1:0] cls;
        input [5:0] e_in;
        input [7:0] d;
        reg [1:0] rgn;
        begin
            rgn = classify(e_in);
            if (d > 8'd16)
                c4_mode = 3'b010;
            else case (rgn)
                2'd2: c4_mode = 3'b000;
                2'd1: c4_mode = (cls==2'd1||cls==2'd3) ? 3'b010 : 3'b000;
                2'd0: c4_mode = (cls==2'd0) ? 3'b011 : 3'b010;
                2'd3: c4_mode = 3'b011;
                default: c4_mode = 3'b000;
            endcase
        end
    endfunction

    // =========================================================================
    // 16-bit LFSR for deterministic noise
    // =========================================================================
    reg [15:0] lfsr;
    wire       lfsr_fb = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else        lfsr <= {lfsr[14:0], lfsr_fb};
    end

    // =========================================================================
    // State
    // =========================================================================
    integer fd;
    integer total_cyc, local_cyc, suite_id, test_id, depth_cnt;
    reg [12:0] cc_feed;      // C12C cancellation MUL feed
    reg [12:0] d_feed;       // C12D energy mode feed
    reg [1:0]  cur_class;
    reg [5:0]  e_in_eff;     // effective E_in after noise

    // Clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // Main
    // =========================================================================
    initial begin : MAIN
        $display("HBS-C12: Adversarial Reality Collapse Suite — 14,600 cycles");

        op_a = 13'h000; op_b = 13'h000; op_sel = 2'b11;
        mode_tag = 3'b000; accum_en = 1'b0; accum_clr = 1'b0;
        host_tile_depth = 6'd63;
        rst_n = 1'b0; depth_cnt = 0;
        cc_feed = {1'b0, 6'd32, 6'd0};
        d_feed  = {1'b0, 6'd32, 6'd0};

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C12_ADVERSARIAL.csv", "w");
        $fwrite(fd, "total_cycle,suite_id,local_cycle,test_id,op,E_in,E_out,accum,region,UF,OVF,noise_param\n");

        for (total_cyc = 0; total_cyc < TOTAL; total_cyc = total_cyc + 1) begin

            @(negedge clk);

            // ── Suite and local cycle derivation ────────────────────────────
            if (total_cyc < C12B_START) begin
                suite_id  = 0;
                local_cyc = total_cyc - C12A_START;
                test_id   = local_cyc / 300;  // noise level 0..5
            end else if (total_cyc < C12C_START) begin
                suite_id  = 1;
                local_cyc = total_cyc - C12B_START;
                test_id   = local_cyc / 526;  // drift step 0..18
            end else if (total_cyc < C12D_START) begin
                suite_id  = 2;
                local_cyc = total_cyc - C12C_START;
                test_id   = local_cyc / 200;  // pattern 0..4
            end else if (total_cyc < C12E_START) begin
                suite_id  = 3;
                local_cyc = total_cyc - C12D_START;
                test_id   = local_cyc / 200;  // mode 0..3
            end else begin
                suite_id  = 4;
                local_cyc = total_cyc - C12E_START;
                test_id   = local_cyc / 200;  // pattern 0..4
            end

            // ── Epoch management (not for C12B) ─────────────────────────────
            if (suite_id != 1 && (depth_cnt >= EPOCH_DEPTH || local_cyc == 0)) begin
                accum_clr = 1'b1;
                depth_cnt = 0;
            end else begin
                accum_clr = 1'b0;
            end

            // ── Default NOP ─────────────────────────────────────────────────
            op_sel = 2'b11;
            op_a   = {1'b0, 6'd32, 6'd32};
            op_b   = {1'b0, 6'd32, 6'd32};
            cur_class = 2'd0;
            e_in_eff  = 6'd32;

            // ================================================================
            // C12A — Noise Injection (suite_id=0)
            // ================================================================
            if (suite_id == 0) begin
                // Base: SUB E=32,f=32 vs E=32,f=35 (A1 baseline)
                op_a    = {1'b0, 6'd32, 6'd32};
                op_sel  = 2'b01;           // SUB
                cur_class = 2'd1;

                // Construct op_b with noise based on test_id (noise level)
                case (test_id)
                    0: begin  // NL0: baseline (no noise)
                        op_b = {1'b0, 6'd32, 6'd35};
                    end
                    1: begin  // NL1: 10% fraction scramble
                        op_b[12]   = 1'b0;
                        op_b[11:6] = 6'd32;
                        op_b[5:0]  = (lfsr[9:0] < 10'd102) ? lfsr[5:0] : 6'd35;
                    end
                    2: begin  // NL2: 30% fraction scramble
                        op_b[12]   = 1'b0;
                        op_b[11:6] = 6'd32;
                        op_b[5:0]  = (lfsr[9:0] < 10'd307) ? lfsr[5:0] : 6'd35;
                    end
                    3: begin  // NL3: 60% fraction scramble
                        op_b[12]   = 1'b0;
                        op_b[11:6] = 6'd32;
                        op_b[5:0]  = (lfsr[9:0] < 10'd614) ? lfsr[5:0] : 6'd35;
                    end
                    4: begin  // NL4: exponent ±1 jitter
                        op_b[12]   = 1'b0;
                        op_b[5:0]  = 6'd35;
                        // jitter: 00→-1, 01→0, 10→0, 11→+1
                        case (lfsr[1:0])
                            2'b00: op_b[11:6] = 6'd31;
                            2'b11: op_b[11:6] = 6'd33;
                            default: op_b[11:6] = 6'd32;
                        endcase
                    end
                    5: begin  // NL5: 10% sign inversion
                        op_b[11:6] = 6'd32;
                        op_b[5:0]  = 6'd35;
                        op_b[12]   = (lfsr[9:0] < 10'd102) ? 1'b1 : 1'b0;
                    end
                    default: op_b = {1'b0, 6'd32, 6'd35};
                endcase
                e_in_eff = op_a[11:6];
            end

            // ================================================================
            // C12B — Long-Horizon Distribution Drift (suite_id=1)
            // ================================================================
            else if (suite_id == 1) begin
                // E_base drifts from 32 to 51 over 10,000 cycles
                // Increment every 526 cycles: 526×19 = 9,994 cycles
                e_in_eff[5:0] = 6'd32 + local_cyc / 526;
                if (e_in_eff > 6'd51) e_in_eff = 6'd51;

                // Alternate ADD and SUB using drifting E_base
                op_a[12]   = 1'b0;
                op_a[11:6] = e_in_eff;
                op_a[5:0]  = 6'd32;
                op_b[12]   = 1'b0;
                op_b[11:6] = e_in_eff;
                op_b[5:0]  = 6'd32 + (local_cyc[2:0]);  // slight fraction variation

                if (local_cyc[0]) begin
                    op_sel    = 2'b01;  // SUB
                    cur_class = 2'd1;
                end else begin
                    op_sel    = 2'b00;  // ADD
                    cur_class = 2'd0;
                end
            end

            // ================================================================
            // C12C — Adversarial Cancellation Chains (suite_id=2)
            // ================================================================
            else if (suite_id == 2) begin
                // Base pattern: MUL(feed, +2) on even cycles,
                //               MUL(feed, -2) on odd cycles → cancels in accum
                // Noise added based on pattern (test_id)
                case (test_id)
                    0: begin  // Clean cancellation
                        if (local_cyc[0] == 0) begin
                            op_a = cc_feed; op_b = {1'b0, 6'd33, 6'd0};  // ×2
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a = cc_feed; op_b = {1'b1, 6'd33, 6'd0};  // ×(-2)
                            op_sel = 2'b10; cur_class = 2'd3;
                        end
                    end
                    1: begin  // E±2 mismatch (exponent asymmetry)
                        if (local_cyc[0] == 0) begin
                            op_a = cc_feed; op_b = {1'b0, 6'd33, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a = cc_feed;
                            // E mismatch: use E=35 instead of E=33 for the negative
                            op_b = {1'b1, 6'd35, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end
                    end
                    2: begin  // 30% fraction noise on cancel operand
                        if (local_cyc[0] == 0) begin
                            op_a = cc_feed; op_b = {1'b0, 6'd33, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a       = cc_feed;
                            op_b[12]   = 1'b1;
                            op_b[11:6] = 6'd33;
                            op_b[5:0]  = (lfsr[9:0] < 10'd307) ? lfsr[5:0] : 6'd0;
                            op_sel = 2'b10; cur_class = 2'd3;
                        end
                    end
                    3: begin  // 10% sign flip on cancel step
                        if (local_cyc[0] == 0) begin
                            op_a = cc_feed; op_b = {1'b0, 6'd33, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a       = cc_feed;
                            // 90%: correct negative, 10%: accidentally positive → cancel fails
                            op_b[12]   = (lfsr[9:0] < 10'd102) ? 1'b0 : 1'b1;
                            op_b[11:6] = 6'd33;
                            op_b[5:0]  = 6'd0;
                            op_sel = 2'b10; cur_class = 2'd3;
                        end
                    end
                    default: begin  // Full corruption (E mismatch + fraction noise + sign flip)
                        if (local_cyc[0] == 0) begin
                            op_a = cc_feed; op_b = {1'b0, 6'd33, 6'd0};
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a       = cc_feed;
                            op_b[12]   = (lfsr[9:0] < 10'd102) ? 1'b0 : 1'b1;
                            op_b[11:6] = 6'd33 + lfsr[1:0];  // ±1..2 E jitter
                            op_b[5:0]  = (lfsr[8:0] < 9'd154) ? lfsr[5:0] : 6'd0; // 30% F noise
                            op_sel = 2'b10; cur_class = 2'd3;
                        end
                    end
                endcase
                e_in_eff = op_a[11:6];
            end

            // ================================================================
            // C12D — Semantic Mismatch (suite_id=3)
            // ================================================================
            else if (suite_id == 3) begin
                // Determine active mode (for MIXED, rotate every 50 cycles)
                reg [1:0] d_mode;
                d_mode = (test_id == 3) ? ((local_cyc % 200) / 50) : test_id[1:0];

                case (d_mode)
                    0: begin  // INT-like: ADD E=32, F cycles 0..63
                        op_a[12]   = 1'b0;
                        op_a[11:6] = 6'd32;
                        op_a[5:0]  = local_cyc[5:0];  // 0..63 cycling
                        op_b       = {1'b0, 6'd32, 6'd32};
                        op_sel     = 2'b00;
                        cur_class  = 2'd0;
                    end
                    1: begin  // PROB-like: ADD E=36..38 (0.25..1.0 probability range)
                        op_a[12]   = 1'b0;
                        op_a[11:6] = 6'd36 + local_cyc[1:0];  // 36..39
                        op_a[5:0]  = 6'd20 + lfsr[3:0];
                        op_b       = {1'b0, 6'd37, 6'd32};
                        op_sel     = 2'b00;
                        cur_class  = 2'd0;
                    end
                    2: begin  // ENERGY-like: MUL chain near SAT boundary
                        op_a       = d_feed;
                        op_b       = {1'b0, 6'd33, 6'd0};  // ×2
                        op_sel     = 2'b10;
                        cur_class  = 2'd3;
                    end
                    default: begin  // MIXED: any remaining
                        op_a = {1'b0, 6'd32, 6'd32}; op_b = {1'b0, 6'd32, 6'd32};
                        op_sel = 2'b00; cur_class = 2'd0;
                    end
                endcase
                e_in_eff = op_a[11:6];
            end

            // ================================================================
            // C12E — Failure Boundary Expansion (suite_id=4)
            // ================================================================
            else if (suite_id == 4) begin
                case (test_id)
                    0: begin  // SAT chain: repeated ADD at E=47
                        op_a   = {1'b0, 6'd47, 6'd32};
                        op_b   = {1'b0, 6'd47, 6'd32};
                        op_sel = 2'b00; cur_class = 2'd2;
                    end
                    1: begin  // COLL chain: repeated ADD at E=16 → TRANSITION→COLLAPSE
                        op_a   = {1'b0, 6'd16, 6'd32};
                        op_b   = {1'b0, 6'd16, 6'd32};
                        op_sel = 2'b00; cur_class = 2'd0;
                    end
                    2: begin  // BOUNCE: alternate E=47 and E=15 ADD every cycle
                        if (local_cyc[0]) begin
                            op_a = {1'b0, 6'd47, 6'd32}; op_b = {1'b0, 6'd47, 6'd32};
                        end else begin
                            op_a = {1'b0, 6'd15, 6'd32}; op_b = {1'b0, 6'd15, 6'd32};
                        end
                        op_sel = 2'b00; cur_class = 2'd2;
                    end
                    3: begin  // DEEP_BOUNCE: MUL push to E=50, then SUB to collapse
                        if ((local_cyc % 40) < 30) begin
                            op_a   = cc_feed; op_b = {1'b0, 6'd33, 6'd0};  // MUL push
                            op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            op_a   = {1'b0, 6'd32, 6'd32};  // SUB near-cancel
                            op_b   = {1'b0, 6'd32, 6'd34};
                            op_sel = 2'b01; cur_class = 2'd1;
                        end
                    end
                    default: begin  // MAXIMAL: cycle SAT/COLL/MUL/SUB every 10 cycles
                        case ((local_cyc % 40) / 10)
                            0: begin op_a={1'b0,6'd47,6'd32}; op_b={1'b0,6'd47,6'd32}; op_sel=2'b00; cur_class=2'd2; end
                            1: begin op_a={1'b0,6'd15,6'd32}; op_b={1'b0,6'd15,6'd32}; op_sel=2'b00; cur_class=2'd0; end
                            2: begin op_a=cc_feed; op_b={1'b0,6'd33,6'd0}; op_sel=2'b10; cur_class=2'd3; end
                            default: begin op_a={1'b0,6'd32,6'd32}; op_b={1'b0,6'd32,6'd35}; op_sel=2'b01; cur_class=2'd1; end
                        endcase
                    end
                endcase
                e_in_eff = op_a[11:6];
            end

            // ── C4 routing ──────────────────────────────────────────────────
            mode_tag = c4_mode(cur_class, e_in_eff, depth_cnt[7:0]);

            // ── Accumulator enable ──────────────────────────────────────────
            if (op_sel == 2'b11 ||
                classify(e_in_eff) == 2'd0 ||
                classify(e_in_eff) == 2'd3)
                accum_en = 1'b0;
            else
                accum_en = 1'b1;

            @(posedge clk); #1;

            // ── Feedback updates ────────────────────────────────────────────
            if (suite_id == 2 || (suite_id == 4 && (test_id == 3 || test_id == 4))) begin
                if (exp_ovf_flag || op_sel != 2'b10)
                    cc_feed = {1'b0, 6'd32, 6'd0};  // reset on OVF or non-MUL
                else
                    cc_feed = result;
            end else begin
                cc_feed = {1'b0, 6'd32, 6'd0};
            end

            if (suite_id == 3) begin
                if (exp_ovf_flag || op_sel != 2'b10)
                    d_feed = {1'b0, 6'd32, 6'd0};
                else
                    d_feed = result;
            end

            // ── Log ─────────────────────────────────────────────────────────
            $fwrite(fd, "%0d,%0d,%0d,%0d,", total_cyc, suite_id, local_cyc, test_id);
            case (op_sel)
                2'b00: $fwrite(fd, "ADD,");
                2'b01: $fwrite(fd, "SUB,");
                2'b10: $fwrite(fd, "MUL,");
                2'b11: $fwrite(fd, "NOP,");
            endcase
            $fwrite(fd, "%0d,%0d,", e_in_eff, result[11:6]);
            $fwrite(fd, "%0d,", accum_out);
            case (classify(result[11:6]))
                2'd0: $fwrite(fd, "COLLAPSE,");
                2'd1: $fwrite(fd, "TRANSITION,");
                2'd2: $fwrite(fd, "STABLE,");
                2'd3: $fwrite(fd, "SATURATE,");
            endcase
            $fwrite(fd, "%0d,%0d,%0d\n", underflow_flag, exp_ovf_flag, test_id);

            depth_cnt = depth_cnt + 1;
        end

        $fclose(fd);
        $display("  14,600 cycles → HBS_C12_ADVERSARIAL.csv");
        $finish;
    end

endmodule

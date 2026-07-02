`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c5_kernel_stress
// Project  : HORUS v3 — C4 Kernel Decision Surface Exhaustive Stress-Test
// File     : tb_hbs_c5_kernel_stress.v
//
// Purpose:
//   Pure combinational exhaustive evaluation of the C4 compiler kernel:
//
//     HORUS_KERNEL(workload_class, E, depth) → (mode_tag, action)
//
//   NO DUT INSTANTIATION. No hardware RTL imported.
//   The C4 kernel truth table is implemented directly as a Verilog
//   combinational function and tested against all 4 × 64 × 32 = 8192
//   input combinations.
//
// Input space:
//   workload_class ∈ {0=A, 1=B, 2=C, 3=D}
//   E              ∈ [0..63]    (6-bit exponent)
//   depth          ∈ [0..31]    (5-bit; extends 1 step beyond D>16 threshold)
//
// Region encoding  (classify function):
//   0 = COLLAPSE   E ≤ 15
//   1 = TRANSITION E ∈ [16..19] or [44..47]
//   2 = STABLE     E ∈ [20..43]
//   3 = SATURATION E ≥ 48
//
// Mode encoding    (matches hardware mode_tag):
//   0 = 000 (STD)
//   2 = 010 (PRSC)
//   3 = 011 (SAFE)
//
// Action encoding:
//   0 = EXECUTE
//   1 = NORMALIZE_THEN_EXECUTE
//   2 = NORMALIZE_THEN_ROUTE
//   3 = SENTINEL_OR_SKIP
//   4 = CLAMP
//   5 = INSERT_EPOCH_BOUNDARY
//
// Output: HBS_C5_KERNEL_STRESS.csv
// ============================================================================

module tb_hbs_c5_kernel_stress;

    // =========================================================================
    // Encoding constants
    // =========================================================================

    // workload_class
    localparam [1:0] CLS_A = 2'd0;
    localparam [1:0] CLS_B = 2'd1;
    localparam [1:0] CLS_C = 2'd2;
    localparam [1:0] CLS_D = 2'd3;

    // region
    localparam [1:0] RGN_COLLAPSE   = 2'd0;
    localparam [1:0] RGN_TRANSITION = 2'd1;
    localparam [1:0] RGN_STABLE     = 2'd2;
    localparam [1:0] RGN_SATURATE   = 2'd3;

    // mode_tag (as 3-bit value matching hardware; only 000/010/011 used)
    localparam [2:0] MODE_STD  = 3'd0;   // 3'b000
    localparam [2:0] MODE_PRSC = 3'd2;   // 3'b010
    localparam [2:0] MODE_SAFE = 3'd3;   // 3'b011

    // action
    localparam [2:0] ACT_EXECUTE            = 3'd0;
    localparam [2:0] ACT_NORM_THEN_EXEC     = 3'd1;
    localparam [2:0] ACT_NORM_THEN_ROUTE    = 3'd2;
    localparam [2:0] ACT_SENTINEL_OR_SKIP   = 3'd3;
    localparam [2:0] ACT_CLAMP              = 3'd4;
    localparam [2:0] ACT_INSERT_EPOCH_BOUND = 3'd5;

    // =========================================================================
    // Region classification function
    // =========================================================================
    function [1:0] classify;
        input [5:0] e;
        begin
            if      (e <= 6'd15)                   classify = RGN_COLLAPSE;
            else if (e <= 6'd19)                   classify = RGN_TRANSITION;
            else if (e <= 6'd43)                   classify = RGN_STABLE;
            else if (e <= 6'd47)                   classify = RGN_TRANSITION;
            else                                   classify = RGN_SATURATE;
        end
    endfunction

    // =========================================================================
    // HORUS_KERNEL — C4 decision function
    // =========================================================================
    // Returns {mode[2:0], action[2:0]} packed as 6-bit value.
    // Implements the exact 32-entry truth table from C4 §1.4.
    //
    // Depth override (depth > 16) is unconditional and applied last,
    // overriding any region/class assignment.
    // =========================================================================
    function [5:0] horus_kernel;
        input [1:0] cls;
        input [5:0] e;
        input [4:0] depth;
        reg [1:0]   region;
        reg [2:0]   mode;
        reg [2:0]   action;
        begin
            region = classify(e);

            // ── Region dispatch ──────────────────────────────────────────────
            case (region)
                RGN_STABLE: begin
                    mode   = MODE_STD;
                    action = ACT_EXECUTE;
                end

                RGN_TRANSITION: begin
                    if (cls == CLS_B || cls == CLS_D) begin
                        mode   = MODE_PRSC;
                        action = ACT_NORM_THEN_EXEC;
                    end else begin
                        mode   = MODE_STD;
                        action = ACT_EXECUTE;
                    end
                end

                RGN_COLLAPSE: begin
                    if (cls == CLS_A) begin
                        mode   = MODE_SAFE;
                        action = ACT_SENTINEL_OR_SKIP;
                    end else begin
                        mode   = MODE_PRSC;
                        action = ACT_NORM_THEN_ROUTE;
                    end
                end

                RGN_SATURATE: begin
                    mode   = MODE_SAFE;
                    action = ACT_CLAMP;
                end

                default: begin
                    mode   = MODE_STD;
                    action = ACT_EXECUTE;
                end
            endcase

            // ── Depth override (unconditional, applied after region) ──────────
            // depth > 16 means depth ≥ 17.  5-bit depth range: 0..31.
            if (depth > 5'd16) begin
                mode   = MODE_PRSC;
                action = ACT_INSERT_EPOCH_BOUND;
            end

            horus_kernel = {mode, action};
        end
    endfunction

    // =========================================================================
    // Test variables
    // =========================================================================
    integer fd;
    integer cycle_cnt;
    integer cls_i, e_i, d_i;

    reg [5:0]  kernel_out;
    reg [2:0]  out_mode;
    reg [2:0]  out_action;
    reg [1:0]  out_region;
    reg        boundary_flag;
    reg        override_flag;

    // =========================================================================
    // Main exhaustive sweep
    // =========================================================================
    initial begin : MAIN

        $display("");
        $display("================================================================");
        $display("  HBS-C5: HORUS C4 Kernel Decision Surface Stress-Test");
        $display("  Exhaustive sweep: 4 classes × 64 E × 32 depth = 8192 states");
        $display("================================================================");

        fd = $fopen("HBS_C5_KERNEL_STRESS.csv", "w");
        $fwrite(fd,
            "cycle,class,E,depth,region,mode,action,boundary_flag,override_flag\n");

        cycle_cnt = 0;

        // Triple-nested counter: exhaustive enumeration
        for (cls_i = 0; cls_i < 4; cls_i = cls_i + 1) begin
            for (e_i = 0; e_i < 64; e_i = e_i + 1) begin
                for (d_i = 0; d_i < 32; d_i = d_i + 1) begin

                    // Compute kernel output
                    kernel_out  = horus_kernel(cls_i[1:0], e_i[5:0], d_i[4:0]);
                    out_mode    = kernel_out[5:3];
                    out_action  = kernel_out[2:0];
                    out_region  = classify(e_i[5:0]);
                    boundary_flag = (e_i == 15 || e_i == 16 || e_i == 47 || e_i == 48);
                    override_flag = (d_i > 16);

                    // Write CSV row
                    $fwrite(fd, "%0d,", cycle_cnt);

                    // class string
                    case (cls_i)
                        0: $fwrite(fd, "A,");
                        1: $fwrite(fd, "B,");
                        2: $fwrite(fd, "C,");
                        3: $fwrite(fd, "D,");
                    endcase

                    $fwrite(fd, "%0d,%0d,", e_i, d_i);

                    // region string
                    case (out_region)
                        RGN_COLLAPSE:   $fwrite(fd, "COLLAPSE,");
                        RGN_TRANSITION: $fwrite(fd, "TRANSITION,");
                        RGN_STABLE:     $fwrite(fd, "STABLE,");
                        RGN_SATURATE:   $fwrite(fd, "SATURATE,");
                    endcase

                    // mode as 3-digit binary string
                    case (out_mode)
                        MODE_STD:  $fwrite(fd, "000,");
                        MODE_PRSC: $fwrite(fd, "010,");
                        MODE_SAFE: $fwrite(fd, "011,");
                        default:   $fwrite(fd, "???,");
                    endcase

                    // action string
                    case (out_action)
                        ACT_EXECUTE:            $fwrite(fd, "EXECUTE,");
                        ACT_NORM_THEN_EXEC:     $fwrite(fd, "NORMALIZE_THEN_EXECUTE,");
                        ACT_NORM_THEN_ROUTE:    $fwrite(fd, "NORMALIZE_THEN_ROUTE,");
                        ACT_SENTINEL_OR_SKIP:   $fwrite(fd, "SENTINEL_OR_SKIP,");
                        ACT_CLAMP:              $fwrite(fd, "CLAMP,");
                        ACT_INSERT_EPOCH_BOUND: $fwrite(fd, "INSERT_EPOCH_BOUNDARY,");
                    endcase

                    $fwrite(fd, "%0d,%0d\n", boundary_flag, override_flag);

                    cycle_cnt = cycle_cnt + 1;
                end
            end
        end

        $fclose(fd);

        $display("  %0d states logged to HBS_C5_KERNEL_STRESS.csv", cycle_cnt);
        $display("================================================================");
        $display("");
        $finish;
    end

endmodule

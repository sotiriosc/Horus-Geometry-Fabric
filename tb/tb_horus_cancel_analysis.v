`timescale 1ns / 1ps
// ============================================================================
// tb_horus_cancel_analysis.v — TEST 9 Cancellation Residual Structure Study
// Observe only. DUT: horus_system | host_tile_depth=63 | accum_en=1
// Run: make cancel_analysis
// ============================================================================

module tb_horus_cancel_analysis;

    localparam CLK_PERIOD = 10;
    localparam CLK_HALF   = CLK_PERIOD / 2;

    localparam [12:0] NFE_ONE = 13'h800;
    localparam [1:0]  OP_MUL  = 2'b10;
    localparam [1:0]  OP_NOP  = 2'b11;

    reg clk, rst_n;
    reg [12:0] op_a, op_b;
    reg [1:0]  op_sel;
    reg accum_en, accum_clr;
    reg [5:0]  host_tile_depth;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire underflow_flag, exp_ovf_flag;
    wire [31:0] pe_accum = dut.u_nfe.accum_reg;

    integer g_cycle, csv_fd;
    reg [31:0] lfsr;

    reg [12:0] y_list [0:4];
    integer yi, rep, n;

    horus_system dut (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a), .op_b(op_b), .op_sel(op_sel),
        .accum_en(accum_en), .accum_clr(accum_clr),
        .host_tile_depth(host_tile_depth),
        .result(result), .accum_out(accum_out),
        .rollover_flag(), .underflow_flag(underflow_flag),
        .exp_ovf_flag(exp_ovf_flag),
        .op_count(), .accum_full()
    );

    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    function [12:0] flip_sign;
        input [12:0] cw;
        flip_sign = cw ^ 13'h1000;
    endfunction

    function [31:0] lfsr_step;
        input [31:0] s;
        lfsr_step = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
    endfunction

    function [12:0] rand_y_full;
        input [31:0] s;
        reg [11:0] v;
        begin
            v = 12'h300 + (s[11:0] % 12'h601);
            rand_y_full = {1'b0, v[11:6], v[5:0]};
        end
    endfunction

    task clr_accum;
        begin
            @(negedge clk);
            op_a = NFE_ONE; op_b = NFE_ONE; op_sel = OP_NOP;
            accum_en = 0; accum_clr = 1;
            @(posedge clk); #1;
            accum_clr = 0;
        end
    endtask

    task mac;
        input [12:0] a, b;
        begin
            @(negedge clk);
            op_a = a; op_b = b; op_sel = OP_MUL;
            accum_en = 1; accum_clr = 0;
            @(posedge clk); #1;
        end
    endtask

    task cancel_pair;
        input [255:0] test_id;
        input [255:0] subtest;
        input integer cycle;
        input [12:0]  x;
        input [12:0]  y;
        input integer order;   // 0 = y then -y, 1 = -y then y
        input integer do_log;
        reg [12:0] ny;
        reg [31:0] r1, r2, residual;
        reg uf1, uf2, ov1, ov2;
        begin
            ny = flip_sign(y);
            clr_accum();
            uf1 = 0; uf2 = 0; ov1 = 0; ov2 = 0;

            if (order == 0) begin
                mac(x, y);  r1 = result; uf1 = underflow_flag; ov1 = exp_ovf_flag;
                mac(x, ny); r2 = result; uf2 = underflow_flag; ov2 = exp_ovf_flag;
            end else begin
                mac(x, ny); r2 = result; uf2 = underflow_flag; ov2 = exp_ovf_flag;
                mac(x, y);  r1 = result; uf1 = underflow_flag; ov1 = exp_ovf_flag;
            end

            residual = pe_accum;

            if (do_log) begin
                $fwrite(csv_fd,
                    "%0s,%0s,%0d,0x%04h,%0d,0x%08h,0x%08h,0x%08h,%0d,%0d,%0d,%0d,%0d\n",
                    test_id, subtest, cycle, y, order,
                    r1, r2, residual,
                    y[11:6], y[5:0],
                    uf1 | uf2, ov1 | ov2, g_cycle);
                g_cycle = g_cycle + 1;
            end
        end
    endtask

    // =========================================================================
    initial begin
        rst_n = 0; accum_en = 0; accum_clr = 0;
        host_tile_depth = 63;
        g_cycle = 0;
        lfsr = 32'hC9A9C001;

        y_list[0] = 13'h300;
        y_list[1] = 13'h480;
        y_list[2] = 13'h600;
        y_list[3] = 13'h780;
        y_list[4] = 13'h900;

        csv_fd = $fopen("cancel_analysis.csv", "w");
        $fwrite(csv_fd,
            "test,subtest,cycle,y_hex,order,r1,r2,residual,e_y,f_y,uf,ovf,g_cycle\n");

        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1;

        $display("TEST 9 — Cancellation residual structure study");

        // ----- 9A: 50 repeats × 5 fixed y -----
        for (yi = 0; yi < 5; yi = yi + 1)
            for (rep = 0; rep < 50; rep = rep + 1)
                cancel_pair("9A", "repeatability", rep, NFE_ONE, y_list[yi], 0, 1);

        // ----- 9B: 100 cycles, fixed y, random order -----
        lfsr = 32'h9B9B9B01;
        for (n = 0; n < 100; n = n + 1) begin
            lfsr = lfsr_step(lfsr);
            cancel_pair("9B", "order_sensitivity", n, NFE_ONE, 13'h600,
                        lfsr[0], 1);
        end

        // ----- 9C + 9D: 1000 random-y pairs -----
        lfsr = 32'h9C9D0001;
        for (n = 0; n < 1000; n = n + 1) begin
            lfsr = lfsr_step(lfsr);
            cancel_pair("9C", "correlation", n, NFE_ONE, rand_y_full(lfsr),
                        lfsr[1], 1);
        end

        $fclose(csv_fd);
        $display("Wrote cancel_analysis.csv (%0d logged pairs)", g_cycle);
        $display("Next: python3 analyze_cancellation.py");
        $finish;
    end

endmodule

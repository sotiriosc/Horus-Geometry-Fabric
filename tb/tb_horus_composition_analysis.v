`timescale 1ns / 1ps
// ============================================================================
// tb_horus_composition_analysis.v — TEST 10 Multi-Operation Composition Stress
// Observe only. DUT: horus_system | host_tile_depth=63 | accum_en=1
// Run: make composition_analysis
// ============================================================================

module tb_horus_composition_analysis;

    localparam CLK_PERIOD = 10;
    localparam CLK_HALF   = CLK_PERIOD / 2;

    localparam [12:0] NFE_ONE = 13'h800;
    localparam [1:0]  OP_ADD  = 2'b00;
    localparam [1:0]  OP_SUB  = 2'b01;
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

    integer g_cycle, csv_fd, n, rep, depth, perm;
    reg [31:0] lfsr;

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

    task exec_op;
        input [12:0] a, b;
        input [1:0]  sel;
        input        do_acc;
        begin
            @(negedge clk);
            op_a = a; op_b = b; op_sel = sel;
            accum_en = do_acc; accum_clr = 0;
            @(posedge clk); #1;
            if (sel == OP_SUB && a[5:0] < b[5:0] && a[11:6] != 0)
                @(posedge clk); #1;
        end
    endtask

    task log_row;
        input [255:0] test_id;
        input [255:0] subtest;
        input integer cycle;
        input [12:0]  y;
        input integer perm_order;
        input integer chain_depth;
        input [31:0]  s1, s2, s3, s4;
        input [31:0]  residual;
        input integer sat_floor;
        input integer sat_max;
        input integer uf_hit;
        input integer ov_hit;
        begin
            $fwrite(csv_fd,
                "%0s,%0s,%0d,0x%04h,%0d,%0d,0x%08h,0x%08h,0x%08h,0x%08h,0x%08h,0x%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                test_id, subtest, cycle, y, perm_order, chain_depth,
                s1, s2, s3, s4, residual, pe_accum,
                y[11:6], y[5:0],
                sat_floor, sat_max, uf_hit, ov_hit, g_cycle);
            g_cycle = g_cycle + 1;
        end
    endtask

    // Short chain (10A baseline): MUL→ADD→MUL→SUB
    task chain_short;
        input [12:0] x;
        input [12:0] y;
        input integer perm_order;
        output [31:0] s1, s2, s3, s4;
        output integer uf_hit, ov_hit;
        reg [12:0] ny, state;
        begin
            uf_hit = 0; ov_hit = 0;
            ny = flip_sign(y);

            case (perm_order)
                0: begin // MUL → ADD → MUL → SUB
                    exec_op(x, y, OP_MUL, 0); s1 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                    exec_op(result[12:0], x, OP_ADD, 0); s2 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                    exec_op(result[12:0], ny, OP_MUL, 0); s3 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                    exec_op(result[12:0], x, OP_SUB, 0); s4 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                end
                1: begin // ADD → MUL → SUB → MUL
                    exec_op(x, y, OP_ADD, 0); s1 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                    exec_op(result[12:0], x, OP_MUL, 0); s2 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                    exec_op(result[12:0], y, OP_SUB, 0); s3 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                    exec_op(result[12:0], ny, OP_MUL, 0); s4 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                end
                default: begin // SUB → MUL → ADD → MUL (perm 2)
                    exec_op(x, y, OP_SUB, 0); s1 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                    exec_op(result[12:0], y, OP_MUL, 0); s2 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                    exec_op(result[12:0], x, OP_ADD, 0); s3 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                    exec_op(result[12:0], ny, OP_MUL, 0); s4 = result;
                    uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                end
            endcase
        end
    endtask

    // Deep chain (10C): 10× (MUL→ADD→SUB)
    task chain_deep;
        input [12:0] x;
        input [12:0] y;
        output [31:0] s1, s2, s3, s4;
        output integer sat_floor, sat_max;
        output integer uf_hit, ov_hit;
        reg [12:0] state;
        integer i;
        begin
            uf_hit = 0; ov_hit = 0;
            sat_floor = 0; sat_max = 0;
            s1 = 0; s2 = 0; s3 = 0;
            state = x;

            for (i = 0; i < 10; i = i + 1) begin
                exec_op(state, y, OP_MUL, 0);
                s1 = result;
                uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                state = result[12:0];

                exec_op(state, x, OP_ADD, 0);
                s2 = result;
                uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                state = result[12:0];

                exec_op(state, y, OP_SUB, 0);
                s3 = result;
                uf_hit = uf_hit | underflow_flag; ov_hit = ov_hit | exp_ovf_flag;
                state = result[12:0];

                if (state == 13'h000) sat_floor = sat_floor + 1;
                if (state == 13'h1FFF) sat_max = sat_max + 1;
            end
            s4 = state;
        end
    endtask

    // =========================================================================
    initial begin
        reg [12:0] y;
        reg [31:0] s1, s2, s3, s4, residual;
        integer uf_hit, ov_hit, sat_floor, sat_max;

        rst_n = 0; accum_en = 0; accum_clr = 0;
        host_tile_depth = 63;
        g_cycle = 0;
        lfsr = 32'h10A00001;

        csv_fd = $fopen("composition_analysis.csv", "w");
        $fwrite(csv_fd,
            "test,subtest,cycle,y_hex,perm_order,chain_depth,s1,s2,s3,s4,residual,pe_acc,e_y,f_y,sat_floor,sat_max,uf,ovf,g_cycle\n");

        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1;

        $display("TEST 10 — Multi-operation composition stress study");

        // ----- 10A: 200 short chains, perm=0, accumulate step4 -----
        clr_accum();
        for (n = 0; n < 200; n = n + 1) begin
            lfsr = lfsr_step(lfsr);
            y = rand_y_full(lfsr);
            chain_short(NFE_ONE, y, 0, s1, s2, s3, s4, uf_hit, ov_hit);
            exec_op(s4[12:0], 13'h000, OP_ADD, 1);
            residual = s4;
            log_row("10A", "short_chain", n, y, 0, 4, s1, s2, s3, s4, residual,
                    0, 0, uf_hit, ov_hit);
        end

        // ----- 10B: 200 short chains, random perm order -----
        clr_accum();
        lfsr = 32'h10B00001;
        for (n = 0; n < 200; n = n + 1) begin
            lfsr = lfsr_step(lfsr);
            y = rand_y_full(lfsr);
            perm = lfsr[1:0] % 3;
            chain_short(NFE_ONE, y, perm, s1, s2, s3, s4, uf_hit, ov_hit);
            exec_op(s4[12:0], 13'h000, OP_ADD, 1);
            residual = s4;
            log_row("10B", "order_perturb", n, y, perm, 4, s1, s2, s3, s4, residual,
                    0, 0, uf_hit, ov_hit);
        end

        // ----- 10C: 100 deep chains (depth 30 ops) -----
        clr_accum();
        lfsr = 32'h10C00001;
        for (n = 0; n < 100; n = n + 1) begin
            lfsr = lfsr_step(lfsr);
            y = rand_y_full(lfsr);
            chain_deep(NFE_ONE, y, s1, s2, s3, s4, sat_floor, sat_max, uf_hit, ov_hit);
            exec_op(s4[12:0], 13'h000, OP_ADD, 1);
            residual = s4;
            log_row("10C", "deep_chain", n, y, 0, 30, s1, s2, s3, s4, residual,
                    sat_floor, sat_max, uf_hit, ov_hit);
        end

        // ----- 10D: 1000 mixed compositions (500 short + 500 deep) -----
        clr_accum();
        lfsr = 32'h10D00001;
        for (n = 0; n < 1000; n = n + 1) begin
            lfsr = lfsr_step(lfsr);
            y = rand_y_full(lfsr);
            if (n < 500) begin
                perm = lfsr[2:0] % 3;
                chain_short(NFE_ONE, y, perm, s1, s2, s3, s4, uf_hit, ov_hit);
                depth = 4;
                sat_floor = 0; sat_max = 0;
            end else begin
                chain_deep(NFE_ONE, y, s1, s2, s3, s4, sat_floor, sat_max, uf_hit, ov_hit);
                depth = 30;
                perm = 0;
            end
            exec_op(s4[12:0], 13'h000, OP_ADD, 1);
            residual = s4;
            log_row("10D", "mixed_model", n, y, perm, depth, s1, s2, s3, s4, residual,
                    sat_floor, sat_max, uf_hit, ov_hit);
        end

        $fclose(csv_fd);
        $display("Wrote composition_analysis.csv (%0d logged compositions)", g_cycle);
        $display("Next: python3 analyze_composition.py");
        $finish;
    end

endmodule

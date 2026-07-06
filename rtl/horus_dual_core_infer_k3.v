// rtl/horus_dual_core_infer_k3.v — K3 measurement variant of horus_dual_core.
//
// Structurally identical to horus_dual_core.v except mode_r is hardwired to 1
// (E4M3/inference always).  Synthesis constant-propagates hi_en = ~mode_r = 0,
// pruning all E3M6-specific logic (upper mantissa gates, E3M6 normalizer, etc.).
//
// Area of this module = dual_core_area - gated_inference_area
// K3 gated fraction = (dual_core_area - this_area) / dual_core_area
//
// DO NOT USE for functional purposes — only for K3 area measurement.

`default_nettype none

module horus_dual_core_infer_k3 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [9:0]  op_a,
    input  wire [9:0]  op_b,
    output reg  [9:0]  result
);

    // mode_r hardwired to 1 — synthesis prunes all ~mode_r logic
    wire mode_r = 1'b1;

    // hi_en = ~mode_r = 0 — synthesis prunes AND gates to constant 0
    wire hi_en = ~mode_r;

    // ── Signs ──────────────────────────────────────────────────────────────────
    wire s_a = mode_r ? op_a[7]   : op_a[9];
    wire s_b = mode_r ? op_b[7]   : op_b[9];
    wire s_r = s_a ^ s_b;

    // ── E3M6 fields (pruned by synthesis since mode_r=1) ──────────────────────
    wire [2:0] e3_a  = op_a[8:6];
    wire [2:0] e3_b  = op_b[8:6];
    wire [5:0] f6_a  = op_a[5:0];
    wire [5:0] f6_b  = op_b[5:0];

    // ── E4M3 fields ────────────────────────────────────────────────────────────
    wire [3:0] e4_a  = op_a[6:3];
    wire [3:0] e4_b  = op_b[6:3];
    wire [2:0] f3_a  = op_a[2:0];
    wire [2:0] f3_b  = op_b[2:0];

    // ── E4M3 special-value detection ──────────────────────────────────────────
    wire nan_a  = mode_r & (e4_a == 4'hF) & (&f3_a);
    wire nan_b  = mode_r & (e4_b == 4'hF) & (&f3_b);
    wire zero_a = mode_r ? (op_a[6:0] == 7'd0) : (op_a[8:0] == 9'd0);
    wire zero_b = mode_r ? (op_b[6:0] == 7'd0) : (op_b[8:0] == 9'd0);
    wire sub_a  = mode_r & (e4_a == 4'd0) & ~zero_a;
    wire sub_b  = mode_r & (e4_b == 4'd0) & ~zero_b;

    // ── E3M6 flush (pruned by synthesis since ~mode_r=0) ──────────────────────
    wire e3_flush = (~mode_r) & ((e3_a == 3'd0) | (e3_b == 3'd0));

    // ── Effective exponents ────────────────────────────────────────────────────
    wire [4:0] ae_a = mode_r ? (sub_a ? 5'd1 : {1'b0, e4_a}) : {2'b00, e3_a};
    wire [4:0] ae_b = mode_r ? (sub_b ? 5'd1 : {1'b0, e4_b}) : {2'b00, e3_b};

    // ── Mantissa gating (hi_en=0 → mant_a6/5/4 all zero) ─────────────────────
    wire mant_a6 = hi_en & ~zero_a;
    wire mant_b6 = hi_en & ~zero_b;
    wire mant_a5 = f6_a[5] & hi_en;
    wire mant_b5 = f6_b[5] & hi_en;
    wire mant_a4 = f6_a[4] & hi_en;
    wire mant_b4 = f6_b[4] & hi_en;

    wire H_a4m3 = ~sub_a & ~zero_a;
    wire H_b4m3 = ~sub_b & ~zero_b;
    wire mant_a3 = mode_r ? H_a4m3 : f6_a[3];
    wire mant_b3 = mode_r ? H_b4m3 : f6_b[3];

    wire [6:0] mant_a = {mant_a6, mant_a5, mant_a4, mant_a3, op_a[2:0]};
    wire [6:0] mant_b = {mant_b6, mant_b5, mant_b4, mant_b3, op_b[2:0]};

    wire [13:0] P = mant_a * mant_b;

    // ── E3M6 normalization (pruned by synthesis since mode_r=1) ───────────────
    wire P_msb_e3m6 = P[13];
    wire [5:0] fr_e3m6 = P_msb_e3m6 ? P[12:7] : P[11:6];
    wire [4:0] e_sum_e3m6 = ae_a + ae_b + {4'b0, P_msb_e3m6};
    wire sat_e3m6      = (e_sum_e3m6 > 5'd11);
    wire sub_out_e3m6  = ~sat_e3m6 & (e_sum_e3m6 <= 5'd4);
    wire [6:0] sub_mant_e3m6 = {1'b1, fr_e3m6};
    reg  [5:0] f_sub_e3m6;
    always @(*) begin
        case (5'd5 - e_sum_e3m6)
            5'd1:    f_sub_e3m6 = sub_mant_e3m6[6:1];
            5'd2:    f_sub_e3m6 = {1'b0, sub_mant_e3m6[6:2]};
            default: f_sub_e3m6 = {2'b00, sub_mant_e3m6[6:3]};
        endcase
    end
    wire [2:0] e_r_e3m6  = e_sum_e3m6[2:0] - 3'd4;
    wire [2:0] e_out_e3m6 = sat_e3m6 ? 3'd7 : (sub_out_e3m6 ? 3'd0 : e_r_e3m6);
    wire [5:0] f_out_e3m6 = sat_e3m6 ? 6'h3F : (sub_out_e3m6 ? f_sub_e3m6 : fr_e3m6);

    // ── E4M3 normalization ─────────────────────────────────────────────────────
    wire P_msb_e4m3 = P[7];
    reg  [2:0] norm_shift_e4m3;
    always @(*) begin
        if (P[7])      norm_shift_e4m3 = 3'd0;
        else if (P[6]) norm_shift_e4m3 = 3'd0;
        else if (P[5]) norm_shift_e4m3 = 3'd1;
        else if (P[4]) norm_shift_e4m3 = 3'd2;
        else if (P[3]) norm_shift_e4m3 = 3'd3;
        else           norm_shift_e4m3 = 3'd4;
    end

    wire [7:0] P_shifted_e4m3 = P[7:0] << norm_shift_e4m3;
    wire       ps_msb  = P_shifted_e4m3[7];

    wire [2:0] man_raw_e4m3   = ps_msb ? P_shifted_e4m3[6:4] : P_shifted_e4m3[5:3];
    wire       rnd_e4m3       = ps_msb ? P_shifted_e4m3[3]   : P_shifted_e4m3[2];
    wire       sty_e4m3       = ps_msb ? |P_shifted_e4m3[2:0]: |P_shifted_e4m3[1:0];
    wire       do_rnd_e4m3    = rnd_e4m3 & (sty_e4m3 | man_raw_e4m3[0]);
    wire [3:0] man_rd_e4m3    = {1'b0, man_raw_e4m3} + {3'b0, do_rnd_e4m3};
    wire       rnd_carry_e4m3 = man_rd_e4m3[3];
    wire [2:0] f3_out_e4m3    = man_rd_e4m3[2:0];

    wire signed [5:0] e_r_pre_e4m3 = $signed({1'b0, ae_a}) + $signed({1'b0, ae_b})
                                      + {5'b0, ps_msb}
                                      - {3'b0, norm_shift_e4m3}
                                      - 6'sd7;
    wire signed [5:0] e_r_e4m3_s = e_r_pre_e4m3 + {5'b0, rnd_carry_e4m3};

    wire overflow_e4m3  = (e_r_e4m3_s > 6'sd15);
    wire nan_out_e4m3   = nan_a | nan_b;
    wire zero_out_e4m3  = zero_a | zero_b;
    wire would_nan_e4m3 = (e_r_e4m3_s == 6'sd15) & (&f3_out_e4m3);

    wire [3:0] e4_out = (overflow_e4m3 | would_nan_e4m3) ? 4'hF : e_r_e4m3_s[3:0];
    wire [2:0] f3_out = (overflow_e4m3 | would_nan_e4m3) ? 3'h6 : f3_out_e4m3;

    wire e4m3_normal_path = (e_r_pre_e4m3 >= 6'sd1);
    wire e4m3_sub_path    = (e_r_pre_e4m3 >= -6'sd2) & (e_r_pre_e4m3 <= 6'sd0);
    wire e4m3_flush_path  = (e_r_pre_e4m3 <= -6'sd3);

    wire [3:0] sub_mant_4  = ps_msb ? P_shifted_e4m3[7:4] : P_shifted_e4m3[6:3];
    wire [3:0] sub_low_4   = ps_msb ? P_shifted_e4m3[3:0] : {1'b0, P_shifted_e4m3[2:0]};

    reg  [2:0] e4m3_fsub_raw;
    reg        e4m3_fsub_rnd;
    reg        e4m3_fsub_sty;
    always @(*) begin
        if (e_r_pre_e4m3 == 6'sd0) begin
            e4m3_fsub_raw = sub_mant_4[3:1];
            e4m3_fsub_rnd = sub_mant_4[0];
            e4m3_fsub_sty = |sub_low_4;
        end else if (e_r_pre_e4m3 == -6'sd1) begin
            e4m3_fsub_raw = {1'b0, sub_mant_4[3:2]};
            e4m3_fsub_rnd = sub_mant_4[1];
            e4m3_fsub_sty = sub_mant_4[0] | (|sub_low_4);
        end else begin
            e4m3_fsub_raw = {2'b00, sub_mant_4[3]};
            e4m3_fsub_rnd = sub_mant_4[2];
            e4m3_fsub_sty = |sub_mant_4[1:0] | (|sub_low_4);
        end
    end

    wire e4m3_fsub_is_flush = (e4m3_fsub_raw == 3'd0);
    wire       e4m3_fsub_drnd = e4m3_fsub_rnd & (e4m3_fsub_sty | e4m3_fsub_raw[0]);
    wire [3:0] e4m3_fsub_rd   = {1'b0, e4m3_fsub_raw} + {3'b0, e4m3_fsub_drnd};

    // ── Output mux (registered result) ────────────────────────────────────────
    reg [9:0] computed;

    always @(*) begin
        if (!mode_r) begin
            if (e3_flush)
                computed = {s_r, 9'd0};
            else
                computed = {s_r, e_out_e3m6, f_out_e3m6};
        end else begin
            if (nan_out_e4m3)
                computed = 10'h07F;
            else if (zero_out_e4m3)
                computed = 10'h000;
            else if (e4m3_flush_path | (e4m3_sub_path & e4m3_fsub_is_flush))
                computed = {2'b00, s_r, 7'd0};
            else if (e4m3_sub_path & e4m3_fsub_rd[3])
                computed = {2'b00, s_r, 4'd1, 3'd0};
            else if (e4m3_sub_path)
                computed = {2'b00, s_r, 4'd0, e4m3_fsub_rd[2:0]};
            else
                computed = {2'b00, s_r, e4_out, f3_out};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) result <= 10'd0;
        else        result <= computed;
    end

endmodule

`default_nettype wire

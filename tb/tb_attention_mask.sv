`timescale 1ns/1ps
//=====================================================================
//  tb_attention_mask.sv  --  加分项 A（因果 Mask）独立测试平台
//
//  被测: attention_top #(.MASK_EN(1'b1))
//  功能: 当 j > pos_i 时屏蔽对应 Key —— 被屏蔽的 Key 不参与 x_max 检索、
//        权重为 0、不进入 L 与 ACC。
//
//  检查三层结果（期望值由 model/attention_golden.py 带 pos 参数算出）:
//    1) 权重缓冲 dut.weight_buf[j] 是否按 Mask 置 0
//    2) L = Σweight 是否正确
//    3) 4 拍输出 O 是否与黄金模型一致
//
//  运行:
//    iverilog -g2012 -o mask.vvp rtl/exp_lut.sv rtl/seq_div.sv rtl/attention_top.sv tb/tb_attention_mask.sv
//    vvp mask.vvp
//=====================================================================

module tb_attention_mask;
    localparam int S = 8;
    localparam int D = 4;
    localparam int N_CASE = 3;          // pos_i = 0 / 3 / 7

    //---------------- 时钟与复位 ----------------
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    //---------------- DUT 接口 ----------------
    logic               start    = 1'b0;
    logic [3:0]         pos_i    = 4'd0;
    logic               q_valid  = 1'b0;
    logic               kv_valid = 1'b0;
    logic signed [7:0]  q_in     = 8'sd0;
    logic signed [7:0]  k_in     = 8'sd0;
    logic signed [7:0]  v_in     = 8'sd0;
    wire signed [7:0]   out_data;
    wire                out_valid;
    wire                done;
    wire                data_ready;

    attention_top #(.S(S), .D(D), .MASK_EN(1'b1), .DOT_PAR(1)) dut (
        .clk (clk), .rst_n (rst_n), .start (start), .pos_i (pos_i),
        .q_in (q_in), .k_in (k_in), .v_in (v_in),
        .q_valid (q_valid), .kv_valid (kv_valid),
        .data_ready (data_ready), .out_data (out_data),
        .out_valid (out_valid), .done (done)
    );

    //------------------------------------------------------------------
    //  测试数据（与 sim/check_mask.py 完全一致）
    //------------------------------------------------------------------
    int        q_data [0:D-1];
    int        k_data [0:S*D-1];
    int        v_data [0:S*D-1];
    logic [3:0] pos_exp [0:N_CASE-1];
    int        w_exp [0:N_CASE*S-1];
    int        l_exp [0:N_CASE-1];
    int        o_exp [0:N_CASE*D-1];

    // iverilog 不支持数组整体初始化, 这里逐元素赋值
    initial begin
        // Q = [1, 1, 0, 0]
        q_data[0] = 1;  q_data[1] = 1;  q_data[2] = 0;  q_data[3] = 0;
        // K0..K7（每个 Token 4 维）
        k_data[ 0] =   0; k_data[ 1] =   0; k_data[ 2] =   0; k_data[ 3] =   0;
        k_data[ 4] =   1; k_data[ 5] =   0; k_data[ 6] =   0; k_data[ 7] =   0;
        k_data[ 8] =   1; k_data[ 9] =   1; k_data[10] =   0; k_data[11] =   0;
        k_data[12] =   2; k_data[13] =   1; k_data[14] =   0; k_data[15] =   0;
        k_data[16] =  -1; k_data[17] =   0; k_data[18] =   0; k_data[19] =   0;
        k_data[20] =  -1; k_data[21] =  -1; k_data[22] =   0; k_data[23] =   0;
        k_data[24] =   2; k_data[25] =   2; k_data[26] =   0; k_data[27] =   0;
        k_data[28] =   0; k_data[29] =   1; k_data[30] =   0; k_data[31] =   0;
        // V0..V7
        v_data[ 0] =  10; v_data[ 1] =   0; v_data[ 2] =   0; v_data[ 3] =   0;
        v_data[ 4] =  20; v_data[ 5] =   4; v_data[ 6] =   0; v_data[ 7] =   0;
        v_data[ 8] =  30; v_data[ 9] =   8; v_data[10] =   0; v_data[11] =   0;
        v_data[12] =  40; v_data[13] =  12; v_data[14] =   0; v_data[15] =   0;
        v_data[16] =  50; v_data[17] =  16; v_data[18] =   0; v_data[19] =   0;
        v_data[20] =  60; v_data[21] =  20; v_data[22] =   0; v_data[23] =   0;
        v_data[24] =  70; v_data[25] =  24; v_data[26] =   0; v_data[27] =   0;
        v_data[28] =  80; v_data[29] =  28; v_data[30] =   0; v_data[31] =   0;

        // 三个用例的 pos_i（黄金模型 check_mask.py 算出）
        pos_exp[0] = 4'd0;  pos_exp[1] = 4'd3;  pos_exp[2] = 4'd7;
        // 期望权重：pos=0 / pos=3 / pos=7
        w_exp[ 0] = 16; w_exp[ 1] =  0; w_exp[ 2] =  0; w_exp[ 3] =  0;
        w_exp[ 4] =  0; w_exp[ 5] =  0; w_exp[ 6] =  0; w_exp[ 7] =  0;
        w_exp[ 8] =  1; w_exp[ 9] =  2; w_exp[10] =  6; w_exp[11] = 16;
        w_exp[12] =  0; w_exp[13] =  0; w_exp[14] =  0; w_exp[15] =  0;
        w_exp[16] =  0; w_exp[17] =  1; w_exp[18] =  2; w_exp[19] =  6;
        w_exp[20] =  0; w_exp[21] =  0; w_exp[22] = 16; w_exp[23] =  1;
        // 期望 L 与输出 O
        l_exp[0] = 16;                         l_exp[1] = 25;  l_exp[2] = 26;
        o_exp[0] = 10; o_exp[1] =  0; o_exp[2] =  0; o_exp[3] =  0;
        o_exp[4] = 35; o_exp[5] = 10; o_exp[6] =  0; o_exp[7] =  0;
        o_exp[8] = 58; o_exp[9] = 19; o_exp[10] = 0; o_exp[11] = 0;
    end

    //---------------- 结果采集 ----------------
    int  got_o [0:D-1];
    int  got_w [0:S-1];
    int  got_l;
    int  errors = 0;
    int  c, i;

    // 在 EXP 结束（进入 ACC 状态）那一拍采样权重与 L
    always @(posedge clk) begin
        if (rst_n && (dut.state == 4'd6)) begin          // 6 = ST_ACC
            // 注意: weight_buf 是 5 位"无符号"Q4.4, 不能按有符号读(否则 16 会显示成 -16)
            for (int j = 0; j < S; j++) got_w[j] = dut.weight_buf[j];
            got_l = dut.lsum;
        end
    end

    //---------------- 主流程 ----------------
    initial begin
        $display("=========================================================");
        $display(" 加分项 A 独立测试: 因果 Mask (j > pos_i 的 Key 被屏蔽)");
        $display("=========================================================");

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (c = 0; c < N_CASE; c++) begin
            // ---------- start ----------
            while (data_ready !== 1'b1) @(negedge clk);
            @(negedge clk);
            pos_i = pos_exp[c];
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            // ---------- Q: D 拍 ----------
            for (i = 0; i < D; i++) begin
                q_in = q_data[i];  q_valid = 1'b1;
                @(negedge clk);
            end
            q_valid = 1'b0;

            // ---------- K/V: S*D 拍 ----------
            for (i = 0; i < S*D; i++) begin
                k_in = k_data[i];  v_in = v_data[i];
                kv_valid = 1'b1;
                @(negedge clk);
            end
            kv_valid = 1'b0;

            // ---------- 采集 D 拍输出 ----------
            for (i = 0; i < D; i++) begin
                while (out_valid !== 1'b1) @(negedge clk);
                got_o[i] = $signed(out_data);
                @(negedge clk);
            end
            while (done !== 1'b1) @(negedge clk);
            @(negedge clk);

            // ---------- 比对 ----------
            $display("\n[用例 %0d] pos_i = %0d", c, pos_exp[c]);
            $display("  权重 weight_buf = %0d %0d %0d %0d %0d %0d %0d %0d",
                     got_w[0], got_w[1], got_w[2], got_w[3],
                     got_w[4], got_w[5], got_w[6], got_w[7]);
            $display("  期望 weight     = %0d %0d %0d %0d %0d %0d %0d %0d",
                     w_exp[c*S+0], w_exp[c*S+1], w_exp[c*S+2], w_exp[c*S+3],
                     w_exp[c*S+4], w_exp[c*S+5], w_exp[c*S+6], w_exp[c*S+7]);

            for (i = 0; i < S; i++) begin
                if (got_w[i] !== w_exp[c*S+i]) begin
                    $display("  [FAIL] weight[%0d]: got %0d, exp %0d", i, got_w[i], w_exp[c*S+i]);
                    errors = errors + 1;
                end
            end
            if (got_l !== l_exp[c]) begin
                $display("  [FAIL] L: got %0d, exp %0d", got_l, l_exp[c]);
                errors = errors + 1;
            end else begin
                $display("  L = %0d (期望 %0d) ✓", got_l, l_exp[c]);
            end
            for (i = 0; i < D; i++) begin
                if (got_o[i] !== o_exp[c*D+i]) begin
                    $display("  [FAIL] O[%0d]: got %0d, exp %0d", i, got_o[i], o_exp[c*D+i]);
                    errors = errors + 1;
                end
            end
            $display("  输出 O = %0d %0d %0d %0d (期望 %0d %0d %0d %0d)",
                     got_o[0], got_o[1], got_o[2], got_o[3],
                     o_exp[c*D+0], o_exp[c*D+1], o_exp[c*D+2], o_exp[c*D+3]);
        end

        $display("\n=========================================================");
        if (errors == 0) $display(" >>> 因果 Mask 独立测试: ALL TESTS PASSED <<<");
        else             $display(" >>> 因果 Mask 独立测试: %0d FAILURES <<<", errors);
        $display("=========================================================");
        $finish;
    end

    initial begin
        #500000;
        $display("*** TIMEOUT ***");
        $finish;
    end
endmodule

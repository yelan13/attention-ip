`timescale 1ns/1ps
//=====================================================================
//  tb_attention.sv  --  Attention IP 自检测试平台 (SystemVerilog)
//
//  用法:
//      iverilog -g2012 -Wall -DNCASES=<n> -o sim/attention.vvp rtl/*.sv tb/tb_attention.sv
//      vvp sim/attention.vvp            (工作目录需在 sim/ 下)
//
//  激励来源: sim/vectors.hex (由 sim/gen_vectors.py 生成)
//      每个用例 72 字节: Q[0..3] | K[0..31] | V[0..31] | O_expected[0..3]
//
//  检查内容:
//      1. 按接口协议驱动 start / q_valid / kv_valid
//      2. 采集 d 拍 out_valid 输出, 与黄金模型期望值逐项比较(含负数)
//      3. 检查 done 时序、输出 X 值与输入握手
//      4. 统计每次任务的周期数(用于性能分析)
//=====================================================================
`ifndef NCASES
    `define NCASES 16
`endif
`ifndef VECFILE
    `define VECFILE "vectors.hex"
`endif
`ifndef VCDFILE
    `define VCDFILE "waves/tb_attention.vcd"
`endif

module tb_attention;
    localparam int S         = 8;                       // Token 数
    localparam int D         = 4;                       // 维度
    localparam int CASE_LEN  = 2*D + 2*S*D;             // 每个用例字节数
    localparam int OUT_OFF   = D + 2*S*D;               // 期望输出偏移
    localparam int VEC_LEN   = `NCASES*CASE_LEN;
    localparam int TIMEOUT_NS = 20000 * `NCASES;        // 超时保护

    //---------------- 时钟与复位 ----------------
    logic clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

    logic rst_n = 1'b0;

    //---------------- DUT 接口 ----------------
    logic               start    = 1'b0;
    logic               q_valid  = 1'b0;
    logic               kv_valid = 1'b0;
    logic signed [7:0]  q_in     = 8'sd0;
    logic signed [7:0]  k_in     = 8'sd0;
    logic signed [7:0]  v_in     = 8'sd0;
    logic signed [7:0]  out_data;
    logic               out_valid;
    logic               done;
    logic               data_ready;

    attention_top #(.S(S), .D(D)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .q_in       (q_in),
        .k_in       (k_in),
        .v_in       (v_in),
        .q_valid    (q_valid),
        .kv_valid   (kv_valid),
        .data_ready (data_ready),
        .out_data   (out_data),
        .out_valid  (out_valid),
        .done       (done)
    );

    //------------------------------------------------------------------
    //  仅用于波形显示的镜像信号
    //  (Icarus 不导出模块内的数组变量, 这里把关键 Buffer 元素接到 TB 的
    //   普通信号上, 便于 GTKWave / 波形截图观察)
    //------------------------------------------------------------------
    logic signed [17:0] dbg_score_0, dbg_score_1, dbg_score_2, dbg_score_3;
    logic signed [17:0] dbg_score_4, dbg_score_5, dbg_score_6, dbg_score_7;
    logic        [4:0]  dbg_w_0, dbg_w_1, dbg_w_2, dbg_w_3;
    logic        [4:0]  dbg_w_4, dbg_w_5, dbg_w_6, dbg_w_7;
    logic signed [15:0] dbg_acc_0, dbg_acc_1, dbg_acc_2, dbg_acc_3;
    logic signed [7:0]  dbg_o_0, dbg_o_1, dbg_o_2, dbg_o_3;

    // 用 generate 条件保护: 当 S / D 被改小时, 超出范围的镜像不再连接到不存在的数组元素
    generate
        if (S > 0) assign dbg_score_0 = dut.score_buf[0];
        if (S > 1) assign dbg_score_1 = dut.score_buf[1];
        if (S > 2) assign dbg_score_2 = dut.score_buf[2];
        if (S > 3) assign dbg_score_3 = dut.score_buf[3];
        if (S > 4) assign dbg_score_4 = dut.score_buf[4];
        if (S > 5) assign dbg_score_5 = dut.score_buf[5];
        if (S > 6) assign dbg_score_6 = dut.score_buf[6];
        if (S > 7) assign dbg_score_7 = dut.score_buf[7];
        if (S > 0) assign dbg_w_0 = dut.weight_buf[0];
        if (S > 1) assign dbg_w_1 = dut.weight_buf[1];
        if (S > 2) assign dbg_w_2 = dut.weight_buf[2];
        if (S > 3) assign dbg_w_3 = dut.weight_buf[3];
        if (S > 4) assign dbg_w_4 = dut.weight_buf[4];
        if (S > 5) assign dbg_w_5 = dut.weight_buf[5];
        if (S > 6) assign dbg_w_6 = dut.weight_buf[6];
        if (S > 7) assign dbg_w_7 = dut.weight_buf[7];
        if (D > 0) assign dbg_acc_0 = dut.acc[0];
        if (D > 1) assign dbg_acc_1 = dut.acc[1];
        if (D > 2) assign dbg_acc_2 = dut.acc[2];
        if (D > 3) assign dbg_acc_3 = dut.acc[3];
        if (D > 0) assign dbg_o_0 = dut.o_reg[0];
        if (D > 1) assign dbg_o_1 = dut.o_reg[1];
        if (D > 2) assign dbg_o_2 = dut.o_reg[2];
        if (D > 3) assign dbg_o_3 = dut.o_reg[3];
    endgenerate

    //---------------- 激励与结果 ----------------
    logic [7:0]      vec [0:VEC_LEN-1];
    logic signed [7:0] got_o [0:D-1];

    int c, i, base;
    int n_error, n_case_pass, n_proto_warn;
    int cyc_cnt, cyc_used, cyc_total, cyc_min, cyc_max;
    logic cyc_en;

    // 周期计数(统计每次任务的延迟)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cyc_cnt <= 0;
        else if (cyc_en) cyc_cnt <= cyc_cnt + 1;
    end

    // 输出 x 值检查(仿真专用, 用 always 而非 always_ff)
    always @(posedge clk) begin
        if (rst_n && out_valid && (^out_data === 1'bx)) begin
            $display("  [FAIL] out_data contains X @ %0t", $time);
            n_error <= n_error + 1;
        end
    end

    // 超时保护
    initial begin
        #TIMEOUT_NS;
        $display("*** TIMEOUT: simulation did not finish (case %0d, state %0d) ***",
                 c, dut.state);
        $finish;
    end

    initial begin
        n_error = 0; n_case_pass = 0; n_proto_warn = 0;
        cyc_total = 0; cyc_min = 999999; cyc_max = 0; cyc_en = 1'b0;
        for (int k = 0; k < D; k++) got_o[k] = 8'sd0;

        $readmemh(`VECFILE, vec);
`ifndef NO_DUMP
        $dumpfile(`VCDFILE);
        $dumpvars(0, tb_attention);
`endif

        $display("=========================================================");
        $display(" Attention IP testbench : %0d cases, S=%0d, d=%0d", `NCASES, S, D);
        $display("=========================================================");

        // 复位
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (c = 0; c < `NCASES; c++) begin
            base = c*CASE_LEN;

            // ---------- start (仅 IDLE 有效) ----------
            while (data_ready !== 1'b1) @(negedge clk);
            @(negedge clk);
            cyc_cnt = 0; cyc_en = 1'b1;     // 从 start 当拍开始计数
            start = 1'b1;
            assert (data_ready === 1'b1)
                else $error("start asserted while data_ready is low");
            @(negedge clk);
            start = 1'b0;

            // ---------- Q: D 拍 ----------
            for (i = 0; i < D; i++) begin
                q_in    = vec[base + i];
                q_valid = 1'b1;
                if (data_ready !== 1'b1) n_proto_warn++;
                @(negedge clk);
            end
            q_valid = 1'b0;

            // ---------- K/V: S*D 拍 ----------
            for (i = 0; i < S*D; i++) begin
                k_in     = vec[base + D + i];
                v_in     = vec[base + D + S*D + i];
                kv_valid = 1'b1;
                if (data_ready !== 1'b1) n_proto_warn++;
                @(negedge clk);
            end
            kv_valid = 1'b0;

            // ---------- 采集 D 个输出 ----------
            for (i = 0; i < D; i++) begin
                while (out_valid !== 1'b1) @(negedge clk);
                got_o[i] = out_data;
                @(negedge clk);
            end
            assert (out_valid !== 1'b1)
                else $error("out_valid asserted for more than d cycles");

            // ---------- 等待 done ----------
            while (done !== 1'b1) @(negedge clk);
            cyc_en = 1'b0;
            cyc_used = cyc_cnt;
            @(negedge clk);

            // ---------- 结果比对 ----------
            cyc_total = cyc_total + cyc_used;
            if (cyc_used < cyc_min) cyc_min = cyc_used;
            if (cyc_used > cyc_max) cyc_max = cyc_used;

            if ((got_o[0] === vec[base+OUT_OFF+0]) &&
                (got_o[1] === vec[base+OUT_OFF+1]) &&
                (got_o[2] === vec[base+OUT_OFF+2]) &&
                (got_o[3] === vec[base+OUT_OFF+3])) begin
                n_case_pass = n_case_pass + 1;
                $display("[PASS] case %0d : O = %0d %0d %0d %0d   (%0d cycles)",
                         c, $signed(got_o[0]), $signed(got_o[1]),
                         $signed(got_o[2]), $signed(got_o[3]), cyc_used);
            end else begin
                n_error = n_error + 1;
                $display("[FAIL] case %0d : got %0d %0d %0d %0d | exp %0d %0d %0d %0d  (%0d cycles)",
                         c,
                         $signed(got_o[0]), $signed(got_o[1]),
                         $signed(got_o[2]), $signed(got_o[3]),
                         $signed(vec[base+OUT_OFF+0]), $signed(vec[base+OUT_OFF+1]),
                         $signed(vec[base+OUT_OFF+2]), $signed(vec[base+OUT_OFF+3]),
                         cyc_used);
            end
        end

        // ---------- 汇总 ----------
        $display("=========================================================");
        $display(" cases total  : %0d", `NCASES);
        $display(" passed       : %0d", n_case_pass);
        $display(" failed       : %0d", n_error);
        $display(" handshake warn: %0d", n_proto_warn);
        $display(" cycles/task  : min=%0d / avg=%0d / max=%0d",
                 cyc_min, cyc_total/`NCASES, cyc_max);
        if (n_error == 0) $display(" >>> RESULT: ALL TESTS PASSED <<<");
        else              $display(" >>> RESULT: %0d FAILURES <<<", n_error);
        $display("=========================================================");
        $finish;
    end
endmodule

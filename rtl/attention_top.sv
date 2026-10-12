`timescale 1ns/1ps
//=====================================================================
//  attention_top.sv  --  基础 Attention 加速器 RTL IP (SystemVerilog)
//
//  默认规模(题目正式任务): S = 8 个 Token, d = 4 维, 8-bit 有符号输入
//  数据流: LOAD_Q -> LOAD_KV -> DOT -> MAX -> EXP -> ACC -> NORM -> OUT
//
//  接口协议(与题目"建议接口"一致):
//    start      : 仅空闲状态有效, 拉高 1 拍启动一次任务
//    q_valid    : q_in 有效, 连续 d 拍(默认 4 拍), 依次是 Q[0]~Q[d-1]
//    kv_valid   : k_in/v_in 有效, 连续 S*d 拍(默认 32 拍),
//                 第 j*d+k 拍给出 K_j[k] 与 V_j[k](K/V 同拍成对输入)
//    data_ready : 为 1 时允许发送输入(IDLE / LOAD_Q / LOAD_KV)
//    out_valid  : 为 1 时 out_data 有效, 连续 d 拍, 依次是 O[0]~O[d-1]
//    done       : d 个结果输出完毕后拉高 1 拍, 然后回到 IDLE
//
//  SystemVerilog 特性:
//    * typedef enum 描述 11 个状态, 波形与代码可读性更好
//    * always_ff / always_comb 明确时序与组合逻辑意图
//    * logic / int / $clog2 / 参数化位宽, 便于修改规模
//=====================================================================
module attention_top #(
    parameter int S      = 8,    // Token 数量
    parameter int D      = 4,    // Head 维度
    parameter int DW     = 8,    // Q/K/V/O 数据位宽(有符号)
    parameter int W_FRAC = 4     // weight 小数位宽(题目固定 4)
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 start,
    input  logic signed [DW-1:0] q_in,
    input  logic signed [DW-1:0] k_in,
    input  logic signed [DW-1:0] v_in,
    input  logic                 q_valid,
    input  logic                 kv_valid,
    output logic                 data_ready,
    output logic signed [DW-1:0] out_data,
    output logic                 out_valid,
    output logic                 done
);

    //=================================================================
    //  位宽推导
    //=================================================================
    localparam int MUL_W  = 2*DW;        // 16 : 8b x 8b 有符号乘积
    localparam int SCR_W  = MUL_W + 2;   // 18 : 4 项点积累加(-65536~65536)
    localparam int DIFF_W = SCR_W + 1;   // 19 : score - x_max 留 1 位余量
    localparam int WGT_W  = W_FRAC + 1;  // 5  : weight 无符号 Q4.4(0~16)
    localparam int L_W    = 8;           // L = Σweight <= 8*16 = 128
    localparam int ACC_W  = 16;          // 累加器 |ACC| <= 128*128 = 16384
    localparam int NUM_W  = 15;          // 除法器被除数幅值位宽
    localparam int QUO_W  = 16;          // 除法器商位宽

    localparam int QC_W = (D   > 1) ? $clog2(D)   : 1;   // Q 装载计数
    localparam int KC_W = (S*D > 1) ? $clog2(S*D) : 1;   // KV 装载计数
    localparam int TC_W = (S   > 1) ? $clog2(S)   : 1;   // Token 计数
    localparam int DC_W = (D   > 1) ? $clog2(D)   : 1;   // 维度计数

    //=================================================================
    //  状态编码
    //=================================================================
    typedef enum logic [3:0] {
        ST_IDLE, ST_LOAD_Q, ST_LOAD_KV, ST_DOT, ST_MAX,
        ST_EXP, ST_ACC, ST_NORM, ST_NORM_WAIT, ST_OUT, ST_DONE
    } state_e;

    state_e state;

    //=================================================================
    //  寄存器与存储
    //=================================================================
    logic [QC_W-1:0] q_cnt;
    logic [KC_W-1:0] kv_cnt;
    logic [DC_W-1:0] dot_cnt, out_cnt, norm_cnt;   // 0 ~ d-1
    logic [TC_W-1:0] tok, exp_cnt;                 // 0 ~ S-1
    logic [TC_W-1:0] acc_cnt;                      // 0 ~ S-1 (V 累加按 Token 循环)

    logic signed [DW-1:0]    q_reg      [D];       // Q 寄存器
    logic signed [DW-1:0]    k_buf      [S*D];     // K Buffer
    logic signed [DW-1:0]    v_buf      [S*D];     // V Buffer
    logic signed [SCR_W-1:0] score_buf  [S];       // Score Buffer
    logic        [WGT_W-1:0] weight_buf [S];       // Weight Buffer
    logic signed [SCR_W-1:0] xmax;                 // 最大 Score
    logic signed [SCR_W-1:0] dot_acc;              // 点积部分和
    logic        [L_W-1:0]   lsum;                 // L = Σweight
    logic signed [ACC_W-1:0] acc [D];              // 4 路累加器
    logic signed [DW-1:0]    o_reg [D];            // 输出结果

    //=================================================================
    //  点积乘法器
    //=================================================================
    logic signed [MUL_W-1:0] dot_prod;
    assign dot_prod = q_reg[dot_cnt] * k_buf[tok*D + dot_cnt];

    //=================================================================
    //  指数查找表
    //=================================================================
    logic             [WGT_W-1:0] exp_w;
    logic signed [DIFF_W-1:0]     exp_diff;
    assign exp_diff = score_buf[exp_cnt] - xmax;

    exp_lut #(.DIFF_W(DIFF_W), .W_FRAC(W_FRAC)) u_exp_lut (
        .diff   (exp_diff),
        .weight (exp_w)
    );

    //=================================================================
    //  除法器接口(分时复用)
    //=================================================================
    logic             div_start;
    logic [NUM_W-1:0] div_numer;
    logic [QUO_W-1:0] div_quo;
    logic             div_done;
    logic signed [ACC_W-1:0] acc_sel;
    logic                    acc_neg;
    logic [QUO_W-1:0]        q_lim, q_sat;
    logic [DW-1:0]           o_val;

    assign div_start = (state == ST_NORM);
    assign acc_sel   = acc[norm_cnt];
    // |ACC| : 取幅值送除法器
    assign div_numer = acc_sel[ACC_W-1] ? (~acc_sel[NUM_W-1:0] + 1'b1)
                                        :  acc_sel[NUM_W-1:0];

    seq_div #(.W_NUM(NUM_W), .W_DEN(L_W), .W_QUO(QUO_W)) u_div (
        .clk   (clk),
        .rst_n (rst_n),
        .start (div_start),
        .numer (div_numer),
        .denom (lsum),
        .quo   (div_quo),
        .done  (div_done)
    );

    // 饱和到 8-bit 有符号范围, 并恢复符号
    localparam logic [QUO_W-1:0] LIM_POS = QUO_W'(127);
    localparam logic [QUO_W-1:0] LIM_NEG = QUO_W'(128);

    always_comb begin
        acc_neg = acc_sel[ACC_W-1];
        q_lim   = acc_neg ? LIM_NEG : LIM_POS;
        q_sat   = (div_quo > q_lim) ? q_lim : div_quo;
        o_val   = acc_neg ? (~q_sat[DW-1:0] + 1'b1) : q_sat[DW-1:0];
    end

    //=================================================================
    //  输出接口
    //=================================================================
    assign data_ready = (state == ST_IDLE) | (state == ST_LOAD_Q) | (state == ST_LOAD_KV);
    assign out_valid  = (state == ST_OUT);
    assign out_data   = o_reg[out_cnt];
    assign done       = (state == ST_DONE);

    //=================================================================
    //  主状态机
    //=================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            q_cnt    <= '0;
            kv_cnt   <= '0;
            dot_cnt  <= '0;
            acc_cnt  <= '0;
            out_cnt  <= '0;
            norm_cnt <= '0;
            tok      <= '0;
            exp_cnt  <= '0;
            dot_acc  <= '0;
            xmax     <= '0;
            lsum     <= '0;
            for (int k = 0; k < D; k++) begin
                acc[k]   <= '0;
                o_reg[k] <= '0;
                q_reg[k] <= '0;
            end
            for (int k = 0; k < S; k++) begin
                score_buf[k]  <= '0;
                weight_buf[k] <= '0;
            end
            for (int k = 0; k < S*D; k++) begin
                k_buf[k] <= '0;
                v_buf[k] <= '0;
            end
        end else begin
            case (state)
            //---------------------------------------------------------
            //  IDLE: 等待 start
            //---------------------------------------------------------
            ST_IDLE: begin
                if (start) begin
                    q_cnt <= '0;
                    // 新任务开始: 清掉上一次任务残留的中间结果
                    lsum    <= '0;
                    xmax    <= '0;
                    dot_acc <= '0;
                    for (int k = 0; k < D; k++) begin
                        acc[k]   <= '0;
                        o_reg[k] <= '0;
                    end
                    if (q_valid) begin          // 允许 start 与第 1 个 q_valid 同拍
                        q_reg[0] <= q_in;
                        if (D == 1) begin
                            state  <= ST_LOAD_KV;
                            kv_cnt <= '0;
                        end else begin
                            q_cnt <= {{(QC_W-1){1'b0}}, 1'b1};
                            state <= ST_LOAD_Q;
                        end
                    end else begin
                        state <= ST_LOAD_Q;
                    end
                end
            end
            //---------------------------------------------------------
            //  LOAD_Q: 连续 D 拍装入 Q
            //---------------------------------------------------------
            ST_LOAD_Q: begin
                if (q_valid) begin
                    q_reg[q_cnt] <= q_in;
                    if (q_cnt == QC_W'(D-1)) begin
                        state  <= ST_LOAD_KV;
                        kv_cnt <= '0;
                    end else begin
                        q_cnt <= q_cnt + 1'b1;
                    end
                end
            end
            //---------------------------------------------------------
            //  LOAD_KV: 连续 S*D 拍装入 K/V
            //---------------------------------------------------------
            ST_LOAD_KV: begin
                if (kv_valid) begin
                    k_buf[kv_cnt] <= k_in;
                    v_buf[kv_cnt] <= v_in;
                    if (kv_cnt == KC_W'(S*D-1)) begin
                        state   <= ST_DOT;
                        tok     <= '0;
                        dot_cnt <= '0;
                        dot_acc <= '0;
                        kv_cnt  <= '0;      // 装载结束, 计数清零(仅为波形可读性)
                    end else begin
                        kv_cnt <= kv_cnt + 1'b1;
                    end
                end
            end
            //---------------------------------------------------------
            //  DOT: 每个 Score 用 D 拍完成乘法累加
            //---------------------------------------------------------
            ST_DOT: begin
                if (dot_cnt == DC_W'(D-1)) begin
                    score_buf[tok] <= dot_acc + dot_prod;
                    dot_acc        <= '0;
                    dot_cnt        <= '0;
                    if (tok == TC_W'(S-1)) begin
                        tok   <= '0;
                        state <= ST_MAX;
                    end else begin
                        tok <= tok + 1'b1;
                    end
                end else begin
                    dot_acc <= dot_acc + dot_prod;
                    dot_cnt <= dot_cnt + 1'b1;
                end
            end
            //---------------------------------------------------------
            //  MAX: 检索 S 个 Score 的最大值
            //---------------------------------------------------------
            ST_MAX: begin
                if (tok == '0) begin
                    xmax <= score_buf[0];
                    if (S == 1) begin
                        state   <= ST_EXP;
                        tok     <= '0;
                        exp_cnt <= '0;
                        lsum    <= '0;
                        for (int k = 0; k < D; k++) acc[k] <= '0;
                    end else begin
                        tok <= {{(TC_W-1){1'b0}}, 1'b1};
                    end
                end else begin
                    if (score_buf[tok] > xmax) xmax <= score_buf[tok];
                    if (tok == TC_W'(S-1)) begin
                        state   <= ST_EXP;
                        tok     <= '0;
                        exp_cnt <= '0;
                        lsum    <= '0;                                  // 清 L
                        for (int k = 0; k < D; k++) acc[k] <= '0;       // 清 ACC
                    end else begin
                        tok <= tok + 1'b1;
                    end
                end
            end
            //---------------------------------------------------------
            //  EXP: weight = exp(score - x_max), 同时累加 L
            //---------------------------------------------------------
            ST_EXP: begin
                weight_buf[exp_cnt] <= exp_w;
                lsum <= lsum + L_W'(exp_w);
                if (exp_cnt == TC_W'(S-1)) begin
                    exp_cnt <= '0;
                    acc_cnt <= '0;
                    state   <= ST_ACC;
                end else begin
                    exp_cnt <= exp_cnt + 1'b1;
                end
            end
            //---------------------------------------------------------
            //  ACC: 每个 Token 一拍, 4 路并行累加 ACC[k] += weight*V[k]
            //---------------------------------------------------------
            ST_ACC: begin
                for (int k = 0; k < D; k++) begin
                    acc[k] <= acc[k] + $signed({1'b0, weight_buf[acc_cnt]})
                                      * v_buf[acc_cnt*D + k];
                end
                if (acc_cnt == TC_W'(S-1)) begin
                    acc_cnt  <= '0;
                    norm_cnt <= '0;
                    state    <= ST_NORM;
                end else begin
                    acc_cnt <= acc_cnt + 1'b1;
                end
            end
            //---------------------------------------------------------
            //  NORM: 分时复用除法器, 求 O[k] = round(ACC[k]/L)
            //---------------------------------------------------------
            ST_NORM: begin
                state <= ST_NORM_WAIT;                    // 发出 1 拍启动脉冲
            end
            ST_NORM_WAIT: begin
                if (div_done) begin
                    o_reg[norm_cnt] <= o_val;
                    if (norm_cnt == DC_W'(D-1)) begin
                        norm_cnt <= '0;
                        out_cnt  <= '0;
                        state    <= ST_OUT;
                    end else begin
                        norm_cnt <= norm_cnt + 1'b1;
                        state    <= ST_NORM;
                    end
                end
            end
            //---------------------------------------------------------
            //  OUT: 依次输出 D 个结果
            //---------------------------------------------------------
            ST_OUT: begin
                if (out_cnt == DC_W'(D-1)) begin
                    out_cnt <= '0;
                    state   <= ST_DONE;
                end else begin
                    out_cnt <= out_cnt + 1'b1;
                end
            end
            //---------------------------------------------------------
            //  DONE: 拉高 1 拍后回到 IDLE
            //---------------------------------------------------------
            ST_DONE: begin
                state <= ST_IDLE;
            end
            default: begin
                state <= ST_IDLE;
            end
            endcase
        end
    end
endmodule

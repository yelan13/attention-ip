`timescale 1ns/1ps
//=====================================================================
//  seq_div.sv  --  无符号顺序除法器(自带四舍五入) (SystemVerilog)
//
//  功能: quo = floor( (numer + (denom>>1)) / denom )
//        即对 numer/denom 做四舍五入(.5 时远离 0)
//  算法: 恢复余数法(restoring division), 每个被除数位一拍
//
//  被除数先加上半个除数, 商里已经包含舍入, 顶层不需要额外舍入逻辑.
//  约束: denom != 0; 且 (numer + denom/2) 不超过 W_NUM+1 位.
//=====================================================================
module seq_div #(
    parameter int W_NUM = 15,   // 被除数(幅值)位宽
    parameter int W_DEN = 8,    // 除数位宽
    parameter int W_QUO = 16    // 商位宽
)(
    input  logic             clk,
    input  logic             rst_n,
    input  logic             start,   // 1 拍启动脉冲(忙时忽略)
    input  logic [W_NUM-1:0] numer,   // 无符号被除数幅值
    input  logic [W_DEN-1:0] denom,   // 无符号除数
    output logic [W_QUO-1:0] quo,     // 商
    output logic             done     // 与 quo 同时有效, 1 拍
);
    localparam int WI      = W_NUM + 1;                       // 加上 denom/2 后的位宽
    localparam int CNT_W   = (WI > 1) ? $clog2(WI) : 1;
    localparam int TOP_BIT = (W_QUO > WI) ? (WI - 1) : (W_QUO - 1);

    logic [WI-1:0]    num_ext;      // numer + denom/2
    logic [W_DEN-1:0] den;
    logic [W_DEN:0]   rem;          // 余数(始终小于 den)
    logic [W_QUO-1:0] q;
    logic [CNT_W-1:0] bit_idx;
    logic             busy;

    logic [W_DEN:0]   sh;
    logic             ge;
    logic [W_DEN:0]   rem_next;
    logic [W_QUO-1:0] q_set;
    logic [W_QUO-1:0] q_next;

    always_comb begin
        sh       = {rem[W_DEN-1:0], num_ext[bit_idx]};
        ge       = (sh >= {1'b0, den});
        rem_next = ge ? (sh - {1'b0, den}) : sh;
        q_set    = q | ({{(W_QUO-1){1'b0}}, 1'b1} << bit_idx);
        q_next   = ge ? q_set : q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy    <= 1'b0;
            done    <= 1'b0;
            quo     <= '0;
            num_ext <= '0;
            den     <= '0;
            rem     <= '0;
            q       <= '0;
            bit_idx <= '0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                if (start) begin
                    num_ext <= {1'b0, numer} +
                               {{(WI-W_DEN){1'b0}}, denom[W_DEN-1:1]};   // + denom/2
                    den     <= denom;
                    rem     <= '0;
                    q       <= '0;
                    bit_idx <= CNT_W'(TOP_BIT);
                    busy    <= 1'b1;
                end
            end else begin
                rem <= rem_next;
                q   <= q_next;
                if (bit_idx == '0) begin
                    busy <= 1'b0;
                    quo  <= q_next;      // 商有效
                    done <= 1'b1;
                end else begin
                    bit_idx <= bit_idx - 1'b1;
                end
            end
        end
    end
endmodule

`timescale 1ns/1ps
//=====================================================================
//  exp_lut.sv  --  Softmax 指数查找表 (SystemVerilog)
//
//  输入 : diff = score - x_max  (有符号整数, diff <= 0)
//  输出 : weight = exp(diff) 的无符号定点数, 小数 W_FRAC 位(题目固定 4)
//
//  取值范围推导:
//    diff <= 0  =>  exp(diff) <= 1.0, 因此输出只需 1 位整数 + W_FRAC 位小数.
//    W_FRAC = 4 时 weight ∈ [0, 16], 16 代表 1.0000.
//
//  量化规则(题目要求): weight = round( exp(diff) * 2^W_FRAC )
//    不是对 exp 取整, 而是先缩放到定点再取整.
//
//  表内容(W_FRAC=4):
//    mag = -diff = x_max - score
//      0 -> 16 (1.0000)   1 -> 6 (0.3679)   2 -> 2 (0.1353)
//      3 -> 1 (0.0498)    4 -> 0 (0.0183)   >=5 -> 0
//    score 是整数, 所以 diff 一定是整数; 4 位小数精度下 5 个地址即为完备表.
//=====================================================================
module exp_lut #(
    parameter int DIFF_W = 19,   // diff 位宽
    parameter int W_FRAC = 4     // weight 小数位宽
)(
    input  logic signed [DIFF_W-1:0] diff,
    output logic        [W_FRAC:0]   weight
);
    localparam int WGT_W = W_FRAC + 1;

    logic [DIFF_W-1:0] mag;      // mag = -diff >= 0

    // ---- 查找表本体: 综合后是一小段组合逻辑 ----
    always_comb begin
        mag = diff[DIFF_W-1] ? (~diff + 1'b1) : diff[DIFF_W-1:0];
        case (mag)
            DIFF_W'(0): weight = WGT_W'(16);   // exp(0)*16  = 16.000
            DIFF_W'(1): weight = WGT_W'(6);    // exp(-1)*16 =  5.886
            DIFF_W'(2): weight = WGT_W'(2);    // exp(-2)*16 =  2.166
            DIFF_W'(3): weight = WGT_W'(1);    // exp(-3)*16 =  0.797
            default:    weight = WGT_W'(0);    // exp(-4)*16 =  0.293 -> 0
        endcase
    end
endmodule

#!/usr/bin/env bash
# run_sim.sh -- Attention IP 一键仿真脚本 (Linux / macOS / WSL)
#   用法: ./sim/run_sim.sh [随机用例数] [随机种子]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N="${1:-32}"
SEED="${2:-20260912}"
NCASES=$((N + 9))

cd "$HERE"
echo "==> [1/4] 生成测试激励 (随机用例 $N 个, seed=$SEED)"
python3 gen_vectors.py -n "$N" --seed "$SEED" --out vectors.hex \
        --report vectors_report.txt --stats vectors_stats.txt

echo "==> [2/4] 编译 RTL + Testbench"
iverilog -g2012 -Wall -DNCASES="$NCASES" -o attention.vvp \
        ../rtl/exp_lut.sv ../rtl/seq_div.sv ../rtl/attention_top.sv ../tb/tb_attention.sv

echo "==> [3/4] 运行仿真"
vvp attention.vvp | tee sim_log.txt

echo "==> [4/4] 渲染波形与日志截图"
python3 vcd_wave.py waves/tb_attention.vcd --out ../doc/wave_overview.png \
        --group overview --task 4 --rel0 -1 --rel1 172 --px 8 \
        --title "Attention IP 单次任务全流程波形 (169 周期)"
python3 vcd_wave.py waves/tb_attention.vcd --out ../doc/wave_datapath.png \
        --group datapath --task 4 --rel0 35 --rel1 92 --px 22 \
        --title "Score / x_max / exp / ACC 数据通路波形"
python3 vcd_wave.py waves/tb_attention.vcd --out ../doc/wave_softmax.png \
        --group softmax --task 4 --rel0 74 --rel1 94 --px 40 \
        --title "Softmax 权重计算 (x_max 检索 + 指数查找表 + L 累加)"
python3 vcd_wave.py waves/tb_attention.vcd --out ../doc/wave_output.png \
        --group output --task 4 --rel0 90 --rel1 172 --px 16 \
        --title "归一化(除法)与输出时序波形"
python3 log2png.py sim_log.txt --out ../doc/sim_log.png
echo "==> 完成。结果见 sim/sim_log.txt, 波形见 doc/wave_*.png"

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_mask.py -- 加分项 A(因果 Mask) 的标准答案生成/核对脚本。

用黄金模型算出不同 pos_i 下的期望输出, 供 tb/tb_attention_mask.sv 使用。
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "model"))
from attention_golden import attention  # noqa: E402

# 与 tb_attention_mask.sv 中硬编码的输入保持一致
Q = [1, 1, 0, 0]
K = [[0, 0, 0, 0], [1, 0, 0, 0], [1, 1, 0, 0], [2, 1, 0, 0],
     [-1, 0, 0, 0], [-1, -1, 0, 0], [2, 2, 0, 0], [0, 1, 0, 0]]
V = [[10, 0, 0, 0], [20, 4, 0, 0], [30, 8, 0, 0], [40, 12, 0, 0],
     [50, 16, 0, 0], [60, 20, 0, 0], [70, 24, 0, 0], [80, 28, 0, 0]]


if __name__ == "__main__":
    print("Q =", Q)
    for pos in (0, 3, 7):
        r = attention(Q, K, V, pos=pos)
        print(f"pos_i = {pos}:")
        print(f"  score  = {r['score']}")
        print(f"  x_max  = {r['xmax']}   (只在不被屏蔽的 Key 里取)")
        print(f"  weight = {r['weight']}")
        print(f"  L      = {r['L']}")
        print(f"  ACC    = {r['ACC']}")
        print(f"  O      = {r['O']}   <-- tb_attention_mask.sv 里的期望值")
    print("\n无 Mask 对照(等价于 pos_i=7):", attention(Q, K, V)["O"])

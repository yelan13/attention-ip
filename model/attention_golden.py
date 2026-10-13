#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
attention_golden.py -- Attention 硬件 IP 的 Python 黄金模型

严格按题目要求实现, 与 RTL 的定点行为逐位一致:
  1. score_j  = Σ_k Q[k]*K_j[k]                      (整数)
  2. x_max    = max(score_j)
  3. weight_j = round( exp(score_j - x_max) * 2^FRAC )  (无符号定点, FRAC=4)
  4. L        = Σ weight_j                            (无符号整数)
  5. ACC[k]   = Σ_j weight_j * V_j[k]                 (整数, 带 FRAC 位小数)
  6. O[k]     = round( ACC[k] / L )                   (8-bit 有符号, .5 远离 0)

说明:
  * 第 3 步是"先缩放到定点再取整", 不是把 exp 四舍五入成整数(题目明确禁止)。
  * 第 6 步的舍入在 RTL 中由"被除数先加 L/2 再整除"实现, 与
    round_half_away(ACC/L) 在该数据范围内完全等价(证明见报告第 5 节)。
  * 浮点版本 attention_float() 用于比较量化损失, 不参与 RTL 比对。
"""

import math
from typing import Dict, List

S_DEFAULT = 8
D_DEFAULT = 4
FRAC_DEFAULT = 4          # weight 小数位宽, 题目固定 4


def round_half_away(x: float) -> int:
    """四舍五入, .5 时远离 0(硬件里用 +L/2 的整型除法实现)。"""
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def exp_lut_value(diff: int, frac: int = FRAC_DEFAULT) -> int:
    """
    硬件 exp_lut 的表内容: weight = round(exp(diff) * 2^frac), diff <= 0。
    与 rtl/exp_lut.v 中的 case 表一一对应:
        mag=0 -> 16, mag=1 -> 6, mag=2 -> 2, mag=3 -> 1, mag>=4 -> 0
    """
    if diff > 0:
        diff = 0                     # 硬件上 diff 只会 <= 0, 这里做保护
    mag = -diff
    if mag >= 4 + 1:
        return 0
    return round_half_away(math.exp(-mag) * (1 << frac))


def attention(q: List[int], k: List[List[int]], v: List[List[int]],
              frac: int = FRAC_DEFAULT, pos: int = None) -> Dict[str, object]:
    """
    定点黄金模型, 返回与 RTL 逐位一致的全部中间结果。

    pos: 加分项 A 的因果 Mask。给定时只允许 j <= pos 的 Key 参与 Softmax
         (被屏蔽的 Key 权重为 0, 且不参与 x_max 检索), 与 RTL 的 MASK_EN=1 行为一致。
    """
    s = len(k)
    d = len(q)
    assert all(len(row) == d for row in k), "K 维度与 Q 不一致"
    assert all(len(row) == d for row in v), "V 维度与 Q 不一致"

    scores = [sum(q[x] * k[j][x] for x in range(d)) for j in range(s)]
    valid = list(range(s)) if pos is None else list(range(min(pos, s - 1) + 1))
    xmax = max(scores[j] for j in valid)
    weights = [exp_lut_value(scores[j] - xmax, frac) if j in valid else 0
               for j in range(s)]
    lsum = sum(weights)
    acc = [sum(weights[j] * v[j][x] for j in range(s)) for x in range(d)]
    out = [round_half_away(a / lsum) if lsum else 0 for a in acc]
    return {
        "score": scores, "xmax": xmax, "weight": weights,
        "L": lsum, "ACC": acc, "O": out,
    }


def attention_float(q: List[int], k: List[List[int]], v: List[List[int]]) -> List[int]:
    """全精度参考(仅用于讨论 Q4.4 量化的精度损失)。"""
    s, d = len(k), len(q)
    scores = [sum(q[x] * k[j][x] for x in range(d)) for j in range(s)]
    xmax = max(scores)
    w = [math.exp(scores[j] - xmax) for j in range(s)]
    lsum = sum(w)
    return [round_half_away(sum(w[j] * v[j][x] for j in range(s)) / lsum) for x in range(d)]


def _selftest() -> None:
    """题目第 3 页手算示例(S=2, d=2)的自检。"""
    q = [1, 2]
    k = [[1, 0], [0, 1]]
    v = [[4, 2], [1, 6]]
    r = attention(q, k, v)
    print("题目手算示例检查 (S=2, d=2):")
    print("  score  =", r["score"], "(题目: [1, 2])")
    print("  x_max  =", r["xmax"], "(题目: 2)")
    print("  weight =", r["weight"], "(题目近似值 0.4, 1 -> Q4.4 为 6, 16)")
    print("  L      =", r["L"], "(题目: 1.4)")
    print("  ACC    =", r["ACC"], "(题目: [2.6, 6.8])")
    print("  O      =", r["O"], "(题目: [2, 5])")
    assert r["score"] == [1, 2], r["score"]
    assert r["xmax"] == 2
    assert r["weight"] == [6, 16]
    assert r["L"] == 22
    assert r["ACC"] == [40, 108]
    assert r["O"] == [2, 5], r["O"]
    print("  浮点参考 O =", attention_float(q, k, v), "(同样为 [2, 5])")
    print("自检通过: Python 模型与题目手算示例一致。")


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        _selftest()

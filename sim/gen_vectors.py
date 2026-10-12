#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_vectors.py -- 生成 RTL 仿真激励与期望结果

输出 vectors.hex: 每个字节一行(16 进制, 二进制补码), 每个用例 72 个字节:
    Q[0..3] (4) | K[0..31] (32) | V[0..31] (32) | O_expected[0..3] (4)
其中 K/V 按 K_j[k] / V_j[k] 的顺序排列, 与 RTL 接口协议一致。

用例包含:
    directed -- 全零/极值/单 token 主导/负值/题目示例启发用例等边界场景
    random   -- 指定数量、指定随机种子的随机用例(可用 -n 调整)
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "model"))
from attention_golden import attention, attention_float  # noqa: E402

S, D = 8, 4


def flatten(q, k, v):
    return list(q) + [x for row in k for x in row] + [x for row in v for x in row]


def directed_cases():
    cases = []

    # 1. 全零: score 全 0 -> weight 全 16, L=128, ACC=0, O=0
    cases.append(("zeros", [0] * D, [[0] * D] * S, [[0] * D] * S))

    # 2. 题目示例启发用例: 只有 token0/token1 有分数, 期望 O=[2,5] 附近的整数结果
    q = [1, 2, 0, 0]
    k = [[1, 0, 0, 0], [0, 1, 0, 0]] + [[-64, -64, 0, 0]] * (S - 2)
    v = [[4, 2, 0, 0], [1, 6, 0, 0]] + [[0, 0, 0, 0]] * (S - 2)
    cases.append(("doc_example_style", q, k, v))

    # 3. 正最大值: 点积达到 18-bit Score 的正边界
    cases.append(("max_positive", [127] * D, [[127] * D] * S, [[127] * D] * S))

    # 4. 负最大值: 点积达到 18-bit Score 的负边界
    cases.append(("max_negative", [-128] * D, [[127] * D] * S, [[-128] * D] * S))

    # 5. 单 token 主导: 只有一个 token 的 score 最大, 其余权重下溢为 0
    q = [10, 0, 0, 0]
    k = [[20, 0, 0, 0]] + [[-20, 0, 0, 0]] * (S - 1)
    v = [[100, -100, 50, -50]] + [[7, 7, 7, 7]] * (S - 1)
    cases.append(("single_dominant", q, k, v))

    # 6. 全 token 平分权重: score 差都在 0..3 内
    q = [1, 1, 1, 1]
    k = [[1, 1, 1, 1]] * S
    v = [[i * 16 - 64 for i in range(D)] for _ in range(S)]
    cases.append(("equal_weights", q, k, v))

    # 7. 负输出: V 全负, 检查有符号舍入方向
    q = [3, -5, 7, -9]
    k = [[2, -1, 0, 4], [-3, 6, 1, -2]] + [[1, 0, -1, 0]] * (S - 2)
    v = [[-33, -1, -128, -7]] * S
    cases.append(("negative_out", q, k, v))

    # 8. 半整数舍入: 构造 ACC/L 接近 .5 的场景
    q = [1, 0, 0, 0]
    k = [[2, 0, 0, 0], [1, 0, 0, 0]] + [[0, 0, 0, 0]] * (S - 2)
    v = [[1, 8, -8, 127]] + [[0, 0, 0, 0]] * (S - 1)
    cases.append(("round_tie", q, k, v))

    # 9. 小范围随机(权重分布更平均, 更接近"真的在做 softmax")
    rng = random.Random(7)
    q = [rng.randint(-8, 7) for _ in range(D)]
    k = [[rng.randint(-8, 7) for _ in range(D)] for _ in range(S)]
    v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(S)]
    cases.append(("small_range", q, k, v))

    return cases


def to_hex_byte(x):
    return f"{(x & 0xFF):02X}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--random", type=int, default=16, help="随机用例数量")
    ap.add_argument("--seed", type=int, default=20260912, help="随机种子")
    ap.add_argument("--out", default="vectors.hex", help="输出激励文件")
    ap.add_argument("--report", default="vectors_report.txt", help="中间结果报告")
    ap.add_argument("--stats", default="vectors_stats.txt", help="汇总统计")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    cases = directed_cases()

    # 随机用例: 一半全量程, 一半小量程(小量程下 softmax 更"软")
    for i in range(args.random):
        lo, hi = (-128, 127) if (i % 2 == 0) else (-8, 7)
        q = [rng.randint(lo, hi) for _ in range(D)]
        k = [[rng.randint(lo, hi) for _ in range(D)] for _ in range(S)]
        v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(S)]
        cases.append((f"random_{i:02d}_{'full' if lo < -8 else 'small'}", q, k, v))

    lines, report, n_quant_diff = [], [], 0
    for idx, (name, q, k, v) in enumerate(cases):
        r = attention(q, k, v)
        o_float = attention_float(q, k, v)
        if r["O"] != o_float:
            n_quant_diff += 1
        lines += [to_hex_byte(b) for b in flatten(q, k, v)]
        lines += [to_hex_byte(b) for b in r["O"]]
        report.append(
            f"[{idx:03d}] {name}\n"
            f"    Q={q}  K={k}\n"
            f"    V={v}\n"
            f"    score={r['score']}  xmax={r['xmax']}\n"
            f"    weight={r['weight']}  L={r['L']}\n"
            f"    ACC={r['ACC']}  O={r['O']}  (浮点参考 O={o_float})\n"
        )

    Path(args.out).write_text("\n".join(lines) + "\n", encoding="ascii")
    Path(args.report).write_text("\n".join(report), encoding="utf-8")

    stats = (
        f"用例总数        : {len(cases)}\n"
        f"随机用例数      : {args.random} (seed={args.seed})\n"
        f"激励文件        : {args.out}  ({len(lines)} 个字节)\n"
        f"与浮点参考不一致: {n_quant_diff} / {len(cases)} "
        f"({100.0*n_quant_diff/len(cases):.1f}%, 反映 Q4.4 权重量化带来的偏差)\n"
    )
    Path(args.stats).write_text(stats, encoding="utf-8")
    print(stats, end="")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vcd_wave.py -- 把仿真 VCD 渲染成时序波形图(PNG), 用于报告与汇报材料

用法:
    python vcd_wave.py waves/tb_attention.vcd --out ../doc/wave_overview.png \
        --t0 <起始时间> --t1 <结束时间> --group overview

不依赖 GTKWave 等 GUI 工具, 只使用 Pillow。
"""

import argparse
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

STATE_NAMES = {
    0: "IDLE", 1: "LOAD_Q", 2: "LOAD_KV", 3: "DOT", 4: "MAX", 5: "EXP",
    6: "ACC", 7: "NORM", 8: "OUT", 9: "DONE", 10: "NORM_W",
}

# 每组的信号列表: (层次名后缀, 显示名, 类型)
# 类型: bit / bus / signed / state / clock
GROUPS = {
    "overview": [
        ("tb_attention.clk",                     "clk",         "clock"),
        ("tb_attention.rst_n",                   "rst_n",       "bit"),
        ("tb_attention.start",                   "start",       "bit"),
        ("tb_attention.q_valid",                 "q_valid",     "bit"),
        ("tb_attention.q_in",                    "q_in",        "signed"),
        ("tb_attention.kv_valid",                "kv_valid",    "bit"),
        ("tb_attention.k_in",                    "k_in",        "signed"),
        ("tb_attention.v_in",                    "v_in",        "signed"),
        ("tb_attention.data_ready",              "data_ready",  "bit"),
        ("tb_attention.dut.state",               "state",       "state"),
        ("tb_attention.dut.kv_cnt",              "kv_cnt",      "bus"),
        ("tb_attention.dut.tok",                 "token",       "bus"),
        ("tb_attention.out_valid",               "out_valid",   "bit"),
        ("tb_attention.out_data",                "out_data",    "signed"),
        ("tb_attention.done",                    "done",        "bit"),
    ],
    "datapath": [
        ("tb_attention.clk",                     "clk",         "clock"),
        ("tb_attention.dut.state",               "state",       "state"),
        ("tb_attention.dut.tok",                 "token",       "bus"),
        ("tb_attention.dut.dot_cnt",             "dot_cnt",     "bus"),
        ("tb_attention.dut.dot_prod",            "Q*K",         "signed"),
        ("tb_attention.dut.dot_acc",             "dot_acc",     "signed"),
        ("tb_attention.dbg_score_0",             "score[0]",    "signed"),
        ("tb_attention.dbg_score_1",             "score[1]",    "signed"),
        ("tb_attention.dut.xmax",                "x_max",       "signed"),
        ("tb_attention.dut.exp_w",               "exp_lut_out", "bus"),
        ("tb_attention.dut.lsum",                "L",           "bus"),
        ("tb_attention.dbg_acc_0",               "ACC[0]",      "signed"),
        ("tb_attention.dbg_acc_1",               "ACC[1]",      "signed"),
        ("tb_attention.dbg_acc_2",               "ACC[2]",      "signed"),
        ("tb_attention.dbg_acc_3",               "ACC[3]",      "signed"),
    ],
    "softmax": [
        ("tb_attention.clk",                     "clk",         "clock"),
        ("tb_attention.dut.state",               "state",       "state"),
        ("tb_attention.dut.tok",                 "token",       "bus"),
        ("tb_attention.dut.exp_cnt",             "exp_cnt",     "bus"),
        ("tb_attention.dut.exp_diff",            "score-x_max", "signed"),
        ("tb_attention.dut.exp_w",               "weight(Q4.4)", "bus"),
        ("tb_attention.dbg_w_0",                 "weight[0]",   "bus"),
        ("tb_attention.dbg_w_1",                 "weight[1]",   "bus"),
        ("tb_attention.dbg_w_2",                 "weight[2]",   "bus"),
        ("tb_attention.dbg_w_7",                 "weight[7]",   "bus"),
        ("tb_attention.dut.lsum",                "L",           "bus"),
    ],
    "output": [
        ("tb_attention.clk",                     "clk",         "clock"),
        ("tb_attention.dut.state",               "state",       "state"),
        ("tb_attention.dut.norm_cnt",            "norm_cnt",    "bus"),
        ("tb_attention.dut.div_start",           "div_start",   "bit"),
        ("tb_attention.dut.div_numer",           "|ACC|",       "bus"),
        ("tb_attention.dut.div_quo",             "div_quo",     "bus"),
        ("tb_attention.dut.div_done",            "div_done",    "bit"),
        ("tb_attention.dut.u_div.bit_idx",       "div.bit_idx", "bus"),
        ("tb_attention.dbg_o_0",                 "O[0]",        "signed"),
        ("tb_attention.dbg_o_1",                 "O[1]",        "signed"),
        ("tb_attention.dbg_o_2",                 "O[2]",        "signed"),
        ("tb_attention.dbg_o_3",                 "O[3]",        "signed"),
        ("tb_attention.out_valid",               "out_valid",   "bit"),
        ("tb_attention.out_data",                "out_data",    "signed"),
        ("tb_attention.done",                    "done",        "bit"),
    ],
}


def parse_vcd(path):
    """返回 (signals, changes): signals 为 {层次名: (位宽, id)}, changes 为 {id: [(t, val)]}"""
    txt = Path(path).read_text(errors="replace")
    scopes, signals, changes = [], {}, {}
    cur_time = 0
    in_defs = True
    var_re = re.compile(r"\$var\s+(\w+)\s+(\d+)\s+(\S+)\s+([^\s$]+)")

    for line in txt.splitlines():
        line = line.strip()
        if not line:
            continue
        if in_defs:
            if line.startswith("$scope"):
                scopes.append(line.split()[2])
            elif line.startswith("$upscope"):
                scopes.pop()
            elif line.startswith("$var"):
                m = var_re.match(line)
                if m:
                    _, width, vid, name = m.groups()
                    full = ".".join(scopes + [name])
                    signals[full] = (int(width), vid)
                    changes.setdefault(vid, [])
            elif line.startswith("$enddefinitions"):
                in_defs = False
        else:
            if line.startswith("#"):
                cur_time = int(line[1:])
            elif line.startswith(("0", "1", "x", "z", "X", "Z")):
                changes[line[1:]].append((cur_time, line[0]))
            elif line.startswith(("b", "B")):
                parts = line[1:].split()
                if len(parts) == 2:
                    changes.setdefault(parts[1], []).append((cur_time, parts[0]))
            elif line.startswith(("r", "R")):
                parts = line[1:].split()
                if len(parts) == 2:
                    changes.setdefault(parts[1], []).append((cur_time, parts[0]))
    return signals, changes


def value_at(changes, vid, t):
    val = None
    for tt, vv in changes.get(vid, []):
        if tt <= t:
            val = vv
        else:
            break
    return val


def load_font(size, cjk=False):
    if cjk:
        cands = ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf",
                 "C:/Windows/Fonts/simsun.ttc", "C:/Windows/Fonts/consola.ttf"]
    else:
        cands = ["C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/msyh.ttc",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]
    for c in cands:
        try:
            return ImageFont.truetype(c, size)
        except Exception:
            continue
    return ImageFont.load_default()


CLK_PERIOD = 10000           # VCD 时间单位: 1 个时钟周期 = 10 ns = 10000


def render(vcd_path, out_path, group, t0, t1, title=None, px=26.0):
    signals, changes = parse_vcd(vcd_path)
    specs = GROUPS[group]

    # 找出每个时间点的采样网格(每个时钟上升沿一格)
    clk_id = signals.get("tb_attention.clk", (1, None))[1]
    edges = [t for t, v in changes.get(clk_id, []) if v == "1"]
    edges = [t for t in edges if t0 <= t <= t1]
    if len(edges) < 2:
        raise SystemExit("时间窗口内没有足够的时钟沿")

    row_h = {"clock": 30, "bit": 34, "bus": 44, "signed": 44, "state": 44}
    px_per_edge = float(px)
    left = 190
    top = 70
    width = int(left + px_per_edge * (len(edges) - 1) + 60)
    height = int(top + sum(row_h[s[2]] for s in specs) + 60)

    img = Image.new("RGB", (width, height), "white")
    d = ImageDraw.Draw(img)
    f_name = load_font(15)
    f_val = load_font(12)
    f_title = load_font(19, cjk=True)
    f_tick = load_font(11, cjk=True)

    d.text((16, 16), title or f"Attention IP 仿真波形 ({group})", fill="#111111", font=f_title)
    d.text((16, 42), f"时间窗口 {t0/1000.0:.0f}~{t1/1000.0:.0f} ns   "
                     f"每格 1 个时钟(10 ns, 100 MHz)   "
                     f"横轴数字 = 窗口内第 N 个时钟上升沿", fill="#555555", font=f_tick)

    def x_of(t):
        # 以时钟沿为网格, 线性映射
        return left + (t - edges[0]) / (edges[-1] - edges[0]) * (width - left - 40)

    # 竖向网格线
    for i, t in enumerate(edges):
        if i % 4:
            continue
        x = x_of(t)
        d.line([(x, top - 12), (x, height - 40)], fill="#eeeeee")
        d.text((x + 2, height - 32), f"{i}", fill="#999999", font=f_tick)

    y = top
    for hier, name, kind in specs:
        w, vid = signals.get(hier, (None, None))
        rh = row_h[kind]
        y_hi, y_lo = y, y + rh - 8
        d.text((16, y + rh // 2 - 10), name, fill="#000000", font=f_name)
        d.line([(left, y_lo), (width - 30, y_lo)], fill="#dddddd")

        if vid is None:
            d.text((left + 8, y + 4), "<no signal>", fill="#cc0000", font=f_val)
            y += rh
            continue

        if kind == "clock":
            pts = []
            for t, v in changes.get(vid, []):
                if t0 <= t <= t1:
                    pts.append((x_of(t), y_hi if v == "1" else y_lo))
            if pts:
                d.line(pts, fill="#006699", width=2)
        elif kind == "bit":
            cur = value_at(changes, vid, t0)
            start = t0
            for t, v in changes.get(vid, []):
                if t <= t0 or t > t1:
                    continue
                xa, xb = x_of(start), x_of(t)
                yy = y_hi if cur == "1" else y_lo
                d.line([(xa, yy), (xb, yy)], fill="#006699", width=2)
                if cur != v:
                    d.line([(xb, y_hi), (xb, y_lo)], fill="#006699", width=2)
                start, cur = t, v
            xa = x_of(start)
            yy = y_hi if cur == "1" else y_lo
            d.line([(xa, yy), (width - 30, yy)], fill="#006699", width=2)
        else:
            # 总线: 值变化时画一个梯形块并标注数值
            cur = value_at(changes, vid, t0)
            start = t0
            segs = [(t, v) for t, v in changes.get(vid, []) if t0 < t <= t1]
            for idx, (t, v) in enumerate(segs + [(t1, None)]):
                xa, xb = x_of(start), x_of(t)
                if cur is not None:
                    try:
                        ival = int(cur, 2)
                        if ival >= (1 << (w - 1)) and kind in ("signed", "state") and kind != "state":
                            ival -= (1 << w)
                    except ValueError:
                        ival = None
                    label = STATE_NAMES.get(int(cur, 2), str(int(cur, 2))) if kind == "state" else (
                        str(ival) if ival is not None else cur)
                    if kind == "bus" and cur and len(cur) > 4:
                        label = f"{int(cur,2)}"
                    if xb - xa > 18:
                        d.rectangle([xa, y_hi, xb, y_lo], outline="#006699", fill="#eaf4fb")
                        d.text(((xa + xb) / 2 - 4 * len(label), (y_hi + y_lo) / 2 - 8),
                               label, fill="#003a5c", font=f_val)
                    else:
                        d.rectangle([xa, y_hi, xb, y_lo], outline="#006699", fill="#eaf4fb")
                start, cur = t, v
        y += rh

    img.save(out_path)
    print(f"波形图已生成: {out_path}  ({width}x{height})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("--out", required=True)
    ap.add_argument("--group", default="overview", choices=list(GROUPS))
    ap.add_argument("--t0", type=int, default=None, help="绝对起始时间")
    ap.add_argument("--t1", type=int, default=None, help="绝对结束时间")
    ap.add_argument("--task", type=int, default=None,
                    help="以第 N 个任务的 start 脉冲为基准(推荐)")
    ap.add_argument("--rel0", type=int, default=0, help="相对任务起点偏移(时钟周期)")
    ap.add_argument("--rel1", type=int, default=170, help="相对任务起点结束偏移(时钟周期)")
    ap.add_argument("--title", default=None)
    ap.add_argument("--px", type=float, default=26.0, help="每个时钟沿的像素宽度")
    args = ap.parse_args()

    t0, t1 = args.t0, args.t1
    if args.task is not None:
        signals, changes = parse_vcd(args.vcd)
        s_id = signals["tb_attention.start"][1]
        starts = [t for t, v in changes[s_id] if v == "1"]
        if args.task >= len(starts):
            raise SystemExit(f"只有 {len(starts)} 个任务, 找不到第 {args.task} 个")
        base = starts[args.task]
        t0 = base + args.rel0 * CLK_PERIOD
        t1 = base + args.rel1 * CLK_PERIOD
    if t0 is None:
        t0 = 0
    if t1 is None:
        t1 = 10**12
    render(args.vcd, args.out, args.group, t0, t1, args.title, args.px)


if __name__ == "__main__":
    main()

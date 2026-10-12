#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""log2png.py -- 把仿真日志渲染成图片(结果截图), 供报告使用。

用法: python log2png.py sim_log.txt --out ../doc/sim_log.png --head 8 --tail 22
"""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def load_font(size, cjk=False):
    if cjk:
        cands = ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf",
                 "C:/Windows/Fonts/consola.ttf"]
    else:
        cands = ["C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/msyh.ttc",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]
    for c in cands:
        try:
            return ImageFont.truetype(c, size)
        except Exception:
            continue
    return ImageFont.load_default()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--out", required=True)
    ap.add_argument("--head", type=int, default=6)
    ap.add_argument("--tail", type=int, default=24)
    ap.add_argument("--title", default="Icarus Verilog 仿真结果 (节选)")
    args = ap.parse_args()

    lines = Path(args.log).read_text(errors="replace").splitlines()
    shown = lines[:args.head] + ["..."] + lines[-args.tail:]

    f = load_font(17)
    ft = load_font(20, cjk=True)
    lh = 24
    width = 1180
    height = 70 + lh * len(shown) + 20
    img = Image.new("RGB", (width, height), "white")
    d = ImageDraw.Draw(img)
    d.text((20, 16), args.title, fill="#111111", font=ft)
    d.line([(20, 48), (width - 20, 48)], fill="#cccccc")
    y = 60
    for ln in shown:
        color = "#111111"
        if "RESULT" in ln or "PASSED" in ln:
            color = "#0a7d24"
        elif "FAIL" in ln or "TIMEOUT" in ln:
            color = "#c00000"
        elif ln.startswith("..."):
            color = "#888888"
        d.text((20, y), ln[:120], fill=color, font=f)
        y += lh
    img.save(args.out)
    print(f"日志截图已生成: {args.out} ({width}x{height})")


if __name__ == "__main__":
    main()

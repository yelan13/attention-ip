# Attention 加速器 IP 设计与验证（考核 A 题）

面向「数字组招生实践项目（大二）· 从公式到 RTL：Attention 加速器 IP 设计与验证」的完整提交物：
RTL 源码、自检测试平台、Python 黄金模型、仿真脚本、波形/结果截图、设计报告与汇报 PPT。

规模按题目正式任务固定为 **S = 8 个 Token、d = 4 维、输入输出 8-bit 有符号整数**。

---

## 最快上手

```powershell
# ① 进入 sim 目录（激励 vectors.hex 与波形目录都在这一层，必须在这里跑）
cd sim

# ② 一键仿真：生成激励 → 编译 → 仿真 → 与黄金模型逐位比对 → 出波形图
powershell -ExecutionPolicy Bypass -File run_sim.ps1

# ③ 压力测试（400 个随机用例 + 9 个定向用例 = 409 例）
powershell -ExecutionPolicy Bypass -File run_sim.ps1 -Stress
```

运行后终端会打印每个用例的 `[PASS] / [FAIL]`、周期统计和汇总结果（`ALL TESTS PASSED`），
并把波形图写到 `doc/`、波形文件写到 `sim/waves/`。

### 手动三步（想看清每一步在做什么）

```powershell
cd sim

# 1) 生成激励与期望输出（黄金模型算标准答案）
python gen_vectors.py -n 32 --seed 20260912 --out vectors.hex `
    --report vectors_report.txt --stats vectors_stats.txt

# 2) 编译 RTL + testbench
iverilog -g2012 -Wall -DNCASES=41 -o attention.vvp `
    ..\rtl\exp_lut.sv ..\rtl\seq_div.sv ..\rtl\attention_top.sv ..\tb\tb_attention.sv

# 3) 运行仿真并比对
vvp attention.vvp
```

> `-DNCASES=41` 是编译期宏，必须与 `vectors.hex` 的用例数（41 × 72 = 2952 行）一致。

---

## 1. 工具版本

| 工具 | 版本 | 说明 |
| --- | --- | --- |
| Icarus Verilog | 12.0 (devel) | RTL 编译与仿真（`iverilog -g2012` / `vvp`） |
| 语言标准 | SystemVerilog (IEEE 1800-2012) | RTL 与 testbench 均使用 `.sv`，见下方“为什么用 SystemVerilog” |
| Python | 3.12.14 | 黄金模型、激励生成、波形渲染 |
| PowerShell | 5.1 / 7.x | 一键脚本 `sim/run_sim.ps1`（另附 `run_sim.sh`） |
| GTKWave | 3.3（可选） | 直接打开 `sim/waves/tb_attention.vcd` 查看波形 |

波形图由 `sim/vcd_wave.py` 直接从 VCD 渲染成 PNG，不依赖图形界面。

---

## 2. 文件结构

```
attention-ip/                        ← 仓库根目录（即本项目仓库）
├── README.md                        # 项目总览：工具版本、文件结构、运行命令、提交对照
├── .gitignore                       # 忽略 .vvp / __pycache__ / 临时目录
├── LICENSE                          # MIT 许可
│
├── rtl/                             # ① 完整 RTL 源代码（SystemVerilog）
│   ├── attention_top.sv             #    顶层 IP：枚举状态机 + Buffer + 数据通路
│   ├── exp_lut.sv                   #    可综合指数查找表（weight 无符号 Q4.4）
│   └── seq_div.sv                   #    顺序除法器（自带四舍五入）
├── tb/
│   ├── tb_attention.sv              # ② 自检测试平台：协议驱动 + 逐项比对 + 周期统计
│   └── tb_attention_mask.sv         # 加分项 A 独立测试：因果 Mask（检查权重/L/输出）
├── model/
│   └── attention_golden.py          # ③ Python 黄金模型（含题目手算示例自检）
│
├── sim/                             # ④ 仿真脚本与仿真结果
│   ├── run_sim.ps1 / run_sim.sh     #    一键仿真（Windows / Linux·macOS）
│   ├── gen_vectors.py               #    激励与期望值生成（每例 72 字节）
│   ├── check_mask.py                #    加分项 A：因果 Mask 的标准答案生成
│   ├── vcd_wave.py / log2png.py     #    VCD→波形图 / 日志→结果截图
│   ├── vectors.hex                  #    当前激励（41 例 × 72 字节 = 2952 行）
│   ├── vectors_report.txt           #    每例的 score/x_max/weight/L/ACC/O 中间结果
│   ├── vectors_stats.txt            #    用例统计
│   ├── sim_log.txt                  #    41 例仿真日志
│   ├── sim_stress_log.txt           #    409 例压力测试日志
│   └── waves/tb_attention.vcd       #    波形文件（GTKWave 直接打开）
│
├── doc/                             # ⑤ 设计报告、汇报 PPT 与波形/结果截图
│   ├── Attention加速器IP设计报告.docx   #  5-8 页设计报告（实际 8 页）
│   ├── Attention加速器IP汇报.pptx       #  5-8 分钟汇报 PPT（实际 10 页）
│   ├── arch_diagram.png / fsm_diagram.png   # 架构图 / 状态机图
│   ├── wave_overview.png            #  单次任务全流程波形
│   ├── wave_datapath.png            #  Score / x_max / exp / ACC 数据通路波形
│   ├── wave_softmax.png             #  Softmax 权重计算波形
│   ├── wave_output.png              #  归一化与输出时序波形
│   └── sim_log.png                  #  仿真结果截图
```

> 提示：GitHub 不能在线预览 `.docx` / `.pptx`，需要下载后用 Word / PowerPoint 打开。

---

## 3. 运行命令

### 一键运行（推荐）

```powershell
# Windows PowerShell（默认 32 个随机用例 + 9 个定向用例）
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1

# 加大随机用例数量
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1 -Random 400

# 压力测试（400 随机用例，不生成波形，速度更快）
powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1 -Stress
```

```bash
# Linux / macOS / WSL
./sim/run_sim.sh 400 12345
```

### 手动分步执行

```powershell
cd sim

# 1) 生成激励（随机用例数、随机种子可调）
python gen_vectors.py -n 32 --seed 20260912 --out vectors.hex

# 2) 编译 RTL + testbench（41 = 32 随机 + 9 定向）
iverilog -g2012 -Wall -DNCASES=41 -o attention.vvp `
    ..\rtl\exp_lut.sv ..\rtl\seq_div.sv ..\rtl\attention_top.sv ..\tb\tb_attention.sv

# 3) 运行仿真（会产生 vectors.hex 校验结果与 waves/tb_attention.vcd）
vvp attention.vvp

# 4) 查看波形
gtkwave waves/tb_attention.vcd
```

### 只跑黄金模型自检（含题目手算示例核对）

```powershell
python model\attention_golden.py --selftest
```

---

## 4. 接口协议

```systemverilog
module attention_top #(
    parameter int S = 8, D = 4, DW = 8, W_FRAC = 4
)(
    input  logic                 clk, rst_n, start,
    input  logic signed [DW-1:0] q_in, k_in, v_in,
    input  logic                 q_valid, kv_valid,
    output logic                 data_ready, out_valid, done,
    output logic signed [DW-1:0] out_data
);
```

### 为什么用 SystemVerilog

* `typedef enum` 描述 11 个状态，波形里直接显示状态名，答辩时不用再对照编码表；
* `always_ff` / `always_comb` 明确区分时序与组合逻辑，避免综合出意外锁存器；
* `logic` / `int` / `$clog2` / 参数化位宽（`S`、`D`、`DW`、`W_FRAC`）便于改规模和复用到更大序列长度；
* 端口名、位宽与时序与题目"建议接口"完全一致，任何按题目接口编写的 testbench 都可以直接例化。

编译时用 `-g2012` 指定 SystemVerilog 标准（Vivado、Questa、VCS 等工具默认支持；Icarus 需要显式加）。
如果指定仿真器较老只支持 Verilog-2001，把 `typedef enum` 换成 `localparam` 编码、`always_ff/always_comb`
换成 `always @` 即可，逻辑不用动（本项目最早就是在 Verilog-2001 上验证通过后再迁移到 SV 的）。

| 信号 | 约定 |
| --- | --- |
| `start` | 仅在 **IDLE** 状态有效，拉高 1 拍启动一次任务 |
| `q_valid` | `q_in` 有效，共 **4 拍**，依次为 Q[0]、Q[1]、Q[2]、Q[3] |
| `kv_valid` | `k_in`/`v_in` 有效，共 **32 拍**，第 `j*4+k` 拍给出 K_j[k] 与 V_j[k]（K/V 同拍成对） |
| `data_ready` | 为 1 时才能发送输入；本设计在 IDLE / LOAD_Q / LOAD_KV 期间为 1，计算期间为 0 |
| `out_valid` | 为 1 时 `out_data` 有效，共 **4 拍**，依次为 O[0]~O[3]（8-bit 有符号） |
| `done` | 4 个结果输出完毕后拉高 **1 拍**，随后回到 IDLE |

> **关于 K/V 输入顺序的说明**：题目接口中 `k_in` / `v_in` 均为 8-bit，而一个 Token 的
> K_j 和 V_j 各有 d=4 个元素，因此本项目按「每拍给出一个 K 元素和对应的一个 V 元素，
> 共 S×d = 32 拍」实现（顺序为 K0[0],V0[0] → K0[1],V0[1] → … → K7[3],V7[3]）。
> 这是 8-bit 端口下唯一可行的数据组织方式，也是 testbench 采用的驱动顺序。

时序示意见 `doc/wave_overview.png`：`start → 4 拍 Q → 32 拍 K/V → 计算 → 4 拍 out_valid → done`。

---

## 5. 设计要点

### 5.1 状态机与周期数

| 状态 | 周期 | 主要动作 |
| --- | --- | --- |
| IDLE | 1 | 采样 `start` 并清空上次残留的 ACC/L |
| LOAD_Q | 4 | 装载 Q 到 Q 寄存器 |
| LOAD_KV | 32 | 装载 K/V 到 K/V Buffer |
| DOT | 32 | 单乘法器串行点积，每 4 拍得到一个 Score，共 8 个 |
| MAX | 8 | 依次比较，检索 x_max |
| EXP | 8 | 计算 `score - x_max` 并查表得到 weight，同时累加 L |
| ACC | 8 | 4 路并行：`ACC[k] += weight × V[k]` |
| NORM | 72 | 顺序除法器分时复用 4 次，`O = round(ACC/L)`（每次 18 拍） |
| OUT | 4 | 依次输出 O[0]~O[3] |
| **合计** | **169 周期** | 任务延迟；100 MHz 下约 **1.69 µs / 次任务**（实测 min = avg = max = 169） |
| DONE | 1 | 任务结束后 `done` 拉高 1 拍，随后返回 IDLE（不计入上面的 169 拍） |

### 5.2 位宽设计（详见报告）

| 数据 | 位宽 | 依据 |
| --- | --- | --- |
| Q/K/V/O | 8-bit 有符号 | 题目规定 |
| 乘积 | 16-bit 有符号 | 8b × 8b |
| Score / x_max | 18-bit 有符号 | 4 项点积，取值范围 ±65536 |
| `score - x_max` | 19-bit 有符号 | 留 1 位余量，保证恒 ≤ 0 |
| weight | 5-bit 无符号（1 整数 + 4 小数，Q4.4） | exp(·) ∈ (0,1]，题目固定小数 4 位 |
| L | 8-bit 无符号 | Σweight ≤ 8 × 16 = 128 |
| ACC | 16-bit 有符号 | \|ACC\| ≤ L × max\|V\| = 128 × 128 = 16384 |

### 5.3 Softmax 的定点处理

* 先求 `x_max`，再算 `score - x_max ≤ 0`，避免指数溢出；
* `weight = round(exp(score - x_max) × 16)`，用 `exp_lut` 查表实现（**不是**对 exp 取整）；
* 由于 Score 为整数、weight 只有 4 位小数，LUT 有效地址只有 `mag = 0~4` 共 5 项：
  `16 / 6 / 2 / 1 / 0`（对应 `exp(0)、exp(-1)、exp(-2)、exp(-3)、exp(-4)`），
  其余全部下溢为 0。这在 4 位小数精度下是最小完备表；
* 量化损失：与全精度浮点 Softmax 相比，测试集约 17% 的用例输出存在 ±1 的差异，
  报告第 7 节给出了分析与更高精度替代方案。

---

## 6. 验证情况

| 测试 | 用例数 | 结果 |
| --- | --- | --- |
| 定向用例（全零 / 极值 / 单 Token 主导 / 等权重 / 负输出 / 舍入边界 / 题目示例） | 9 | 全部通过 |
| 随机用例（全量程 ±128 与小量程 ±8 各半） | 32 | 全部通过 |
| 压力测试（400 随机用例，seed = 12345） | 409 | 全部通过 |

验证方式：Python 黄金模型按题目规则逐位计算期望输出，写入 `vectors.hex`；
testbench 在每次任务结束后比对 4 个输出元素，并检查 `done` 时序与输出是否存在 X。
`sim/vectors_report.txt` 保存了每个用例的 score / x_max / weight / L / ACC / O 中间结果。

---

## 7. 已知限制与后续可扩展项

1. **K/V 装载与计算未重叠**：装载占 36 拍，可以边装载边做点积，进一步压缩周期；点积本身已支持 4 路并行（加分项 B，第 8 节）。
2. **除法器串行复用**：NORM 占 72 拍（总周期的 43%）。可换成 4 路并行除法器或倒数 LUT，
   代价是面积增加（加分项 B）。
3. **定点精度**：weight 固定 4 位小数，score 差 ≥ 4 的 Token 权重会下溢为 0，
   等价于硬 Attention。更高精度可用更大 ROM / 分段线性 / CORDIC 方案（加分项 E、F）。
4. **因果 Mask 已实现**（加分项 A，见第 8 节：`MASK_EN` + `pos_i`，附独立测试）；**动态阈值筛选（加分项 D）尚未实现**，当前版本聚焦题目基础要求。
5. 参数化支持 `S`、`D`、`DW`、`W_FRAC`，但默认配置按题目固定为 8 / 4 / 8 / 4；
   更大规模（如 S=256）需要重新评估 Buffer 容量与带宽（加分项 C、G）。

---

## 8. 加分项实现与验证（A / B / C）

题目第十二节的加分项里，A、B 是需要独立测试的功能项，C 是参数化。三项均已实现并实测：

| 加分项 | 实现方式 | 独立测试 | 实测结果 |
| --- | --- | --- | --- |
| **A 因果 Mask** | `attention_top` 新增 `pos_i` 输入与 `MASK_EN` 参数：`j > pos_i` 的 Key 不参与 `x_max` 检索、权重置 0、不进入 L 与 ACC（MAX / EXP 状态） | `tb/tb_attention_mask.sv`：独立测试平台，检查权重、L、输出三层 | `pos_i` = 0 / 3 / 7 三组全部通过：O = [10,0,0,0] / [35,10,0,0] / [58,19,0,0]，被屏蔽位权重全为 0 |
| **B 并行点积** | 新增 `DOT_PAR` 参数：`DOT_PAR=D` 时用 D 个乘法器一拍算完一个 Score（新增 `ST_DOT_FAST` 状态），点积 32 拍 → 8 拍 | 同一套 41 例 + 409 例压力测试 | 周期 169 → **145 拍**（−14%），409/409 全部通过；代价是 +3 个 8×8 乘法器与 3 个 18 位加法器 |
| **C 参数化** | `S` / `D` / `DW` / `W_FRAC` 全部参数化，计数器位宽由 `$clog2` 自动推导，`exp_lut`、`seq_div` 随参数传递 | 把 S 改成 4 后重跑标准回归 | 激励自动变为 40 字节/例，**41/41 通过**，周期 169 → **125 拍** |

### 复现命令

```powershell
cd sim

# 加分项 A：因果 Mask 独立测试
iverilog -g2012 -Wall -o mask.vvp ..\rtl\exp_lut.sv ..\rtl\seq_div.sv ..\rtl\attention_top.sv ..\tb\tb_attention_mask.sv
vvp mask.vvp

# 加分项 B：并行点积（标准回归 / 压力测试）
powershell -ExecutionPolicy Bypass -File run_sim.ps1 -DotPar 4
powershell -ExecutionPolicy Bypass -File run_sim.ps1 -Stress -DotPar 4

# 加分项 C：改规模（把 tb/tb_attention.sv 与 sim/gen_vectors.py 里的 S 改成 4 后重跑）
powershell -ExecutionPolicy Bypass -File run_sim.ps1 -NoWave
```

### 周期与资源对比

| 配置 | 单次任务周期 | 8×8 乘法器 | 说明 |
| --- | --- | --- | --- |
| 基础版（S=8，DOT_PAR=1） | 169 | 1 | 面积优先，点积与除法器都串行复用 |
| 并行点积（S=8，DOT_PAR=4） | 145 | 4 | 面积换时间；除法器仍复用 1 个，归一化占 50% |
| 缩小规模（S=4，DOT_PAR=1） | 125 | 1 | 归一化仍是 72 拍（只与 d 有关），占比升到 58% |

> E（指数函数硬件实现方法调研）与 G（S=256、d=64 时的 Softmax 问题）属于报告类加分项：
> 报告第 10 节给出调研方向，第 8.3 节给出 S=256 的存储、带宽与数值分析结论。

---

## 9. 提交内容对照表

| 题目要求的提交内容 | 本提交包中的位置 |
| --- | --- |
| 完整 RTL 源代码 | `rtl/attention_top.sv`、`rtl/exp_lut.sv`、`rtl/seq_div.sv` |
| 自己编写或扩展的 testbench | `tb/tb_attention.sv` |
| 仿真脚本 | `sim/run_sim.ps1`（Windows 一键）、`sim/run_sim.sh`（Linux/macOS）、`sim/gen_vectors.py`（激励与期望值生成） |
| 波形 | `sim/waves/tb_attention.vcd`（GTKWave 直接打开） |
| 结果截图 | `doc/wave_overview.png`、`doc/wave_datapath.png`、`doc/wave_softmax.png`、`doc/wave_output.png`、`doc/sim_log.png` |
| 5-8 页设计报告 | `doc/Attention加速器IP设计报告.docx`（8 页）与 `doc/Attention加速器IP设计报告.pdf` |
| 5-8 分钟汇报 PPT | `doc/Attention加速器IP汇报.pptx`（11 页，含加分项页）与 `doc/Attention加速器IP汇报.pdf` |
| README：工具版本、运行命令、文件结构 | 本文件 |

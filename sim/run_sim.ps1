<#
    run_sim.ps1 -- Attention IP 一键仿真脚本 (Windows / PowerShell)

    用法:
        powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1
        powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1 -Random 400 -Stress
        powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1 -Random 0 -Seed 1

    流程: 生成激励 -> 编译 RTL+TB -> 运行仿真 -> 渲染波形与日志截图
#>
param(
    [int]   $Random = 32,          # 随机用例数量
    [int]   $Seed   = 20260912,    # 随机种子
    [switch]$Stress,               # 压力测试(400 随机用例, 不生成波形以节省时间)
    [switch]$NoWave                # 不生成波形图片
)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

function Find-Tool($candidates, $name) {
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "找不到 $name, 请先安装并加入 PATH"
}

$python = Find-Tool @(
    "C:\Users\ZhuanZ1\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe") "python"
$iverilog = Find-Tool @("C:\iverilog\bin\iverilog.exe") "iverilog"
$vvp      = Find-Tool @("C:\iverilog\bin\vvp.exe")      "vvp"

$env:PYTHONIOENCODING = "utf-8"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ($Stress) { $Random = 400 }
$ncases = $Random + 9          # 9 个定向用例
$runDir = if ($Stress) { "stress_run" } else { "." }          # 压力测试用独立运行目录
$vec    = if ($Stress) { "stress_run\vectors.hex" } else { "vectors.hex" }
$log    = if ($Stress) { "sim_stress_log.txt" } else { "sim_log.txt" }
$simv   = if ($Stress) { "stress_run\stress.vvp" } else { "attention.vvp" }
if ($Stress) { New-Item -ItemType Directory -Force -Path (Join-Path $here $runDir) | Out-Null }
New-Item -ItemType Directory -Force -Path (Join-Path $here "waves") | Out-Null

Push-Location $here
try {
    Write-Host "==> [1/4] 生成测试激励 (随机用例 $Random 个, seed=$Seed)" -ForegroundColor Cyan
    & $python gen_vectors.py -n $Random --seed $Seed --out $vec `
        --report (Join-Path $runDir "vectors_report.txt") --stats (Join-Path $runDir "vectors_stats.txt")

    Write-Host "==> [2/4] 编译 RTL + Testbench" -ForegroundColor Cyan
    $defs = @("-g2012", "-Wall", "-DNCASES=$ncases")
    if ($Stress) { $defs += "-DNO_DUMP" }
    & $iverilog @defs -o $simv `
        ..\rtl\exp_lut.sv ..\rtl\seq_div.sv ..\rtl\attention_top.sv ..\tb\tb_attention.sv

    Write-Host "==> [3/4] 运行仿真" -ForegroundColor Cyan
    if ($Stress) {
        Push-Location $runDir
        & $vvp "stress.vvp" | Tee-Object -FilePath (Join-Path $here $log)
        Pop-Location
    } else {
        & $vvp $simv | Tee-Object -FilePath $log
    }

    if (-not $Stress -and -not $NoWave) {
        Write-Host "==> [4/4] 渲染波形与日志截图" -ForegroundColor Cyan
        & $python vcd_wave.py waves\tb_attention.vcd --out ..\doc\wave_overview.png `
            --group overview --task 4 --rel0 -1 --rel1 172 --px 8 `
            --title "Attention IP 单次任务全流程波形 (169 周期)"
        & $python vcd_wave.py waves\tb_attention.vcd --out ..\doc\wave_datapath.png `
            --group datapath --task 4 --rel0 35 --rel1 92 --px 22 `
            --title "Score / x_max / exp / ACC 数据通路波形"
        & $python vcd_wave.py waves\tb_attention.vcd --out ..\doc\wave_softmax.png `
            --group softmax --task 4 --rel0 74 --rel1 94 --px 40 `
            --title "Softmax 权重计算 (x_max 检索 + 指数查找表 + L 累加)"
        & $python vcd_wave.py waves\tb_attention.vcd --out ..\doc\wave_output.png `
            --group output --task 4 --rel0 90 --rel1 172 --px 16 `
            --title "归一化(除法)与输出时序波形"
        & $python log2png.py $log --out ..\doc\sim_log.png
    }
    Write-Host "==> 完成。结果见 sim\$log , 波形见 doc\wave_*.png" -ForegroundColor Green
}
finally {
    Pop-Location
}


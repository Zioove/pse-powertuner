<#
.SYNOPSIS
    三档配置对照基准：CPU 单/多核吞吐 + 频率驻留 + 调度抖动
.DESCRIPTION
    纯 .NET 实现，不依赖第三方工具。
    - 吞吐：多线程浮点/内存混合负载
    - 频率：CallNtPowerInformation 读取各逻辑处理器实时 MHz
    - 抖动：1ms 忙等切片的间隔偏差（近似唤醒延迟/DPC 影响）
.EXAMPLE
    .\Invoke-PowerBench.ps1 -Seconds 20 -Label "极致版"
#>
[CmdletBinding()]
param(
    [int]$Seconds = 20,
    [string]$Label = (Get-Date -Format 'HHmmss')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'modules\PowerTune.psm1') -Force
$work = Get-WorkRoot

#region ── 实时频率读取 ─────────────────────────────────────────────────

$freqSrc = @'
using System;
using System.Runtime.InteropServices;

public static class PseCpuFreq
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESSOR_POWER_INFORMATION
    {
        public uint Number;
        public uint MaxMhz;
        public uint CurrentMhz;
        public uint MhzLimit;
        public uint MaxIdleState;
        public uint CurrentIdleState;
    }

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint CallNtPowerInformation(
        int InformationLevel, IntPtr lpInputBuffer, uint nInputBufferSize,
        IntPtr lpOutputBuffer, uint nOutputBufferSize);

    public static uint[] Current()
    {
        int n = Environment.ProcessorCount;
        int sz = Marshal.SizeOf(typeof(PROCESSOR_POWER_INFORMATION));
        IntPtr p = Marshal.AllocHGlobal(sz * n);
        try
        {
            uint r = CallNtPowerInformation(11, IntPtr.Zero, 0, p, (uint)(sz * n));
            if (r != 0) return new uint[0];
            uint[] res = new uint[n];
            for (int i = 0; i < n; i++)
            {
                IntPtr q = (IntPtr)((long)p + (long)i * sz);
                PROCESSOR_POWER_INFORMATION s =
                    (PROCESSOR_POWER_INFORMATION)Marshal.PtrToStructure(
                        q, typeof(PROCESSOR_POWER_INFORMATION));
                res[i] = s.CurrentMhz;
            }
            return res;
        }
        finally { Marshal.FreeHGlobal(p); }
    }
}
'@

$hasFreq = $true
try { Add-Type -TypeDefinition $freqSrc -ErrorAction Stop }
catch {
    $hasFreq = $false
    Write-TuneLog "频率读取不可用（$($_.Exception.Message)），跳过频率统计" 'WARN'
}

#endregion

#region ── 负载与抖动测量 ───────────────────────────────────────────────

function Invoke-CpuLoad {
    <#  多线程混合负载：整数/浮点/内存访问，返回总操作数与耗时  #>
    param(
        [Parameter(Mandatory)][int]$Threads,
        [Parameter(Mandatory)][int]$Milliseconds
    )

    $bucket = [hashtable]::Synchronized(@{})
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $threads = 1..$Threads | ForEach-Object {
        $idx = $_
        $t = [Threading.Thread]::new([Threading.ThreadStart]{
            $acc = 0.0
            $ops = 0L
            $localSw = [Diagnostics.Stopwatch]::StartNew()
            $buf = New-Object 'double[]' 512
            for ($i = 0; $i -lt 512; $i++) { $buf[$i] = $i * 0.5 }
            while ($localSw.ElapsedMilliseconds -lt $Milliseconds) {
                for ($i = 1; $i -le 10000; $i++) {
                    $acc += [Math]::Sqrt($i) * 1.000001
                    $buf[$i % 512] = $acc * 0.999999
                    if ($acc -gt 1e12) { $acc = 0.0 }
                }
                $ops += 10000
            }
            $bucket[$idx] = $ops
        })
        $t.IsBackground = $true
        $t.Start()
        $t
    }
    foreach ($t in $threads) { $t.Join() }

    $total = 0L
    foreach ($v in $bucket.Values) { $total += [long]$v }

    [pscustomobject]@{
        Threads   = $Threads
        ElapsedMs = $sw.ElapsedMilliseconds
        Ops       = $total
        MopsPerSec = if ($sw.ElapsedMilliseconds -gt 0) {
            [math]::Round($total / ($sw.ElapsedMilliseconds / 1000.0) / 1e6, 2)
        } else { 0 }
    }
}

function Measure-SchedulerJitter {
    <#  1ms 忙等切片，统计实际间隔与目标的偏差  #>
    param([int]$Milliseconds = 3000)

    $samples = New-Object 'System.Collections.Generic.List[double]'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = 0.0
    while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
        $spin = [Diagnostics.Stopwatch]::StartNew()
        while ($spin.Elapsed.TotalMilliseconds -lt 1.0) { }
        $now = $sw.Elapsed.TotalMilliseconds
        $samples.Add([Math]::Abs(($now - $last) - 1.0))
        $last = $now
    }
    if ($samples.Count -eq 0) { return [pscustomobject]@{ P50 = 0; P99 = 0; Max = 0 } }
    $sorted = @($samples | Sort-Object)
    $p50 = [int][math]::Floor($sorted.Count * 0.50)
    $p99 = [Math]::Min([int][math]::Floor($sorted.Count * 0.99), $sorted.Count - 1)
    [pscustomobject]@{
        P50 = [math]::Round($sorted[$p50], 3)
        P99 = [math]::Round($sorted[$p99], 3)
        Max = [math]::Round($sorted[-1], 3)
    }
}

function Measure-AverageFrequency {
    param([int]$Samples = 20, [int]$IntervalMs = 100)
    if (-not $hasFreq) { return 0 }
    $all = New-Object 'System.Collections.Generic.List[uint]'
    for ($i = 0; $i -lt $Samples; $i++) {
        $r = [PseCpuFreq]::Current()
        foreach ($v in $r) { if ($v -gt 0) { $all.Add($v) } }
        Start-Sleep -Milliseconds $IntervalMs
    }
    if ($all.Count -eq 0) { return 0 }
    [math]::Round(($all | Measure-Object -Average).Average)
}

#endregion

#region ── 执行 ─────────────────────────────────────────────────────────

$scheme     = Get-ActiveScheme
$schemeName = (Get-SchemeList)[$scheme]
$logical    = [Environment]::ProcessorCount

Write-Host "`n═══ 基准测试：$Label ═══" -ForegroundColor Cyan
Write-Host "当前方案: $schemeName ($scheme)" -ForegroundColor DarkGray
Write-Host "逻辑处理器: $logical · 每项负载 ${Seconds}s`n" -ForegroundColor DarkGray

Write-Host '[1/4] 单线程吞吐 ...' -ForegroundColor Yellow
$single = Invoke-CpuLoad -Threads 1 -Milliseconds ($Seconds * 1000)

Write-Host "[2/4] 全核吞吐（$logical 线程）..." -ForegroundColor Yellow
$multi = Invoke-CpuLoad -Threads $logical -Milliseconds ($Seconds * 1000)

Write-Host '[3/4] 调度抖动 ...' -ForegroundColor Yellow
$jitter = Measure-SchedulerJitter -Milliseconds 3000

Write-Host '[4/4] 平均频率 ...' -ForegroundColor Yellow
$freqAvg = Measure-AverageFrequency

$result = [pscustomobject]@{
    Timestamp   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Label       = $Label
    Scheme      = $schemeName
    SchemeGuid  = $scheme
    SingleScore = $single.MopsPerSec
    MultiScore  = $multi.MopsPerSec
    Scaling     = if ($single.MopsPerSec -gt 0) { [math]::Round($multi.MopsPerSec / $single.MopsPerSec, 2) } else { 0 }
    FreqAvgMHz  = $freqAvg
    JitterP50ms = $jitter.P50
    JitterP99ms = $jitter.P99
    JitterMaxms = $jitter.Max
}

Write-Host "`n═══ 结果 ═══" -ForegroundColor Cyan
$result | Format-List

$csv = Join-Path $work 'reports\bench.csv'
$result | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8
Write-Host "已追加记录到 $csv" -ForegroundColor DarkGray

# 与历史同方案对比
$hist = @(Import-Csv $csv -ErrorAction SilentlyContinue | Where-Object { $_.SchemeGuid -eq $scheme })
if ($hist.Count -gt 1) {
    $prev = $hist[-2]
    Write-Host '与上次同方案对比：' -ForegroundColor Yellow
    foreach ($f in @('SingleScore','MultiScore','FreqAvgMHz','JitterP99ms')) {
        $d = [double]$result.$f - [double]$prev.$f
        $sign = if ($d -gt 0) { '+' } else { '' }
        Write-Host ('  {0,-14} {1,9} -> {2,9}  ({3}{4})' -f $f, $prev.$f, $result.$f, $sign, [math]::Round($d, 2))
    }
}

Write-Host "`n生成图表报告: .\Show-PowerReport.ps1 -Open`n" -ForegroundColor DarkGray

#endregion

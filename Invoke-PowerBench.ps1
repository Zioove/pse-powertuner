<#
.SYNOPSIS
    三档配置对照基准：CPU 单/多核吞吐 + 频率驻留 + 调度抖动
.DESCRIPTION
    纯 .NET 实现，不依赖第三方工具。
    - 吞吐：多线程浮点/内存混合负载（编译后的 C# 热点循环，非 PowerShell 解释执行）
    - 频率：CallNtPowerInformation 读取各逻辑处理器实时 MHz
    - 抖动：1ms 切片的时间偏差（近似唤醒延迟/DPC 影响）

    实现说明：负载与抖动测量都放在 Add-Type 编译的 C# 里，用真正的
    System.Threading.Thread 执行。不要用 [Threading.Thread]::new([ThreadStart]{...})
    把 PowerShell 脚本块当委托——新线程没有 Runspace，会抛出不可捕获的
    PSInvalidOperationException 并直接终止宿主进程。
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
Import-Module (Join-Path $root 'modules\PowerTune.psm1') -Force -WarningAction SilentlyContinue
$work = Get-WorkRoot

#region ── 原生测量（C# 实现） ─────────────────────────────────────────

$benchSrc = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class PseBench
{
    // ── 实时频率 ──
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

    public static uint[] CurrentMhz()
    {
        int n = Environment.ProcessorCount;
        int sz = Marshal.SizeOf(typeof(PROCESSOR_POWER_INFORMATION));
        for (int attempt = 0; attempt < 3; attempt++)
        {
            IntPtr p = Marshal.AllocHGlobal(sz * n);
            try
            {
                uint r = CallNtPowerInformation(11, IntPtr.Zero, 0, p, (uint)(sz * n));
                if (r == 122 /* ERROR_INSUFFICIENT_BUFFER */) { n *= 2; continue; }
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
        return new uint[0];
    }

    // ── 吞吐负载：每个线程跑固定时长的混合浮点/内存循环 ──
    private static long RunWorker(int ms)
    {
        double acc = 0.0;
        long ops = 0;
        double[] buf = new double[512];
        for (int i = 0; i < 512; i++) buf[i] = i * 0.5;
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(ms);
        do
        {
            for (int i = 1; i <= 10000; i++)
            {
                acc += Math.Sqrt(i) * 1.000001;
                buf[i % 512] = acc * 0.999999;
                if (acc > 1e12) acc = 0.0;
            }
            ops += 10000;
        } while (DateTime.UtcNow < deadline);
        return ops;
    }

    /// <summary>返回 {总操作数, 实际耗时毫秒}</summary>
    public static long[] RunLoad(int threads, int ms)
    {
        if (threads < 1) threads = 1;
        long[] results = new long[threads];
        Thread[] workers = new Thread[threads];
        System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();

        for (int t = 0; t < threads; t++)
        {
            int idx = t;
            workers[t] = new Thread(delegate () { results[idx] = RunWorker(ms); });
            workers[t].IsBackground = true;
            workers[t].Start();
        }
        for (int t = 0; t < threads; t++) workers[t].Join();
        sw.Stop();

        long total = 0;
        for (int t = 0; t < threads; t++) total += results[t];
        return new long[] { total, sw.ElapsedMilliseconds };
    }

    // ── 调度抖动：按固定 1ms 目标切片，记录实际间隔偏差（微秒级） ──
    public static double[] Jitter(int ms)
    {
        List<double> samples = new List<double>();
        System.Diagnostics.Stopwatch total = System.Diagnostics.Stopwatch.StartNew();
        System.Diagnostics.Stopwatch slice = new System.Diagnostics.Stopwatch();
        double last = 0.0;
        bool first = true;

        while (total.ElapsedMilliseconds < ms)
        {
            slice.Restart();
            while (slice.Elapsed.TotalMilliseconds < 1.0) { Thread.SpinWait(50); }
            double now = total.Elapsed.TotalMilliseconds;
            // 丢弃第一个样本：起点未对齐，恒为约 0，会把中位数拉低
            if (!first) samples.Add(Math.Abs((now - last) - 1.0));
            first = false;
            last = now;
        }

        samples.Sort();
        return samples.ToArray();
    }

    /// <summary>最近秩百分位，idx = ceil(p*N)-1</summary>
    public static double Percentile(double[] sorted, double p)
    {
        if (sorted == null || sorted.Length == 0) return 0.0;
        int idx = (int)Math.Ceiling(p * sorted.Length) - 1;
        if (idx < 0) idx = 0;
        if (idx >= sorted.Length) idx = sorted.Length - 1;
        return sorted[idx];
    }
}
'@

$hasBench = $true
try {
    if (-not ('PseBench' -as [type])) { Add-Type -TypeDefinition $benchSrc -ErrorAction Stop }
} catch {
    $hasBench = $false
    Write-TuneLog "测量组件编译失败（$($_.Exception.Message)），本次仅输出方案信息" 'WARN'
}

#endregion

#region ── 包装函数 ─────────────────────────────────────────────────────

function Invoke-CpuLoad {
    <#  多线程混合负载：返回总操作数与耗时  #>
    param(
        [Parameter(Mandatory)][int]$ThreadCount,
        [Parameter(Mandatory)][int]$Milliseconds
    )
    # 注意：变量名不能叫 $threads——参数名大小写不敏感，会覆盖 [int] 参数导致类型转换异常
    $r = [PseBench]::RunLoad($ThreadCount, $Milliseconds)
    $total = [long]$r[0]; $elapsed = [long]$r[1]
    [pscustomobject]@{
        Threads    = $ThreadCount
        ElapsedMs  = $elapsed
        Ops        = $total
        MopsPerSec = if ($elapsed -gt 0) {
            [math]::Round($total / ($elapsed / 1000.0) / 1e6, 2)
        } else { 0 }
    }
}

function Measure-SchedulerJitter {
    param([int]$Milliseconds = 3000)
    $s = [PseBench]::Jitter($Milliseconds)
    if ($s.Length -eq 0) { return [pscustomobject]@{ P50 = 0; P99 = 0; Max = 0; Samples = 0 } }
    [pscustomobject]@{
        P50     = [math]::Round([PseBench]::Percentile($s, 0.50), 3)
        P99     = [math]::Round([PseBench]::Percentile($s, 0.99), 3)
        Max     = [math]::Round($s[$s.Length - 1], 3)
        Samples = $s.Length
    }
}

function Measure-AverageFrequency {
    param([int]$Samples = 20, [int]$IntervalMs = 100)
    if (-not $hasBench) { return 0 }
    $all = New-Object 'System.Collections.Generic.List[uint]'
    for ($i = 0; $i -lt $Samples; $i++) {
        foreach ($v in [PseBench]::CurrentMhz()) { if ($v -gt 0) { $all.Add($v) } }
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

if (-not $hasBench) {
    Write-Host '测量组件不可用，无法执行基准。' -ForegroundColor Red
    exit 1
}

Write-Host '[1/4] 单线程吞吐 ...' -ForegroundColor Yellow
$single = Invoke-CpuLoad -ThreadCount 1 -Milliseconds ($Seconds * 1000)

Write-Host "[2/4] 全核吞吐（$logical 线程）..." -ForegroundColor Yellow
$multi = Invoke-CpuLoad -ThreadCount $logical -Milliseconds ($Seconds * 1000)

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

# 与历史同方案对比（仅当历史记录具备同名字段，避免旧 schema 静默变 0）
$hist = @(Import-Csv $csv -ErrorAction SilentlyContinue | Where-Object { $_.SchemeGuid -eq $scheme })
if ($hist.Count -gt 1) {
    $prev = $hist[-2]
    $fields = @('SingleScore','MultiScore','FreqAvgMHz','JitterP99ms')
    $usable = @($fields | Where-Object { $prev.PSObject.Properties.Name -contains $_ })
    if ($usable.Count -eq $fields.Count) {
        Write-Host '与上次同方案对比：' -ForegroundColor Yellow
        foreach ($f in $fields) {
            $d = [double]$result.$f - [double]$prev.$f
            $sign = if ($d -gt 0) { '+' } else { '' }
            Write-Host ('  {0,-14} {1,9} -> {2,9}  ({3}{4})' -f $f, $prev.$f, $result.$f, $sign, [math]::Round($d, 2))
        }
    } else {
        Write-Host '历史记录字段不全（schema 变更），跳过对比。' -ForegroundColor DarkGray
    }
}

Write-Host "`n生成图表报告: .\Show-PowerReport.ps1 -Open`n" -ForegroundColor DarkGray

#endregion

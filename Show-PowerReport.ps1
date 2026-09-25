<#
.SYNOPSIS
    生成电源配置报告：当前值 vs 三档目标值 + 基准测试历史 + 备份记录（HTML）
.EXAMPLE
    .\Show-PowerReport.ps1
    .\Show-PowerReport.ps1 -Open
#>
[CmdletBinding()]
param([switch]$Open)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'modules\PowerTune.psm1') -Force
$work = Get-WorkRoot

$scheme  = Get-ActiveScheme
$schemes = Get-SchemeList
$csv     = Join-Path $work 'reports\bench.csv'
$bench   = if (Test-Path $csv) { @(Import-Csv $csv) } else { @() }

$known   = Get-KnownSettings
$pStable = Get-ProfileDefinition 'balanced-stable'
$pMax    = Get-ProfileDefinition 'max-perf'
$pEco    = Get-ProfileDefinition 'eco'

$allNames = @()
foreach ($p in @($pStable, $pMax, $pEco)) { $allNames += $p.AC.Keys }
$allNames = $allNames | Sort-Object -Unique

$rows = foreach ($a in $allNames) {
    $cur = Get-PowerSettingValue -Name $a
    [pscustomobject]@{
        Name    = $a
        Desc    = $known[$a].Desc
        Current = if ($null -ne $cur.AC) { $cur.AC } else { $null }
        Stable  = $pStable.AC[$a]
        Extreme = $pMax.AC[$a]
        Eco     = $pEco.AC[$a]
    }
}

function HtmlEnc { param([string]$s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append(@"
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>电源配置报告</title><style>
*{box-sizing:border-box}
body{font:14px/1.65 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif;
     margin:0;padding:32px 20px;background:#0e1014;color:#e8e8ea}
.wrap{max-width:1100px;margin:0 auto}
h1{font-size:21px;margin:0 0 6px;letter-spacing:.3px}
.sub{color:#8b93a7;font-size:12.5px;margin-bottom:26px}
.sub b{color:#c9d3e3;font-weight:600}
h2{font-size:15px;margin:30px 0 12px;color:#7cc4ff;font-weight:600;
   border-left:3px solid #7cc4ff;padding-left:10px}
table{border-collapse:collapse;width:100%;font-size:12.5px;background:#161a21;
      border-radius:10px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.4)}
th{background:#1d222b;padding:10px 12px;text-align:left;font-weight:600;
   color:#9fb0c9;font-size:11.5px;letter-spacing:.4px}
td{padding:8px 12px;border-top:1px solid #222833;vertical-align:top}
tr:hover td{background:#1b2029}
code{font-family:"Cascadia Mono",Consolas,monospace;font-size:11.5px;color:#a8d5ff}
.d{color:#6b7488;font-size:12px}
.cur{font-weight:700}
.match-ext{color:#5fd38d}.match-sta{color:#ffcc66}.match-eco{color:#7cc4ff}.none{color:#4d5563}
.badge{display:inline-block;padding:3px 10px;border-radius:12px;font-size:11.5px;
       background:#232a36;color:#9fb0c9;margin-right:6px}
.legend{color:#6b7488;font-size:12px;margin-top:10px}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px;vertical-align:middle}
.warn{background:#241d16;border-left:3px solid #ffcc66;padding:10px 14px;
      border-radius:6px;color:#e8d9b8;font-size:12.5px;margin:14px 0}
</style></head><body><div class="wrap">
<h1>PowerSettingsExplorer 性能配置报告</h1>
<div class="sub">生成时间 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') · 当前方案 <b>$(HtmlEnc $schemes[$scheme])</b> ($scheme) · 逻辑处理器 $([Environment]::ProcessorCount)</div>
"@)

$hw = Get-HardwareProfile
[void]$sb.Append('<h2>硬件与选档依据</h2><table>')
$hwRows = @(
    @('CPU', $hw.CPU),
    @('核心 / 线程', "$($hw.Cores) / $($hw.Logical)"),
    @('大小核异构', $(if ($hw.Hetero) { '是' } else { '否' })),
    @('NVMe', $(if ($hw.NVMe) { '是' } else { '否' })),
    @('笔记本(电池)', $(if ($hw.IsLaptop) { '是' } else { '否' })),
    @('虚拟机', $(if ($hw.IsVM) { '是' } else { '否' })),
    @('内存', "$($hw.RAMGB) GB"),
    @('系统', $hw.OS),
    @('自动推荐档', (Resolve-Profile $hw))
)
foreach ($kv in $hwRows) {
    [void]$sb.Append("<tr><td class='d' style='width:180px'>$(HtmlEnc $kv[0])</td><td>$(HtmlEnc $kv[1])</td></tr>")
}
[void]$sb.Append('</table>')

# ── 三档对照 ──
[void]$sb.Append('<h2>三档目标值对照（AC 交流档）</h2>')
[void]$sb.Append('<table><tr><th>设置项</th><th>说明</th><th>当前值</th><th>稳定本</th><th>极致版</th><th>节能版</th></tr>')
foreach ($r in $rows) {
    $cls = 'none'
    $curTxt = if ($null -ne $r.Current) { $r.Current } else { '—' }
    if ($null -ne $r.Current) {
        if ($r.Current -eq $r.Extreme)    { $cls = 'match-ext' }
        elseif ($r.Current -eq $r.Stable) { $cls = 'match-sta' }
        elseif ($r.Current -eq $r.Eco)    { $cls = 'match-eco' }
    }
    [void]$sb.Append('<tr>')
    [void]$sb.Append("<td><code>$(HtmlEnc $r.Name)</code></td>")
    [void]$sb.Append("<td class='d'>$(HtmlEnc $r.Desc)</td>")
    [void]$sb.Append("<td class='cur $cls'>$curTxt</td>")
    [void]$sb.Append("<td>$($r.Stable)</td><td>$($r.Extreme)</td><td>$($r.Eco)</td>")
    [void]$sb.Append('</tr>')
}
[void]$sb.Append('</table>')
[void]$sb.Append(@'
<div class="legend">
<span class="dot" style="background:#5fd38d"></span>当前值 = 极致版
<span class="dot" style="background:#ffcc66;margin-left:14px"></span>当前值 = 稳定本
<span class="dot" style="background:#7cc4ff;margin-left:14px"></span>当前值 = 节能版
<span class="dot" style="background:#4d5563;margin-left:14px"></span>本机不支持或不匹配
</div>
'@)

#region ── 基准数据 ──
if ($bench.Count -gt 0) {
    [void]$sb.Append('<h2>基准测试记录</h2>')
    [void]$sb.Append('<table><tr><th>时间</th><th>标签</th><th>方案</th><th>单核</th><th>多核</th><th>扩展比</th><th>频率MHz</th><th>抖动P50</th><th>抖动P99</th><th>抖动Max</th></tr>')
    foreach ($b in $bench) {
        [void]$sb.Append('<tr>')
        [void]$sb.Append("<td class='d'>$(HtmlEnc $b.Timestamp)</td>")
        [void]$sb.Append("<td>$(HtmlEnc $b.Label)</td>")
        [void]$sb.Append("<td>$(HtmlEnc $b.Scheme)</td>")
        [void]$sb.Append("<td>$($b.SingleScore)</td><td>$($b.MultiScore)</td><td>$($b.Scaling)</td>")
        [void]$sb.Append("<td>$($b.FreqAvgMHz)</td><td>$($b.JitterP50ms)</td><td>$($b.JitterP99ms)</td><td>$($b.JitterMaxms)</td>")
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')

    $best  = $bench | Sort-Object { [double]$_.MultiScore } -Descending | Select-Object -First 1
    $quiet = $bench | Sort-Object { [double]$_.JitterP99ms } | Select-Object -First 1
    [void]$sb.Append('<h2>结论</h2>')
    [void]$sb.Append("<p>多核吞吐最高：<span class='badge'>$(HtmlEnc $best.Label) / $(HtmlEnc $best.Scheme)</span> $($best.MultiScore) Mops/s</p>")
    [void]$sb.Append("<p>调度最稳定：<span class='badge'>$(HtmlEnc $quiet.Label) / $(HtmlEnc $quiet.Scheme)</span> P99 抖动 $($quiet.JitterP99ms) ms</p>")
} else {
    [void]$sb.Append('<h2>基准测试</h2>')
    [void]$sb.Append('<p class="d">暂无数据。执行 <code>.\Invoke-PowerBench.ps1 -Label "极致版"</code> 后重新生成报告。</p>')
}
#endregion

# ── 备份记录 ──
$bks = @(Get-ChildItem (Join-Path $work 'backup') -Directory -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending)
if ($bks.Count -gt 0) {
    [void]$sb.Append('<h2>备份记录（最近 12 条）</h2><table><tr><th>时间</th><th>目录</th></tr>')
    foreach ($b in ($bks | Select-Object -First 12)) {
        [void]$sb.Append("<tr><td class='d'>$($b.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))</td><td><code>$(HtmlEnc $b.Name)</code></td></tr>")
    }
    [void]$sb.Append('</table>')
}

[void]$sb.Append('<h2>风险提示</h2>')
[void]$sb.Append(@'
<div class="warn">
极致版会把最小处理器状态设为 100% 并禁止核心停放。在散热受限的轻薄本上这反而可能触发降频，
表现低于稳定本。回滚命令：<code>.\Rollback-PowerScheme.ps1</code>
或 <code>.\Apply-PowerProfile.ps1 -Restore</code>
</div>
'@)

[void]$sb.Append('</div></body></html>')

$out = Join-Path $work "reports\power-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
$sb.ToString() | Set-Content -Path $out -Encoding UTF8
Write-Host "报告已生成: $out" -ForegroundColor Green
if ($Open) { Start-Process $out }

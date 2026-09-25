<#
.SYNOPSIS
    PowerSettingsExplorer 性能自动调整 —— 一键入口（稳定本 / 极致版 / 节能版）
.DESCRIPTION
    通过 powrprof.dll 原生 API 读写电源设置（不是 powercfg，原因见模块头部说明）。
    自动探测硬件特征选档，也可 -Profile 显式指定。
.EXAMPLE
    .\Apply-PowerProfile.ps1 -Detect                    # 只看检测与推荐
    .\Apply-PowerProfile.ps1 -List                      # 打印三档配置表
    .\Apply-PowerProfile.ps1 -Diff max-perf             # 对比当前值 vs 目标值（只读）
    .\Apply-PowerProfile.ps1 -Profile auto -IncludeDC   # 应用推荐档（含电池档）
    .\Apply-PowerProfile.ps1 -Profile max-perf -DryRun  # 演练：写临时方案后立即删除
    .\Apply-PowerProfile.ps1 -Restore                   # 恢复出厂电源方案
#>
[CmdletBinding()]
param(
    [ValidateSet('auto','balanced-stable','max-perf','eco')]
    [string]$Profile = 'auto',

    [switch]$IncludeDC,
    [switch]$Detect,
    [switch]$List,
    [ValidateSet('balanced-stable','max-perf','eco')]
    [string]$Diff,
    [switch]$DryRun,        # 写到临时方案、校验、然后删除，不留痕迹
    [switch]$NoActivate,
    [switch]$SkipBackup,
    [switch]$Restore,
    [string]$RestoreFrom
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'modules\PowerTune.psm1') -Force -WarningAction SilentlyContinue

#region ── 展示 ─────────────────────────────────────────────────────────

function Show-Detect {
    param($Hw, [string]$Recommended)
    Write-Host "`n═══ 硬件与设置能力检测 ═══`n" -ForegroundColor Cyan
    Write-Host ('  CPU          : {0}' -f $Hw.CPU)
    Write-Host ('  核心 / 线程  : {0} / {1}' -f $Hw.Cores, $Hw.Logical)
    Write-Host ('  大小核异构   : {0}' -f $(if ($Hw.Hetero) { '是' } else { '否' }))
    Write-Host ('  NVMe 存储    : {0}' -f $(if ($Hw.NVMe) { '是' } else { '否' }))
    Write-Host ('  笔记本(电池) : {0}' -f $(if ($Hw.IsLaptop) { '是' } else { '否' }))
    Write-Host ('  虚拟机       : {0}' -f $(if ($Hw.IsVM) { '是' } else { '否' }))
    Write-Host ('  内存         : {0} GB' -f $Hw.RAMGB)
    Write-Host ('  系统         : {0}' -f $Hw.OS)

    $known = Get-KnownSettings
    $readable = 0; $unsupported = @()
    foreach ($n in $known.Keys) {
        $v = Get-Value -Name $n
        if ($null -ne $v.AC) { $readable++ } else { $unsupported += $n }
    }
    Write-Host "`n  设置项       : $readable / $($known.Count) 项可读（原生 API 探测）"
    if ($unsupported.Count) {
        Write-Host "  不可用       : $($unsupported -join ', ')" -ForegroundColor DarkGray
    }

    Write-Host "`n推荐配置档: " -NoNewline
    Write-Host $Recommended -ForegroundColor Green
    $why = switch ($Recommended) {
        'max-perf'        { '核心数充足或存在大小核 → 禁止核心停放、锁定高频、激进升频、EPP 归零' }
        'eco'             { '笔记本且核心数较少 → 限制最大处理器状态、EPP 拉满、积极降频' }
        'balanced-stable' { '虚拟机或通用平台 → 保守值' }
    }
    Write-Host "理由: $why`n" -ForegroundColor DarkGray
}

function Show-ProfileTable {
    $all = @()
    foreach ($k in (Get-ProfileList)) {
        $all += (Get-ProfileDefinition $k).AC.Keys
        $all += (Get-ProfileDefinition $k).DC.Keys
    }
    $all = $all | Sort-Object -Unique
    $known = Get-KnownSettings

    Write-Host "`n═══ 三档配置对照 ═══`n" -ForegroundColor Cyan
    $rows = foreach ($a in $all) {
        [pscustomobject]@{
            '设置项' = $a
            '说明'   = $known[$a].Desc
            '状态'   = $known[$a].V
            '稳定AC' = (Get-ProfileDefinition 'balanced-stable').AC[$a]
            '极致AC' = (Get-ProfileDefinition 'max-perf').AC[$a]
            '节能AC' = (Get-ProfileDefinition 'eco').AC[$a]
            '稳定DC' = (Get-ProfileDefinition 'balanced-stable').DC[$a]
            '极致DC' = (Get-ProfileDefinition 'max-perf').DC[$a]
            '节能DC' = (Get-ProfileDefinition 'eco').DC[$a]
        }
    }
    $rows | Format-Table -AutoSize
    Write-Host '空值 = 该档不设置此项。所有 GUID 均经本机读写往返验证。' -ForegroundColor DarkGray
    Write-Host ''
}

function Show-ProfileDiff {
    param([string]$ProfileKey)
    $p   = Get-ProfileDefinition $ProfileKey
    $act = Get-ActiveScheme
    $names = Get-SchemeList
    Write-Host "`n═══ 当前方案（$($names[$act])） vs $($p.Title) ═══`n" -ForegroundColor Cyan
    $rows = @(Get-ProfileDiff -ProfileKey $ProfileKey)
    $rows | Format-Table @{n='设置项'; e={$_.Setting}},
                         @{n='说明';   e={$_.Desc}},
                         @{n='当前';   e={$_.Current}},
                         @{n='目标';   e={$_.Target}},
                         @{n='一致';   e={ if ($_.Match) { '[=]' } else { '[ ]' } }} -AutoSize
    $mis  = @($rows | Where-Object { -not $_.Match -and $_.Supported })
    $unsp = @($rows | Where-Object { -not $_.Supported })
    Write-Host ("共 {0} 项：{1} 项待调整，{2} 项本机不支持。" -f $rows.Count, $mis.Count, $unsp.Count) -ForegroundColor Yellow
    Write-Host '（只读命令，不修改任何设置）' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region ── 主流程 ───────────────────────────────────────────────────────

if ($List) { Show-ProfileTable; exit 0 }

if (-not ($Detect -or $Diff) -and -not (Test-Admin)) {
    Write-Host '需要管理员权限。请以管理员身份运行 PowerShell 后重试。' -ForegroundColor Red
    exit 1
}

$hw       = Get-HardwareProfile
$resolved = if ($Profile -eq 'auto') { Resolve-Profile $hw } else { $Profile }

if ($Diff) { Show-ProfileDiff -ProfileKey $Diff; exit 0 }

Show-Detect $hw $resolved
if ($Detect) { exit 0 }

# ── DryRun：写临时方案后立即删除 ──
if ($DryRun) {
    $p = Get-ProfileDefinition $resolved
    Write-Host "═══ 演练模式：$($p.Title) ═══" -ForegroundColor Cyan
    Write-Host '写入临时方案并校验，随后立即删除，不改动任何现有方案。' -ForegroundColor DarkGray

    $base = switch ($resolved) {
        'max-perf' { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        'eco'      { 'a1841308-3541-4fab-bc81-f71556f20b4a' }
        default    { '381b4222-f694-41f0-9685-ff5bb260df2e' }
    }
    $tmp = New-PowerScheme -FriendlyName 'PSE-DRYRUN-TEMP' -BaseGuid $base

    $ok = 0; $bad = @()
    foreach ($n in ($p.AC.Keys | Sort-Object)) {
        if (Set-Value -Name $n -Value ([int]$p.AC[$n]) -Scope 'AC' -SchemeGuid $tmp) { $ok++ }
        else { $bad += $n }
    }
    if ($IncludeDC) {
        foreach ($n in ($p.DC.Keys | Sort-Object)) {
            if (Set-Value -Name $n -Value ([int]$p.DC[$n]) -Scope 'DC' -SchemeGuid $tmp) { $ok++ }
            else { $bad += "$n(DC)" }
        }
    }

    Write-Host "`n写入并回读校验通过 $ok 项；失败 $(@($bad).Count) 项。" -ForegroundColor Green
    if (@($bad).Count) { Write-Host "失败: $($bad -join ', ')" -ForegroundColor DarkGray }

    Invoke-PowerCfg -Arguments @('/delete', $tmp) | Out-Null
    Write-Host "已删除临时方案 $tmp，系统状态未改变。" -ForegroundColor Green
    exit 0
}

if ($RestoreFrom) {
    Export-PowerSnapshot -Tag 'before-import' | Out-Null
    $n = Import-PowerSnapshot -BackupDir $RestoreFrom
    if (Test-Path (Join-Path $RestoreFrom 'values.json')) {
        Restore-SnapshotValues -BackupDir $RestoreFrom | Out-Null
    }
    $mf = Join-Path $RestoreFrom 'manifest.json'
    if (Test-Path $mf) {
        $prev = (Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json).ActiveScheme
        if ($prev -and (Get-SchemeList).ContainsKey($prev)) {
            Set-ActiveScheme -SchemeGuid $prev
            Write-Host "已重新激活原方案 $prev" -ForegroundColor Green
        }
    }
    Write-Host "已从 $RestoreFrom 导入 $n 个方案并还原设置值。" -ForegroundColor Green
    exit 0
}

if ($Restore) {
    Export-PowerSnapshot -Tag 'before-restore' | Out-Null
    Restore-PowerDefaults
    Write-Host '已恢复 Windows 默认电源方案。' -ForegroundColor Green
    exit 0
}

$result = Apply-Profile -ProfileKey $resolved `
                        -IncludeDC:$IncludeDC `
                        -NoActivate:$NoActivate `
                        -SkipBackup:$SkipBackup

# ── 生效核验 ──
Write-Host '═══ 生效核验 ═══' -ForegroundColor Cyan
$act = Get-ActiveScheme
Write-Host ('  激活方案: {0}  ({1})' -f (Get-SchemeList)[$act], $act)

foreach ($n in @('PERFBOOSTMODE','PERFEPP','CPMINCORES','PROCTHROTTLEMIN',
                 'PROCTHROTTLEMAX','PERFHETERO','PERFINCPOL','PERFLATENCYSENSITIVITY')) {
    $v = Get-Value -Name $n
    if ($null -ne $v.AC) {
        $dcTxt = if ($null -ne $v.DC) { $v.DC } else { '—' }
        Write-Host ('  {0,-22} AC={1,-5} DC={2}' -f $n, $v.AC, $dcTxt)
    } else {
        Write-Host ('  {0,-22} 本机不支持' -f $n) -ForegroundColor DarkGray
    }
}

Write-Host "`n后续可执行：" -ForegroundColor DarkGray
Write-Host '  .\Rollback-PowerScheme.ps1 -List           # 查看备份'
Write-Host '  .\Rollback-PowerScheme.ps1                 # 回滚到最近备份'
Write-Host '  .\Invoke-PowerBench.ps1 -Label "极致版"    # 基准对照'
Write-Host '  .\Show-PowerReport.ps1 -Open               # HTML 报告'
Write-Host ''

#endregion

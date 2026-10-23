<#
.SYNOPSIS
    回滚电源方案：从备份导入，或恢复 Windows 默认值
.EXAMPLE
    .\Rollback-PowerScheme.ps1 -List          # 列出全部备份
    .\Rollback-PowerScheme.ps1                # 回滚到最近一次备份
    .\Rollback-PowerScheme.ps1 -Index 3       # 回滚到倒数第 3 个备份
    .\Rollback-PowerScheme.ps1 -Defaults      # 直接恢复出厂电源方案
#>
[CmdletBinding()]
param(
    [switch]$List,
    [int]$Index = 1,
    [string]$BackupDir,
    [switch]$Defaults,
    [switch]$RemoveClones      # 删除 PSE-Stable/PSE-Extreme/PSE-Eco 等克隆方案
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'modules\PowerTune.psm1') -Force

Assert-Admin
$bkRoot  = Join-Path (Get-WorkRoot) 'backup'
$backups = @(Get-ChildItem $bkRoot -Directory -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending)

if ($List) {
    Write-Host "`n备份列表（$bkRoot）：`n" -ForegroundColor Cyan
    if ($backups.Count -eq 0) { Write-Host '  （暂无备份）' -ForegroundColor DarkGray; exit 0 }
    $i = 0
    foreach ($b in $backups) {
        $i++
        $mf = Join-Path $b.FullName 'manifest.json'
        $cnt = if (Test-Path $mf) { (Get-Content $mf -Raw | ConvertFrom-Json).SchemeCount } else { '?' }
        Write-Host ('  [{0,2}] {1,-40} {2}  方案数={3}' -f
            $i, $b.Name, $b.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $cnt)
    }
    Write-Host "`n用法: .\Rollback-PowerScheme.ps1 -Index <序号>`n" -ForegroundColor DarkGray
    exit 0
}

if ($Defaults) {
    Export-PowerSnapshot -Tag 'before-defaults' | Out-Null
    Restore-PowerDefaults
    Write-Host '已恢复 Windows 默认电源方案。' -ForegroundColor Green
    exit 0
}

if ($RemoveClones) {
    # 只删本工具克隆出来的方案，且不删当前激活的
    $active = Get-ActiveScheme
    $targets = @((Get-SchemeList).GetEnumerator() |
                 Where-Object { $_.Value -match '^PSE-(Stable|Extreme|Eco|DRYRUN)' -and $_.Key -ne $active })
    if ($targets.Count -eq 0) { Write-Host '没有可删除的克隆方案。' -ForegroundColor DarkGray; exit 0 }
    foreach ($t in $targets) {
        $r = Invoke-PowerCfg -Arguments @('/delete', $t.Key)
        if ($r.Ok) { Write-Host "已删除 $($t.Value) ($($t.Key))" -ForegroundColor Green }
        else       { Write-Host "删除失败 $($t.Value): $($r.Output)" -ForegroundColor Yellow }
    }
    exit 0
}

if ($BackupDir) {
    $target = $BackupDir
} else {
    if ($backups.Count -eq 0) {
        Write-Host '暂无备份可回滚。使用 -Defaults 可恢复出厂方案。' -ForegroundColor Yellow
        exit 1
    }
    if ($Index -lt 1 -or $Index -gt $backups.Count) {
        throw "Index 超出范围（有效值 1..$($backups.Count)）"
    }
    $target = $backups[$Index - 1].FullName
}

Write-Host "回滚来源: $target" -ForegroundColor Cyan
$n = Import-PowerSnapshot -BackupDir $target

# .pow 导入装不下隐藏项（powercfg 在本机只暴露 95 项处理器设置里的 2 项），
# 必须再用原生 API 按 values.json 逐项还原——这才是唯一可靠的还原依据。
$v = Restore-SnapshotValues -BackupDir $target
$a = Restore-SnapshotAttributes -BackupDir $target

$mf = Join-Path $target 'manifest.json'
if (Test-Path $mf) {
    $prev = (Get-Content $mf -Raw | ConvertFrom-Json).ActiveScheme
    if ($prev -and (Get-SchemeList).ContainsKey($prev)) {
        Invoke-PowerCfg -Quiet -Arguments @('/setactive', $prev) | Out-Null
        Write-TuneLog "已重新激活原方案 $prev" 'OK'
    } else {
        Write-Host '原激活方案已不存在（可能被恢复出厂清除），保持当前方案。' -ForegroundColor DarkGray
    }
}

Write-Host "`n回滚完成：导入 $n 个方案，还原 $v 项设置值，还原 $a 项隐藏属性。" -ForegroundColor Green
(& powercfg.exe /getactivescheme) | ForEach-Object { Write-Host "  $_" }

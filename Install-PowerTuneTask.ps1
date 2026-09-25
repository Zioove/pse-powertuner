<#
.SYNOPSIS
    注册自动调整计划任务：登录应用 / 插拔电源自适应 / 定时核验
.EXAMPLE
    .\Install-PowerTuneTask.ps1 -Mode OnLogon      # 登录时应用推荐档
    .\Install-PowerTuneTask.ps1 -Mode Adaptive     # 插电=极致版, 电池=节能版
    .\Install-PowerTuneTask.ps1 -Mode Hourly       # 每小时核验一次
    .\Install-PowerTuneTask.ps1 -Remove            # 卸载全部任务
#>
[CmdletBinding()]
param(
    [ValidateSet('OnLogon','Adaptive','Hourly')][string]$Mode = 'OnLogon',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'modules\PowerTune.psm1') -Force
Assert-Admin

$taskName = 'PSE-PowerTuner'
$apply    = Join-Path $root 'Apply-PowerProfile.ps1'

if ($Remove) {
    foreach ($n in @($taskName, "$taskName-Adaptive")) {
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false
            Write-Host "已移除任务 $n" -ForegroundColor Green
        }
    }
    exit 0
}

$psExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $psExe) { $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10))

$applyAction = New-ScheduledTaskAction -Execute $psExe `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$apply`" -Profile auto -SkipBackup" `
    -WorkingDirectory $root

switch ($Mode) {

    'OnLogon' {
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName $taskName -Action $applyAction -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host '已注册：登录时应用推荐配置档' -ForegroundColor Green
    }

    'Hourly' {
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) `
            -RepetitionInterval ([TimeSpan]::FromHours(1)) `
            -RepetitionDuration ([TimeSpan]::FromDays(3650))
        Register-ScheduledTask -TaskName $taskName -Action $applyAction -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host '已注册：每小时核验并重新应用配置档' -ForegroundColor Green
    }

    'Adaptive' {
        # 插电 → 极致版；电池 → 节能版。用 WMI 电池状态判断，避免依赖 ACPI 事件。
        $adaptPath = Join-Path $root 'Adaptive-Switch.ps1'
        $adaptBody = @"
# 自动生成：插电/电池场景切换（由 Install-PowerTuneTask.ps1 写入）
`$ErrorActionPreference = 'Stop'
`$here = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
`$onBattery = `$false
if (`$bat) { `$onBattery = (`$bat.BatteryStatus -eq 1) }
`$target = if (`$onBattery) { 'eco' } else { 'max-perf' }
& (Join-Path `$here 'Apply-PowerProfile.ps1') -Profile `$target -SkipBackup -IncludeDC
"@
        $adaptBody | Set-Content -Path $adaptPath -Encoding UTF8

        $adaptAction = New-ScheduledTaskAction -Execute $psExe `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$adaptPath`"" `
            -WorkingDirectory $root

        # 每小时轮询 + 登录时各跑一次
        $hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) `
            -RepetitionInterval ([TimeSpan]::FromMinutes(15)) `
            -RepetitionDuration ([TimeSpan]::FromDays(3650))
        $logon  = New-ScheduledTaskTrigger -AtLogOn

        Register-ScheduledTask -TaskName "$taskName-Adaptive" -Action $adaptAction `
            -Trigger @($hourly, $logon) -Principal $principal -Settings $settings -Force | Out-Null
        Register-ScheduledTask -TaskName $taskName -Action $applyAction -Trigger $logon `
            -Principal $principal -Settings $settings -Force | Out-Null

        Write-Host '已注册自适应切换：' -ForegroundColor Green
        Write-Host "  $taskName            → 登录时应用推荐档"
        Write-Host "  $taskName-Adaptive   → 每 15 分钟检测：插电=极致版，电池=节能版"
        Write-Host "  切换脚本: $adaptPath" -ForegroundColor DarkGray
    }
}

Get-ScheduledTask -TaskName "$taskName*" -ErrorAction SilentlyContinue |
    Format-Table TaskName, State -AutoSize

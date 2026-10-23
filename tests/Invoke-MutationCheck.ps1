<#
.SYNOPSIS
    Mutation check for tests\Invoke-Tests.ps1 - proves the suite can actually fail.

.DESCRIPTION
    A test that always passes is worthless. This script copies the repo to a
    temp directory, injects one deliberate defect at a time into the copy,
    runs tests\Invoke-Tests.ps1 against the copy, and asserts that the expected
    test ID turns red.

    The real repo is never modified: every mutation happens inside a throwaway
    copy under $env:TEMP that is deleted afterwards.

.PARAMETER KeepWork
    Leave the last mutated copy on disk for inspection.

.EXAMPLE
    pwsh -NoProfile -File tests\Invoke-MutationCheck.ps1

.NOTES
    Exit code 0 = every mutation was caught. Exit code 1 = at least one survived.
#>
[CmdletBinding()]
param([switch]$KeepWork)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path $env:TEMP ('pse-mut-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

function New-Copy {
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    Copy-Item $repo $work -Recurse -Force
    # Strip Mark-of-the-Web so RemoteSigned does not block the copied module.
    Get-ChildItem $work -Recurse -File | ForEach-Object {
        try { Remove-Item -LiteralPath "$($_.FullName):Zone.Identifier" -ErrorAction SilentlyContinue } catch { }
    }
}

function Invoke-Suite {
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $work 'tests\Invoke-Tests.ps1') -NoRuntime 2>&1
    $failed = @($out | Select-String -Pattern '^\s+FAIL\s+\[(S\d+|R\d+)\]' | ForEach-Object {
            [regex]::Match($_.Line, '\[(S\d+|R\d+)\]').Groups[1].Value
        })
    [pscustomobject]@{ Exit = $LASTEXITCODE; Failed = $failed }
}

# Each entry: the file to corrupt, a literal to find, its replacement, and the
# test ID that MUST fail as a result.
$mutations = @(
    @{ Name = 'S01 syntax error';                         File = 'Invoke-PowerBench.ps1';    Find = 'Write-Host "[2/4] 全核吞吐（$logical 线程）..." -ForegroundColor Yellow'; Replace = 'Write-Host "unclosed'; Expect = 'S01' }
    @{ Name = 'S02 undefined function';                   File = 'Show-PowerReport.ps1';     Find = '$cur = Get-PowerSettingValue -Name $a'; Replace = '$cur = Get-PowerSettingValueXYZ -Name $a'; Expect = 'S02' }
    @{ Name = 'S02 function defined in another file only'; File = 'Rollback-PowerScheme.ps1'; Find = 'Assert-Admin'; Replace = 'Assert-AdminEarly'; Expect = 'S02' }
    @{ Name = 'S03 invented parameter';                   File = 'Rollback-PowerScheme.ps1'; Find = 'Import-PowerSnapshot -BackupDir $target'; Replace = 'Import-PowerSnapshot -BackupDir $target -Verbose2'; Expect = 'S03' }
    @{ Name = 'S03 ambiguous parameter prefix';           File = 'Invoke-PowerBench.ps1';    Find = '$scheme     = Get-ActiveScheme'; Replace = '$scheme     = Get-ActiveScheme -XX 1'; Expect = 'S03' }
    @{ Name = 'S05 export removed';                       File = 'modules\PowerTune.psm1';   Find = 'function Restore-PowerDefaults {'; Replace = 'function Restore-PowerDefaultsGone {'; Expect = 'S05' }
    @{ Name = 'S07 status disagrees with whitelist';      File = 'modules\PowerTune.psm1';   Find = "Desc='升频时间（本机只读）'; V='只读'"; Replace = "Desc='升频时间（本机只读）'; V='验证'"; Expect = 'S07' }
    @{ Name = 'S07 whitelist entry removed';              File = 'modules\PowerTune.psm1';   Find = "'IDLEDISABLE','SYSCOOLING','ALLOWTHROTTLE','DUTYCYCLING','PERFRESOURCEPRIORITY'"; Replace = "'SYSCOOLING','ALLOWTHROTTLE','DUTYCYCLING','PERFRESOURCEPRIORITY'"; Expect = 'S07' }
    @{ Name = 'S08 malformed GUID';                       File = 'modules\PowerTune.psm1';   Find = "PERFEPP1        = @{ Guid='36687f9e-e3a5-4dbf-b1dc-15eb381c6864'"; Replace = "PERFEPP1        = @{ Guid='36687f9e-e3a5-4dbf-b1dc-15eb381c68ZZ'"; Expect = 'S08' }
    @{ Name = 'S09 duplicated GUID';                      File = 'modules\PowerTune.psm1';   Find = "CPMAXCORES      = @{ Guid='ea062031-0e34-4ff1-9b6d-eb1059334028'"; Replace = "CPMAXCORES      = @{ Guid='0cc5b647-c1df-4637-891a-dec35c318583'"; Expect = 'S09' }
    @{ Name = 'S10 unknown profile key';                  File = 'modules\PowerTune.psm1';   Find = "SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='0'; MAXFREQ='0'"; Replace = "SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='0'; MAXFREQ='0'; BOGUSKEY='1'"; Expect = 'S10' }
    @{ Name = 'S11 profile writes read-only setting';     File = 'modules\PowerTune.psm1';   Find = "PERFLATENCYSENSITIVITY='50'`n            SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='0'"; Replace = "PERFLATENCYSENSITIVITY='50'; PERFTIME='30'`n            SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='0'"; Expect = 'S11' }
    @{ Name = 'S12 undocumented DC-only key';             File = 'modules\PowerTune.psm1';   Find = "SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='1'; MAXFREQ='0'"; Replace = "SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='1'; MAXFREQ='0'; PERFTIME='30'"; Expect = 'S12' }
    @{ Name = 'S13 out-of-range profile value';           File = 'modules\PowerTune.psm1';   Find = "PERFEPP='50'; PERFEPP1='50'"; Replace = "PERFEPP='150'; PERFEPP1='50'"; Expect = 'S13' }
    @{ Name = 'S14 ValidateSet drift';                    File = 'modules\PowerTune.psm1';   Find = "param([Parameter(Mandatory)][ValidateSet('balanced-stable','max-perf','eco')][string]`$ProfileKey)`n    `$Script:Profiles[`$ProfileKey]"; Replace = "param([Parameter(Mandatory)][ValidateSet('balanced-stable','max-perf')][string]`$ProfileKey)`n    `$Script:Profiles[`$ProfileKey]"; Expect = 'S14' }
    @{ Name = 'S15 _ref probe GUID drift';                File = '_ref\Test-PwrApi.ps1';     Find = "CPMINCORES           = '0cc5b647-c1df-4637-891a-dec35c318583'"; Replace = "CPMINCORES           = '0cc5b647-c1df-4637-891a-dec35c318584'"; Expect = 'S15' }
    @{ Name = 'S18 range table lies';                     File = 'tests\Test-Ranges.psd1';   Find = 'CPMINCORES          = @{ Min = 0; Max = 100;'; Replace = 'CPMINCORES          = @{ Min = 0; Max = 90;'; Expect = 'S18' }
    @{ Name = 'S19 README count drift';                   File = 'README.md';                Find = '**26 项可读可写**'; Replace = '**28 项可读可写**'; Expect = 'S19' }
    @{ Name = 'S20 README table drift';                   File = 'README.md';                Find = '| `CPMINCORES` 最小停放核心% | 25 |'; Replace = '| `CPMINCORES` 最小停放核心% | 30 |'; Expect = 'S20' }
    @{ Name = 'S21 unapproved verb';                      File = 'modules\PowerTune.psm1';   Find = 'function Get-ProfileList {'; Replace = 'function Apply-ProfileList {'; Expect = 'S21' }
    @{ Name = 'S23 hardcoded path';                       File = 'Apply-PowerProfile.ps1';   Find = '$root = Split-Path -Parent $MyInvocation.MyCommand.Path'; Replace = '$root = ''C:\Users\somebody\PSE-PowerTuner'''; Expect = 'S23' }
    @{ Name = 'S24 scriptblock as thread delegate';       File = 'Invoke-PowerBench.ps1';    Find = '$t = [Threading.Thread]::new([Threading.ThreadStart]{'; Replace = '$t = [Threading.Thread]::new([Threading.ParameterizedThreadStart]{'; Expect = 'S24' }
)

$results = @()
try {
    foreach ($m in $mutations) {
        New-Copy
        $path = Join-Path $work $m.File
        $text = Get-Content $path -Raw -Encoding UTF8
        if (-not $text.Contains($m.Find)) {
            $results += [pscustomobject]@{
                Mutation = $m.Name; Expected = $m.Expect
                Result   = 'PATTERN-NOT-FOUND (mutation list is stale)'; Ok = $false
            }
            continue
        }
        [System.IO.File]::WriteAllText($path, $text.Replace($m.Find, $m.Replace),
            (New-Object Text.UTF8Encoding($false)))

        $r = Invoke-Suite
        $hit = $r.Failed -contains $m.Expect
        $results += [pscustomobject]@{
            Mutation = $m.Name
            Expected = $m.Expect
            Result   = if ($hit) { 'caught' } else { 'SURVIVED (failed: ' + ($r.Failed -join ',') + ')' }
            Ok       = $hit
        }
    }
} finally {
    if (-not $KeepWork -and (Test-Path $work)) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}

$results | Format-Table -AutoSize
$caught = @($results | Where-Object Ok).Count
Write-Host ''
Write-Host ('CAUGHT {0}/{1} mutation(s)' -f $caught, $results.Count)
if ($caught -ne $results.Count) { exit 1 } else { exit 0 }

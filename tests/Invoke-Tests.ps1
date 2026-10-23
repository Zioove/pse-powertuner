<#
.SYNOPSIS
    Self-contained test runner for PSE-PowerTuner. No Pester, no network, no
    third-party modules.

.DESCRIPTION
    Runs two groups of tests:

      STATIC   - parse / AST / data-integrity / documentation checks.
                 Never needs admin, never mutates a power setting.
      RUNTIME  - touches the real powrprof API. Gated on elevation: when not
                 elevated these SKIP loudly instead of failing. They never
                 modify the active power scheme: the write path is exercised
                 against a throwaway scheme created with powercfg
                 /duplicatescheme and deleted in a finally block.

.PARAMETER ForceRuntime
    Run the RUNTIME group even when not elevated. Only for CI / a machine where
    writing to a throwaway duplicated scheme is known to be permitted. The
    active scheme is still never touched.

.PARAMETER NoRuntime
    Skip the RUNTIME group entirely.

.EXAMPLE
    pwsh -NoProfile -File tests\Invoke-Tests.ps1

.EXAMPLE
    pwsh -NoProfile -File tests\Invoke-Tests.ps1 -NoRuntime

.NOTES
    Exit code 0 = no FAIL. Exit code 1 = at least one FAIL.
#>
[CmdletBinding()]
param(
    [switch]$ForceRuntime,
    [switch]$NoRuntime
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off          # the runner itself stays lenient; the StrictMode
                             # *test* opts in locally and in a child process.

# ══════════════════════════════════════════════════════════════════════════
#region 0. Bootstrap
# ══════════════════════════════════════════════════════════════════════════

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:TestsDir = $PSScriptRoot
$script:Results  = [System.Collections.Generic.List[object]]::new()
$script:Clock    = [Diagnostics.Stopwatch]::StartNew()
$script:Notes    = [System.Collections.Generic.List[string]]::new()

$script:Module      = $null
$script:ModuleOk    = $false
$script:ModuleError = $null

$script:IsAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# ── console helpers ────────────────────────────────────────────────────────
$script:UseColor = -not $env:NO_COLOR
function Write-Head([string]$Text) {
    if ($script:UseColor) { Write-Host $Text -ForegroundColor Cyan } else { Write-Host $Text }
}
function Write-Sub([string]$Text) {
    if ($script:UseColor) { Write-Host $Text -ForegroundColor DarkGray } else { Write-Host $Text }
}

# ── result plumbing ────────────────────────────────────────────────────────
function Add-Result {
    param(
        [string]$Id,
        [string]$Category,
        [string]$Name,
        [ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status,
        [string[]]$Findings = @(),
        [string[]]$Notes = @()
    )
    $script:Results.Add([pscustomobject]@{
            Id       = $Id
            Category = $Category
            Name     = $Name
            Status   = $Status
            Findings = @($Findings)
            Notes    = @($Notes)
        })
}

<#
    Body contract:
      return $null                      -> PASS
      return string[]                   -> every element is a FAIL finding
      return @{ Findings=@(); Notes=@() } -> explicit
      throw                             -> FAIL (test bug or hard error)
#>
function Invoke-Case {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body,
        [switch]$Skip,
        [string]$SkipReason
    )

    if ($Skip) {
        Add-Result -Id $Id -Category $Category -Name $Name -Status 'SKIP' -Notes @($SkipReason)
        Write-Sub ("  SKIP  [{0}] {1}  ({2})" -f $Id, $Name, $SkipReason)
        return
    }

    $findings = @()
    $notes    = @()
    try {
        $r = & $Body
        if ($null -ne $r) {
            if ($r -is [hashtable]) {
                if ($r.ContainsKey('Findings')) { $findings = @($r.Findings) }
                if ($r.ContainsKey('Notes'))    { $notes    = @($r.Notes) }
            } else {
                $findings = @($r)
            }
        }
    } catch {
        $findings = @(('测试自身抛出异常 / test threw: {0} (line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber))
    }
    $findings = @($findings | Where-Object { $_ -and "$_".Trim() })
    $notes    = @($notes    | Where-Object { $_ -and "$_".Trim() })

    $status = if ($findings.Count -gt 0) { 'FAIL' } else { 'PASS' }
    Add-Result -Id $Id -Category $Category -Name $Name -Status $status -Findings $findings -Notes $notes

    if ($status -eq 'FAIL') {
        if ($script:UseColor) { Write-Host ("  FAIL  [{0}] {1}" -f $Id, $Name) -ForegroundColor Red }
        else { Write-Host ("  FAIL  [{0}] {1}" -f $Id, $Name) }
        foreach ($f in $findings) { Write-Host ("          - {0}" -f $f) -ForegroundColor DarkYellow }
    } else {
        if ($script:UseColor) { Write-Host ("  PASS  [{0}] {1}" -f $Id, $Name) -ForegroundColor Green }
        else { Write-Host ("  PASS  [{0}] {1}" -f $Id, $Name) }
    }
    foreach ($n in $notes) { Write-Sub ("          · {0}" -f $n) }
}

function Join-PathSafe {
    param([string]$Base, [string]$Child)
    if ($Base) { return (Join-Path $Base $Child) }
    return $Child
}

function Fmt-Finding {
    param([string]$File, [int]$Line, [string]$Message)
    $leaf = if ($File) { Split-Path -Leaf $File } else { '?' }
    if ($Line -gt 0) { return ('{0}:{1} — {2}' -f $leaf, $Line, $Message) }
    return ('{0} — {1}' -f $leaf, $Message)
}

# ══════════════════════════════════════════════════════════════════════════
#endregion
#region 1. Load the module + reference data
# ══════════════════════════════════════════════════════════════════════════

Write-Head "`n═══ PSE-PowerTuner test suite ═══"
Write-Sub ("  repo    : {0}" -f $script:RepoRoot)
Write-Sub ("  pwsh    : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Write-Sub ("  admin   : {0}" -f $script:IsAdmin)
Write-Host ''

$psm1 = Join-Path $script:RepoRoot 'modules\PowerTune.psm1'

# The repo ships unsigned scripts carrying a Mark-of-the-Web Zone.Identifier
# (they were extracted from a download), and LocalMachine policy here is
# RemoteSigned - so Import-Module is refused by default. Process-scope bypass
# is per-process only, so this is not a persistent system change.
$effectivePolicy = try { Get-ExecutionPolicy } catch { 'Unknown' }
if ($effectivePolicy -notin @('Bypass', 'Unrestricted')) {
    try {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
        $script:Notes.Add("execution policy was '$effectivePolicy'; set Process scope to Bypass for this run only")
    } catch {
        $script:Notes.Add("could not relax execution policy ('$effectivePolicy'): $($_.Exception.Message)")
    }
}

try {
    Import-Module $psm1 -Force -WarningAction SilentlyContinue -ErrorAction Stop
    $script:Module   = Get-Module PowerTune
    $script:ModuleOk = $null -ne $script:Module
} catch {
    $script:ModuleError = $_.Exception.Message
}
if (-not $script:ModuleOk) {
    Write-Sub ("  module import FAILED: {0}" -f $script:ModuleError)
}

# Live module state (read through the module's own scope so the tests see the
# same objects the shipped code sees).
$ModuleState = @{}
if ($script:ModuleOk) {
    $ModuleState = & $script:Module {
        @{
            Settings  = $Script:Settings
            Writable  = $Script:Writable
            Profiles  = $Script:Profiles
            SubGroup  = $Script:SubGroup
            Scheme    = $Script:Scheme
        }
    }
}

$script:Settings = $ModuleState['Settings']
$script:Writable = $ModuleState['Writable']
$script:Profiles = $ModuleState['Profiles']
$script:SubGroup = $ModuleState['SubGroup']
$script:Scheme   = $ModuleState['Scheme']

$rangeFile = Join-Path $script:TestsDir 'Test-Ranges.psd1'
$script:Ranges = $null
if (Test-Path $rangeFile) {
    try { $script:Ranges = Import-PowerShellDataFile -Path $rangeFile } catch { }
}

# Reference data files.
$refWritableCsv = Join-Path $script:RepoRoot '_ref\writable-test.csv'
$refProcessorCsv = Join-Path $script:RepoRoot '_ref\processor-settings.csv'
$refApiPs1 = Join-Path $script:RepoRoot '_ref\Test-PwrApi.ps1'

$script:RefWritable = if (Test-Path $refWritableCsv) { @(Import-Csv $refWritableCsv) } else { @() }
$script:RefProcessor = if (Test-Path $refProcessorCsv) { @(Import-Csv $refProcessorCsv) } else { @() }
$script:ReadmeText = if (Test-Path (Join-Path $script:RepoRoot 'README.md')) {
    Get-Content (Join-Path $script:RepoRoot 'README.md') -Raw -Encoding UTF8
} else { '' }

# Repo scripts under test (tests\ itself is excluded from logic analysis).
$script:RepoFiles = @(
    Get-ChildItem $script:RepoRoot -Recurse -File -Include *.ps1, *.psm1 |
        Where-Object { $_.FullName -notlike "$($script:TestsDir)*" }
)
$script:TestFiles = @(
    Get-ChildItem $script:TestsDir -Recurse -File -Include *.ps1, *.psm1
)

Write-Sub ("  scanned : {0} repo script(s), {1} test script(s)" -f $script:RepoFiles.Count, $script:TestFiles.Count)
Write-Host ''

# ══════════════════════════════════════════════════════════════════════════
#endregion
#region 2. AST infrastructure
# ══════════════════════════════════════════════════════════════════════════

$script:AstCache = @{}

function Get-ParsedFile {
    param([Parameter(Mandatory)][string]$Path)
    if ($script:AstCache.ContainsKey($Path)) { return $script:AstCache[$Path] }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $entry = [pscustomobject]@{
        Path   = $Path
        Ast    = $ast
        Errors = @($errors)
        Tokens = $tokens
    }
    $script:AstCache[$Path] = $entry
    $entry
}

function Get-FunctionTable {
    <#  name -> @{ Params=@(); Advanced=bool; File=...; Line=int }  #>
    param([Parameter(Mandatory)][string]$Path)
    $parsed = Get-ParsedFile -Path $Path
    $table = @{}
    $fds = $parsed.Ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($f in $fds) {
        $params = [System.Collections.Generic.List[string]]::new()
        $advanced = $false
        $pb = $f.Body.ParamBlock
        if ($pb) {
            foreach ($attr in $pb.Attributes) {
                if ($attr.TypeName.Name -eq 'CmdletBinding') { $advanced = $true }
            }
            foreach ($p in $pb.Parameters) {
                foreach ($attr in $p.Attributes) {
                    if ($attr.TypeName.Name -eq 'Parameter') { $advanced = $true }
                }
                $params.Add($p.Name.VariablePath.UserPath)
            }
        }
        # A function is also "advanced" if its body has a [CmdletBinding()] attribute.
        foreach ($a in $f.Body.Attributes) {
            if ($a.TypeName.Name -eq 'CmdletBinding') { $advanced = $true }
        }
        $table[$f.Name] = [pscustomobject]@{
            Name     = $f.Name
            Params   = @($params)
            Advanced = $advanced
            File     = $Path
            Line     = $f.Extent.StartLineNumber
        }
    }
    $table
}

function Get-CommandName {
    <#
        Extract the literal command name from a CommandAst, or $null if dynamic.
        A bare word (Split-Path), a quoted string ('powercfg.exe') and a
        variable ("$exe") are ALL StringConstantExpressionAst in the PowerShell
        AST; only the StringConstantType differs. BareWord/Quoted are static,
        Expandable/HereString may interpolate and are treated as dynamic.
    #>
    param([Parameter(Mandatory)]$CommandAst)
    $el = $CommandAst.CommandElements[0]
    if ($null -eq $el) { return $null }
    if ($el -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
    if ($el.StringConstantType -in @('BareWord', 'SingleQuoted', 'DoubleQuoted')) { return $el.Value }
    return $null
}

function Get-HashtablePairs {
    <#
        HashtableAst.KeyValuePairs is a list of Tuple<ExpressionAst, StatementAst>.
        The value side is a StatementAst, so the literal lives at
        Item2.PipelineElements[0].Expression. Returns @{ Key = <string value> }.
    #>
    param([Parameter(Mandatory)]$HashtableAst)
    $out = @{}
    foreach ($kv in $HashtableAst.KeyValuePairs) {
        $keyExpr = $kv.Item1
        if ($keyExpr -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $stmt = $kv.Item2
        if ($null -eq $stmt -or $stmt.PipelineElements.Count -eq 0) { continue }
        $valExpr = $stmt.PipelineElements[0].Expression
        if ($valExpr -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $out[$keyExpr.Value] = $valExpr.Value
        } elseif ($valExpr -is [System.Management.Automation.Language.ConstantExpressionAst]) {
            $out[$keyExpr.Value] = [string]$valExpr.Value
        }
    }
    $out
}

$script:CmdletCache = @{}
function Resolve-ExternalCommand {
    param([string]$Name)
    if ($script:CmdletCache.ContainsKey($Name)) { return $script:CmdletCache[$Name] }
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    $script:CmdletCache[$Name] = $c
    return $c
}

# Windows cmdlets that only exist when an optional Windows feature/module is
# present. Missing them is an environment fact, not a repo defect.
$script:OptionalCmdlets = @(
    'Get-ScheduledTask', 'Register-ScheduledTask', 'Unregister-ScheduledTask',
    'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskSettingsSet',
    'New-ScheduledTaskPrincipal', 'Get-PhysicalDisk', 'Get-CimInstance',
    'Get-WmiObject', 'Get-Battery'
)

$script:CommonParams = @(
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
    'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable',
    'OutVariable', 'OutBuffer', 'PipelineVariable'
)

function Test-ParamMatch {
    <#  Returns @{ Ok; Reason } for a given parameter name against a declared set. #>
    param(
        [Parameter(Mandatory)][string]$Given,
        [string[]]$Declared,
        [switch]$AllowCommon
    )
    if ($AllowCommon -and ($script:CommonParams -contains $Given)) {
        return @{ Ok = $true; Reason = 'common' }
    }
    if ($Declared -contains $Given) { return @{ Ok = $true; Reason = 'exact' } }
    $prefix = @($Declared | Where-Object { $_ -like "$Given*" })
    if ($prefix.Count -eq 1) { return @{ Ok = $true; Reason = 'prefix' } }
    if ($prefix.Count -gt 1) {
        return @{ Ok = $false; Reason = ('ambiguous prefix, candidates: {0}' -f ($prefix -join ', ')) }
    }
    return @{ Ok = $false; Reason = 'not declared' }
}

# ══════════════════════════════════════════════════════════════════════════
#endregion
#region 3. STATIC TESTS
# ══════════════════════════════════════════════════════════════════════════

Write-Head '── STATIC (no admin, no system mutation) ─────────────────────────────'

# ── S01 parse ─────────────────────────────────────────────────────────────
Invoke-Case -Id 'S01' -Category 'static' -Name 'Every .ps1/.psm1 parses with zero syntax errors' -Body {
    $out = @()
    foreach ($f in @($script:RepoFiles + $script:TestFiles)) {
        $p = Get-ParsedFile -Path $f.FullName
        foreach ($e in $p.Errors) {
            $out += Fmt-Finding $f.FullName $e.Extent.StartLineNumber ("语法错误 / parse error: {0}" -f $e.Message)
        }
    }
    return @{ Findings = $out; Notes = @(('{0} file(s) parsed' -f (@($script:RepoFiles + $script:TestFiles).Count))) }
}

# ── S02 undefined command ─────────────────────────────────────────────────
Invoke-Case -Id 'S02' -Category 'static' -Name 'No call to an undefined function (AST CommandAst)' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $notes = @()

    # Every function defined anywhere in the repo, by file.
    $perFileFuncs = @{}
    $repoFuncs = @{}
    foreach ($f in $script:RepoFiles) {
        $t = Get-FunctionTable -Path $f.FullName
        $perFileFuncs[$f.FullName] = $t
        foreach ($k in $t.Keys) { $repoFuncs[$k] = $t[$k] }
    }
    $moduleFuncs = @{}
    if ($script:ModuleOk) {
        foreach ($c in (Get-Command -Module $script:Module -ErrorAction SilentlyContinue)) {
            if ($c.CommandType -eq 'Function') { $moduleFuncs[$c.Name] = $true }
        }
    }

    $checked = 0
    foreach ($f in $script:RepoFiles) {
        $parsed = Get-ParsedFile -Path $f.FullName
        $text = Get-Content $f.FullName -Raw -Encoding UTF8
        $local = $perFileFuncs[$f.FullName]

        # A .ps1 only sees module functions if it actually imports the module.
        $importsModule = $text -match 'Import-Module[^\r\n]*PowerTune\.psm1'
        $inScope = @{}
        foreach ($k in $local.Keys) { $inScope[$k] = 'local' }
        if ($importsModule -or $f.Extension -eq '.psm1') {
            foreach ($k in $moduleFuncs.Keys) { if (-not $inScope.ContainsKey($k)) { $inScope[$k] = 'module' } }
        }

        $calls = $parsed.Ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $calls) {
            $name = Get-CommandName -CommandAst $c
            if (-not $name) { continue }
            $checked++
            if ($inScope.ContainsKey($name)) { continue }
            $ext = Resolve-ExternalCommand -Name $name
            if ($ext) { continue }
            if ($script:OptionalCmdlets -contains $name) {
                $notes += (Fmt-Finding $f.FullName $c.Extent.StartLineNumber ("可选 Windows 命令在此环境不存在 / optional Windows cmdlet unavailable: {0}" -f $name))
                continue
            }
            # Also allow a function defined in *another* repo file but not imported:
            # still report, because at runtime it is not in scope.
            $hint = if ($repoFuncs.ContainsKey($name)) {
                " (defined in $(Split-Path -Leaf $repoFuncs[$name].File):$($repoFuncs[$name].Line) but not in scope here)"
            } else { '' }
            $findings += (Fmt-Finding $f.FullName $c.Extent.StartLineNumber ("调用未定义命令 / call to undefined command '{0}'{1}" -f $name, $hint))
        }
    }
    $notes += ('{0} command call(s) resolved' -f $checked)
    return @{ Findings = $findings; Notes = $notes }
}

# ── S03 undefined parameter ───────────────────────────────────────────────
Invoke-Case -Id 'S03' -Category 'static' -Name 'No call passes a parameter the target function does not declare' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $notes = @()

    $repoFuncs = @{}
    foreach ($f in $script:RepoFiles) {
        $t = Get-FunctionTable -Path $f.FullName
        foreach ($k in $t.Keys) { $repoFuncs[$k] = $t[$k] }
    }

    $checkedCalls = 0
    $checkedParams = 0
    $cmdletNotes = @()

    foreach ($f in $script:RepoFiles) {
        $parsed = Get-ParsedFile -Path $f.FullName
        $calls = $parsed.Ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $calls) {
            $name = Get-CommandName -CommandAst $c
            if (-not $name) { continue }
            $target = $null
            $isRepo = $false
            if ($repoFuncs.ContainsKey($name)) { $target = $repoFuncs[$name]; $isRepo = $true }
            else {
                $ext = Resolve-ExternalCommand -Name $name
                if ($ext -and $ext.Parameters) {
                    $declared = @($ext.Parameters.Keys)
                    $advanced = $ext.CommandType -ne 'Cmdlet' -or $true
                    $target = [pscustomobject]@{ Name = $name; Params = $declared; Advanced = $true; Line = 0; File = $null }
                }
            }
            if (-not $target) { continue }
            if ($target.Params.Count -eq 0 -and -not $isRepo) { continue }
            $checkedCalls++

            for ($i = 1; $i -lt $c.CommandElements.Count; $i++) {
                $el = $c.CommandElements[$i]
                if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $given = $el.ParameterName
                if ([string]::IsNullOrWhiteSpace($given)) { continue }
                $checkedParams++
                $r = Test-ParamMatch -Given $given -Declared $target.Params -AllowCommon:($target.Advanced)
                if ($r.Ok) { continue }
                $msg = "参数 '{0}' 未在 {1} 中声明 / parameter '-{0}' is not declared by {1} ({2})" -f $given, $name, $r.Reason
                if ($isRepo) {
                    $findings += (Fmt-Finding $f.FullName $el.Extent.StartLineNumber $msg)
                } else {
                    $cmdletNotes += (Fmt-Finding $f.FullName $el.Extent.StartLineNumber $msg)
                }
            }
        }
    }
    $notes += ('{0} call(s), {1} named parameter(s) checked' -f $checkedCalls, $checkedParams)
    if ($cmdletNotes.Count) { $notes += ('cmdlet-level (informational): ' + ($cmdletNotes -join ' | ')) }
    return @{ Findings = $findings; Notes = $notes }
}

# ── S04 call before definition at script scope ────────────────────────────
Invoke-Case -Id 'S04' -Category 'static' -Name 'No script-scope call to a function defined later in the same file' -Body {
    $findings = @()
    foreach ($f in $script:RepoFiles) {
        $parsed = Get-ParsedFile -Path $f.FullName
        $funcs = Get-FunctionTable -Path $f.FullName
        if ($funcs.Count -eq 0) { continue }

        # Top-level statements only: walk the EndBlock/NamedBlocks but drop
        # anything nested inside a FunctionDefinitionAst.
        $tops = @()
        foreach ($stmt in $parsed.Ast.EndBlock.Statements) { $tops += $stmt }
        foreach ($nb in $parsed.Ast.NamedBlocks) { foreach ($stmt in $nb.Statements) { $tops += $stmt } }

        foreach ($stmt in $tops) {
            $calls = $stmt.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($c in $calls) {
                $name = Get-CommandName -CommandAst $c
                if (-not $name -or -not $funcs.ContainsKey($name)) { continue }
                if ($c.Extent.StartLineNumber -lt $funcs[$name].Line) {
                    $findings += (Fmt-Finding $f.FullName $c.Extent.StartLineNumber (
                        "在脚本作用域调用 '{0}' 早于其定义（定义于第 {1} 行）/ called before its definition at line {1}" -f $name, $funcs[$name].Line))
                }
            }
        }
    }
    $findings
}

# ── S05 export surface ────────────────────────────────────────────────────
Invoke-Case -Id 'S05' -Category 'static' -Name 'Module exports exactly the intended function set' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $expected = @(
        'Test-Admin', 'Assert-Admin', 'Get-WorkRoot', 'Write-TuneLog', 'Invoke-PowerCfg',
        'Get-SettingSubGroup', 'Get-SettingGuid', 'Get-Value', 'Set-Value', 'Test-Writable',
        'Get-ProfileDefinition', 'Get-ProfileList', 'Get-KnownSettings', 'Get-WritableSettings',
        'Get-HardwareProfile', 'Resolve-Profile', 'Get-SchemeList', 'Get-ActiveScheme',
        'Find-SchemeByName', 'New-PowerScheme', 'Set-ActiveScheme', 'Enable-HiddenSettings',
        'Export-PowerSnapshot', 'Import-PowerSnapshot', 'Restore-SnapshotValues',
        'Restore-SnapshotAttributes',
        'Restore-PowerDefaults', 'Get-ProfileDiff', 'Set-PowerProfile'
    )
    $actual = @(Get-Command -Module $script:Module -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandType -eq 'Function' } | ForEach-Object { $_.Name } | Sort-Object)
    $expectedSorted = @($expected | Sort-Object)
    $findings = @()
    $missing = @($expectedSorted | Where-Object { $actual -notcontains $_ })
    $extra = @($actual | Where-Object { $expectedSorted -notcontains $_ })
    if ($missing.Count) { $findings += ('模块未导出 / missing exports: {0}' -f ($missing -join ', ')) }
    if ($extra.Count) { $findings += ('模块多导出 / unexpected exports: {0}' -f ($extra -join ', ')) }
    return @{
        Findings = $findings
        Notes    = @(('{0} functions exported' -f $actual.Count))
    }
}

# ── S06 StrictMode getter smoke ───────────────────────────────────────────
Invoke-Case -Id 'S06' -Category 'static' -Name 'Set-StrictMode 3.0 compatibility: every read-only getter' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $notes = @()

    # Deliberately excluded: Test-Writable (writes a probe value to the ACTIVE
    # scheme and restores it - a real system mutation, not a getter) and
    # Write-TuneLog (side-effecting logger, not a getter).
    $plan = [ordered]@{
        'Test-Admin'           = { Test-Admin }
        'Get-WorkRoot'         = { Get-WorkRoot }
        'Get-KnownSettings'    = { Get-KnownSettings }
        'Get-WritableSettings' = { Get-WritableSettings }
        'Get-ProfileList'      = { Get-ProfileList }
        'Get-ProfileDefinition' = { Get-ProfileDefinition -ProfileKey 'max-perf' }
        'Get-HardwareProfile'  = { Get-HardwareProfile }
        'Get-SchemeList'       = { Get-SchemeList }
        'Get-ActiveScheme'     = { Get-ActiveScheme }
        'Find-SchemeByName'    = { Find-SchemeByName -FriendlyName '__no_such_scheme__' }
        'Get-SettingSubGroup'  = { Get-SettingSubGroup -Name 'PERFEPP' }
        'Get-SettingGuid'      = { Get-SettingGuid -Name 'PERFEPP' }
        'Get-Value'            = { Get-Value -Name 'PERFEPP' }
        'Get-ProfileDiff'      = { Get-ProfileDiff -ProfileKey 'eco' }
        'Resolve-Profile'      = { Resolve-Profile (Get-HardwareProfile) }
    }

    $ok = 0
    foreach ($name in $plan.Keys) {
        try {
            $sb = [scriptblock]::Create(@"
Set-StrictMode -Version 3.0
`$global:ErrorActionPreference = 'Stop'
$($plan[$name].ToString())
"@)
            $null = & $sb
            $ok++
        } catch {
            $findings += ('{0} 在 StrictMode 3.0 下抛出 / throws under StrictMode 3.0: {1}' -f $name, $_.Exception.Message)
        }
    }

    # One child-process run as an independent confirmation that a clean
    # pwsh session can import the module and read a setting.
    try {
        $child = & pwsh -NoProfile -ExecutionPolicy Bypass -Command @"
Set-StrictMode -Version 3.0
`$ErrorActionPreference='Stop'
Import-Module '$psm1' -Force -WarningAction SilentlyContinue
`$v = Get-Value -Name 'PROCTHROTTLEMIN'
if (`$null -eq `$v.AC) { 'UNREADABLE' } else { 'OK ' + `$v.AC }
"@ 2>&1
        $childText = ($child -join ' ').Trim()
        if ($childText -notlike 'OK*') {
            $findings += ('子进程导入/读取失败 / child-process import+read failed: {0}' -f $childText)
        } else {
            $notes += ('child process: {0}' -f $childText)
        }
    } catch {
        $findings += ('子进程检查失败 / child-process check failed: {0}' -f $_.Exception.Message)
    }

    $notes += ('{0}/{1} getters clean under StrictMode 3.0' -f $ok, $plan.Count)
    return @{ Findings = $findings; Notes = $notes }
}

# ── S07 settings schema ───────────────────────────────────────────────────
Invoke-Case -Id 'S07' -Category 'static' -Name '$Script:Settings schema: fields, group membership, status enum' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $allowedStatus = @('验证', '只读', '不可用')
    foreach ($name in $script:Settings.Keys) {
        $s = $script:Settings[$name]
        foreach ($field in @('Guid', 'Group', 'Desc', 'V')) {
            if (-not $s.Contains($field)) { $findings += ("{0}: 缺少字段 / missing field '{1}'" -f $name, $field) }
            elseif ([string]::IsNullOrWhiteSpace([string]$s[$field])) { $findings += ("{0}: 字段为空 / empty field '{1}'" -f $name, $field) }
        }
        if ($s.Contains('Group') -and $s.Group -and -not $script:SubGroup.ContainsKey($s.Group)) {
            $findings += ("{0}: Group '{1}' 不在 `$Script:SubGroup 中" -f $name, $s.Group)
        }
        if ($s.Contains('V') -and $s.V -and ($allowedStatus -notcontains $s.V)) {
            $findings += ("{0}: 状态 '{1}' 不在允许集合 {2} 中" -f $name, $s.V, ($allowedStatus -join '/'))
        }
        # status must agree with the writable whitelist
        $inW = $script:Writable -contains $name
        $shouldBeWritable = ($s.V -eq '验证')
        if ($inW -ne $shouldBeWritable) {
            $findings += ("{0}: V='{1}' 与 `$Script:Writable 成员关系不一致 (inWritable={2})" -f $name, $s.V, $inW)
        }
    }
    $findings
}

# ── S08 GUID validity ─────────────────────────────────────────────────────
Invoke-Case -Id 'S08' -Category 'static' -Name 'Every GUID in Settings / SubGroup / Scheme is a valid GUID' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $count = 0
    foreach ($name in $script:Settings.Keys) {
        $count++
        $raw = [string]$script:Settings[$name].Guid
        $g = [Guid]::Empty
        if (-not [Guid]::TryParse($raw, [ref]$g)) {
            $findings += ("{0}: 非法 GUID / invalid GUID '{1}'" -f $name, $raw)
        } elseif ($g -eq [Guid]::Empty) {
            $findings += ("{0}: GUID 为零值 / all-zero GUID" -f $name)
        }
    }
    foreach ($name in $script:SubGroup.Keys) {
        $count++
        $g = [Guid]::Empty
        if (-not [Guid]::TryParse([string]$script:SubGroup[$name], [ref]$g)) {
            $findings += ("SubGroup {0}: 非法 GUID / invalid GUID '{1}'" -f $name, $script:SubGroup[$name])
        }
    }
    foreach ($name in $script:Scheme.Keys) {
        $count++
        $g = [Guid]::Empty
        if (-not [Guid]::TryParse([string]$script:Scheme[$name], [ref]$g)) {
            $findings += ("Scheme {0}: 非法 GUID / invalid GUID '{1}'" -f $name, $script:Scheme[$name])
        }
    }
    return @{ Findings = $findings; Notes = @(('{0} GUID(s) validated' -f $count)) }
}

# ── S09 duplicate GUIDs ───────────────────────────────────────────────────
Invoke-Case -Id 'S09' -Category 'static' -Name 'No two setting names share a GUID' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $groups = $script:Settings.Keys | Group-Object { ([string]$script:Settings[$_].Guid).ToLower() }
    foreach ($g in $groups) {
        if ($g.Count -gt 1) {
            $findings += ("GUID {0} 被多个设置名共用 / shared by: {1}" -f $g.Name, ($g.Group -join ', '))
        }
    }
    $findings
}

# ── S10 profile keys exist ────────────────────────────────────────────────
Invoke-Case -Id 'S10' -Category 'static' -Name 'Every profile key exists in $Script:Settings' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    foreach ($p in $script:Profiles.Keys) {
        foreach ($scope in @('AC', 'DC')) {
            foreach ($k in $script:Profiles[$p].$scope.Keys) {
                if (-not $script:Settings.Contains($k)) {
                    $findings += ("{0}.{1}: 未知设置名 / unknown setting '{2}'" -f $p, $scope, $k)
                }
            }
        }
    }
    $findings
}

# ── S11 profile keys writable ─────────────────────────────────────────────
Invoke-Case -Id 'S11' -Category 'static' -Name 'Every profile key is in $Script:Writable (or documented unsupported)' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    # Settings deliberately excluded from profiles even though writable - empty
    # today; add here only with a comment explaining why.
    $documentedUnsupported = @()
    foreach ($p in $script:Profiles.Keys) {
        foreach ($scope in @('AC', 'DC')) {
            foreach ($k in $script:Profiles[$p].$scope.Keys) {
                if ($script:Writable -contains $k) { continue }
                if ($documentedUnsupported -contains $k) { continue }
                $status = if ($script:Settings.Contains($k)) { $script:Settings[$k].V } else { '?' }
                $findings += ("{0}.{1}: '{2}' 不在可写白名单中（状态={3}）/ not in writable whitelist" -f $p, $scope, $k, $status)
            }
        }
    }
    $findings
}

# ── S12 AC/DC parity ──────────────────────────────────────────────────────
Invoke-Case -Id 'S12' -Category 'static' -Name 'Each profile AC/DC key sets match, or the difference is listed' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    # Deliberate AC-only omissions. Everything here is a setting that is left
    # at the base scheme's DC default on purpose (battery stays conservative).
    $documented = @{
        'balanced-stable' = @('PERFINCTHRESHOLD', 'PERFDECTHRESHOLD', 'PERFRESOURCEPRIORITY')
        'max-perf'        = @('PERFINCTHRESHOLD', 'PERFDECTHRESHOLD', 'PERFRESOURCEPRIORITY', 'IDLEDISABLE', 'DUTYCYCLING')
        'eco'             = @('PERFINCTHRESHOLD', 'PERFDECTHRESHOLD', 'PERFRESOURCEPRIORITY')
    }
    $findings = @()
    $notes = @()
    foreach ($p in $script:Profiles.Keys) {
        $ac = @($script:Profiles[$p].AC.Keys | Sort-Object)
        $dc = @($script:Profiles[$p].DC.Keys | Sort-Object)
        $acOnly = @($ac | Where-Object { $dc -notcontains $_ })
        $dcOnly = @($dc | Where-Object { $ac -notcontains $_ })
        $allow = if ($documented.ContainsKey($p)) { $documented[$p] } else { @() }
        foreach ($k in $acOnly) {
            if ($allow -notcontains $k) {
                $findings += ("{0}: '{1}' 仅在 AC 表中，且未列入已知差异 / AC-only and not in the documented list" -f $p, $k)
            }
        }
        foreach ($k in $dcOnly) {
            $findings += ("{0}: '{1}' 仅在 DC 表中 / DC-only (never documented)" -f $p, $k)
        }
        if ($acOnly.Count) {
            $notes += ('{0}: deliberate AC-only = {1}' -f $p, ($acOnly -join ', '))
        }
    }
    return @{ Findings = $findings; Notes = $notes }
}

# ── S13 profile value ranges ──────────────────────────────────────────────
Invoke-Case -Id 'S13' -Category 'static' -Name 'Every profile value is numeric and inside the documented range' -Skip:(-not $script:ModuleOk -or $null -eq $script:Ranges) -SkipReason 'module or Test-Ranges.psd1 unavailable' -Body {
    $findings = @()
    $checked = 0
    $rangeTable = $script:Ranges.Settings
    foreach ($p in $script:Profiles.Keys) {
        foreach ($scope in @('AC', 'DC')) {
            foreach ($k in $script:Profiles[$p].$scope.Keys) {
                $raw = $script:Profiles[$p].$scope[$k]
                $n = 0
                if (-not [int]::TryParse([string]$raw, [ref]$n)) {
                    $findings += ("{0}.{1}.{2}: 非整数值 / non-integer value '{3}'" -f $p, $scope, $k, $raw)
                    continue
                }
                $checked++
                if (-not $rangeTable.ContainsKey($k)) {
                    $findings += ("{0}.{1}.{2}: 无已知范围数据 / no range entry in Test-Ranges.psd1" -f $p, $scope, $k)
                    continue
                }
                $r = $rangeTable[$k]
                if ([int64]$n -lt [int64]$r.Min -or [int64]$n -gt [int64]$r.Max) {
                    $findings += ("{0}.{1}.{2} = {3} 超出范围 {4}..{5} / out of range" -f $p, $scope, $k, $n, $r.Min, $r.Max)
                }
                if ($r.ContainsKey('Allowed') -and ($r.Allowed -notcontains $n)) {
                    $findings += ("{0}.{1}.{2} = {3} 不在枚举集合 {4} 中 / not an allowed value" -f $p, $scope, $k, $n, ($r.Allowed -join '/'))
                }
            }
        }
    }
    return @{ Findings = $findings; Notes = @(('{0} value(s) validated against {1} range entries' -f $checked, $rangeTable.Count)) }
}

# ── S14 profile list / ValidateSet drift ──────────────────────────────────
Invoke-Case -Id 'S14' -Category 'static' -Name 'Get-ProfileList and every ValidateSet agree with $Script:Profiles' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $real = @($script:Profiles.Keys | Sort-Object)
    $listed = @(Get-ProfileList | Sort-Object)
    if (($real -join '|') -ne ($listed -join '|')) {
        $findings += ("Get-ProfileList 返回 [{0}]，但 `$Script:Profiles 有 [{1}]" -f ($listed -join ','), ($real -join ','))
    }

    # ValidateSet on module functions
    foreach ($fn in @('Get-ProfileDefinition', 'Apply-Profile', 'Get-ProfileDiff')) {
        $cmd = Get-Command $fn -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $p = $cmd.Parameters['ProfileKey']
        if (-not $p) { $findings += ("{0}: 缺少 -ProfileKey 参数" -f $fn); continue }
        $vs = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        if ($vs.Count -eq 0) { $findings += ("{0}.ProfileKey 没有 ValidateSet，新增档位不会被拦住" -f $fn); continue }
        $set = @($vs[0].ValidValues | Sort-Object)
        if (($set -join '|') -ne ($real -join '|')) {
            $findings += ("{0}.ProfileKey ValidateSet=[{1}] 与档位表 [{2}] 不一致" -f $fn, ($set -join ','), ($real -join ','))
        }
    }

    # Apply-PowerProfile.ps1 -Profile / -Diff ValidateSets (parsed from AST so
    # the script does not have to be executed).
    $apply = Join-Path $script:RepoRoot 'Apply-PowerProfile.ps1'
    if (Test-Path $apply) {
        $parsed = Get-ParsedFile -Path $apply
        foreach ($pAst in $parsed.Ast.ParamBlock.Parameters) {
            $pName = $pAst.Name.VariablePath.UserPath
            if ($pName -notin @('Profile', 'Diff')) { continue }
            $vs = @($pAst.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
            if ($vs.Count -eq 0) { continue }
            $values = @($vs[0].PositionalArguments | ForEach-Object { $_.Value })
            $check = @($values | Where-Object { $_ -ne 'auto' } | Sort-Object)
            if (($check -join '|') -ne ($real -join '|')) {
                $findings += ("Apply-PowerProfile.ps1 -{0} ValidateSet=[{1}] 与档位表 [{2}] 不一致" -f $pName, ($check -join ','), ($real -join ','))
            }
        }
    }
    $findings
}

# ── S15 _ref/Test-PwrApi.ps1 GUID agreement ───────────────────────────────
Invoke-Case -Id 'S15' -Category 'static' -Name 'GUIDs in _ref\Test-PwrApi.ps1 agree with $Script:Settings' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $notes = @()
    if (-not (Test-Path $refApiPs1)) { return @{ Findings = @(); Notes = @('_ref\Test-PwrApi.ps1 not found') } }

    $parsed = Get-ParsedFile -Path $refApiPs1
    # The probe table is the hashtable literal with the most entries.
    $hts = @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) |
            Sort-Object { $_.KeyValuePairs.Count } -Descending)
    if ($hts.Count -eq 0) { return @{ Findings = @('_ref\Test-PwrApi.ps1: 找不到探测表 hashtable') } }

    $pairs = Get-HashtablePairs -HashtableAst $hts[0]
    if ($pairs.Count -lt 10) { return @{ Findings = @(('_ref\Test-PwrApi.ps1: 探测表只解析出 {0} 项（应为 34 项）' -f $pairs.Count)) } }

    foreach ($k in ($pairs.Keys | Sort-Object)) {
        $refGuid = $pairs[$k].ToLower()
        if ($script:Settings.Contains($k)) {
            $modGuid = ([string]$script:Settings[$k].Guid).ToLower()
            if ($modGuid -ne $refGuid) {
                $findings += ("{0}: 模块 GUID {1} ≠ _ref GUID {2} / GUID disagreement" -f $k, $modGuid, $refGuid)
            }
        } else {
            $notes += ('{0} = {1} (probe-only, not in module)' -f $k, $refGuid)
        }
    }

    # The probe table itself must not contain two names mapping to a GUID that
    # is a near-miss of another (a classic hand-typed GUID typo).
    $dupes = $pairs.Keys | Group-Object { $pairs[$_].ToLower() } | Where-Object Count -gt 1
    foreach ($d in $dupes) { $findings += ('_ref 探测表内 GUID 重复 / duplicate GUID in probe table: {0} -> {1}' -f $d.Name, ($d.Group -join ', ')) }

    return @{ Findings = $findings; Notes = $notes }
}

# ── S16 writable-test.csv agreement ───────────────────────────────────────
Invoke-Case -Id 'S16' -Category 'static' -Name 'GUIDs and counts in _ref\writable-test.csv agree with the module' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $notes = @()
    if ($script:RefWritable.Count -eq 0) { return @{ Findings = @('_ref\writable-test.csv missing or empty') } }

    foreach ($row in $script:RefWritable) {
        $n = [string]$row.Name
        if (-not $script:Settings.Contains($n)) { continue }
        $mod = ([string]$script:Settings[$n].Guid).ToLower()
        $csv = ([string]$row.Guid).ToLower()
        if ($mod -ne $csv) {
            $findings += ("{0}: 模块 GUID {1} ≠ writable-test.csv GUID {2}" -f $n, $mod, $csv)
        }
    }

    $csvWritable = @($script:RefWritable | Where-Object { $_.'可写' -eq 'True' })
    $csvReadOnly = @($script:RefWritable | Where-Object { $_.'可读' -eq 'True' -and $_.'可写' -eq 'False' })
    $csvUnreadable = @($script:RefWritable | Where-Object { $_.'可读' -eq 'False' })

    if ($csvWritable.Count -ne $script:Writable.Count) {
        $notes += ('CSV 可写={0}，模块白名单={1}（差异是设计选择，README 数字另测）' -f $csvWritable.Count, $script:Writable.Count)
    }

    # Every module-whitelisted setting must be present in the CSV and marked writable.
    foreach ($w in $script:Writable) {
        $row = $script:RefWritable | Where-Object { $_.Name -eq $w } | Select-Object -First 1
        if (-not $row) { $findings += ("{0}: 在模块白名单中但不在 writable-test.csv 中" -f $w); continue }
        if ($row.'可写' -ne 'True') { $findings += ("{0}: 在模块白名单中但 CSV 标记为不可写" -f $w) }
    }

    $notes += ('CSV rows={0} 可写={1} 只读={2} 不可读={3}' -f $script:RefWritable.Count, $csvWritable.Count, $csvReadOnly.Count, $csvUnreadable.Count)
    return @{ Findings = $findings; Notes = $notes }
}

# ── S17 processor-settings.csv membership ─────────────────────────────────
Invoke-Case -Id 'S17' -Category 'static' -Name 'Every module GUID appears in _ref\processor-settings.csv' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    if ($script:RefProcessor.Count -eq 0) { return @('_ref\processor-settings.csv missing or empty') }
    $byGuid = @{}
    foreach ($r in $script:RefProcessor) { $byGuid[([string]$r.Guid).ToLower()] = $r.Name }
    $missing = 0
    foreach ($k in $script:Settings.Keys) {
        $g = ([string]$script:Settings[$k].Guid).ToLower()
        if (-not $byGuid.ContainsKey($g)) {
            $findings += ("{0} ({1}): 不在 processor-settings.csv 的 {2} 项清单中" -f $k, $g, $script:RefProcessor.Count)
            $missing++
        }
    }
    return @{ Findings = $findings; Notes = @(('{0} CSV rows, {1} module GUID(s) matched' -f $script:RefProcessor.Count, ($script:Settings.Count - $missing))) }
}

# ── S18 range table completeness + registry cross-check ───────────────────
Invoke-Case -Id 'S18' -Category 'static' -Name 'Range table covers every setting and matches the OS registry bounds' -Skip:(-not $script:ModuleOk -or $null -eq $script:Ranges) -SkipReason 'module or Test-Ranges.psd1 unavailable' -Body {
    $findings = @()
    $notes = @()
    $rangeTable = $script:Ranges.Settings

    foreach ($k in $script:Settings.Keys) {
        if (-not $rangeTable.ContainsKey($k)) {
            $findings += ("{0}: Test-Ranges.psd1 缺少该设置的取值范围" -f $k)
        }
    }
    foreach ($k in $rangeTable.Keys) {
        if (-not $script:Settings.Contains($k)) {
            $findings += ("Test-Ranges.psd1: 条目 '{0}' 在 `$Script:Settings 中不存在（陈旧数据）" -f $k)
        }
    }

    # Cross-check against HKLM where Windows publishes ValueMin/ValueMax.
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\{0}' -f $script:Ranges.SubGroup
    $registryChecked = 0
    if (Test-Path $base) {
        foreach ($k in $script:Settings.Keys) {
            $g = [string]$script:Settings[$k].Guid
            $key = Join-Path $base $g
            if (-not (Test-Path $key)) { continue }
            $props = Get-ItemProperty $key -ErrorAction SilentlyContinue
            if ($null -eq $props -or $null -eq $props.ValueMax) { continue }
            if (-not $rangeTable.ContainsKey($k)) { continue }
            $registryChecked++
            $rMin = [int64]$props.ValueMin
            $rMax = [int64]$props.ValueMax
            $tMin = [int64]$rangeTable[$k].Min
            $tMax = [int64]$rangeTable[$k].Max
            if ($tMin -ne $rMin -or $tMax -ne $rMax) {
                $findings += ("{0}: Test-Ranges.psd1 范围 {1}..{2} ≠ 注册表 {3}..{4}" -f $k, $tMin, $tMax, $rMin, $rMax)
            }
        }
        $notes += ('{0} range(s) cross-checked against HKLM PowerSettings' -f $registryChecked)
    } else {
        $notes += 'registry PowerSettings key unavailable; OS cross-check skipped'
    }
    return @{ Findings = $findings; Notes = $notes }
}

# ── S19 README numeric claims ─────────────────────────────────────────────
Invoke-Case -Id 'S19' -Category 'static' -Name 'README numeric claims match the code and reference data' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $notes = @()
    $md = $script:ReadmeText
    if ([string]::IsNullOrWhiteSpace($md)) { return @('README.md missing or empty') }

    $csvWritable = @($script:RefWritable | Where-Object { $_.'可写' -eq 'True' })
    $csvReadOnly = @($script:RefWritable | Where-Object { $_.'可读' -eq 'True' -and $_.'可写' -eq 'False' })
    $csvUnreadable = @($script:RefWritable | Where-Object { $_.'可读' -eq 'False' })

    function Read-ClaimInt {
        param([string]$Pattern)
        $m = [regex]::Match($md, $Pattern)
        if ($m.Success) { return [int]$m.Groups[1].Value }
        return $null
    }

    # "34 项候选设置"
    $claimCandidates = Read-ClaimInt '(\d+)\s*项候选设置'
    if ($null -ne $claimCandidates -and $claimCandidates -ne $script:RefWritable.Count) {
        $findings += ("README 声称 {0} 项候选设置，writable-test.csv 实有 {1} 行" -f $claimCandidates, $script:RefWritable.Count)
    }

    # "**30 项可读可写**" —— 这是 CSV 里实测可读可写的总数
    $claimWritable = Read-ClaimInt '\*\*(\d+)\s*项可读可写\*\*'
    if ($null -ne $claimWritable) {
        if ($claimWritable -ne $csvWritable.Count) {
            $findings += ("README 声称 {0} 项可读可写，writable-test.csv 标记可写的有 {1} 项" -f $claimWritable, $csvWritable.Count)
        }
    } else { $notes += 'README: "N 项可读可写" claim not found' }

    # "其中 **27 项编入三档配置**" —— 这是白名单条数，和上一个是不同的数
    $claimInProfiles = Read-ClaimInt '其中\s*\*\*(\d+)\s*项编入三档配置\*\*'
    if ($null -ne $claimInProfiles) {
        if ($claimInProfiles -ne $script:Writable.Count) {
            $findings += ("README 声称 {0} 项编入三档配置，模块 `$Script:Writable 有 {1} 项" -f $claimInProfiles, $script:Writable.Count)
        }
    } else { $notes += 'README: "N 项编入三档配置" claim not found' }

    # "**3 项只读**"
    $claimReadOnly = Read-ClaimInt '\*\*(\d+)\s*项只读\*\*'
    if ($null -ne $claimReadOnly -and $claimReadOnly -ne $csvReadOnly.Count) {
        $findings += ("README 声称 {0} 项只读，CSV 中「可读=True 且 可写=False」的有 {1} 项: {2}" -f
            $claimReadOnly, $csvReadOnly.Count, (($csvReadOnly | ForEach-Object { $_.Name }) -join ', '))
    }

    # "**1 项不可读**"
    $claimUnreadable = Read-ClaimInt '\*\*(\d+)\s*项不可读\*\*'
    if ($null -ne $claimUnreadable -and $claimUnreadable -ne $csvUnreadable.Count) {
        $findings += ("README 声称 {0} 项不可读，CSV 中「可读=False」的有 {1} 项: {2}" -f
            $claimUnreadable, $csvUnreadable.Count, (($csvUnreadable | ForEach-Object { $_.Name }) -join ', '))
    }

    # The breakdown must add up to the candidate count.
    if ($null -ne $claimCandidates -and $null -ne $claimWritable -and $null -ne $claimReadOnly -and $null -ne $claimUnreadable) {
        $sum = $claimWritable + $claimReadOnly + $claimUnreadable
        if ($sum -ne $claimCandidates) {
            $findings += ("README 分类不自洽：{0}(可写) + {1}(只读) + {2}(不可读) = {3}，但候选总数是 {4}" -f
                $claimWritable, $claimReadOnly, $claimUnreadable, $sum, $claimCandidates)
        }
    }

    # "极致版演练：47 项写入全部通过；节能版：41 项"
    $rehearsal = [regex]::Matches($md, '\*\*(\d+)\s*项写入全部通过\*\*|：\*\*(\d+)\s*项')
    $m47 = [regex]::Match($md, '\*\*(\d+)\s*项写入全部通过')
    if ($m47.Success) {
        $v = [int]$m47.Groups[1].Value
        $actual = $script:Profiles['max-perf'].AC.Count + $script:Profiles['max-perf'].DC.Count
        if ($v -ne $actual) {
            $findings += ("README 声称极致版演练写入 {0} 项，max-perf AC+DC = {1}" -f $v, $actual)
        }
    }
    $mEco = [regex]::Match($md, '节能版：\*\*(\d+)\s*项')
    if ($mEco.Success) {
        $v = [int]$mEco.Groups[1].Value
        $actual = $script:Profiles['eco'].AC.Count + $script:Profiles['eco'].DC.Count
        if ($v -ne $actual) {
            $findings += ("README 声称节能版写入 {0} 项，eco AC+DC = {1}" -f $v, $actual)
        }
    }

    # "95 项完整清单"
    $m95 = [regex]::Match($md, '(\d+)\s*项完整清单')
    if ($m95.Success) {
        $v = [int]$m95.Groups[1].Value
        if ($v -ne $script:RefProcessor.Count) {
            $findings += ("README 声称 {0} 项完整清单，processor-settings.csv 有 {1} 行" -f $v, $script:RefProcessor.Count)
        }
    }

    # Intro: "把处理器性能相关的 26 项设置自动调成三档场景"
    $mIntro = [regex]::Match($md, '把处理器性能相关的\s*(\d+)\s*项')
    if ($mIntro.Success) {
        $v = [int]$mIntro.Groups[1].Value
        $used = @{}
        foreach ($p in $script:Profiles.Keys) {
            foreach ($s in @('AC', 'DC')) { foreach ($k in $script:Profiles[$p].$s.Keys) { $used[$k] = $true } }
        }
        if ($v -ne $used.Count) {
            $findings += ("README 开篇声称 {0} 项设置，三档实际用到 {1} 项" -f $v, $used.Count)
        }
    }

    # "powercfg 只肯显示 2 项" - read-only powercfg query, no admin needed.
    $m2 = [regex]::Match($md, 'powercfg`?\s*只肯显示\s*(\d+)\s*项')
    if ($m2.Success) {
        try {
            $scheme = (& powercfg.exe /getactivescheme 2>&1) -join "`n"
            $sg = [regex]::Match($scheme, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})').Groups[1].Value
            if ($sg) {
                $q = & powercfg.exe /query $sg $script:SubGroup['PROCESSOR'] 2>&1
                $shown = @($q | Select-String -SimpleMatch '电源设置 GUID').Count
                if ($shown -ne [int]$m2.Groups[1].Value) {
                    $findings += ("README 声称 powercfg 只显示 {0} 项，实测当前方案下显示 {1} 项" -f $m2.Groups[1].Value, $shown)
                } else {
                    $notes += ("powercfg shows {0} setting(s) under SUB_PROCESSOR - claim verified" -f $shown)
                }
            }
        } catch {
            $notes += 'powercfg claim not verified (powercfg unavailable)'
        }
    }

    return @{ Findings = $findings; Notes = $notes }
}

# ── S20 README 三档差异 table vs code ─────────────────────────────────────
Invoke-Case -Id 'S20' -Category 'static' -Name 'README "三档差异" table numbers match the profile tables' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $notes = @()
    $md = $script:ReadmeText

    # Isolate the section that starts at the "三档差异" heading.
    $start = $md.IndexOf('三档差异')
    if ($start -lt 0) { return @('README: 找不到「三档差异」小节') }
    $section = $md.Substring($start)
    $end = $section.IndexOf('## ', 3)
    if ($end -gt 0) { $section = $section.Substring(0, $end) }

    $rows = @($section -split "`r?`n" | Where-Object { $_ -match '^\s*\|' })
    if ($rows.Count -lt 4) { return @('README: 「三档差异」表格解析失败') }

    $rowCount = 0
    foreach ($row in $rows) {
        $cells = @($row.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt 4) { continue }
        if ($cells[0] -match '^:?-+:?$' -or $cells[0] -eq '设置') { continue }

        $names = @([regex]::Matches($cells[0], '`([A-Z0-9_]+)`') | ForEach-Object { $_.Groups[1].Value })
        if ($names.Count -eq 0) { continue }

        $scope = if ($cells[0] -match '（DC）') { 'DC' } else { 'AC' }
        $cols = @(
            @{ Profile = 'balanced-stable'; Cell = $cells[1] },
            @{ Profile = 'max-perf';        Cell = $cells[2] },
            @{ Profile = 'eco';             Cell = $cells[3] }
        )

        foreach ($col in $cols) {
            $cellInts = @([regex]::Matches($col.Cell, '-?\d+') | ForEach-Object { [int]$_.Value })
            $profileTable = $script:Profiles[$col.Profile].$scope

            if ($names.Count -eq 1) {
                $name = $names[0]
                if (-not $script:Settings.Contains($name)) {
                    $findings += ("README 表格引用了未知设置 '{0}'" -f $name); continue
                }
                $rowCount++
                $codeVal = if ($profileTable.ContainsKey($name)) { [int]$profileTable[$name] } else { $null }
                $claimVal = if ($cellInts.Count) { $cellInts[0] } else { $null }
                if ($null -eq $claimVal -and $null -eq $codeVal) { continue }
                if ($null -eq $claimVal) {
                    $findings += ("README 表格 {0}/{1}: 未给出数值，但代码写了 {2}" -f $col.Profile, $name, $codeVal)
                } elseif ($null -eq $codeVal) {
                    $findings += ("README 表格 {0}/{1}: 声称 {2}，但该档 {3} 表未包含此项" -f $col.Profile, $name, $claimVal, $scope)
                } elseif ($claimVal -ne $codeVal) {
                    $findings += ("README 表格 {0}/{1}: 声称 {2}，代码是 {3}" -f $col.Profile, $name, $claimVal, $codeVal)
                }
            } elseif ($names.Count -eq 2 -and $cellInts.Count -ge 2) {
                for ($i = 0; $i -lt 2; $i++) {
                    $name = $names[$i]
                    if (-not $script:Settings.Contains($name)) {
                        $findings += ("README 表格引用了未知设置 '{0}'" -f $name); continue
                    }
                    $rowCount++
                    $codeVal = if ($profileTable.ContainsKey($name)) { [int]$profileTable[$name] } else { $null }
                    $claimVal = $cellInts[$i]
                    if ($null -eq $codeVal) {
                        $findings += ("README 表格 {0}/{1}: 声称 {2}，但该档 {3} 表未包含此项" -f $col.Profile, $name, $claimVal, $scope)
                    } elseif ($claimVal -ne $codeVal) {
                        $findings += ("README 表格 {0}/{1}: 声称 {2}，代码是 {3}" -f $col.Profile, $name, $claimVal, $codeVal)
                    }
                }
            }
        }
    }
    $notes += ('{0} table cell(s) compared' -f $rowCount)
    return @{ Findings = $findings; Notes = $notes }
}

# ── S21 approved verbs ────────────────────────────────────────────────────
Invoke-Case -Id 'S21' -Category 'static' -Name 'All exported functions use an approved PowerShell verb' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $bad = @()
    foreach ($c in (Get-Command -Module $script:Module -ErrorAction SilentlyContinue)) {
        if ($c.CommandType -ne 'Function') { continue }
        $verb = ($c.Name -split '-')[0]
        if (-not (Get-Verb $verb -ErrorAction SilentlyContinue)) { $bad += $c.Name }
    }
    foreach ($b in $bad) {
        $findings += ("{0}: 谓词未获批准，Import-Module 会输出警告 / unapproved verb (warning on every import)" -f $b)
    }
    $findings
}

# ── S22 API contract ──────────────────────────────────────────────────────
Invoke-Case -Id 'S22' -Category 'static' -Name 'Unknown setting names are rejected without touching the system' -Skip:(-not $script:ModuleOk) -SkipReason 'module import failed' -Body {
    $findings = @()
    $ghost = '__NO_SUCH_SETTING__'
    $v = Get-Value -Name $ghost
    if ($null -ne $v) {
        $findings += 'Get-Value 对未知设置名没有返回 $null'
    }
    $ok = Set-Value -Name $ghost -Value 1 -Scope 'AC'
    if ($ok -ne $false) {
        $findings += 'Set-Value 对未知设置名没有返回 $false（可能已执行原生写入）'
    }
    # An out-of-range value must not be silently truncated into a write.
    $r = Get-ProfileDefinition -ProfileKey 'max-perf'
    if ($null -eq $r -or -not $r.ContainsKey('AC')) { $findings += 'Get-ProfileDefinition 返回结构异常' }
    $findings
}

# ── S23 no hardcoded absolute local paths in shipped scripts ──────────────
Invoke-Case -Id 'S23' -Category 'static' -Name 'Shipped scripts contain no hardcoded absolute local paths' -Body {
    $findings = @()
    $notes = @()
    foreach ($f in $script:RepoFiles) {
        $parsed = Get-ParsedFile -Path $f.FullName
        $strs = $parsed.Ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
        foreach ($s in $strs) {
            if ($s.Value -notmatch '^[A-Za-z]:\\') { continue }
            if ($s.Value -match '\$env:') { continue }
            $msg = "硬编码绝对路径 / hardcoded absolute path '{0}'" -f $s.Value
            if ($f.DirectoryName -eq $script:RepoRoot) {
                $findings += (Fmt-Finding $f.FullName $s.Extent.StartLineNumber $msg)
            } else {
                $notes += (Fmt-Finding $f.FullName $s.Extent.StartLineNumber ($msg + ' (dev helper, informational)'))
            }
        }
    }
    return @{ Findings = $findings; Notes = $notes }
}

# ── S24 no PowerShell scriptblock used as a thread delegate ───────────────
Invoke-Case -Id 'S24' -Category 'static' -Name 'No scriptblock is cast to a thread/delegate type (fatal at runtime)' -Body {
    <#
        A [scriptblock] can only be converted to a delegate if a runspace is
        available on the executing thread. Handing one to [Threading.Thread]
        kills the whole pwsh process with an unhandled
        PSInvalidOperationException ("no runspace available in this thread") -
        it is not catchable, so a try/catch in the shipped code cannot save it.
        Detect the pattern statically instead of trying to run it.
    #>
    $findings = @()
    $delegateish = @('ThreadStart', 'ParameterizedThreadStart', 'WaitCallback',
        'Action', 'Func', 'TimerCallback', 'AsyncCallback', 'WaitOrTimerCallback')
    foreach ($f in $script:RepoFiles) {
        $parsed = Get-ParsedFile -Path $f.FullName
        $casts = $parsed.Ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] }, $true)
        foreach ($c in $casts) {
            if ($c.Child -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            # TypeName.Name is the literal as written, e.g. 'Threading.ThreadStart'
            # for [Threading.ThreadStart] - compare on the final segment.
            $typeName = $c.Type.TypeName.Name
            $leaf = ($typeName -split '\.')[-1]
            if ($delegateish -notcontains $leaf) { continue }
            $findings += (Fmt-Finding $f.FullName $c.Extent.StartLineNumber (
                '脚本块被强转为线程/委托 [{0}]，运行时会以致命错误终止进程 / scriptblock cast to delegate [{0}] - fatal at runtime' -f $typeName))
        }
    }
    $findings
}

# ══════════════════════════════════════════════════════════════════════════
#endregion
#region 4. RUNTIME TESTS
# ══════════════════════════════════════════════════════════════════════════

Write-Head ''
Write-Head '── RUNTIME (needs admin; never touches the active scheme) ─────────────'

$runtimeAllowed = (-not $NoRuntime) -and ($script:IsAdmin -or $ForceRuntime)
$runtimeSkipReason = if ($NoRuntime) { '-NoRuntime' }
elseif (-not $script:IsAdmin) { '未提权 / not elevated (re-run from an elevated pwsh, or pass -ForceRuntime)' }
else { '' }

if (-not $runtimeAllowed) {
    Write-Sub ("  !! RUNTIME GROUP SKIPPED: {0}" -f $runtimeSkipReason)
}

# ── R01 read-only sweep ───────────────────────────────────────────────────
Invoke-Case -Id 'R01' -Category 'runtime' -Name 'Get-Value reads every setting on the active scheme (read-only)' `
    -Skip:(-not $runtimeAllowed -or -not $script:ModuleOk) `
    -SkipReason $(if (-not $runtimeAllowed) { $runtimeSkipReason } else { 'module import failed' }) -Body {
    $findings = @()
    $notes = @()
    $readable = @()
    $unreadable = @()
    $declaredUnavailable = @()
    $declaredWritable = @()

    foreach ($k in $script:Settings.Keys) {
        $v = Get-Value -Name $k
        if ($null -ne $v.AC -or $null -ne $v.DC) { $readable += $k } else { $unreadable += $k }
        if ($script:Settings[$k].V -eq '不可用' -and ($null -ne $v.AC -or $null -ne $v.DC)) { $declaredUnavailable += $k }
        if ($script:Settings[$k].V -eq '验证' -and $null -eq $v.AC) { $declaredWritable += $k }
    }

    if ($unreadable.Count) {
        $findings += ('读取失败 / unreadable on the active scheme: {0}' -f ($unreadable -join ', '))
    }
    if ($declaredUnavailable.Count) {
        $findings += ('标记为「不可用」但实际可读 / marked 不可用 in $Script:Settings yet readable: {0} - metadata is stale' -f ($declaredUnavailable -join ', '))
    }
    if ($declaredWritable.Count) {
        $findings += ('标记为「验证」（可写）但读不到 / marked writable yet unreadable: {0}' -f ($declaredWritable -join ', '))
    }
    $notes += ('{0}/{1} settings readable' -f $readable.Count, $script:Settings.Count)
    return @{ Findings = $findings; Notes = $notes }
}

# ── R02 throwaway-scheme round trip ───────────────────────────────────────
Invoke-Case -Id 'R02' -Category 'runtime' -Name 'Write/read-back/restore round trip on a throwaway duplicated scheme' `
    -Skip:(-not $runtimeAllowed -or -not $script:ModuleOk) `
    -SkipReason $(if (-not $runtimeAllowed) { $runtimeSkipReason } else { 'module import failed' }) -Body {
    $findings = @()
    $notes = @()
    $tmpGuid = $null
    $activeBefore = Get-ActiveScheme

    try {
        # 1. Create an isolated scheme to experiment on.
        $base = $script:Scheme['Balanced']
        $r = Invoke-PowerCfg -Arguments @('/duplicatescheme', $base)
        if (-not $r.Ok) { throw ("powercfg /duplicatescheme 失败: {0}" -f $r.Output) }
        $m = [regex]::Match($r.Output, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
        if (-not $m.Success) { throw ("无法解析临时方案 GUID: {0}" -f $r.Output) }
        $tmpGuid = $m.Groups[1].Value.ToLower()

        # 2. Hard guard: never operate on the active scheme.
        if ($tmpGuid -eq $activeBefore) { throw '临时方案 GUID 与当前激活方案相同，拒绝继续 / refusing: throwaway GUID equals active scheme' }
        if (-not (Get-SchemeList).ContainsKey($tmpGuid)) { throw '临时方案未出现在 /list 中' }

        # 3. Round trip a representative slice of the whitelist.
        $probes = @('PROCTHROTTLEMIN', 'PROCTHROTTLEMAX', 'PERFEPP', 'PERFBOOSTMODE', 'CPMINCORES')
        foreach ($name in $probes) {
            if (-not $script:Settings.Contains($name)) { continue }
            $before = Get-Value -Name $name -SchemeGuid $tmpGuid
            if ($null -eq $before.AC) {
                $findings += ("{0}: 临时方案上读取失败（无法验证往返）/ unreadable on throwaway scheme" -f $name)
                continue
            }
            $orig = [int]$before.AC
            $probe = if ($orig -lt 100) { $orig + 1 } else { $orig - 1 }
            $wrote = Set-Value -Name $name -Value $probe -Scope 'AC' -SchemeGuid $tmpGuid
            if (-not $wrote) {
                $findings += ("{0}: 写入 {1} 后回读不一致（Set-Value 返回 false）/ write+readback mismatch" -f $name, $probe)
            } else {
                $after = Get-Value -Name $name -SchemeGuid $tmpGuid
                if ($null -eq $after.AC -or [int]$after.AC -ne $probe) {
                    $findings += ("{0}: 回读 {1} ≠ 写入 {2} / read-back mismatch" -f $name, $after.AC, $probe)
                }
            }
            # restore
            $restored = Set-Value -Name $name -Value $orig -Scope 'AC' -SchemeGuid $tmpGuid
            $final = Get-Value -Name $name -SchemeGuid $tmpGuid
            if (-not $restored -or $null -eq $final.AC -or [int]$final.AC -ne $orig) {
                $findings += ("{0}: 还原失败，期望 {1} 实得 {2} / restore failed" -f $name, $orig, $final.AC)
            }
        }

        # 4. DC round trip on one setting (exercises the DC P/Invoke path).
        $dcName = 'PROCTHROTTLEMAX'
        $beforeDc = Get-Value -Name $dcName -SchemeGuid $tmpGuid
        if ($null -ne $beforeDc.DC) {
            $origDc = [int]$beforeDc.DC
            $probeDc = if ($origDc -lt 100) { $origDc + 1 } else { $origDc - 1 }
            $okDc = Set-Value -Name $dcName -Value $probeDc -Scope 'DC' -SchemeGuid $tmpGuid
            if (-not $okDc) { $findings += ('{0} (DC): 写入回读不一致' -f $dcName) }
            [void](Set-Value -Name $dcName -Value $origDc -Scope 'DC' -SchemeGuid $tmpGuid)
            $finalDc = Get-Value -Name $dcName -SchemeGuid $tmpGuid
            if ($null -eq $finalDc.DC -or [int]$finalDc.DC -ne $origDc) {
                $findings += ('{0} (DC): 还原失败，期望 {1} 实得 {2}' -f $dcName, $origDc, $finalDc.DC)
            }
        } else {
            $notes += ('{0} (DC) unreadable on throwaway scheme; DC path not exercised' -f $dcName)
        }
    } catch {
        $findings += ('运行时测试异常 / runtime test error: {0}' -f $_.Exception.Message)
    } finally {
        # 5. Always remove the throwaway scheme.
        if ($tmpGuid) {
            $del = Invoke-PowerCfg -Arguments @('/delete', $tmpGuid)
            if (-not $del.Ok) {
                $findings += ('临时方案删除失败 / failed to delete throwaway scheme {0}: {1}' -f $tmpGuid, $del.Output)
            }
            Start-Sleep -Milliseconds 200
            if ((Get-SchemeList).ContainsKey($tmpGuid)) {
                $findings += ('临时方案仍存在 / throwaway scheme {0} still present after delete' -f $tmpGuid)
            }
        }
        $activeAfter = Get-ActiveScheme
        if ($activeAfter -ne $activeBefore) {
            $findings += ('激活方案被改变 / active scheme changed: {0} -> {1}' -f $activeBefore, $activeAfter)
        }
    }

    $notes += ('throwaway scheme {0} created and deleted; active scheme unchanged ({1})' -f $tmpGuid, $activeBefore)
    return @{ Findings = $findings; Notes = $notes }
}

# ══════════════════════════════════════════════════════════════════════════
#endregion
#region 5. Summary
# ══════════════════════════════════════════════════════════════════════════

$script:Clock.Stop()

$pass = @($script:Results | Where-Object Status -eq 'PASS').Count
$fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
$skip = @($script:Results | Where-Object Status -eq 'SKIP').Count
$total = $script:Results.Count

Write-Host ''
Write-Head '═══ SUMMARY ═══'

$script:Results |
    Select-Object Id, Category, Status, @{ n = 'Test'; e = { $_.Name } }, @{ n = '#F'; e = { $_.Findings.Count } } |
    Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host

if ($fail -gt 0) {
    Write-Head '─── FAILURES ───'
    foreach ($r in ($script:Results | Where-Object Status -eq 'FAIL')) {
        Write-Host ("[{0}] {1}" -f $r.Id, $r.Name) -ForegroundColor Red
        foreach ($f in $r.Findings) { Write-Host ("    - {0}" -f $f) -ForegroundColor Yellow }
    }
    Write-Host ''
}

$skipList = @($script:Results | Where-Object Status -eq 'SKIP')
if ($skipList.Count) {
    Write-Head '─── SKIPPED ───'
    foreach ($r in $skipList) {
        Write-Host ("[{0}] {1}  ->  {2}" -f $r.Id, $r.Name, ($r.Notes -join '; ')) -ForegroundColor DarkGray
    }
    Write-Host ''
}

if ($script:Notes.Count) {
    Write-Head '─── NOTES ───'
    foreach ($n in $script:Notes) { Write-Sub ("  · {0}" -f $n) }
    Write-Host ''
}

$verdictColor = if ($fail -gt 0) { 'Red' } else { 'Green' }
$line = '  TOTAL {0}   PASS {1}   FAIL {2}   SKIP {3}   ({4:N1}s)' -f $total, $pass, $fail, $skip, $script:Clock.Elapsed.TotalSeconds
if ($script:UseColor) { Write-Host $line -ForegroundColor $verdictColor } else { Write-Host $line }

if ($fail -gt 0) {
    Write-Host ''
    if ($script:UseColor) { Write-Host '  RESULT: FAILED' -ForegroundColor Red } else { Write-Host '  RESULT: FAILED' }
    exit 1
} else {
    Write-Host ''
    if ($script:UseColor) { Write-Host '  RESULT: OK' -ForegroundColor Green } else { Write-Host '  RESULT: OK' }
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════
#endregion

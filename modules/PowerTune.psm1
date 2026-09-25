<#
.SYNOPSIS
    PowerSettingsExplorer 性能自动调整 —— 原生 API 公共库
.DESCRIPTION
    复刻 PowerSettingsExplorer 的访问通路：直接调用 powrprof.dll 的
    PowerRead/WriteAC/DCValueIndex，而不是 powercfg.exe。

    为什么必须这样做：
      本机（以及多数 OEM 精简电源策略机器）的 powercfg /query 只认「方案已承载」
      的设置，对注册表中存在但方案未实例化的隐藏项一律返回「指定的电源方案、子组或
      设置不存在」。实测同一 GUID：
        powercfg /query SUB_PROCESSOR be337238-...  → 报不存在
        PowerReadACValueIndex(同 GUID)              → rc=0, value=2
      因此基于 powercfg 的脚本会静默跳过全部 Turbo / EPP / 核心停放设置。

    本机实测：34 项候选中 29 项可读可写（见 _ref\writable-test.csv）。
.NOTES
    需要管理员权限。Windows 10 / 11。
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

#region ── 原生 API 包装 ─────────────────────────────────────────────────

$Script:PwrSrc = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PwrNative {
    [DllImport("powrprof.dll")]
    public static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);
    [DllImport("powrprof.dll")]
    public static extern uint PowerSetActiveScheme(IntPtr root, ref Guid scheme);
    [DllImport("powrprof.dll")]
    public static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid set, out uint v);
    [DllImport("powrprof.dll")]
    public static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid set, out uint v);
    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteACValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid set, uint v);
    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid set, uint v);
    [DllImport("powrprof.dll")]
    public static extern uint PowerReadSettingAttributes(ref Guid sub, ref Guid set);
    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteSettingAttributes(ref Guid sub, ref Guid set, uint attr);
    [DllImport("powrprof.dll", CharSet = CharSet.Unicode)]
    public static extern uint PowerReadFriendlyName(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid set, StringBuilder buf, ref uint size);

    public static Guid ActiveScheme() {
        IntPtr p;
        uint rc = PowerGetActiveScheme(IntPtr.Zero, out p);
        if (rc != 0) throw new Exception("PowerGetActiveScheme failed rc=" + rc);
        Guid g = (Guid)Marshal.PtrToStructure(p, typeof(Guid));
        Marshal.FreeHGlobal(p);
        return g;
    }
    public static int SetActive(Guid s) { return (int)PowerSetActiveScheme(IntPtr.Zero, ref s); }

    public static string ReadAC(Guid s, Guid sub, Guid set) {
        uint v; uint rc = PowerReadACValueIndex(IntPtr.Zero, ref s, ref sub, ref set, out v);
        return rc == 0 ? v.ToString() : "ERR:" + rc;
    }
    public static string ReadDC(Guid s, Guid sub, Guid set) {
        uint v; uint rc = PowerReadDCValueIndex(IntPtr.Zero, ref s, ref sub, ref set, out v);
        return rc == 0 ? v.ToString() : "ERR:" + rc;
    }
    public static int WriteAC(Guid s, Guid sub, Guid set, uint v) {
        return (int)PowerWriteACValueIndex(IntPtr.Zero, ref s, ref sub, ref set, v);
    }
    public static int WriteDC(Guid s, Guid sub, Guid set, uint v) {
        return (int)PowerWriteDCValueIndex(IntPtr.Zero, ref s, ref sub, ref set, v);
    }
    public static uint Attributes(Guid sub, Guid set) { return PowerReadSettingAttributes(ref sub, ref set); }
    public static int SetAttributes(Guid sub, Guid set, uint attr) { return (int)PowerWriteSettingAttributes(ref sub, ref set, attr); }

    public static string LocalName(Guid s, Guid sub, Guid set) {
        uint size = 512;
        StringBuilder sb = new StringBuilder(512);
        uint rc = PowerReadFriendlyName(IntPtr.Zero, ref s, ref sub, ref set, sb, ref size);
        return rc == 0 ? sb.ToString() : "";
    }
}
'@

if (-not ('PwrNative' -as [type])) {
    Add-Type -TypeDefinition $Script:PwrSrc -ErrorAction Stop
}

#endregion

#region ── GUID 常量 ─────────────────────────────────────────────────────

$Script:SubGroup = @{
    PROCESSOR  = '54533251-82be-4824-96c1-47b60b740d00'
    DISK       = '0012ee47-9041-4b5d-9b77-535fba8b1442'
    PCIEXPRESS = '501a4d13-42af-4429-9fd1-a8218c268e20'
    USB        = '2a737441-1930-4402-8d77-b2bebba308a3'
    SLEEP      = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    VIDEO      = '7516b95f-f776-4464-8c53-06167f40cc99'
    GRAPHICS   = '5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c'
    BUTTONS    = '4f971e89-eebd-4455-a8de-9e59040e7347'
    BATTERY    = 'e73a048d-bf27-4f12-9731-8b2076e8891f'
    IS         = '48672f38-7a9a-4bb2-8bf8-3d85be19de4e'
    PRESENCE   = '8619b916-e004-4dd8-9b66-dae86f806698'
}

$Script:Scheme = @{
    Balanced   = '381b4222-f694-41f0-9685-ff5bb260df2e'
    HighPerf   = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    PowerSaver = 'a1841308-3541-4fab-bc81-f71556f20b4a'
}

#endregion

#region ── 设置表（GUID 全部经本机读写往返验证） ─────────────────────────

$Script:Settings = [ordered]@{

    # ══ 处理器性能提升 ══
    PERFBOOSTMODE   = @{ Guid='be337238-0d82-4146-a960-4f3749d470c7'; Group='PROCESSOR'
                         Desc='性能提升模式 0禁用/1启用/2激进'; V='验证' }
    PERFBOOSTPOL    = @{ Guid='45bcc044-d885-43e2-8605-ee0ec6e96b59'; Group='PROCESSOR'
                         Desc='性能提升策略'; V='验证' }

    # ══ 能效偏好 ══
    PERFEPP         = @{ Guid='36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; Group='PROCESSOR'
                         Desc='能效偏好EPP 0纯性能→100纯节能'; V='验证' }
    PERFEPP1        = @{ Guid='36687f9e-e3a5-4dbf-b1dc-15eb381c6864'; Group='PROCESSOR'
                         Desc='EPP（能效类1）'; V='验证' }

    # ══ 核心停放 ══
    CPMINCORES      = @{ Guid='0cc5b647-c1df-4637-891a-dec35c318583'; Group='PROCESSOR'
                         Desc='最小停放核心% 100=禁止停放'; V='验证' }
    CPMAXCORES      = @{ Guid='ea062031-0e34-4ff1-9b6d-eb1059334028'; Group='PROCESSOR'
                         Desc='最大停放核心%'; V='验证' }
    CPCONCURRENCY   = @{ Guid='2430ab6f-a520-44a2-9601-f7f23b5134b1'; Group='PROCESSOR'
                         Desc='停放并发阈值'; V='验证' }
    CPHEADROOM      = @{ Guid='f735a673-2066-4f80-a0c5-ddee0cf1bf5d'; Group='PROCESSOR'
                         Desc='停放并发余量阈值'; V='验证' }
    CPLATENCYHINTUNPARK = @{ Guid='616cdaa5-695e-4545-97ad-97dc2d1bdd88'; Group='PROCESSOR'
                         Desc='延迟提示最少解停核心数'; V='验证' }

    # ══ 异构调度（大小核）══
    PERFHETERO      = @{ Guid='7f2f5cfa-f10c-4823-b5e1-e93ae85f46b5'; Group='PROCESSOR'
                         Desc='异构调度策略 0自动/4优先P核'; V='验证' }
    PERFAUTONOMOUS  = @{ Guid='8baa4a8a-14c6-4451-8e8b-14bdbd197537'; Group='PROCESSOR'
                         Desc='性能自主模式'; V='验证' }

    # ══ 频率缩放 ══
    PROCTHROTTLEMIN = @{ Guid='893dee8e-2bef-41e0-89c6-b55d0929964c'; Group='PROCESSOR'
                         Desc='最小处理器状态%'; V='验证' }
    PROCTHROTTLEMAX = @{ Guid='bc5038f7-23e0-4960-96da-33abaf5935ec'; Group='PROCESSOR'
                         Desc='最大处理器状态%'; V='验证' }
    THROTTLEMIN_EC1 = @{ Guid='893dee8e-2bef-41e0-89c6-b55d0929964d'; Group='PROCESSOR'
                         Desc='最小处理器状态%（能效类1）'; V='验证' }
    THROTTLEMAX_EC1 = @{ Guid='bc5038f7-23e0-4960-96da-33abaf5935ed'; Group='PROCESSOR'
                         Desc='最大处理器状态%（能效类1）'; V='验证' }
    PERFINCPOL      = @{ Guid='465e1f50-b610-473a-ab58-00d1077dc418'; Group='PROCESSOR'
                         Desc='升频策略 0保守/1激进/2常时'; V='验证' }
    PERFDECPOL      = @{ Guid='40fbefc7-2e9d-4d25-a185-0cfd8574bac6'; Group='PROCESSOR'
                         Desc='降频策略 0保守/1激进'; V='验证' }
    PERFINCTHRESHOLD= @{ Guid='06cadf0e-64ed-448a-8927-ce7bf90eb35d'; Group='PROCESSOR'
                         Desc='升频阈值'; V='验证' }
    PERFDECTHRESHOLD= @{ Guid='12a0ab44-fe28-4fa9-b3bd-4b64f44960a6'; Group='PROCESSOR'
                         Desc='降频阈值'; V='验证' }
    PERFLATENCYSENSITIVITY = @{ Guid='619b7505-003b-4e82-b7a6-4dd29c300971'; Group='PROCESSOR'
                         Desc='延迟敏感度提示'; V='验证' }
    MAXFREQ         = @{ Guid='75b0ae3f-bce0-45a7-8c89-c9611c25e100'; Group='PROCESSOR'
                         Desc='最大处理器频率MHz 0=不限制'; V='验证' }

    # ══ 空闲与散热 ══
    IDLEDISABLE     = @{ Guid='5d76a2ca-e8c0-402f-a133-2158492d58ad'; Group='PROCESSOR'
                         Desc='空闲禁用 1=禁止深度空闲'; V='验证' }
    SYSCOOLING      = @{ Guid='94d3a615-a899-4ac5-ae2b-e4d8f634367f'; Group='PROCESSOR'
                         Desc='系统散热策略 0被动/1主动'; V='验证' }
    ALLOWTHROTTLE   = @{ Guid='3b04d4fd-1cc7-4f23-ab1c-d1337819c4bb'; Group='PROCESSOR'
                         Desc='允许节流状态'; V='验证' }
    DUTYCYCLING     = @{ Guid='4e4450b3-6179-4e91-b8f1-5bb9938f81a1'; Group='PROCESSOR'
                         Desc='处理器占空比 0禁用/1启用'; V='验证' }
    PERFRESOURCEPRIORITY = @{ Guid='603fe9ce-8d01-4b48-a968-1d706c28fd5c'; Group='PROCESSOR'
                         Desc='处理器资源优先级'; V='验证' }

    # ══ 本机只读 / 不可用（保留记录，写入会被拒并记为 Fail）══
    PERFINCTIME     = @{ Guid='984cf492-3bed-4488-a8f9-4286c97bf5aa'; Group='PROCESSOR'
                         Desc='升频时间（本机只读）'; V='只读' }
    PERFDECTIME     = @{ Guid='d8edeb9b-95cf-4f95-a73c-b061973693c8'; Group='PROCESSOR'
                         Desc='降频时间（本机只读）'; V='只读' }
    PERFTIME        = @{ Guid='4d2b0152-7d5c-498b-88e2-34345392a2c5'; Group='PROCESSOR'
                         Desc='性能检查间隔（本机只读）'; V='只读' }
    HETEROSCHED     = @{ Guid='93b8b6dc-0698-4d1c-9ee4-0644e900c85d'; Group='PROCESSOR'
                         Desc='异构线程调度策略（本机不可读）'; V='不可用' }
}

# 本机可写白名单（来自 _ref\writable-test.csv 实测）
$Script:Writable = @(
    'PERFBOOSTMODE','PERFBOOSTPOL','PERFEPP','PERFEPP1',
    'CPMINCORES','CPMAXCORES','CPCONCURRENCY','CPHEADROOM','CPLATENCYHINTUNPARK',
    'PERFHETERO','PERFAUTONOMOUS',
    'PROCTHROTTLEMIN','PROCTHROTTLEMAX','THROTTLEMIN_EC1','THROTTLEMAX_EC1',
    'PERFINCPOL','PERFDECPOL','PERFINCTHRESHOLD','PERFDECTHRESHOLD',
    'PERFLATENCYSENSITIVITY','MAXFREQ',
    'IDLEDISABLE','SYSCOOLING','ALLOWTHROTTLE','DUTYCYCLING','PERFRESOURCEPRIORITY'
)

#endregion

#region ── 三档配置（数值语义取自本机实测取值范围） ────────────────────

$Script:Profiles = @{
    'balanced-stable' = @{
        Title = '稳定本(日常/办公)'
        Clone = 'PSE-Stable'
        AC = @{
            PERFBOOSTMODE='2'; PERFBOOSTPOL='2'; PERFEPP='50'; PERFEPP1='50'
            CPMINCORES='25'; CPMAXCORES='100'; PERFHETERO='4'; PERFAUTONOMOUS='1'
            PROCTHROTTLEMIN='5'; PROCTHROTTLEMAX='100'
            THROTTLEMIN_EC1='5'; THROTTLEMAX_EC1='100'
            PERFINCPOL='0'; PERFDECPOL='0'
            PERFINCTHRESHOLD='60'; PERFDECTHRESHOLD='20'
            PERFLATENCYSENSITIVITY='50'
            SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='0'
            MAXFREQ='0'; PERFRESOURCEPRIORITY='100'
        }
        DC = @{
            PERFBOOSTMODE='1'; PERFBOOSTPOL='1'; PERFEPP='70'; PERFEPP1='70'
            CPMINCORES='50'; CPMAXCORES='100'; PERFHETERO='0'; PERFAUTONOMOUS='1'
            PROCTHROTTLEMIN='5'; PROCTHROTTLEMAX='80'
            THROTTLEMIN_EC1='5'; THROTTLEMAX_EC1='80'
            PERFINCPOL='0'; PERFDECPOL='0'
            PERFLATENCYSENSITIVITY='50'
            SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='0'; MAXFREQ='0'
        }
    }

    'max-perf' = @{
        Title = '极致版(游戏/渲染/低延迟)'
        Clone = 'PSE-Extreme'
        AC = @{
            PERFBOOSTMODE='2'; PERFBOOSTPOL='2'; PERFEPP='0'; PERFEPP1='0'
            CPMINCORES='100'; CPMAXCORES='100'
            CPCONCURRENCY='100'; CPHEADROOM='100'; CPLATENCYHINTUNPARK='100'
            PERFHETERO='4'; PERFAUTONOMOUS='0'
            PROCTHROTTLEMIN='100'; PROCTHROTTLEMAX='100'
            THROTTLEMIN_EC1='100'; THROTTLEMAX_EC1='100'
            PERFINCPOL='2'; PERFDECPOL='0'
            PERFINCTHRESHOLD='20'; PERFDECTHRESHOLD='60'
            PERFLATENCYSENSITIVITY='100'
            IDLEDISABLE='0'; SYSCOOLING='1'; ALLOWTHROTTLE='2'
            DUTYCYCLING='0'; MAXFREQ='0'; PERFRESOURCEPRIORITY='100'
        }
        DC = @{
            PERFBOOSTMODE='2'; PERFBOOSTPOL='2'; PERFEPP='10'; PERFEPP1='10'
            CPMINCORES='100'; CPMAXCORES='100'
            CPCONCURRENCY='100'; CPHEADROOM='100'; CPLATENCYHINTUNPARK='100'
            PERFHETERO='4'; PERFAUTONOMOUS='0'
            PROCTHROTTLEMIN='50'; PROCTHROTTLEMAX='100'
            THROTTLEMIN_EC1='50'; THROTTLEMAX_EC1='100'
            PERFINCPOL='2'; PERFDECPOL='0'
            PERFLATENCYSENSITIVITY='100'
            SYSCOOLING='1'; ALLOWTHROTTLE='2'; MAXFREQ='0'
        }
    }

    'eco' = @{
        Title = '节能版(续航/移动办公)'
        Clone = 'PSE-Eco'
        AC = @{
            PERFBOOSTMODE='1'; PERFBOOSTPOL='1'; PERFEPP='80'; PERFEPP1='80'
            CPMINCORES='50'; CPMAXCORES='100'; PERFHETERO='0'; PERFAUTONOMOUS='1'
            PROCTHROTTLEMIN='5'; PROCTHROTTLEMAX='85'
            THROTTLEMIN_EC1='5'; THROTTLEMAX_EC1='85'
            PERFINCPOL='0'; PERFDECPOL='1'
            PERFINCTHRESHOLD='60'; PERFDECTHRESHOLD='20'
            PERFLATENCYSENSITIVITY='0'
            SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='0'
            MAXFREQ='0'; PERFRESOURCEPRIORITY='100'
        }
        DC = @{
            PERFBOOSTMODE='0'; PERFBOOSTPOL='0'; PERFEPP='100'; PERFEPP1='100'
            CPMINCORES='70'; CPMAXCORES='100'; PERFHETERO='0'; PERFAUTONOMOUS='1'
            PROCTHROTTLEMIN='5'; PROCTHROTTLEMAX='60'
            THROTTLEMIN_EC1='5'; THROTTLEMAX_EC1='60'
            PERFINCPOL='0'; PERFDECPOL='1'
            PERFLATENCYSENSITIVITY='0'
            SYSCOOLING='1'; ALLOWTHROTTLE='2'; IDLEDISABLE='1'; MAXFREQ='0'
        }
    }
}

#endregion

#region ── 基础设施 ─────────────────────────────────────────────────────

function Test-Admin {
    [CmdletBinding()] param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) { throw 'PowerTune 需要管理员权限，请以管理员身份运行 PowerShell。' }
}

function Get-WorkRoot {
    $root = Join-Path $env:ProgramData 'PSE-PowerTuner'
    foreach ($d in @($root, "$root\backup", "$root\log", "$root\reports")) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $root
}

function Write-TuneLog {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR','SKIP')][string]$Level = 'INFO')
    $line = '{0}  [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path (Join-Path (Get-WorkRoot) 'log\powertune.log') -Value $line -Encoding UTF8 } catch { }
    $color = switch ($Level) {
        'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'SKIP' { 'DarkGray' } 'OK' { 'Green' } default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Invoke-PowerCfg {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & powercfg.exe @Arguments 2>&1
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ($out -join "`n") }
}

#endregion

#region ── 读写核心（全部走 powrprof） ──────────────────────────────────

function Get-SettingSubGroup {
    param([Parameter(Mandatory)][string]$Name)
    [Guid]$Script:SubGroup[$Script:Settings[$Name].Group]
}

function Get-SettingGuid {
    param([Parameter(Mandatory)][string]$Name)
    [Guid]$Script:Settings[$Name].Guid
}

function Get-Value {
    <#  读取指定方案下某设置的 AC / DC 值；失败返回 $null  #>
    param([Parameter(Mandatory)][string]$Name, [string]$SchemeGuid)
    if (-not $Script:Settings.Contains($Name)) { return $null }

    $s  = if ($SchemeGuid) { [Guid]$SchemeGuid } else { [PwrNative]::ActiveScheme() }
    $sg = Get-SettingSubGroup $Name
    $st = Get-SettingGuid $Name

    $ac = [PwrNative]::ReadAC($s, $sg, $st)
    $dc = [PwrNative]::ReadDC($s, $sg, $st)
    [pscustomobject]@{
        AC    = if ($ac -like 'ERR:*') { $null } else { [int]$ac }
        DC    = if ($dc -like 'ERR:*') { $null } else { [int]$dc }
        ACErr = if ($ac -like 'ERR:*') { $ac } else { $null }
        DCErr = if ($dc -like 'ERR:*') { $dc } else { $null }
    }
}

function Set-Value {
    <#  写入设置的 AC/DC 值；返回 $true 表示写入并回读校验通过  #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value,
        [ValidateSet('AC','DC')][string]$Scope = 'AC',
        [string]$SchemeGuid
    )
    if (-not $Script:Settings.Contains($Name)) { return $false }

    $s  = if ($SchemeGuid) { [Guid]$SchemeGuid } else { [PwrNative]::ActiveScheme() }
    $sg = Get-SettingSubGroup $Name
    $st = Get-SettingGuid $Name

    $rc = if ($Scope -eq 'AC') {
        [PwrNative]::WriteAC($s, $sg, $st, [uint32]$Value)
    } else {
        [PwrNative]::WriteDC($s, $sg, $st, [uint32]$Value)
    }
    if ($rc -ne 0) { return $false }

    $back = if ($Scope -eq 'AC') {
        [PwrNative]::ReadAC($s, $sg, $st)
    } else {
        [PwrNative]::ReadDC($s, $sg, $st)
    }
    return ($back -eq "$Value")
}

function Test-Writable {
    <#  实测某设置在本机是否可写（写探测值并还原） #>
    param([Parameter(Mandatory)][string]$Name, [string]$SchemeGuid)
    $cur = Get-Value -Name $Name -SchemeGuid $SchemeGuid
    if ($null -eq $cur.AC) { return $false }
    $orig  = $cur.AC
    $probe = if ($orig -eq 0) { 1 } else { 0 }
    $ok = Set-Value -Name $Name -Value $probe -Scope 'AC' -SchemeGuid $SchemeGuid
    [void](Set-Value -Name $Name -Value $orig -Scope 'AC' -SchemeGuid $SchemeGuid)
    return $ok
}

function Get-ProfileDefinition {
    param([Parameter(Mandatory)][ValidateSet('balanced-stable','max-perf','eco')][string]$ProfileKey)
    $Script:Profiles[$ProfileKey]
}

function Get-ProfileList { @('balanced-stable','max-perf','eco') }
function Get-KnownSettings { $Script:Settings }
function Get-WritableSettings { $Script:Writable }

function Get-HardwareProfile {
    <#  探测硬件特征，用于自动选档  #>
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem

    # 排除 WMI 中名为 "Notebook" 的伪电池设备
    $bats = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue |
              Where-Object { $_.DeviceID -notlike '*Notebook*' -and $_.DeviceID -notlike '*Microsoft*' })

    $nvme = $false
    try {
        $nvme = @(Get-PhysicalDisk -ErrorAction SilentlyContinue |
                  Where-Object { $_.BusType -eq 'NVMe' }).Count -gt 0
    } catch { }

    $isVM = ($cs.Model -match 'Virtual|VMware|KVM|Hyper-V|Parallels') -or
            ($cs.Manufacturer -match 'VMware' -and $cs.Model -match 'Virtual')

    $name = [string]$cpu.Name
    # 大小核：12 代及以后 Intel 桌面/移动、Core Ultra、骁龙 X
    $hetero = ($name -match 'Core Ultra') -or
              ($name -match 'i[3579]-1[2-9]\d{3}') -or
              ($name -match 'Snapdragon.*X')

    [pscustomobject]@{
        CPU      = $name
        Cores    = [int]$cpu.NumberOfCores
        Logical  = [int]$cpu.NumberOfLogicalProcessors
        Hetero   = $hetero
        NVMe     = $nvme
        IsLaptop = ($bats.Count -gt 0)
        IsVM     = $isVM
        RAMGB    = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        OS       = $os.Caption
    }
}

function Resolve-Profile {
    <#  按硬件特征自动选档  #>
    param($Hw)
    if ($Hw.IsVM)                               { return 'balanced-stable' }
    if ($Hw.Hetero -and $Hw.Cores -ge 10)       { return 'max-perf' }
    if ($Hw.Cores -ge 8 -and -not $Hw.IsLaptop) { return 'max-perf' }
    if ($Hw.IsLaptop -and $Hw.Cores -le 6)      { return 'eco' }
    return 'balanced-stable'
}

#endregion

#region ── 方案管理 ─────────────────────────────────────────────────────

function Get-SchemeList {
    $ids = @{}
    foreach ($l in (& powercfg.exe /list)) {
        $m = [regex]::Match($l,
            '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*\((.*?)\)')
        if ($m.Success) { $ids[$m.Groups[1].Value.ToLower()] = $m.Groups[2].Value.Trim() }
    }
    $ids
}

function Get-ActiveScheme { ([PwrNative]::ActiveScheme()).ToString().ToLower() }

function Find-SchemeByName {
    param([Parameter(Mandatory)][string]$FriendlyName)
    foreach ($kv in (Get-SchemeList).GetEnumerator()) {
        if ($kv.Value -eq $FriendlyName) { return $kv.Key }
    }
    return $null
}

function New-PowerScheme {
    param(
        [Parameter(Mandatory)][string]$FriendlyName,
        [Parameter(Mandatory)][string]$BaseGuid
    )
    $exist = Find-SchemeByName -FriendlyName $FriendlyName
    if ($exist) { return $exist }

    $r = Invoke-PowerCfg -Arguments @('-duplicatescheme', $BaseGuid)
    if (-not $r.Ok) { throw "复制方案失败（基底 $BaseGuid）: $($r.Output)" }
    $m = [regex]::Match($r.Output,
        '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if (-not $m.Success) { throw "无法解析新方案 GUID: $($r.Output)" }
    $guid = $m.Groups[1].Value.ToLower()
    Invoke-PowerCfg -Arguments @('/changename', $guid, $FriendlyName) | Out-Null
    Write-TuneLog "新建方案 $FriendlyName -> $guid" 'OK'
    return $guid
}

function Set-ActiveScheme {
    param([Parameter(Mandatory)][string]$SchemeGuid)
    $g = [Guid]$SchemeGuid
    if ([PwrNative]::SetActive($g) -ne 0) {
        Invoke-PowerCfg -Arguments @('/setactive', $SchemeGuid) | Out-Null
    }
    Invoke-PowerCfg -Arguments @('/S', $SchemeGuid) | Out-Null
    Write-TuneLog "已激活方案 $SchemeGuid" 'OK'
}

function Enable-HiddenSettings {
    <#  清除隐藏标志（attribute bit0 = 1 表示隐藏） #>
    $n = 0
    foreach ($name in $Script:Settings.Keys) {
        $sg = Get-SettingSubGroup $name
        $st = Get-SettingGuid $name
        $attr = [PwrNative]::Attributes($sg, $st)
        if (($attr -band 1) -eq 1) {
            if ([PwrNative]::SetAttributes($sg, $st, ($attr -band (-bnot 1))) -eq 0) { $n++ }
        }
    }
    Write-TuneLog "已取消隐藏 $n 项设置" 'OK'
}

#endregion

#region ── 备份 / 回滚 ──────────────────────────────────────────────────

function Export-PowerSnapshot {
    param([string]$Tag = 'manual')
    $root  = Get-WorkRoot
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir   = Join-Path $root "backup\$stamp-$Tag"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $list = Get-SchemeList
    $i = 0
    foreach ($g in $list.Keys) {
        $i++
        $safe = ($list[$g] -replace '[^\w\u4e00-\u9fa5-]', '_')
        if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'scheme' }
        Invoke-PowerCfg -Arguments @('/export', (Join-Path $dir ("{0:d2}_{1}.pow" -f $i, $safe)), $g) | Out-Null
    }

    # 原生 API 快照每个方案的每项设置值（唯一可靠的还原依据）
    $snapshot = @{}
    foreach ($g in $list.Keys) {
        $vals = @{}
        foreach ($name in $Script:Settings.Keys) {
            $v = Get-Value -Name $name -SchemeGuid $g
            if ($null -ne $v.AC) { $vals["$name|AC"] = $v.AC }
            if ($null -ne $v.DC) { $vals["$name|DC"] = $v.DC }
        }
        $snapshot[$g] = $vals
    }
    $snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dir 'values.json') -Encoding UTF8

    $active = Get-ActiveScheme
    [pscustomobject]@{
        Tag          = $Tag
        Stamp        = $stamp
        Dir          = $dir
        ActiveScheme = $active
        ActiveName   = if ($list.ContainsKey($active)) { $list[$active] } else { '' }
        SchemeCount  = $i
        Schemes      = $list
        CreatedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $dir 'manifest.json') -Encoding UTF8

    Write-TuneLog "已备份 $i 个方案 + 全部设置值 -> $dir" 'OK'
    return $dir
}

function Import-PowerSnapshot {
    param([Parameter(Mandatory)][string]$BackupDir)
    if (-not (Test-Path $BackupDir)) { throw "备份目录不存在: $BackupDir" }
    $n = 0
    foreach ($f in (Get-ChildItem $BackupDir -Filter '*.pow' | Sort-Object Name)) {
        $r = Invoke-PowerCfg -Arguments @('/import', $f.FullName)
        if ($r.Ok) { $n++ } else { Write-TuneLog "导入失败 $($f.Name): $($r.Output)" 'WARN' }
    }
    Write-TuneLog "导入 $n 个方案" 'OK'
    return $n
}

function Restore-SnapshotValues {
    <#  从备份目录的 values.json 还原设置值 #>
    param([Parameter(Mandatory)][string]$BackupDir)
    $f = Join-Path $BackupDir 'values.json'
    if (-not (Test-Path $f)) { Write-TuneLog '备份中无 values.json，跳过值还原' 'WARN'; return 0 }

    $data = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $n = 0; $fail = 0
    foreach ($scheme in $data.PSObject.Properties.Name) {
        if (-not (Get-SchemeList).ContainsKey($scheme)) { continue }
        foreach ($kv in $data.$scheme.PSObject.Properties) {
            $parts = $kv.Name -split '\|'
            if (Set-Value -Name $parts[0] -Value ([int]$kv.Value) -Scope $parts[1] -SchemeGuid $scheme) { $n++ }
            else { $fail++ }
        }
    }
    Write-TuneLog "值还原完成：成功 $n，失败 $fail" 'OK'
    return $n
}

function Restore-PowerDefaults {
    Invoke-PowerCfg -Arguments @('-restoredefaultschemes') | Out-Null
    Write-TuneLog '已恢复 Windows 默认电源方案' 'OK'
}

#endregion

#region ── 应用与对比 ───────────────────────────────────────────────────

function Get-ProfileDiff {
    param(
        [Parameter(Mandatory)][ValidateSet('balanced-stable','max-perf','eco')][string]$ProfileKey,
        [string]$SchemeGuid
    )
    $p = $Script:Profiles[$ProfileKey]
    foreach ($name in ($p.AC.Keys | Sort-Object)) {
        $cur    = Get-Value -Name $name -SchemeGuid $SchemeGuid
        $target = [int]$p.AC[$name]
        [pscustomobject]@{
            Setting   = $name
            Desc      = $Script:Settings[$name].Desc
            Current   = if ($null -ne $cur.AC) { $cur.AC } else { '—' }
            Target    = $target
            Supported = ($null -ne $cur.AC)
            Match     = ($null -ne $cur.AC -and $cur.AC -eq $target)
        }
    }
}

function Apply-Profile {
    <#  备份 → 克隆 → 取消隐藏 → 逐项写入(原生API) → 激活 → 回读校验 #>
    param(
        [Parameter(Mandatory)][ValidateSet('balanced-stable','max-perf','eco')][string]$ProfileKey,
        [switch]$IncludeDC,
        [switch]$NoActivate,
        [switch]$SkipBackup
    )
    Assert-Admin
    $p = $Script:Profiles[$ProfileKey]

    Write-Host "`n═══ 应用配置档：$($p.Title) ═══`n" -ForegroundColor Cyan

    if (-not $SkipBackup) {
        $bk = Export-PowerSnapshot -Tag "before-$ProfileKey"
        Write-Host "备份: $bk`n" -ForegroundColor DarkGray
    }

    Enable-HiddenSettings

    $base = switch ($ProfileKey) {
        'max-perf' { $Script:Scheme.HighPerf }
        'eco'      { $Script:Scheme.PowerSaver }
        default    { $Script:Scheme.Balanced }
    }
    $guid = New-PowerScheme -FriendlyName $p.Clone -BaseGuid $base

    $ok = 0; $fail = @()

    Write-Host '── 交流(AC) ──' -ForegroundColor Yellow
    foreach ($name in ($p.AC.Keys | Sort-Object)) {
        $v = [int]$p.AC[$name]
        if (Set-Value -Name $name -Value $v -Scope 'AC' -SchemeGuid $guid) {
            Write-TuneLog ("OK    {0,-22} AC = {1,-4} {2}" -f $name, $v, $Script:Settings[$name].Desc) 'OK'
            $ok++
        } else {
            Write-TuneLog ("Fail  {0,-22} AC = {1,-4} 本机不支持或写入被拒" -f $name, $v) 'SKIP'
            $fail += "$name/AC"
        }
    }

    if ($IncludeDC) {
        Write-Host "`n── 电池(DC) ──" -ForegroundColor Yellow
        foreach ($name in ($p.DC.Keys | Sort-Object)) {
            $v = [int]$p.DC[$name]
            if (Set-Value -Name $name -Value $v -Scope 'DC' -SchemeGuid $guid) {
                Write-TuneLog ("OK    {0,-22} DC = {1,-4} {2}" -f $name, $v, $Script:Settings[$name].Desc) 'OK'
                $ok++
            } else {
                Write-TuneLog ("Fail  {0,-22} DC = {1,-4} 本机不支持或写入被拒" -f $name, $v) 'SKIP'
                $fail += "$name/DC"
            }
        }
    } else {
        Write-Host "`n（未指定 -IncludeDC：电池档保持基底方案默认）" -ForegroundColor DarkGray
    }

    if (-not $NoActivate) { Set-ActiveScheme -SchemeGuid $guid }

    Write-Host "`n完成：写入并校验通过 $ok 项，失败 $(@($fail).Count) 项。" -ForegroundColor Green
    if (@($fail).Count -gt 0) {
        Write-Host "失败项: $($fail -join ', ')" -ForegroundColor DarkGray
    }

    [pscustomobject]@{
        Profile    = $ProfileKey
        Title      = $p.Title
        SchemeGuid = $guid
        Applied    = $ok
        Failed     = @($fail).Count
        FailedList = @($fail)
    }
}

#endregion

Export-ModuleMember -Function *

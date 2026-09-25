# 探测验证：确认 powrprof 原生 API 的写入能力边界
# 目的：为三档脚本确定「本机真实可写」的设置集合
$ErrorActionPreference = 'Stop'

$src = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PwrApi {
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
    [DllImport("powrprof.dll")]
    public static extern uint PowerEnumerate(IntPtr root, IntPtr scheme, IntPtr sub, uint access, uint idx, IntPtr buf, ref uint size);

    public static Guid Active() {
        IntPtr p; uint rc = PowerGetActiveScheme(IntPtr.Zero, out p);
        if (rc != 0) throw new Exception("PowerGetActiveScheme rc=" + rc);
        Guid g = (Guid)Marshal.PtrToStructure(p, typeof(Guid));
        Marshal.FreeHGlobal(p);
        return g;
    }
    public static uint WriteAC(Guid s, Guid sub, Guid set, uint v) { return PowerWriteACValueIndex(IntPtr.Zero, ref s, ref sub, ref set, v); }
    public static uint WriteDC(Guid s, Guid sub, Guid set, uint v) { return PowerWriteDCValueIndex(IntPtr.Zero, ref s, ref sub, ref set, v); }
    public static string ReadAC(Guid s, Guid sub, Guid set) {
        uint v; uint rc = PowerReadACValueIndex(IntPtr.Zero, ref s, ref sub, ref set, out v);
        return rc == 0 ? v.ToString() : "ERR" + rc;
    }
    public static string ReadDC(Guid s, Guid sub, Guid set) {
        uint v; uint rc = PowerReadDCValueIndex(IntPtr.Zero, ref s, ref sub, ref set, out v);
        return rc == 0 ? v.ToString() : "ERR" + rc;
    }
}
'@
Add-Type -TypeDefinition $src -ErrorAction Stop

$PROC = [Guid]'54533251-82be-4824-96c1-47b60b740d00'
$scheme = [PwrApi]::Active()
Write-Host "激活方案: $scheme`n" -ForegroundColor Cyan

# 待测设置表：名称 -> GUID
$table = [ordered]@{
  PERFBOOSTMODE        = 'be337238-0d82-4146-a960-4f3749d470c7'
  PERFBOOSTPOL         = '45bcc044-d885-43e2-8605-ee0ec6e96b59'
  PERFEPP              = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
  PERFEPP1             = '36687f9e-e3a5-4dbf-b1dc-15eb381c6864'
  CPMINCORES           = '0cc5b647-c1df-4637-891a-dec35c318583'
  CPMAXCORES           = 'ea062031-0e34-4ff1-9b6d-eb1059334028'
  CPCONCURRENCY        = '2430ab6f-a520-44a2-9601-f7f23b5134b1'
  CPHEADROOM           = 'f735a673-2066-4f80-a0c5-ddee0cf1bf5d'
  CPLATENCYHINTUNPARK  = '616cdaa5-695e-4545-97ad-97dc2d1bdd88'
  PERFHETERO           = '7f2f5cfa-f10c-4823-b5e1-e93ae85f46b5'
  PERFAUTONOMOUS       = '8baa4a8a-14c6-4451-8e8b-14bdbd197537'
  PERFINCPOL           = '465e1f50-b610-473a-ab58-00d1077dc418'
  PERFDECPOL           = '40fbefc7-2e9d-4d25-a185-0cfd8574bac6'
  PERFINCTIME          = '984cf492-3bed-4488-a8f9-4286c97bf5aa'
  PERFDECTIME          = 'd8edeb9b-95cf-4f95-a73c-b061973693c8'
  PERFINCTHRESHOLD     = '06cadf0e-64ed-448a-8927-ce7bf90eb35d'
  PERFDECTHRESHOLD     = '12a0ab44-fe28-4fa9-b3bd-4b64f44960a6'
  PERFTIME             = '4d2b0152-7d5c-498b-88e2-34345392a2c5'
  PERFLATENCYSENSITIVITY = '619b7505-003b-4e82-b7a6-4dd29c300971'
  IDLEDISABLE          = '5d76a2ca-e8c0-402f-a133-2158492d58ad'
  PROCTHROTTLEMIN      = '893dee8e-2bef-41e0-89c6-b55d0929964c'
  PROCTHROTTLEMAX      = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
  THROTTLEMIN_EC1      = '893dee8e-2bef-41e0-89c6-b55d0929964d'
  THROTTLEMAX_EC1      = 'bc5038f7-23e0-4960-96da-33abaf5935ed'
  MAXFREQ              = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'
  SYSCOOLING           = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'
  ALLOWTHROTTLE        = '3b04d4fd-1cc7-4f23-ab1c-d1337819c4bb'
  DUTYCYCLING          = '4e4450b3-6179-4e91-b8f1-5bb9938f81a1'
  IDLEPROMOTE          = '7b224883-b3cc-4d79-819f-8374152cbe7c'
  IDLEDEMOTE           = '4b92d758-5a24-4851-a470-815d78aee119'
  IDLEMAX              = '9943e905-9a30-4ec1-9b99-44dd3b76f7a2'
  PERFRESOURCEPRIORITY = '603fe9ce-8d01-4b48-a968-1d706c28fd5c'
  HETEROSCHED          = '93b8b6dc-0688-4d1c-9ee4-0644e900c85d'
  HETEROSCHED2         = '93b8b6dc-0668-4d1c-9ee4-0644e900c85d'
}

Write-Host "=== 逐项测试（读 → 写 → 回读）===" -ForegroundColor Cyan
$results = foreach($k in $table.Keys){
  $g = [Guid]$table[$k]
  $before = [PwrApi]::ReadAC($scheme, $PROC, $g)
  $attr   = [PwrApi]::PowerReadSettingAttributes([ref]$PROC, [ref]$g)
  $readable = ($before -notlike 'ERR*')
  $writable = $false; $after = $before
  if($readable){
    # 写入一个与当前不同的值以便验证
    $cur = [int]$before
    $testVal = if($cur -eq 0){ 1 } else { 0 }
    $rc = [PwrApi]::WriteAC($scheme, $PROC, $g, [uint32]$testVal)
    $after = [PwrApi]::ReadAC($scheme, $PROC, $g)
    $writable = ($rc -eq 0 -and $after -eq "$testVal")
    # 还原
    [void][PwrApi]::WriteAC($scheme, $PROC, $g, [uint32]$cur)
  }
  [pscustomobject]@{
    Name     = $k
    Guid     = $table[$k]
    可读     = $readable
    可写     = $writable
    原值     = $before
    隐藏     = (($attr -band 1) -eq 1)
  }
}
$results | Format-Table -AutoSize
$results | Export-Csv (Join-Path $PSScriptRoot 'writable-test.csv') -NoTypeInformation -Encoding UTF8
Write-Host "可读+可写: $(@($results | Where-Object { $_.可读 -and $_.可写 }).Count) / $($results.Count)" -ForegroundColor Green
Write-Host "已导出 _ref\writable-test.csv"

# github.com:443 被网络屏蔽时，通过 REST 对象 API 上传本地仓库内容。
# 流程：逐个文件建 blob → 建 tree → 建 commit → 建 ref
$ErrorActionPreference = 'Stop'

$RepoDir = 'C:\Users\hongx\Documents\jiebao\PSE-PowerTuner'
$Owner   = 'Zioove'
$Repo    = 'pse-powertuner'
$Branch  = 'main'
$GhExe   = 'C:\Program Files\GitHub CLI\gh.exe'

$skipFiles = @('_ref\PowerSettingsExplorer.exe', '_ref/PowerSettingsExplorer.exe')

function Invoke-Api {
    param([string]$Method, [string]$ApiPath, $Body)
    $callArgs = @('api', '--method', $Method, "repos/$Owner/$Repo/$ApiPath")
    $tmpf = $null
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $tmpf = Join-Path $env:TEMP "gh-api-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        [System.IO.File]::WriteAllText($tmpf, $json, (New-Object Text.UTF8Encoding($false)))
        $callArgs += @('--input', $tmpf)
    }
    $out = & $GhExe @callArgs 2>&1
    if ($tmpf) { Remove-Item $tmpf -Force -ErrorAction SilentlyContinue }
    if ($LASTEXITCODE -ne 0) { throw "API $Method $ApiPath 失败: $($out -join ' ')" }
    return (($out -join "`n") | ConvertFrom-Json)
}

Push-Location $RepoDir
try {
    $files = @(git ls-files)
    Write-Host "待上传文件 $($files.Count) 个`n" -ForegroundColor Cyan

    $entries = @()
    $i = 0
    foreach ($f in $files) {
        $i++
        if ($skipFiles -contains $f) { Write-Host "  跳过 $f" -ForegroundColor DarkGray; continue }
        $full = Join-Path $RepoDir $f
        if (-not (Test-Path $full)) { continue }
        $content = [System.IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)

        $blob = Invoke-Api -Method POST -ApiPath 'git/blobs' -Body @{
            content  = $content
            encoding = 'utf-8'
        }
        $entries += @{
            path = ($f -replace '\\','/')
            mode = '100644'
            type = 'blob'
            sha  = $blob.sha
        }
        Write-Host ("  [{0,2}/{1}] {2,-42} {3}" -f $i, $files.Count, $f, $blob.sha.Substring(0,8)) -ForegroundColor Green
    }

    Write-Host "`n建 tree ..." -ForegroundColor Cyan
    $tree = Invoke-Api -Method POST -ApiPath 'git/trees' -Body @{ tree = $entries }

    Write-Host "建 commit ..." -ForegroundColor Cyan
    $msg = @"
feat: PSE-PowerTuner — 基于 powrprof 原生 API 的三档电源性能调优

基于 PowerSettingsExplorer 逆向出的隐藏电源设置 GUID 表，通过 powrprof.dll
原生 API（而非 powercfg）读写 26 项处理器性能设置，提供稳定本/极致版/节能版三档。

关键发现：OEM 精简电源策略机器的 powercfg /query 只认「方案已承载」的设置，
对注册表中存在的隐藏项报「不存在」——同一 GUID 下 powercfg 失败而
PowerReadACValueIndex 返回 rc=0。因此纯 powercfg 的脚本会静默跳过全部
Turbo/EPP/核心停放设置。处理器子组注册表下有 95 项，powercfg 只显示 2 项。

实测：34 项候选中 26 项可写、3 项只读、1 项不可读；极致版端到端演练 47 项
全部通过 0 失败，节能版 41 项通过。
"@
    $commit = Invoke-Api -Method POST -ApiPath 'git/commits' -Body @{
        message = $msg
        tree    = $tree.sha
    }
    Write-Host ("  commit {0}  tree {1}" -f $commit.sha.Substring(0,8), $tree.sha.Substring(0,8)) -ForegroundColor Green

    Write-Host "`n更新 ref refs/heads/$Branch ..." -ForegroundColor Cyan
    $ref = Invoke-Api -Method PATCH -ApiPath "git/refs/heads/$Branch" -Body @{ sha = $commit.sha; force = $true }
    Write-Host ("  ref -> {0}" -f $ref.object.sha) -ForegroundColor Green
    Write-Host "`n完成。" -ForegroundColor Green
}
finally { Pop-Location }

# github.com:443 被网络屏蔽时，通过 REST 对象 API 上传本地仓库内容。
# 支持二进制文件（base64 编码），自动以远程当前 HEAD 为父节点追加新提交。
# 用法：设置 $env:PSE_COMMIT_MSG 后运行；不设则用默认提交信息。
$ErrorActionPreference = 'Stop'

$RepoDir = 'C:\Users\hongx\Documents\jiebao\PSE-PowerTuner'
$Owner   = 'Zioove'
$Repo    = 'pse-powertuner'
$Branch  = 'main'
$GhExe   = 'C:\Program Files\GitHub CLI\gh.exe'
$CommitMsg = $env:PSE_COMMIT_MSG
if (-not $CommitMsg) { $CommitMsg = 'chore: 同步本地变更' }

function Invoke-Api {
    param([string]$Method, [string]$ApiPath, $Body)
    $callArgs = @('api', '--method', $Method, "repos/$Owner/$Repo/$ApiPath")
    $tmpf = $null
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        $tmpf = Join-Path $env:TEMP "gh-api-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        # 必须无 BOM，否则 GitHub 报 Problems parsing JSON
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
    Write-Host "待上传 $($files.Count) 个文件" -ForegroundColor Cyan

    $parent = $null
    try {
        $parent = (& $GhExe api "repos/$Owner/$Repo/git/ref/heads/$Branch" --jq '.object.sha' 2>$null).Trim()
    } catch { }
    if ($parent) { Write-Host "父提交: $($parent.Substring(0,8))" -ForegroundColor DarkGray }

    $binExt = @('.exe','.zip','.png','.jpg','.jpeg','.gif','.ico','.pdf','.bin','.dll','.7z','.gz')
    $entries = @()
    $i = 0
    foreach ($f in $files) {
        $i++
        $full = Join-Path $RepoDir $f
        if (-not (Test-Path $full)) { continue }
        $rel = ($f -replace '\\','/')
        $isBin = $binExt -contains ([System.IO.Path]::GetExtension($f).ToLower())

        if ($isBin) {
            $b64  = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($full))
            $blob = Invoke-Api -Method POST -ApiPath 'git/blobs' -Body @{ content = $b64; encoding = 'base64' }
        } else {
            $txt  = [System.IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
            $blob = Invoke-Api -Method POST -ApiPath 'git/blobs' -Body @{ content = $txt; encoding = 'utf-8' }
        }
        $entries += @{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha }
        Write-Host ("  [{0,2}/{1}] {2,-40} {3}  {4}" -f $i, $files.Count, $rel, $blob.sha.Substring(0,8), $(if($isBin){'binary'}else{'text'})) -ForegroundColor Green
    }

    Write-Host "`n建 tree ..." -ForegroundColor Cyan
    $tree = Invoke-Api -Method POST -ApiPath 'git/trees' -Body @{ tree = $entries }

    Write-Host "建 commit ..." -ForegroundColor Cyan
    $body = @{ message = $CommitMsg; tree = $tree.sha }
    if ($parent) { $body.parents = @($parent) }
    $commit = Invoke-Api -Method POST -ApiPath 'git/commits' -Body $body
    Write-Host ("  commit {0}" -f $commit.sha.Substring(0,8)) -ForegroundColor Green

    Write-Host "更新 ref ..." -ForegroundColor Cyan
    $ref = Invoke-Api -Method PATCH -ApiPath "git/refs/heads/$Branch" -Body @{ sha = $commit.sha; force = $true }
    Write-Host ("  ref -> {0}" -f $ref.object.sha) -ForegroundColor Green
    Write-Host "`n完成。" -ForegroundColor Green
}
finally { Pop-Location }

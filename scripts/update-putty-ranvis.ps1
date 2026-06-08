# scripts/update-putty-ranvis.ps1
# PuTTY-ranvis ミラーリング＆マニフェスト更新（2リポジトリ構成対応／世代管理つき）
#
# 必要環境変数:
#   GH_REPO            : ミラー先＝マニフェストリポジトリ(A) "owner/repo"
#   GITHUB_TOKEN       : gh CLI 用トークン（A への release 書き込み権限が必要）
#   MANIFEST_REPO_DIR  : チェックアウト済みマニフェストリポジトリ(A)のローカルパス

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
. "$PSScriptRoot\_common.ps1"

# ---- 設定 ----------------------------------------------------------
$mirrorTag    = 'putty-ranvis-latest'
$keepVersions = 3
$browserUA    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$ghRepo       = $env:GH_REPO

$repoRoot   = Get-ManifestRepoRoot
$bucketPath = Join-Path $repoRoot "bucket"
$logDir     = Join-Path $repoRoot "logs"
$logFile    = Join-Path $logDir "update_log.txt"
$jsonPath   = Join-Path $bucketPath "putty-ranvis.json"
$date       = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName   = Split-Path $jsonPath -Leaf
$workDir    = Join-Path ([System.IO.Path]::GetTempPath()) "putty-ranvis-mirror"

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
function Write-Log($msg) { "$msg" | Out-File $logFile -Append -Encoding UTF8 }

try {
    Write-Log "$date - [PuTTY-ranvis] Mirror & Update Started"

    if (-not $ghRepo) { throw "Environment variable GH_REPO is not set." }

    # ---- 1) サイトから最新版情報を取得 -----------------------------
    $pageUrl = 'https://www.ranvis.com/putty'
    $html    = (Invoke-WebRequest -Uri $pageUrl -UserAgent $browserUA -UseBasicParsing).Content

    $m64 = [regex]::Match($html, 'PuTTY-(?<ver>[\d.]+)-ranvis-(?<date>\d{8})\.win64\.7z')
    $m32 = [regex]::Match($html, 'PuTTY-(?<ver>[\d.]+)-ranvis-(?<date>\d{8})\.win32\.zip')
    if (-not $m64.Success) { throw "Could not find win64 .7z link on the page." }

    $ver        = $m64.Groups['ver'].Value
    $dateStamp  = $m64.Groups['date'].Value
    $newVersion = "$ver.$dateStamp"

    $json       = Get-Content $jsonPath -Raw | ConvertFrom-Json
    $oldVersion = $json.version

    if ($newVersion -eq $oldVersion) {
        Write-Log "[$fileName] $newVersion (Up to date)"
        Write-Log "--------------------------------------------------"
        return
    }

    Write-Log "[$fileName] New version detected: $oldVersion -> $newVersion"

    # ---- 2) zip/7z を取得 -----------------------------------------
    if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
    New-Item -ItemType Directory -Path $workDir | Out-Null

    $srcBase = 'https://www.ranvis.com/downloads'
    $assets  = @()

    $name64 = "PuTTY-$ver-ranvis-$dateStamp.win64.7z"
    $path64 = Join-Path $workDir $name64
    Invoke-WebRequest -Uri "$srcBase/$name64" -UserAgent $browserUA -OutFile $path64 -UseBasicParsing
    $assets += $path64

    if ($m32.Success) {
        $ver32  = $m32.Groups['ver'].Value
        $date32 = $m32.Groups['date'].Value
        $name32 = "PuTTY-$ver32-ranvis-$date32.win32.zip"
        $path32 = Join-Path $workDir $name32
        Invoke-WebRequest -Uri "$srcBase/$name32" -UserAgent $browserUA -OutFile $path32 -UseBasicParsing
        $assets += $path32
    }

    # ---- 3) GitHubリリース(固定タグ)へミラー（ミラー先＝リポジトリA）---
    & gh release view $mirrorTag --repo $ghRepo *>&1 | Out-Null
    $relExists = ($LASTEXITCODE -eq 0)
    if (-not $relExists) {
        & gh release create $mirrorTag --repo $ghRepo `
            --title "PuTTY-ranvis mirror" `
            --notes "Auto-mirrored from https://www.ranvis.com/putty (User-Agent workaround for Scoop)."
        if ($LASTEXITCODE -ne 0) { throw "gh release create failed." }
    }

    & gh release upload $mirrorTag @assets --repo $ghRepo --clobber
    if ($LASTEXITCODE -ne 0) { throw "gh release upload failed." }
    Write-Log "[$fileName] Mirrored assets to $ghRepo (tag: $mirrorTag)"

    # ---- 4) マニフェスト更新 --------------------------------------
    $mirrorBase = "https://github.com/$ghRepo/releases/download/$mirrorTag"

    $json.version = $newVersion
    $json.architecture.'64bit'.url = "$mirrorBase/$name64"
    $json.architecture.'64bit'.psobject.Properties.Remove('hash')
    if ($m32.Success) {
        $json.architecture.'32bit'.url = "$mirrorBase/$name32"
        $json.architecture.'32bit'.psobject.Properties.Remove('hash')
    }

    $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
    Write-Log "[$fileName] Updated: $oldVersion -> $newVersion"

    # ---- 5) 古い世代のアセットを削除（$keepVersions 世代を残す）-----
    $assetJson = & gh release view $mirrorTag --repo $ghRepo --json assets 2>$null
    if ($LASTEXITCODE -eq 0 -and $assetJson) {
        $allAssets = ($assetJson | ConvertFrom-Json).assets

        $tagged = foreach ($a in $allAssets) {
            if ($a.name -match 'PuTTY-([\d.]+)-ranvis-(\d{8})\.(win64\.7z|win32\.zip)') {
                [PSCustomObject]@{
                    Name    = $a.name
                    VerKey  = "$($matches[1]).$($matches[2])"
                    Date    = [int]$matches[2]
                }
            }
        }

        $keepKeys = $tagged | Sort-Object Date -Descending |
                    Select-Object -ExpandProperty VerKey -Unique |
                    Select-Object -First $keepVersions

        $toDelete = $tagged | Where-Object { $keepKeys -notcontains $_.VerKey }

        foreach ($d in $toDelete) {
            & gh release delete-asset $mirrorTag $d.Name --repo $ghRepo --yes *>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "[$fileName] Deleted old asset: $($d.Name)"
            } else {
                Write-Log "[$fileName] WARNING: failed to delete asset: $($d.Name)"
            }
        }
    } else {
        Write-Log "[$fileName] WARNING: could not enumerate assets for cleanup."
    }

    Write-Log "--------------------------------------------------"
} catch {
    Write-Log "$date - [PuTTY-ranvis] Critical Error: $_"
    exit 1
} finally {
    if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}

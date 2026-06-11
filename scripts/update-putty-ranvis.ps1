# scripts/update-putty-ranvis.ps1
# PuTTY-ranvis ミラーリング＆マニフェスト更新（2リポジトリ構成対応／世代管理つき）
#
# 必要環境変数:
#   GH_REPO            : ミラー先＝マニフェストリポジトリ(A) "owner/repo"
#   GITHUB_TOKEN       : gh CLI 用トークン（A への release 書き込み権限が必要）
#   MANIFEST_REPO_DIR  : チェックアウト済みマニフェストリポジトリ(A)のローカルパス

# ErrorActionPreference は 'Continue' にしておき（デフォルト）、
# PowerShell cmdlets には -ErrorAction Stop を付けてエラー検知する。
# gh などのネイティブコマンドは $LASTEXITCODE で判定する。
$ProgressPreference    = 'SilentlyContinue'
. "$PSScriptRoot\_common.ps1"

# ---- 設定 ----------------------------------------------------------
$mirrorTag    = 'putty-ranvis-latest'
$keepVersions = 3
$browserUA    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$ghRepo       = $env:GH_REPO

$repoRoot   = Get-ManifestRepoRoot
$updaterRoot = Split-Path $PSScriptRoot -Parent
$bucketPath = Join-Path $repoRoot "bucket"
$logDir     = Join-Path $updaterRoot "logs"
$logFile    = Join-Path $logDir "update_log.txt"
$jsonPath   = Join-Path $bucketPath "putty-ranvis.json"
$date       = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName   = Split-Path $jsonPath -Leaf
$workDir    = Join-Path ([System.IO.Path]::GetTempPath()) "putty-ranvis-mirror"

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -ErrorAction Stop | Out-Null }

try {
    Write-Info "$date - [PuTTY-ranvis] Mirror & Update Started" $logFile

    if (-not $ghRepo) { throw "Environment variable GH_REPO is not set." }

    # ---- 1) サイトから最新版情報を取得 -----------------------------
    $pageUrl = 'https://www.ranvis.com/putty'
    Write-Info "[$fileName] Fetching $pageUrl ..." $logFile
    $html    = (Invoke-WebRequest -Uri $pageUrl -UserAgent $browserUA -UseBasicParsing -ErrorAction Stop).Content

    $m64 = [regex]::Match($html, 'PuTTY-(?<ver>[\d.]+)-ranvis-(?<date>\d{8})\.win64\.7z')
    $m32 = [regex]::Match($html, 'PuTTY-(?<ver>[\d.]+)-ranvis-(?<date>\d{8})\.win32\.zip')
    if (-not $m64.Success) { throw "Could not find win64 .7z link on the page." }

    $ver        = $m64.Groups['ver'].Value
    $dateStamp  = $m64.Groups['date'].Value
    $newVersion = "$ver.$dateStamp"

    $json       = Get-Content $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $oldVersion = $json.version

    Write-Info "[$fileName] Current=$oldVersion  Latest=$newVersion" $logFile

    # 期待されるミラーアセット名
    $expectedName64 = "PuTTY-$ver-ranvis-$dateStamp.win64.7z"

    # ミラー先に当該アセットが既に存在するか確認
    $assetExists = $false
    # $LASTEXITCODE を正しく取るため、2> $null で stderr を捨てる
    $assetJson = & gh release view $mirrorTag --repo $ghRepo --json assets 2>$null
    if ($LASTEXITCODE -eq 0 -and $assetJson) {
        $names = ($assetJson | ConvertFrom-Json).assets.name
        if ($names -contains $expectedName64) { $assetExists = $true }
    } else {
        Write-Info "[$fileName] Release '$mirrorTag' does not exist yet (will create)" $logFile
    }

    if (($newVersion -eq $oldVersion) -and $assetExists) {
        Write-Info "[$fileName] $newVersion (Up to date, mirror exists)" $logFile
        Write-Info "--------------------------------------------------" $logFile
        return
    }

    if ($newVersion -eq $oldVersion) {
        Write-Info "[$fileName] $newVersion (version same, but mirror missing -> re-mirroring)" $logFile
    } else {
        Write-Info "[$fileName] New version detected: $oldVersion -> $newVersion" $logFile
    }

    # ---- 2) zip/7z を取得 -----------------------------------------
    if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction Stop }
    New-Item -ItemType Directory -Path $workDir -ErrorAction Stop | Out-Null

    $srcBase = 'https://www.ranvis.com/downloads'
    $assets  = @()

    $name64 = "PuTTY-$ver-ranvis-$dateStamp.win64.7z"
    $path64 = Join-Path $workDir $name64
    Write-Info "[$fileName] Downloading $name64 ..." $logFile
    Invoke-WebRequest -Uri "$srcBase/$name64" -UserAgent $browserUA -OutFile $path64 -UseBasicParsing -ErrorAction Stop
    $assets += $path64

    if ($m32.Success) {
        $ver32  = $m32.Groups['ver'].Value
        $date32 = $m32.Groups['date'].Value
        $name32 = "PuTTY-$ver32-ranvis-$date32.win32.zip"
        $path32 = Join-Path $workDir $name32
        Write-Info "[$fileName] Downloading $name32 ..." $logFile
        Invoke-WebRequest -Uri "$srcBase/$name32" -UserAgent $browserUA -OutFile $path32 -UseBasicParsing -ErrorAction Stop
        $assets += $path32
    }

    # ---- 3) GitHubリリース(固定タグ)へミラー（ミラー先＝リポジトリA）---
    & gh release view $mirrorTag --repo $ghRepo 2>$null
    $relExists = ($LASTEXITCODE -eq 0)
    if (-not $relExists) {
        Write-Info "[$fileName] Creating release tag $mirrorTag ..." $logFile
        $createOut = & gh release create $mirrorTag --repo $ghRepo --title "PuTTY-ranvis mirror" --notes "Auto-mirrored from https://www.ranvis.com/putty (User-Agent workaround for Scoop)." 2>&1 | Out-String
        Write-Info "[$fileName] gh create output: $createOut" $logFile
        if ($LASTEXITCODE -ne 0) { throw "gh release create failed. Output: $createOut" }
    }

    Write-Info "[$fileName] Uploading assets to $ghRepo (tag: $mirrorTag) ..." $logFile
    $ghArgs = @('release', 'upload', $mirrorTag) + $assets + @('--repo', $ghRepo, '--clobber')
    $uploadOut = & gh $ghArgs 2>&1 | Out-String
    Write-Info "[$fileName] gh upload output: $uploadOut" $logFile
    if ($LASTEXITCODE -ne 0) { throw "gh release upload failed. Output: $uploadOut" }
    Write-Info "[$fileName] Mirrored assets to $ghRepo (tag: $mirrorTag)" $logFile

    # ---- 4) マニフェスト更新 --------------------------------------
    $mirrorBase = "https://github.com/$ghRepo/releases/download/$mirrorTag"

    Write-Info "[$fileName] Calculating hashes..." $logFile
    $json.version = $newVersion
    $json.architecture.'64bit'.url = "$mirrorBase/$name64"
    $hash64 = (Get-FileHash $path64 -Algorithm SHA256).Hash
    $json.architecture.'64bit' | Add-Member -MemberType NoteProperty -Name 'hash' -Value $hash64 -Force
    if ($m32.Success) {
        $json.architecture.'32bit'.url = "$mirrorBase/$name32"
        $hash32 = (Get-FileHash $path32 -Algorithm SHA256).Hash
        $json.architecture.'32bit' | Add-Member -MemberType NoteProperty -Name 'hash' -Value $hash32 -Force
    }

    $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii -ErrorAction Stop
    Write-Info "[$fileName] Updated: $oldVersion -> $newVersion" $logFile

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
            & gh release delete-asset $mirrorTag $d.Name --repo $ghRepo --yes 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Info "[$fileName] Deleted old asset: $($d.Name)" $logFile
            } else {
                Write-Info "[$fileName] WARNING: failed to delete asset: $($d.Name)" $logFile
            }
        }
    } else {
        Write-Info "[$fileName] WARNING: could not enumerate assets for cleanup." $logFile
    }

    Write-Info "--------------------------------------------------" $logFile
} catch {
    Write-Info "$date - [PuTTY-ranvis] ERROR: $_" $logFile
    Write-Host "::error::[PuTTY-ranvis] $_"
    throw
} finally {
    if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}

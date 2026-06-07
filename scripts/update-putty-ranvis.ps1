# scripts/update-putty-ranvis.ps1
# PuTTY-ranvis ミラーリング＆マニフェスト更新
# 必要env: GH_REPO ("owner/repo"), GH_TOKEN (gh CLI用)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$mirrorTag  = 'putty-ranvis-latest'
$browserUA  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$ghRepo     = $env:GH_REPO

if ($env:BUCKET_DIR) {
    $bucketPath = $env:BUCKET_DIR
} elseif ($env:SCOOP) {
    $bucketPath = "$env:SCOOP\buckets\my-bucket\bucket"
} else {
    $bucketPath = "$env:USERPROFILE\scoop\buckets\my-bucket\bucket"
}

$jsonPath = "$bucketPath\putty-ranvis.json"
$logFile  = "$bucketPath\update_log.txt"
$date     = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName = Split-Path $jsonPath -Leaf
$workDir  = Join-Path ([System.IO.Path]::GetTempPath()) "putty-ranvis-mirror"

function Write-Log($msg) { "$msg" | Out-File $logFile -Append -Encoding UTF8 }

try {
    Write-Log "$date - [PuTTY-ranvis] Mirror & Update Started"
    if (-not $ghRepo) { throw "Environment variable GH_REPO is not set." }

    # 1) 最新版情報を取得
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

    # 2) zip/7z 取得（ブラウザUA偽装）
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

    # 3) GitHub Release(固定タグ)へミラー
    & gh release view $mirrorTag --repo $ghRepo *>$null
    $relExists = ($LASTEXITCODE -eq 0)
    if (-not $relExists) {
        & gh release create $mirrorTag --repo $ghRepo `
            --title "PuTTY-ranvis mirror" `
            --notes "Auto-mirrored from https://www.ranvis.com/putty (UA workaround for Scoop)."
        if ($LASTEXITCODE -ne 0) { throw "gh release create failed." }
    }

    & gh release upload $mirrorTag @assets --repo $ghRepo --clobber
    if ($LASTEXITCODE -ne 0) { throw "gh release upload failed." }
    Write-Log "[$fileName] Mirrored assets to $ghRepo (tag: $mirrorTag)"

    # 4) マニフェスト更新（ミラーURLに向ける）
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
    Write-Log "--------------------------------------------------"
} catch {
    Write-Log "$date - [PuTTY-ranvis] Critical Error: $_"
    exit 1
} finally {
    if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}

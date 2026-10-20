# scripts/update-mame.ps1
# MAME マニフェスト更新（2リポジトリ構成対応）

$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\_common.ps1"

$repoRoot       = Get-ManifestRepoRoot
$updaterRoot    = Split-Path $PSScriptRoot -Parent
$bucketPath     = Join-Path $repoRoot "bucket"
$logDir         = Join-Path $updaterRoot "logs"
$logFile        = Join-Path $logDir "update_log.txt"
$jsonPath       = Join-Path $bucketPath "mame.json"
$date           = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName       = Split-Path $jsonPath -Leaf

# MAME の自己解凍 exe を 7z として展開させる Scoop 用サフィックス（公式マニフェストと同じ）
$urlSuffix      = '#/dl.7z'
$releaseApi     = 'https://api.github.com/repos/mamedev/mame/releases/latest'
$userAgent      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

try {
    Write-Info "$date - [MAME] Update Check Started" $logFile

    $headers = @{
        'User-Agent' = $userAgent
        'Accept'     = 'application/vnd.github+json'
    }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
    }

    $release = Invoke-RestMethod -Uri $releaseApi -Headers $headers -ErrorAction Stop

    # リリース名 "MAME 0.289" からバージョンを取得（タグは mame0289 形式）
    if ($release.name -match 'MAME\s+([\d.]+)') {
        $newVersion = $matches[1]
    } elseif ($release.tag_name -match '^mame(\d+)$') {
        # フォールバック: mame0289 -> 0.289
        $digits     = $matches[1]
        $newVersion = $digits.Substring(0, $digits.Length - 3) + '.' + $digits.Substring($digits.Length - 3)
    } else {
        throw "Could not determine version from release name '$($release.name)' / tag '$($release.tag_name)'."
    }
    $cleanVersion = $newVersion -replace '[._-]', ''

    $asset = $release.assets | Where-Object {
        $_.name -match '^mame\d+b?_(x64|64bit)\.exe$' -and $_.name -notmatch 'debug'
    } | Select-Object -First 1

    if (-not $asset) {
        $names = ($release.assets | Select-Object -ExpandProperty name) -join ', '
        throw "Windows x64 asset not found in release $($release.tag_name). Assets: $names"
    }

    $downloadUrl = $asset.browser_download_url
    $manifestUrl = "$downloadUrl$urlSuffix"

    $json       = Get-Content $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $oldVersion = $json.version

    Write-Info "[$fileName] Current=$oldVersion  Latest=$newVersion" $logFile

    if (($newVersion -eq $oldVersion) -and
        ($json.architecture.'64bit'.url -eq $manifestUrl) -and
        $json.architecture.'64bit'.hash) {
        Write-Info "[$fileName] $newVersion (Up to date)" $logFile
        Write-Info "--------------------------------------------------" $logFile
        return
    }

    if ($newVersion -ne $oldVersion) {
        Write-Info "[$fileName] New version detected: $oldVersion -> $newVersion" $logFile
    } else {
        Write-Info "[$fileName] URL changed for same version -> re-generating manifest entry" $logFile
    }
    Write-Info "[$fileName] Download URL: $manifestUrl" $logFile

    # ハッシュはリリース同梱の SHA256SUMS を優先（80MB超の本体ダウンロードを回避）
    $hash = $null
    $sumsAsset = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
    if ($sumsAsset) {
        try {
            $resp = Invoke-WebRequest -Uri $sumsAsset.browser_download_url -Headers @{ 'User-Agent' = $userAgent } -UseBasicParsing -ErrorAction Stop
            $text = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
            $pattern = '(?m)^([0-9a-fA-F]{64})[ \t]+\*?' + [regex]::Escape($asset.name) + '[ \t]*$'
            $m = [regex]::Match($text, $pattern)
            if ($m.Success) { $hash = $m.Groups[1].Value.ToLower() }
        } catch {
            Write-Info "[$fileName] WARNING: failed to read SHA256SUMS: $_" $logFile
        }
    }
    if (-not $hash) {
        Write-Info "[$fileName] SHA256SUMS unavailable; downloading asset to calculate hash..." $logFile
        $hash = Get-RemoteSha256 -Url $downloadUrl -UserAgent $userAgent
    }
    Write-Info "[$fileName] SHA256: $hash" $logFile

    $json.version = $newVersion
    $arch = $json.architecture.'64bit'
    $arch.url = $manifestUrl
    # hash が既にあれば位置を維持したまま更新、無ければ追加
    if ($arch.PSObject.Properties['hash']) {
        $arch.hash = $hash
    } else {
        $arch | Add-Member -MemberType NoteProperty -Name 'hash' -Value $hash
    }

    # autoupdate の URL テンプレートも現在のタグ/アセット名に合わせて自己修復
    if ($json.autoupdate.architecture.'64bit') {
        $assetTemplate = $asset.name.Replace($cleanVersion, '$cleanVersion')
        if ($release.tag_name.Contains($cleanVersion)) {
            $tagTemplate = $release.tag_name.Replace($cleanVersion, '$cleanVersion')
        } else {
            $tagTemplate = 'mame$cleanVersion'
        }
        $json.autoupdate.architecture.'64bit'.url = "https://github.com/mamedev/mame/releases/download/$tagTemplate/$assetTemplate$urlSuffix"
    }

    $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
    Write-Info "[$fileName] Updated: $oldVersion -> $newVersion" $logFile
    Write-Info "--------------------------------------------------" $logFile
} catch {
    Write-Info "$date - [MAME] ERROR: $_" $logFile
    Write-Host "::error::[MAME] $_"
    throw
}

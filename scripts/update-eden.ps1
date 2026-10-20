# scripts/update-eden.ps1
# Eden Nightly マニフェスト更新（2リポジトリ構成対応）
#
# バージョンは Gitea API の releases/latest の tag_name から取得する。
# 以前は checkver.ps1 の標準出力を正規表現で解析していたが、API エラー時に
# "Invoke-RestMethod: The remote server returned an error..." の "The" を
# バージョンとして誤採用する問題があったため、API を直接参照する方式に変更。
# 併せて $version / $commit の形式を検証し、不正値はマニフェストへ書き込まない。

$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\_common.ps1"

$repoRoot    = Get-ManifestRepoRoot
$updaterRoot = Split-Path $PSScriptRoot -Parent

$bucketPath = Join-Path $repoRoot "bucket"
$logDir     = Join-Path $updaterRoot "logs"
$logFile    = Join-Path $logDir "update_log.txt"
$jsonPath   = Join-Path $bucketPath "eden-nightly.json"
$date       = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName   = Split-Path $jsonPath -Leaf

$apiUrl          = 'https://git.eden-emu.dev/api/v1/repos/eden-ci/nightly/releases/latest'
$defaultTemplate = 'https://nightly.eden-emu.dev/v$version/Eden-Windows-$commit-amd64-clang-pgo.zip'
$userAgent       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

try {
    Write-Info "$date - [Eden] Update Check Started" $logFile

    $headers = @{
        'User-Agent' = $userAgent
        'Accept'     = 'application/json'
    }
    # Eden は第三者ホストのため GitHub トークンは送らない。
    # 必要なら EDEN_TOKEN (Gitea のアクセストークン) を明示的に渡した場合のみ使用する。
    if ($env:EDEN_TOKEN) {
        $headers['Authorization'] = "token $($env:EDEN_TOKEN)"
    }

    # 一時的なネットワークエラーに備えてリトライ（4xx は即座に失敗させる）
    $release    = $null
    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
            break
        } catch {
            $status = $null
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
            }
            $transient = (-not $status) -or ($status -ge 500) -or ($status -eq 429)
            if ((-not $transient) -or ($attempt -eq $maxRetries)) {
                throw "Failed to query Eden API ($apiUrl): $_"
            }
            Write-Info "[$fileName] API request failed (attempt $attempt/$maxRetries): $_" $logFile
            Start-Sleep -Seconds (5 * $attempt)
        }
    }

    # tag_name は "v1792353251.de7e6e01d4" 形式（Unix時刻 + コミットSHA）
    $tag = [string]$release.tag_name
    if ($tag -notmatch '^v?(\d+)\.([0-9a-fA-F]{7,40})$') {
        throw "Unexpected tag_name '$tag' in Eden release."
    }
    $versionPart = $matches[1]
    $commit      = $matches[2].ToLower()
    $newVersion  = "$versionPart.$commit"

    $json       = Get-Content $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $oldVersion = $json.version

    # URL テンプレート（旧 Gitea 配信パスは CDN へ自己修復）
    $storedTemplate = $json.autoupdate.architecture.'64bit'.url
    $urlTemplate    = $storedTemplate
    $needsMigration = $false
    if (-not $urlTemplate -or $urlTemplate -match 'git\.eden-emu\.dev/eden-ci/nightly/releases/download/') {
        $urlTemplate    = $defaultTemplate
        $needsMigration = $true
    }

    $newUrl     = $urlTemplate.Replace('$version', $newVersion).Replace('$commit', $commit)
    $currentUrl = $json.architecture.'64bit'.url

    Write-Info "[$fileName] Current=$oldVersion  Latest=$newVersion" $logFile

    if (($newVersion -eq $oldVersion) -and ($currentUrl -eq $newUrl) -and
        $json.architecture.'64bit'.hash -and -not $needsMigration) {
        Write-Info "[$fileName] $oldVersion (Up to date)" $logFile
        Write-Info "--------------------------------------------------" $logFile
        return
    }

    if ($newVersion -ne $oldVersion) {
        Write-Info "[$fileName] New version detected: $oldVersion -> $newVersion" $logFile
    } elseif ($needsMigration) {
        Write-Info "[$fileName] Old download domain detected, migrating to CDN..." $logFile
    } else {
        Write-Info "[$fileName] URL changed for same version -> re-generating manifest entry" $logFile
    }
    if ($needsMigration) {
        Write-Info "[$fileName] Migrated urlTemplate to CDN: $urlTemplate" $logFile
    }
    Write-Info "[$fileName] Download URL: $newUrl" $logFile
    Write-Info "[$fileName] Calculating hashes..." $logFile

    # 配信直後は CDN にアセットが未配置のことがあるため、失敗時は
    # マニフェストを変更せずに次回へ持ち越す（不正な URL を書き込まない）。
    $hash = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $hash = Get-RemoteSha256 -Url $newUrl -UserAgent $userAgent
            break
        } catch {
            if ($attempt -eq 3) {
                Write-Info "[$fileName] WARNING: asset not available yet, skipping this run: $_" $logFile
                Write-Host "::warning::[Eden] asset not available yet ($newUrl): $_"
                Write-Info "--------------------------------------------------" $logFile
                return
            }
            Write-Info "[$fileName] Download failed (attempt $attempt/3): $_" $logFile
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    Write-Info "[$fileName] SHA256: $hash" $logFile

    $json.version = $newVersion
    $json.autoupdate.architecture.'64bit'.url = $urlTemplate

    $arch = $json.architecture.'64bit'
    $arch.url = $newUrl
    if ($arch.PSObject.Properties['hash']) {
        $arch.hash = $hash
    } else {
        $arch | Add-Member -MemberType NoteProperty -Name 'hash' -Value $hash
    }

    $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
    Write-Info "[$fileName] Updated: $oldVersion -> $newVersion" $logFile
    Write-Info "--------------------------------------------------" $logFile
} catch {
    Write-Info "$date - [Eden] ERROR: $_" $logFile
    Write-Host "::error::[Eden] $_"
    throw
}
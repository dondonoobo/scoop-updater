# scripts/update-fbneo.ps1
# FinalBurn Neo (Nightly) マニフェスト更新（2リポジトリ構成対応）
#
# バージョンは GitHub の rolling release "latest" の target_commitish（コミットSHA）から取得する。
# 以前は checkver.ps1 の標準出力を正規表現で解析していたが、API エラー時に
# "Invoke-RestMethod: The remote server returned an error..." の "The" を
# バージョンとして誤採用する問題があったため、API を直接参照する方式に変更。

$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\_common.ps1"

$repoRoot    = Get-ManifestRepoRoot          # ← マニフェストリポジトリ(A)
$updaterRoot = Split-Path $PSScriptRoot -Parent

$bucketPath = Join-Path $repoRoot "bucket"
$logDir     = Join-Path $updaterRoot "logs"
$logFile    = Join-Path $logDir "update_log.txt"
$jsonPath   = Join-Path $bucketPath "fbneo-nightly.json"
$date       = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName   = Split-Path $jsonPath -Leaf

$apiUrl    = 'https://api.github.com/repos/finalburnneo/FBNeo/releases/tags/latest'
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

try {
    Write-Info "$date - [FBNeo] Update Check Started" $logFile

    $headers = @{
        'User-Agent' = $userAgent
        'Accept'     = 'application/vnd.github+json'
    }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
    }

    # 一時的なネットワーク/レート制限エラーに備えてリトライ
    $release   = $null
    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
            break
        } catch {
            if ($attempt -eq $maxRetries) {
                throw "Failed to query GitHub API ($apiUrl): $_"
            }
            Write-Info "[$fileName] API request failed (attempt $attempt/$maxRetries): $_" $logFile
            Start-Sleep -Seconds (5 * $attempt)
        }
    }

    # target_commitish は通常 40桁のコミットSHA。先頭7桁をバージョンとして使用する。
    $sha = [string]$release.target_commitish
    if ($sha -notmatch '^[0-9a-fA-F]{7,40}$') {
        throw "Unexpected target_commitish '$sha' in release '$($release.tag_name)'."
    }
    $newVersion = $sha.Substring(0, 7).ToLower()

    $json       = Get-Content $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $oldVersion = $json.version

    Write-Info "[$fileName] Current=$oldVersion  Latest=$newVersion" $logFile

    if ($newVersion -eq $oldVersion) {
        Write-Info "[$fileName] $oldVersion (Up to date)" $logFile
        Write-Info "--------------------------------------------------" $logFile
        return
    }

    Write-Info "[$fileName] New version detected: $oldVersion -> $newVersion" $logFile

    $json.version = $newVersion

    foreach ($arch in '64bit', '32bit') {
        $node = $json.architecture.$arch
        if (-not $node -or -not $node.url) { continue }

        $url = $node.url
        Write-Info "[$fileName] Calculating hash for $arch ($url)..." $logFile
        $hash = Get-RemoteSha256 -Url $url -UserAgent $userAgent
        Write-Info "[$fileName] $arch SHA256: $hash" $logFile

        if ($node.PSObject.Properties['hash']) {
            $node.hash = $hash
        } else {
            $node | Add-Member -MemberType NoteProperty -Name 'hash' -Value $hash
        }
    }

    $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
    Write-Info "[$fileName] Updated: $oldVersion -> $newVersion" $logFile
    Write-Info "--------------------------------------------------" $logFile
} catch {
    Write-Info "$date - [FBNeo] ERROR: $_" $logFile
    Write-Host "::error::[FBNeo] $_"
    throw
}
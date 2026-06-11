# scripts/update-eden.ps1
# Eden Nightly マニフェスト更新（2リポジトリ構成対応）

$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\_common.ps1"

$repoRoot       = Get-ManifestRepoRoot
$updaterRoot    = Split-Path $PSScriptRoot -Parent
$checkverScript = Get-CheckverScript

$bucketPath = Join-Path $repoRoot "bucket"
$logDir     = Join-Path $updaterRoot "logs"
$logFile    = Join-Path $logDir "update_log.txt"
$jsonPath   = Join-Path $bucketPath "eden-nightly.json"
$date       = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName   = Split-Path $jsonPath -Leaf

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

try {
    Write-Info "$date - [Eden] Update Check Started" $logFile

    $checkOutput = & $checkverScript $jsonPath -NoColors *>&1 | Out-String

    if ($checkOutput -match '(?m)^\s*[\w-]+:\s+([^\s\r\n]+)') {
        $newVersion = $matches[1]
        $json       = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $oldVersion = $json.version

        if ($newVersion -ne $oldVersion) {
            $json.version = $newVersion

            $commit = if ($newVersion -match '\.([0-9a-f]+)$') { $matches[1] } else { $newVersion }

            $urlTemplate = $json.autoupdate.architecture.'64bit'.url
            $newUrl = $urlTemplate.Replace('$version', $newVersion).Replace('$commit', $commit)
            $json.architecture.'64bit'.url = $newUrl

            $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii

            $checkhashesScript = Get-CheckhashesScript
            Write-Info "[$fileName] Calculating hashes..." $logFile
            & $checkhashesScript $jsonPath *>&1 | Out-Null
            Write-Info "[$fileName] Updated: $oldVersion -> $newVersion" $logFile
        } else {
            Write-Info "[$fileName] $newVersion (Up to date)" $logFile
        }
    } else {
        Write-Info "[$fileName] WARNING: could not parse checkver output" $logFile
        Write-Info "[$fileName] checkver raw output: $checkOutput" $logFile
    }

    Write-Info "--------------------------------------------------" $logFile
} catch {
    Write-Info "$date - [Eden] ERROR: $_" $logFile
    Write-Host "::error::[Eden] $_"
    throw
}

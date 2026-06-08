# scripts/update-eden.ps1
# Eden Nightly マニフェスト更新（2リポジトリ構成対応）

$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\_common.ps1"

$repoRoot       = Get-ManifestRepoRoot
$checkverScript = Get-CheckverScript

$bucketPath = Join-Path $repoRoot "bucket"
$logDir     = Join-Path $repoRoot "logs"
$logFile    = Join-Path $logDir "update_log.txt"
$jsonPath   = Join-Path $bucketPath "eden-nightly.json"
$date       = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName   = Split-Path $jsonPath -Leaf

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

try {
    "$date - [Eden] Update Check Started" | Out-File $logFile -Append -Encoding UTF8

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
            $json.architecture.'64bit'.psobject.Properties.Remove('hash')

            $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
            "[$fileName] Updated: $oldVersion -> $newVersion" | Out-File $logFile -Append -Encoding UTF8
        } else {
            "[$fileName] $newVersion (Up to date)" | Out-File $logFile -Append -Encoding UTF8
        }
    } else {
        "[$fileName] WARNING: could not parse checkver output" | Out-File $logFile -Append -Encoding UTF8
    }

    "--------------------------------------------------" | Out-File $logFile -Append -Encoding UTF8
} catch {
    "$date - [Eden] Critical Error: $_" | Out-File $logFile -Append -Encoding UTF8
}

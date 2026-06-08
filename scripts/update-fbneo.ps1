# scripts/update-fbneo.ps1
# FinalBurn Neo (Nightly) マニフェスト更新（2リポジトリ構成対応）

$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\_common.ps1"

$repoRoot       = Get-ManifestRepoRoot          # ← マニフェストリポジトリ(A)
$checkverScript = Get-CheckverScript

$bucketPath = Join-Path $repoRoot "bucket"
$logDir     = Join-Path $repoRoot "logs"
$logFile    = Join-Path $logDir "update_log.txt"
$jsonPath   = Join-Path $bucketPath "fbneo-nightly.json"
$date       = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName   = Split-Path $jsonPath -Leaf

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

try {
    "$date - [FBNeo] Update Check Started" | Out-File $logFile -Append -Encoding UTF8

    $checkOutput = & $checkverScript $jsonPath -NoColors *>&1 | Out-String

    if ($checkOutput -match '(?m)^\s*[\w-]+:\s+([^\s\r\n]+)') {
        $newVersion = $matches[1]
        $json       = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $oldVersion = $json.version

        if ($newVersion -ne $oldVersion) {
            $json.version = $newVersion

            foreach ($arch in '64bit', '32bit') {
                if ($json.architecture.$arch) {
                    $json.architecture.$arch.psobject.Properties.Remove('hash')
                }
            }

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
    "$date - [FBNeo] Critical Error: $_" | Out-File $logFile -Append -Encoding UTF8
}

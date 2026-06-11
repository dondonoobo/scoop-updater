# scripts/update-fbneo.ps1
# FinalBurn Neo (Nightly) マニフェスト更新（2リポジトリ構成対応）

$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\_common.ps1"

$repoRoot       = Get-ManifestRepoRoot          # ← マニフェストリポジトリ(A)
$updaterRoot    = Split-Path $PSScriptRoot -Parent
$checkverScript = Get-CheckverScript

$bucketPath = Join-Path $repoRoot "bucket"
$logFolderName = if ($env:GITHUB_ACTIONS) { "logs" } else { "local_logs" }
$logDir     = Join-Path $updaterRoot $logFolderName
$logFile    = Join-Path $logDir "update_log.txt"
$jsonPath   = Join-Path $bucketPath "fbneo-nightly.json"
$date       = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName   = Split-Path $jsonPath -Leaf

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

try {
    Write-Info "$date - [FBNeo] Update Check Started" $logFile

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
    Write-Info "$date - [FBNeo] ERROR: $_" $logFile
    Write-Host "::error::[FBNeo] $_"
    throw
}

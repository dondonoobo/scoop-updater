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
            $commit = if ($newVersion -match '\.([0-9a-f]+)$') { $matches[1] } else { $newVersion }

            $urlTemplate = $json.autoupdate.architecture.'64bit'.url
            # 配信先移行の自動修復: 旧Giteaパス -> CDN (nightly.eden-emu.dev)
            if ($urlTemplate -match 'git\.eden-emu\.dev/eden-ci/nightly/releases/download/') {
                $urlTemplate = $urlTemplate -replace 'https://git\.eden-emu\.dev/eden-ci/nightly/releases/download/v\$version/', 'https://nightly.eden-emu.dev/v$version/'
                $json.autoupdate.architecture.'64bit'.url = $urlTemplate
                Write-Info "[$fileName] Migrated urlTemplate to CDN: $urlTemplate" $logFile
            }
            $newUrl = $urlTemplate.Replace('$version', $newVersion).Replace('$commit', $commit)

            Write-Info "[$fileName] New version detected: $oldVersion -> $newVersion" $logFile
            Write-Info "[$fileName] Download URL: $newUrl" $logFile
            Write-Info "[$fileName] Calculating hashes..." $logFile
            try {
                $hash = Get-RemoteSha256 -Url $newUrl
            } catch {
                throw "Failed to download hash target ${newUrl}: $_"
            }
            $json.version = $newVersion
            $json.architecture.'64bit'.url = $newUrl
            $json.architecture.'64bit' | Add-Member -MemberType NoteProperty -Name 'hash' -Value $hash -Force

            $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
            Write-Info "[$fileName] Updated: $oldVersion -> $newVersion" $logFile
        } else {
            Write-Info "[$fileName] $oldVersion (Up to date)" $logFile
            # バージョン一致でも旧ドメインが残っていたら自己修復する
            $currentUrl = $json.architecture.'64bit'.url
            $urlTemplate = $json.autoupdate.architecture.'64bit'.url
            $needsMigrate = ($currentUrl -match 'git\.eden-emu\.dev/eden-ci/nightly/releases/download/') -or ($urlTemplate -match 'git\.eden-emu\.dev/eden-ci/nightly/releases/download/')
            if ($needsMigrate) {
                Write-Info "[$fileName] Old download domain detected, migrating to CDN..." $logFile
                $commit = if ($oldVersion -match '\.([0-9a-f]+)$') { $matches[1] } else { $oldVersion }
                $fixedTemplate = 'https://nightly.eden-emu.dev/v$version/Eden-Windows-$commit-amd64-clang-pgo.zip'
                $json.autoupdate.architecture.'64bit'.url = $fixedTemplate
                $fixedUrl = $fixedTemplate.Replace('$version', $oldVersion).Replace('$commit', $commit)
                Write-Info "[$fileName] Download URL: $fixedUrl" $logFile
                Write-Info "[$fileName] Calculating hashes..." $logFile
                try {
                    $hash = Get-RemoteSha256 -Url $fixedUrl
                } catch {
                    throw "Failed to download hash target ${fixedUrl}: $_"
                }
                $json.architecture.'64bit'.url = $fixedUrl
                $json.architecture.'64bit' | Add-Member -MemberType NoteProperty -Name 'hash' -Value $hash -Force
                $json | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding Ascii
                Write-Info "[$fileName] Migrated URL (same version): $oldVersion" $logFile
            }
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

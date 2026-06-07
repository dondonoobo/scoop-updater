# scripts/update-fbneo.ps1
# FinalBurn Neo (Nightly) 専用 マニフェスト更新スクリプト
$ProgressPreference = 'SilentlyContinue'

if ($env:BUCKET_DIR) {
    $bucketPath = $env:BUCKET_DIR
} elseif ($env:SCOOP) {
    $bucketPath = "$env:SCOOP\buckets\my-bucket\bucket"
} else {
    $bucketPath = "$env:USERPROFILE\scoop\buckets\my-bucket\bucket"
}
$checkverScript = "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1"

$jsonPath = "$bucketPath\fbneo-nightly.json"
$logFile  = "$bucketPath\update_log.txt"
$date     = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
$fileName = Split-Path $jsonPath -Leaf

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
    exit 1
}

# scripts/_common.ps1
# マニフェストリポジトリ(A)のパスとログ出力先を解決する共通関数

function Get-ManifestRepoRoot {
    # 優先: 明示的な環境変数
    if ($env:MANIFEST_REPO_DIR -and (Test-Path $env:MANIFEST_REPO_DIR)) {
        return (Resolve-Path $env:MANIFEST_REPO_DIR).Path
    }
    # CI: ワークフローでチェックアウトした manifest ディレクトリ
    if ($env:GITHUB_WORKSPACE -and (Test-Path (Join-Path $env:GITHUB_WORKSPACE 'manifest'))) {
        return (Join-Path $env:GITHUB_WORKSPACE 'manifest')
    }
    throw "MANIFEST_REPO_DIR is not set and no 'manifest' dir found under GITHUB_WORKSPACE."
}

function Get-CheckverScript {
    if ($env:GITHUB_WORKSPACE) {
        return "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1"
    } else {
        return "$env:SCOOP\apps\scoop\current\bin\checkver.ps1"
    }
}

function Get-CheckhashesScript {
    if ($env:GITHUB_WORKSPACE) {
        return "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkhashes.ps1"
    } else {
        return "$env:SCOOP\apps\scoop\current\bin\checkhashes.ps1"
    }
}

# 指定URLをダウンロードして SHA256 ハッシュ(小文字)を返す
function Get-RemoteSha256 {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$UserAgent
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    try {
        $iwrArgs = @{ Uri = $Url; OutFile = $tmp; UseBasicParsing = $true; ErrorAction = 'Stop' }
        if ($UserAgent) { $iwrArgs['UserAgent'] = $UserAgent }
        try {
            Invoke-WebRequest @iwrArgs
        } catch {
            throw "Get-RemoteSha256 failed for URL '$Url': $_"
        }
        return (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# 標準出力とログファイルの両方に書き込む
function Write-Info {
    param(
        [string]$Message,
        [string]$LogFile
    )
    Write-Host $Message
    if ($LogFile) {
        $Message | Out-File $LogFile -Append -Encoding UTF8
    }
}

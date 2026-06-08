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

<#
Update-PoB2-JP.ps1 — PoB2-JP 自己更新（配布先にも更新を届ける）

GitHub の VERSION を見て、ローカルより新しければ patch（翻訳CSV・スクリプト等）を
自動ダウンロードして PoB2-JP フォルダを更新する。PoB 本体には一切触れない。
オフライン/失敗時は黙ってスキップ（起動を止めない）。.exe ランチャ本体は実行中ロックのため更新対象外。

呼び出し: Install-PoB2-JP.ps1 の冒頭から（-NoUpdate でスキップ可）。単体実行も可。
#>
param(
    [string]$PatchRoot,                       # PoB2-JP フォルダ。未指定なら本スクリプト位置から推定
    [string]$Repo = "kyohei0612/PoB2-JP",     # 配布元リポ（owner/name）
    [string]$Branch = "main",
    [switch]$Quiet
)
$ErrorActionPreference = "Stop"

function Resolve-PatchRoot {
    param([string]$Req)
    if ($Req -and (Test-Path (Join-Path $Req "payload"))) { return (Resolve-Path $Req).Path }
    # 本スクリプトは <PatchRoot>\payload\scripts\Update-PoB2-JP.ps1
    $cand = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (Test-Path (Join-Path $cand "payload")) { return (Resolve-Path $cand).Path }
    return $null
}

function Compare-Version {
    param([string]$A, [string]$B)  # A>B なら 1
    $pa = @($A -split '[.\-]'); $pb = @($B -split '[.\-]')
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { [void][int]::TryParse($pa[$i], [ref]$x) }
        if ($i -lt $pb.Count) { [void][int]::TryParse($pb[$i], [ref]$y) }
        if ($x -ne $y) { if ($x -gt $y) { return 1 } else { return -1 } }
    }
    return 0
}

try {
    $root = Resolve-PatchRoot $PatchRoot
    if (-not $root) { return }
    $localVerFile = Join-Path $root "VERSION"
    $localVer = "0"
    if (Test-Path $localVerFile) { $localVer = (Get-Content -LiteralPath $localVerFile -Raw).Trim() }

    $rawUrl = "https://raw.githubusercontent.com/$Repo/$Branch/VERSION"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $remoteVer = $null
    try { $remoteVer = (Invoke-WebRequest -Uri $rawUrl -UseBasicParsing -TimeoutSec 6).Content.Trim() } catch { return }  # オフライン等は静かに終了
    if (-not $remoteVer) { return }

    if ((Compare-Version $remoteVer $localVer) -le 0) {
        if (-not $Quiet) { Write-Host "PoB2-JP: 日本語化は最新です (v$localVer)" }
        return
    }
    Write-Host "PoB2-JP: 新しい日本語化アップデート v$remoteVer があります（現在 v$localVer）。適用します..."

    # アーカイブをDL→展開→patch のみ上書き（PoB本体・.exe ランチャは触らない）
    $tmp = Join-Path $env:TEMP ("pob2jp-upd-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp "src.zip"
        Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing -TimeoutSec 60
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        $ext = Get-ChildItem -LiteralPath $tmp -Directory | Where-Object { $_.Name -like "PoB2-JP-*" } | Select-Object -First 1
        if (-not $ext) { Write-Host "PoB2-JP: 更新展開に失敗（スキップ）"; return }
        # 更新対象: payload(翻訳CSV/runtime含む), tools, VERSION, README/NOTICE。実行中の .exe は除外。
        foreach ($sub in @("payload", "tools")) {
            $src = Join-Path $ext.FullName $sub
            if (Test-Path $src) { robocopy $src (Join-Path $root $sub) /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XO 2>$null | Out-Null }
        }
        foreach ($f in @("VERSION", "README.md", "NOTICE_JP.txt", "PoB2-JP.ico")) {
            $src = Join-Path $ext.FullName $f
            if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $root $f) -Force }
        }
        Write-Host "PoB2-JP: アップデート完了 (v$remoteVer)。日本語化を再適用します。"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    # 更新は best-effort。失敗しても通常起動を妨げない。
    if (-not $Quiet) { Write-Host "PoB2-JP: 更新チェックをスキップ ($_)" }
}

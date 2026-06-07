<#
Launch-PoB2-JP.ps1 — 日本語起動の単一エントリ（自己完結ランチャ）

設計: pob-jp/specs/update-loop-fix.md §3。
シーケンス:
  [1] 排他   : PoB が既に起動中なら、ファイルロック中の再パッチ事故を避けて何もせず終了。
  [2] 適用   : Install-PoB2-JP.ps1 を呼ぶ。Install 側が冪等で、
                - 未適用/原本巻戻り/新バージョン → フル再適用
                - 既に最新JP適用済           → 高速パスで即終了
              を自動判定する（branch a/b/c/d をカバー）。
  [3] 起動   : "Path of Building-PoE2.exe" を起動して終了。

ロジックは Install-PoB2-JP.ps1 に一本化（重複なし）。本スクリプトは薄いオーケストレータ。
PoB2-JP.exe（.NET ランチャ）は Install-PoB2-JP.ps1 を直接叩く設計のため本スクリプトを経由しないが、
デスクトップショートカット / CLI / 将来の .exe 付け替え用の正規エントリとして提供する。
#>
param(
    [string]$PoBRoot,
    [switch]$Force,        # Install へ委譲（高速パス無効化）
    [switch]$NoLaunch      # JP 適用のみ行い PoB は起動しない（CI/検証用）
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$PoBExeName = "Path of Building-PoE2.exe"

function Resolve-PoBRoot {
    param([string]$Requested)
    $candidates = @()
    if ($Requested) { $candidates += $Requested }
    if ($env:POB2_PATH) { $candidates += $env:POB2_PATH }
    # scripts/ の2つ上（パッケージ親 = PoB ルート想定）と、その親
    $candidates += (Split-Path (Split-Path $ScriptDir -Parent) -Parent)
    $candidates += (Split-Path (Split-Path (Split-Path $ScriptDir -Parent) -Parent) -Parent)
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c "Launch.lua")) -and (Test-Path (Join-Path $c $PoBExeName))) {
            return (Resolve-Path $c).Path
        }
    }
    throw "PoB2 root (with $PoBExeName) not found. Pass -PoBRoot '<path>'."
}

function Test-NoLoop {
    # verify_no_update_loop.py を呼び「ループ無し」を返す。python不在/失敗時は $null（=判定不能→起動は止めない）。
    param([string]$Root, [string]$ScriptDir)
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { return $null }
    $verify = Join-Path (Split-Path (Split-Path $ScriptDir -Parent) -Parent) "tools\verify_no_update_loop.py"
    if (-not (Test-Path $verify)) { return $null }
    try {
        $out = & python $verify --root $Root --json 2>$null | Out-String
        $r = $out | ConvertFrom-Json
        return (-not $r.loops)
    } catch { return $null }
}

function Get-Tier {
    param([string]$Root)
    $sp = Join-Path $Root ".pob2jp-state.json"
    if (-not (Test-Path $sp)) { return $null }
    try { return ((Get-Content -LiteralPath $sp -Raw -Encoding UTF8) -replace "^$([char]0xFEFF)", '' | ConvertFrom-Json).tier } catch { return $null }
}

$Root = Resolve-PoBRoot $PoBRoot
Write-Host "PoB2 root: $Root"

# [1] 排他: PoB 起動中は再パッチしない（ファイルロック/二重起動の事故防止）。
# プロセス名で照合（.Path 不要＝別権限/保護プロセスでも取りこぼさない）。万一の改名に備え Path 照合も併用。
$running = @(Get-Process -Name "Path of Building-PoE2" -ErrorAction SilentlyContinue)
if ($running.Count -eq 0) {
    $running = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and (Split-Path $_.Path -Leaf) -ieq $PoBExeName })
}
if ($running.Count -gt 0) {
    Write-Host "Path of Building is already running; leaving it as-is (no re-patch)."
    return
}

# [2] 適用: Install に委譲（冪等。高速パス/フル再適用/巻戻り再パッチを自動判定）。
# ルート解決も Install へ一本化するため $Root を必ず渡す（Find-PoBRoot は -PoBRoot を最優先）。
# Install は失敗時 throw（$ErrorActionPreference=Stop で伝播）。.ps1 呼出に $LASTEXITCODE は効かないため try/catch で受ける。
$installer = Join-Path $ScriptDir "Install-PoB2-JP.ps1"
if (-not (Test-Path $installer)) { throw "Install-PoB2-JP.ps1 not found next to launcher: $installer" }
$installArgs = @{ PoBRoot = $Root }
if ($Force) { $installArgs.Force = $true }
try {
    & $installer @installArgs
} catch {
    throw "Install-PoB2-JP.ps1 failed: $_"
}

# [2.5] 自動検証ゲート＋自己修復（フック適用=tier full の時のみ）。
# verify でループを検知したら 1回だけ -Force 再適用、なお駄目なら data-only へ縮退（起動は必ず通す）。
if ((Get-Tier $Root) -eq "full") {
    $noLoop = Test-NoLoop $Root $ScriptDir
    if ($noLoop -eq $false) {
        Write-Host "PoB2-JP: update loop detected post-install; self-healing (re-apply)..."
        try { & $installer -PoBRoot $Root -Force } catch {}
        $noLoop = Test-NoLoop $Root $ScriptDir
        if ($noLoop -eq $false) {
            Write-Host "PoB2-JP: self-heal failed; degrading to data-only (translation hooks off, loop-safe)."
            try { & $installer -PoBRoot $Root -NoHooks -NoRuntime } catch {}
        }
    }
}

# [3] 起動
if ($NoLaunch) { Write-Host "JP applied; -NoLaunch set, not starting PoB."; return }
$pobExe = Join-Path $Root $PoBExeName
if (-not (Test-Path $pobExe)) { throw "$PoBExeName not found at $Root" }
Write-Host "Starting Path of Building (PoE2)..."
Start-Process -FilePath $pobExe -WorkingDirectory $Root

param(
    [string]$PoBRoot
)

$ErrorActionPreference = "Stop"

$rootCandidates = @()
if ($PoBRoot) { $rootCandidates += $PoBRoot }
if ($env:POB2_PATH) { $rootCandidates += $env:POB2_PATH }
$ScriptRoot = $PSScriptRoot
if (Test-Path (Join-Path $ScriptRoot "payload")) {
    $PackageRoot = $ScriptRoot
} else {
    $PackageRoot = Split-Path (Split-Path $ScriptRoot -Parent) -Parent
}
$rootCandidates += $PackageRoot
$rootCandidates += (Split-Path $PackageRoot -Parent)

$root = $null
foreach ($candidate in $rootCandidates) {
    if ($candidate -and (Test-Path (Join-Path $candidate "Launch.lua"))) {
        $root = (Resolve-Path $candidate).Path
        break
    }
}
if (-not $root) { throw "PoB2 root not found" }

Write-Host "PoB2 root: $root"

$runtimeMarker = Join-Path $root ".pob2jp-runtime.json"
if (Test-Path $runtimeMarker) {
    try {
        $runtimeState = Get-Content -LiteralPath $runtimeMarker -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @($runtimeState.added)) {
            if (-not $name) { continue }
            $addedPath = Join-Path $root $name
            if (Test-Path $addedPath) {
                Remove-Item -LiteralPath $addedPath -Force
                Write-Host "Removed added runtime file: $name"
            }
        }
    } catch {
        Write-Host "Warning: failed to read runtime marker: $runtimeMarker"
    }
    Remove-Item -LiteralPath $runtimeMarker -Force
}

$jpModule = Join-Path $root "Modules\PoeJP"
if (Test-Path $jpModule) {
    Remove-Item -LiteralPath $jpModule -Recurse -Force
    Write-Host "Removed Modules\PoeJP"
}

$jpTranslate = Join-Path $root "Data\Translate\ja-JP"
if (Test-Path $jpTranslate) {
    Remove-Item -LiteralPath $jpTranslate -Recurse -Force
    Write-Host "Removed Data\Translate\ja-JP"
}

$fontDir = Join-Path $root "SimpleGraphic\Fonts"
foreach ($fontName in @("JpUI.ttf", "JpUI-Bold.ttf")) {
    $fontPath = Join-Path $fontDir $fontName
    if (Test-Path $fontPath) {
        Remove-Item -LiteralPath $fontPath -Force
        Write-Host "Removed font file: $fontName"
    }
}

# pob2jp: 更新ループ抑止/Phase2 の生成物を除去（UpdateCheck.lua 本体は下の .bak 一括復元で原本に戻る）
foreach ($meta in @(".pob2jp-keep.txt", ".pob2jp-state.json", ".pob2jp-log.txt", ".pob2jp-log.txt.1", ".pob2jp-coverage.json")) {
    $metaPath = Join-Path $root $meta
    if (Test-Path $metaPath) {
        Remove-Item -LiteralPath $metaPath -Force
        Write-Host "Removed $meta"
    }
}

# manifest 登録ファイル一覧（upstream原本）を絶対パスで集合化。
# JP追加物（manifest非登録: 例 JpUI.ttf）の .bak は「原本」ではないため復元せず破棄し、
# 原本へ完全復帰させる（無差別復元だと JP 追加フォントが復活して残骸が残る）。
$registered = @{}
$manPath = Join-Path $root "manifest.xml"
if (Test-Path $manPath) {
    try {
        $doc = [xml](Get-Content -LiteralPath $manPath -Raw)
        foreach ($f in $doc.PoBVersion.File) {
            $rel = (($f.GetAttribute("name")) -replace '\{space\}', ' ') -replace '/', '\'
            $registered[((Join-Path $root $rel).ToLower())] = $true
        }
    } catch { Write-Host "Warning: failed to parse manifest.xml; restoring all backups." }
}

$backups = @(Get-ChildItem -LiteralPath $root -Filter "*.pob2jp.bak" -Recurse -Force | Sort-Object FullName -Descending)
if ($backups.Count -eq 0) {
    Write-Host "No PoB2-JP backups found"
    exit 0
}

foreach ($backup in $backups) {
    $target = $backup.FullName.Substring(0, $backup.FullName.Length - ".pob2jp.bak".Length)
    # manifest を読めた場合のみ: 未登録ファイル(=vanilla原本が存在しない JP追加物)の .bak は
    # 「JP自身のコピー」(再インストール時に生成される stale bak)なので復元すると蘇ってしまう。
    # 復元はせず stale bak を破棄するだけ。実体ファイルは消さない（vanilla誤削除を避ける。
    # JP追加実体の除去はフォント明示削除(上)と .pob2jp-runtime.json の added 機構が担当）。
    if ($registered.Count -gt 0 -and -not $registered.ContainsKey($target.ToLower())) {
        Remove-Item -LiteralPath $backup.FullName -Force
        Write-Host "Dropped stale non-upstream backup: $($backup.Name)"
        continue
    }
    Copy-Item -LiteralPath $backup.FullName -Destination $target -Force
    Remove-Item -LiteralPath $backup.FullName -Force
    Write-Host "Restored $target"
}
Write-Host "PoB2-JP reset complete"

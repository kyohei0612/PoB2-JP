param(
    [string]$PoBRoot,
    [string]$PayloadName = "payload",
    [switch]$NoRuntime,
    [switch]$NoHooks,
    [switch]$Force,  # 高速パス(既に最新JP適用済なら即終了)を無効化し、常にフルインストールする
    [switch]$NoUpdate # GitHub からの日本語化アップデート自動取得をスキップ
)

$ErrorActionPreference = "Stop"

$PackageRoot = $PSScriptRoot
if (Test-Path (Join-Path $PackageRoot $PayloadName)) {
    $Payload = Join-Path $PackageRoot $PayloadName
} else {
    $ScriptPayload = Split-Path $PackageRoot -Parent
    $PackageRoot = Split-Path $ScriptPayload -Parent
    $RequestedPayload = Join-Path $PackageRoot $PayloadName
    if (Test-Path $RequestedPayload) {
        $Payload = $RequestedPayload
    } else {
        $Payload = $ScriptPayload
    }
}
$BackupSuffix = ".pob2jp.bak"
$OfficialSimpleGraphicMinSize = 2100000
$LaunchMarker = "-- pob2jp: load translator"
$MainMarker = "-- pob2jp: unicode detect"
$CommonMarker = "-- pob2jp: utf8 keep"

$RuntimeDlls = @(
    "SimpleGraphicExtend.dll",
    "abseil_dll.dll",
    "brotlicommon.dll",
    "brotlidec.dll",
    "bz2.dll",
    "fmt.dll",
    "glfw3.dll",
    "libGLESv2.dll",
    "libcurl.dll",
    "lua51.dll",
    "re2.dll",
    "zlib1.dll",
    "zstd.dll",
    "freetype.dll",
    "harfbuzz.dll",
    "fribidi-0.dll",
    "libwebp.dll",
    "libpng16.dll",
    "libquickjs.dll",
    "libsharpyuv.dll",
    "loadall.dll",
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll",
    "msvcp140_codecvt_ids.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll"
)

$FontTargets = @(
    "Liberation Sans.tgf",
    "Liberation Sans Bold.tgf",
    "Bitstream Vera Sans Mono.tgf",
    "Fontin.tgf",
    "Fontin Italic.tgf",
    "Fontin SmallCaps.tgf",
    "Fontin SmallCaps Italic.tgf"
)

$NoRuntime = [bool]$NoRuntime
$NoHooks = [bool]$NoHooks
$HasRuntimePayload = Test-Path (Join-Path $Payload "runtime\SimpleGraphicExtend.dll")
if (-not $HasRuntimePayload -and -not $NoRuntime) {
    Write-Host "Runtime payload not found; installing data-only safe localization."
    $NoRuntime = $true
    $NoHooks = $true
}

function Find-PoBRoot {
    param([string]$Requested)
    $candidates = @()
    if ($Requested) { $candidates += $Requested }
    if ($env:POB2_PATH) { $candidates += $env:POB2_PATH }
    $candidates += $PackageRoot
    $candidates += (Split-Path $PackageRoot -Parent)
    $candidates += (Get-Location).Path
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate "Launch.lua"))) {
            return (Resolve-Path $candidate).Path
        }
    }
    throw "PoB2 folder not found. Put this PoB2-JP folder inside the Path of Building Community (PoE2) folder, or run: .\Install-PoB2-JP.ps1 -PoBRoot `"D:\Path of Building Community (PoE2)`""
}

function Backup-File {
    param([string]$Path)
    if (Test-Path $Path) {
        $backup = "$Path$BackupSuffix"
        if (-not (Test-Path $backup)) {
            Copy-Item -LiteralPath $Path -Destination $backup -Force
        }
    }
}

function Copy-FileWithBackup {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Force -Path (Split-Path $Destination -Parent) | Out-Null
    Backup-File $Destination
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Copy-DirectoryClean {
    param([string]$Source, [string]$Destination)
    if (Test-Path $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Destination -Parent) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

function Set-TextUtf8NoBom {
    param([string]$Path, [string]$Value)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

# ===== Phase 2: アンカー耐性・可観測性ヘルパ =====

function Write-JpLog {
    # PoBルート .pob2jp-log.txt へ1行追記（UTF-8, 64KB超でローテ）。失敗しても本処理を止めない。
    param([string]$Message, [string]$Root = $script:Root)
    if (-not $Root) { return }
    try {
        $log = Join-Path $Root ".pob2jp-log.txt"
        if ((Test-Path $log) -and ((Get-Item $log).Length -gt 65536)) { Move-Item -LiteralPath $log -Destination "$log.1" -Force }
        $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        Add-Content -LiteralPath $log -Value ("{0} {1}" -f $stamp, $Message) -Encoding UTF8
    } catch {}
}

function Resolve-Anchor {
    # literal候補（複数・CRLF両試行）→ regex の順で、テキスト中に実在する「置換対象文字列」を解決する。
    # regex は capture group 1 を対象に（無ければ全マッチ）。全滅は Found=$false（呼び出し側が縮退判断、throwしない）。
    param(
        [string]$Text,
        [string[]]$Literals = @(),
        [string]$Regex = $null,
        [string]$Name = ""
    )
    foreach ($lit in $Literals) {
        if (-not $lit) { continue }
        if ($Text.Contains($lit)) {
            return [pscustomobject]@{ Found = $true; Match = $lit; Method = "literal"; Name = $Name }
        }
        $alt = $lit.Replace("`n", "`r`n")
        if ($alt -ne $lit -and $Text.Contains($alt)) {
            return [pscustomobject]@{ Found = $true; Match = $alt; Method = "literal-crlf"; Name = $Name }
        }
    }
    if ($Regex) {
        $m = [regex]::Match($Text, $Regex)
        if ($m.Success) {
            $cap = if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Value }
            return [pscustomobject]@{ Found = $true; Match = $cap; Method = "regex"; Name = $Name }
        }
    }
    return [pscustomobject]@{ Found = $false; Match = $null; Method = "none"; Name = $Name }
}

function Patch-LaunchLua {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($text.Contains("local function poejpSafeTranslate")) {
        Write-Host "Launch.lua already patched"
        return
    }
    if ($text.Contains($LaunchMarker)) {
        $backup = "$Path$BackupSuffix"
        if (Test-Path $backup) {
            Copy-Item -LiteralPath $backup -Destination $Path -Force
            $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            Write-Host "Restored old Launch.lua hook before repatching"
        }
    }

    $oldHook = [string]::Join("`n", @(
"`t`tlocal _DrawString = DrawString",
"`t`tfunction DrawString(x, y, align, height, font, text)",
"`t`t`tif type(text) == `"string`" then",
"`t`t`t`ttext = poejp.tDisplay(text)",
"`t`t`tend",
"`t`t`treturn _DrawString(x, y, align, height, font, text)",
"`t`tend",
""
))

    $newHook = [string]::Join("`n", @(
"`t`tlocal function poejpSafeTranslate(text)",
"`t`t`tlocal ok, translated = pcall(poejp.tDisplay, text)",
"`t`t`tif ok and type(translated) == `"string`" then",
"`t`t`t`treturn translated",
"`t`t`tend",
"`t`t`treturn text",
"`t`tend",
"`t`tlocal _DrawString = DrawString",
"`t`tlocal _DrawStringWidth = DrawStringWidth",
"`t`tfunction DrawString(x, y, align, height, font, text)",
"`t`t`tif type(text) == `"string`" then",
"`t`t`t`ttext = poejpSafeTranslate(text)",
"`t`t`tend",
"`t`t`treturn _DrawString(x, y, align, height, font, text)",
"`t`tend",
"`t`tfunction DrawStringWidth(height, font, text)",
"`t`t`tif type(text) == `"string`" then",
"`t`t`t`ttext = poejpSafeTranslate(text)",
"`t`t`tend",
"`t`t`treturn _DrawStringWidth(height, font, text)",
"`t`tend",
""
))

    if ($text.Contains($LaunchMarker)) {
        if ($text.Contains($oldHook)) {
            Backup-File $Path
            $text = $text.Replace($oldHook, $newHook)
            Set-TextUtf8NoBom $Path $text
            Write-Host "Patched Launch.lua width hook"
            return
        }
        Write-Host "Launch.lua has an unknown existing PoB2-JP hook; skipped"
        return
    }

    $ra = Resolve-Anchor -Text $text -Literals @("`tRenderInit(`"DPI_AWARE`")", "RenderInit(`"DPI_AWARE`")") -Regex 'RenderInit\s*\(\s*"DPI_AWARE"\s*\)' -Name "Launch.RenderInit"
    if (-not $ra.Found) {
        Write-Host "Launch.lua RenderInit anchor unresolved; skipped (will degrade to data-only)"
        Write-JpLog "ANCHOR name=Launch.RenderInit method=MISSING"
        return $false
    }
    Write-JpLog "ANCHOR name=Launch.RenderInit method=$($ra.Method)"
    $anchor = $ra.Match
    $block = [string]::Join("`n", @(
"`t-- pob2jp: load translator",
"`tlocal poejpLoadOk, poejpLoaded = pcall(LoadModule, `"Modules/PoeJP/Init`")",
"`tif poejpLoadOk then",
"`t`tpoejp = poejpLoaded",
"`telse",
"`t`tConPrintf(`"PoB2-JP: translator load failed: %s`", tostring(poejpLoaded))",
"`tend",
"`tif poejp and poejp.enabled then",
"`t`tConPrintf(`"PoB2-JP: %d translations loaded (%s)`", poejp.count, poejp.locale)",
"`t`tlocal function poejpSafeTranslate(text)",
"`t`t`tlocal ok, translated = pcall(poejp.tDisplay, text)",
"`t`t`tif ok and type(translated) == `"string`" then",
"`t`t`t`treturn translated",
"`t`t`tend",
"`t`t`treturn text",
"`t`tend",
"`t`tlocal _DrawString = DrawString",
"`t`tlocal _DrawStringWidth = DrawStringWidth",
"`t`tfunction DrawString(x, y, align, height, font, text)",
"`t`t`tif type(text) == `"string`" then",
"`t`t`t`ttext = poejpSafeTranslate(text)",
"`t`t`tend",
"`t`t`treturn _DrawString(x, y, align, height, font, text)",
"`t`tend",
"`t`tfunction DrawStringWidth(height, font, text)",
"`t`t`tif type(text) == `"string`" then",
"`t`t`t`ttext = poejpSafeTranslate(text)",
"`t`t`tend",
"`t`t`treturn _DrawStringWidth(height, font, text)",
"`t`tend",
"`telseif poejp then",
"`t`tConPrintf(`"PoB2-JP: translation CSV not loaded`")",
"`tend",
""
))
    Backup-File $Path
    $text = $text.Replace($anchor, "$anchor`n$block")
    Set-TextUtf8NoBom $Path $text
    Write-Host "Patched Launch.lua"
    return $true
}

function Patch-MainLua {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($text.Contains($MainMarker) -or $text.Contains("type(_G.poejp)")) {
        Write-Host "Main.lua already patched"
        return
    }
    $old = [string]::Join("`n", @(
"function main:DetectUnicodeSupport()",
"`t-- PoeCharm has utf8 global that normal PoB doesn't have",
"`tself.unicode = type(_G.utf8) == `"table`"",
"`tif self.unicode then",
"`t`tConPrintf(`"Unicode support detected`")",
"`tend",
"end",
""
))
    $oldCrLf = $old.Replace("`n", "`r`n")
    $new = [string]::Join("`n", @(
"function main:DetectUnicodeSupport()",
"`t-- pob2jp: unicode detect",
"`tself.unicode = type(_G.utf8) == `"table`" or type(_G.charm) == `"table`" or type(_G.poejp) == `"table`"",
"`tif self.unicode then",
"`t`tConPrintf(`"Unicode support detected`")",
"`tend",
"end",
""
))
    $newForFile = if ($text.Contains($oldCrLf)) { $new.Replace("`n", "`r`n") } else { $new }
    Backup-File $Path
    if ($text.Contains($oldCrLf)) {
        $text = $text.Replace($oldCrLf, $newForFile)
    } elseif ($text.Contains($old)) {
        $text = $text.Replace($old, $newForFile)
    } else {
        $pattern = 'function main:DetectUnicodeSupport\(\)\s+-- PoeCharm has utf8 global that normal PoB doesn''t have\s+self\.unicode = type\(_G\.utf8\) == "table"\s+if self\.unicode then\s+ConPrintf\("Unicode support detected"\)\s+end\s+end'
        $replaced = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newForFile }, 1)
        if ($replaced -eq $text) {
            Write-Host "Main.lua unicode block not found; skipped"
            return
        }
        $text = $replaced
    }
    Set-TextUtf8NoBom $Path $text
    Write-Host "Patched Main.lua"
}

function Patch-CommonLua {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $changed = $false
    $oldGsub = "`t`t:gsub(`"[\128-\255]`", `"?`")"
    if ($text.Contains($oldGsub)) {
        $text = $text.Replace($oldGsub, "`t`t$CommonMarker`n`t`t-- :gsub(`"[\128-\255]`", `"?`")")
        $changed = $true
    }
    $oldMatch = "`t`tif self:match(orPattern) then"
    $newMatch = "`t`tif charm and charm.TranslateMatch and charm.TranslateMatch(self, orPattern) or self:match(orPattern) then"
    if ($text.Contains($oldMatch) -and -not $text.Contains($newMatch)) {
        $text = $text.Replace($oldMatch, $newMatch)
        $changed = $true
    }
    if (-not $changed) {
        Write-Host "Common.lua already patched or no known anchors"
        return
    }
    Backup-File $Path
    Set-TextUtf8NoBom $Path $text
    Write-Host "Patched Common.lua"
}

function First-Existing {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Install-Fonts {
    param([string]$Root)
    $winFonts = Join-Path $env:WINDIR "Fonts"
    $regular = First-Existing @(
        (Join-Path $winFonts "YuGothM.ttc"),
        (Join-Path $winFonts "YuGothR.ttc"),
        (Join-Path $winFonts "meiryo.ttc"),
        (Join-Path $winFonts "msgothic.ttc")
    )
    $bold = First-Existing @(
        (Join-Path $winFonts "YuGothB.ttc"),
        (Join-Path $winFonts "YuGothM.ttc"),
        (Join-Path $winFonts "meiryob.ttc"),
        (Join-Path $winFonts "meiryo.ttc"),
        (Join-Path $winFonts "msgothic.ttc")
    )
    if (-not $regular) {
        Write-Host "Japanese Windows font not found; skipped font override"
        return
    }
    if (-not $bold) { $bold = $regular }
    $fontDir = Join-Path $Root "SimpleGraphic\Fonts"
    New-Item -ItemType Directory -Force -Path $fontDir | Out-Null
    Copy-FileWithBackup $regular (Join-Path $fontDir "JpUI.ttf")
    Copy-FileWithBackup $bold (Join-Path $fontDir "JpUI-Bold.ttf")
    $tgf = "{`n  `"fonts`": [`n    {`"file`": `"JpUI.ttf`", `"scale`": 1.0}`n  ]`n}`n"
    foreach ($name in $FontTargets) {
        $target = Join-Path $fontDir $name
        Backup-File $target
        Set-TextUtf8NoBom $target $tgf
    }
    $cfg = Join-Path $Root "Launch.cfg"
    if (Test-Path $cfg) {
        $kept = Get-Content -LiteralPath $cfg -Encoding UTF8 | Where-Object { $_ -notmatch '^set\s+(font_name|font_resolution|font_spacing_x)\s+' }
        Backup-File $cfg
        if ($kept.Count -gt 0) {
            Set-Content -LiteralPath $cfg -Value $kept -Encoding UTF8
        } else {
            Remove-Item -LiteralPath $cfg -Force
        }
    }
}

function Install-Runtime {
    param([string]$Root)
    $runtimeRoot = Join-Path $Payload "runtime"
    foreach ($name in $RuntimeDlls) {
        $source = Join-Path $runtimeRoot $name
        if (-not (Test-Path $source)) { throw "Runtime file missing: $name" }
    }
    $simple = Join-Path $Root "SimpleGraphic.dll"
    $simpleIsCjk = (Test-Path $simple) -and ((Get-Item $simple).Length -lt $OfficialSimpleGraphicMinSize)
    if (-not $simpleIsCjk) {
        Copy-FileWithBackup (Join-Path $runtimeRoot "SimpleGraphicExtend.dll") $simple
    }
    $added = @()
    foreach ($name in $RuntimeDlls) {
        if ($name -eq "SimpleGraphicExtend.dll") { continue }
        $dst = Join-Path $Root $name
        if ($simpleIsCjk -and (Test-Path $dst)) { continue }
        if (-not (Test-Path $dst)) { $added += $name }
        Copy-FileWithBackup (Join-Path $runtimeRoot $name) $dst
    }
    Install-Fonts $Root
    $marker = @{ added = $added } | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath (Join-Path $Root ".pob2jp-runtime.json") -Value $marker -Encoding UTF8
}

function Restore-RuntimeBackups {
    param([string]$Root)
    $names = @("SimpleGraphic.dll")
    foreach ($name in $RuntimeDlls) {
        if ($name -ne "SimpleGraphicExtend.dll") {
            $names += $name
        }
    }
    foreach ($name in $names) {
        $target = Join-Path $Root $name
        $backup = "$target$BackupSuffix"
        if (Test-Path $backup) {
            Copy-Item -LiteralPath $backup -Destination $target -Force
            Write-Host "Restored runtime backup: $name"
        }
    }
}

function Remove-AddedRuntime {
    # JP が新規追加した（manifest非登録・vanilla原本なし）runtime DLL を .pob2jp-runtime.json の
    # added リストに基づき除去。data-only 縮退で「差分ゼロ＝vanilla完全復帰」を徹底するため。
    # ループ安全性自体は manifest 非登録ゆえ残っても無害だが、残骸を残さない。
    param([string]$Root)
    $marker = Join-Path $Root ".pob2jp-runtime.json"
    if (-not (Test-Path $marker)) { return }
    try {
        $st = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @($st.added)) {
            if (-not $name) { continue }
            $p = Join-Path $Root $name
            if (Test-Path $p) { Remove-Item -LiteralPath $p -Force; Write-Host "Removed JP-added runtime: $name" }
        }
        Remove-Item -LiteralPath $marker -Force
    } catch {}
}

function Restore-HookBackups {
    param([string]$Root)
    $paths = @(
        (Join-Path $Root "Launch.lua"),
        (Join-Path $Root "Modules\Main.lua"),
        (Join-Path $Root "Modules\Common.lua")
    )
    foreach ($target in $paths) {
        $backup = "$target$BackupSuffix"
        if (Test-Path $backup) {
            Copy-Item -LiteralPath $backup -Destination $target -Force
            Write-Host "Restored hook backup: $target"
        }
    }
}

# ===== PoB2-JP: update-loop fix (added 2026-06) =====

function Get-Sha1Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLower() }
    finally { $sha.Dispose() }
}

$Latin1 = [System.Text.Encoding]::GetEncoding(28591)  # ISO-8859-1: 1:1 byte<->char (PS5.1互換)

function Test-MatchesSha1 {
    # UpdateCheck.lua と同じ CRLF 寛容判定。raw sha1 を先に比較し、
    # 一致すれば即 true（DLL等バイナリ/大半のファイルはここで決着、351MBでも1ハッシュのみ）。
    # 不一致時だけ Latin1(1:1) で \n->\r\n 変換版を生成して再比較。1バイトずつのList追加を廃止。
    param([string]$Path, [string]$ExpectedSha1)
    $expected = $ExpectedSha1.ToLower()
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ((Get-Sha1Hex $bytes) -eq $expected) { return $true }
    $crlf = $Latin1.GetString($bytes).Replace("`n", "`r`n")
    return ((Get-Sha1Hex ($Latin1.GetBytes($crlf))) -eq $expected)
}

# UpdateCheck.lua の3アンカー仕様（literal優先・regexフォールバック）。Test-AnchorHealth と共用。
$script:UcAnchorA = @{ Lit = @("runtimePath = runtimePath or runtimeFallback or scriptPath");
                       Rx  = 'runtimePath\s*=\s*runtimePath\s+or\s+runtimeFallback\s+or\s+scriptPath'; Name = "UpdateCheck.A" }
$script:UcAnchorB = @{ Lit = @("local updateFiles = { }", "local updateFiles = {}");
                       Rx  = 'local\s+updateFiles\s*=\s*\{\s*\}'; Name = "UpdateCheck.B" }
# C は最脆: ループ本体先頭の if(...) then を行頭インデント込みで捕捉（条件式の文言に依存しない）
$script:UcAnchorC = @{ Lit = @("`tif (not localFiles[name] or localFiles[name].sha1 ~= data.sha1) and (not localFiles[sanitizedName] or localFiles[sanitizedName].sha1 ~= data.sha1) then");
                       Rx  = '([ \t]*if\s*\(\s*not\s+localFiles\[name\][\s\S]*?\)\s*then)'; Name = "UpdateCheck.C" }

function Patch-UpdateCheckLua {
    # 戻り値: $true=適用成功 / "skip"=既適用or対象なし / $false=必須アンカー解決不能（呼び出し側が縮退判断）
    param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Host "UpdateCheck.lua not found; skipped"; return "skip" }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($text.Contains("pob2jp: load keep-list")) { Write-Host "UpdateCheck.lua already patched"; return "skip" }

    $rA = Resolve-Anchor -Text $text -Literals $script:UcAnchorA.Lit -Regex $script:UcAnchorA.Rx -Name $script:UcAnchorA.Name
    $rB = Resolve-Anchor -Text $text -Literals $script:UcAnchorB.Lit -Regex $script:UcAnchorB.Rx -Name $script:UcAnchorB.Name
    $rC = Resolve-Anchor -Text $text -Literals $script:UcAnchorC.Lit -Regex $script:UcAnchorC.Rx -Name $script:UcAnchorC.Name
    foreach ($r in @($rA, $rB, $rC)) {
        if (-not $r.Found) { Write-Host "UpdateCheck.lua anchor unresolved: $($r.Name)"; Write-JpLog "ANCHOR name=$($r.Name) method=MISSING"; return $false }
        Write-JpLog "ANCHOR name=$($r.Name) method=$($r.Method)"
    }

    # C: 解決した実マッチからインデントを検出し、keep+versionガードのskip分岐でラップ（元条件は elseif で温存）
    $cMatch = $rC.Match
    $indent = [regex]::Match($cMatch, '^[ \t]*').Value
    $cond = $cMatch.Substring($indent.Length)
    $condElse = $cond -replace '^if\b', 'elseif'
    $newC = "${indent}if pob2jpKeep[name] and not pob2jpVersionChanged then`n${indent}`t-- pob2jp: skip JP-diverged file while same version (prevents false update loop)`n${indent}$condElse"

    $insertA = @'

-- pob2jp: load keep-list of JP-diverged files (skipped while PoB version is unchanged)
local pob2jpKeep = {}
do
    local pob2jpKeepFile = io.open(scriptPath.."/.pob2jp-keep.txt", "r")
    if pob2jpKeepFile then
        for line in pob2jpKeepFile:lines() do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1, 1) ~= "#" then
                pob2jpKeep[line] = true
            end
        end
        pob2jpKeepFile:close()
    end
end
'@

    $insertB = @'
-- pob2jp: protect JP-diverged files only while the PoB version is unchanged
local pob2jpVersionChanged = (localVer ~= remoteVer)
'@

    # R1強化: 各アンカーは1回だけ出現すべき。複数出現は String.Replace の全置換で二重挿入→
    # Lua の local 二重宣言/構文破壊を招くため、当てずに data-only へ縮退する（壊さない）。
    foreach ($mm in @($rA.Match, $rB.Match, $cMatch)) {
        $occ = ([regex]::Matches($text, [regex]::Escape($mm))).Count
        if ($occ -ne 1) {
            Write-Host "UpdateCheck.lua anchor not unique (occurrences=$occ); skipping patch (degrade to data-only)."
            Write-JpLog "ANCHOR name=UpdateCheck result=NON-UNIQUE occ=$occ"
            return $false
        }
    }

    Backup-File $Path
    $text = $text.Replace($rA.Match, $rA.Match + $insertA)
    $text = $text.Replace($rB.Match, $insertB + "`n" + $rB.Match)
    $text = $text.Replace($cMatch, $newC)
    # R1: 置換後の整合を post-verify。崩れたら .bak から原本復帰し $false（縮退）— ファイルを壊さない
    $ok = $true
    foreach ($m in @("pob2jp: load keep-list", "pob2jpVersionChanged", "pob2jp: skip JP-diverged", "localFiles[name]")) {
        if (-not $text.Contains($m)) { $ok = $false }
    }
    if (-not $ok) {
        $bak = "$Path$BackupSuffix"
        if (Test-Path $bak) { Copy-Item -LiteralPath $bak -Destination $Path -Force }
        Write-Host "UpdateCheck.lua post-patch verification failed; reverted"
        Write-JpLog "ANCHOR name=UpdateCheck.C method=$($rC.Method) result=POSTVERIFY-FAIL reverted=1"
        return $false
    }
    Set-TextUtf8NoBom $Path $text
    Write-Host "Patched UpdateCheck.lua"
    return $true
}

function Write-KeepList {
    # manifest 登録ファイルのうち on-disk sha1 が不一致 = JP が改変した = keep 対象、を動的に列挙
    param([string]$Root)
    $manPath = Join-Path $Root "manifest.xml"
    if (-not (Test-Path $manPath)) { Write-Host "manifest.xml not found; keep-list skipped"; return }
    $doc = [xml](Get-Content -LiteralPath $manPath -Raw)
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($f in $doc.PoBVersion.File) {
        $name = $f.GetAttribute("name")        # manifest 生表記（{space}含む）。これがkeepキー
        $rel = $name -replace '\{space\}', ' '  # 物理パス解決用にのみ {space}→space 変換
        $abs = Join-Path $Root $rel
        if (-not (Test-Path $abs)) { continue }
        $msha = ($f.GetAttribute("sha1")).ToLower()
        # keep には必ず $name（manifest生表記）を入れる。UpdateCheck.lua の照合キー pob2jpKeep[name] は
        # remoteFiles の生キー＝manifest生表記なので、ここを変換するとスペース入りフォント等でskip不発になる。
        if (-not (Test-MatchesSha1 $abs $msha)) { [void]$keep.Add($name) }
    }
    if ($keep -notcontains "UpdateCheck.lua") { [void]$keep.Add("UpdateCheck.lua") }
    $header = "# Auto-generated by PoB2-JP installer. JP-diverged files; skipped during same-version PoB update checks. Do not edit."
    Set-TextUtf8NoBom (Join-Path $Root ".pob2jp-keep.txt") (($header + "`n" + ($keep -join "`n")) + "`n")
    Write-Host ("Wrote .pob2jp-keep.txt ({0} files)" -f $keep.Count)
}

function Write-State {
    param([string]$Root, [string]$Tier = "full", [string]$DegradeReason = $null)
    $manPath = Join-Path $Root "manifest.xml"
    $ver = "unknown"
    if (Test-Path $manPath) {
        try {
            $doc = [xml](Get-Content -LiteralPath $manPath -Raw)
            $ver = $doc.SelectSingleNode("/PoBVersion/Version").GetAttribute("number")
        } catch {}
    }
    $state = [ordered]@{
        patchedVersion = $ver
        patchedAt      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        installer      = "PoB2-JP"
        tier           = $Tier           # full | data-only
        degradeReason  = $DegradeReason  # 縮退理由（full時は null）
    }
    Set-TextUtf8NoBom (Join-Path $Root ".pob2jp-state.json") ($state | ConvertTo-Json)
    Write-Host "Wrote .pob2jp-state.json (version $ver, tier $Tier)"
}

function Reset-StaleBackups {
    # PoB がバージョン更新で管理ファイルを新原本へ戻した場合、古い .bak を新原本で取り直す。
    # 現ファイルが upstream 原本(=manifest sha1 一致)で、かつ .bak が古い時のみ更新（パッチ済は触らない）。
    param([string]$Root)
    $manPath = Join-Path $Root "manifest.xml"
    if (-not (Test-Path $manPath)) { return }
    $doc = [xml](Get-Content -LiteralPath $manPath -Raw)
    $refreshed = 0
    foreach ($f in $doc.PoBVersion.File) {
        $rel = ($f.GetAttribute("name")) -replace '\{space\}', ' '
        $abs = Join-Path $Root $rel
        $bak = "$abs$BackupSuffix"
        if (-not (Test-Path $abs) -or -not (Test-Path $bak)) { continue }
        $msha = ($f.GetAttribute("sha1")).ToLower()
        # 現ファイルが upstream 原本(manifest一致)で、かつ .bak が古い(=原本でない)時だけ取り直す
        if (Test-MatchesSha1 $abs $msha) {
            if (-not (Test-MatchesSha1 $bak $msha)) {
                Copy-Item -LiteralPath $abs -Destination $bak -Force
                $refreshed++
            }
        }
    }
    if ($refreshed -gt 0) { Write-Host "Refreshed $refreshed stale backup(s) after PoB update" }
}

function Get-ManifestVersion {
    param([string]$Root)
    $manPath = Join-Path $Root "manifest.xml"
    if (-not (Test-Path $manPath)) { return $null }
    try {
        $doc = [xml](Get-Content -LiteralPath $manPath -Raw)
        return $doc.SelectSingleNode("/PoBVersion/Version").GetAttribute("number")
    } catch { return $null }
}

function Test-JpCurrent {
    # フル再インストール不要かを判定（高速パス）。マーカー健在 + state.patchedVersion==現manifest +
    # keep/state 生成済 を全て満たす時のみ true。新ver更新/原本巻戻り/未インストールは false。
    param([string]$Root)
    foreach ($rel in @(".pob2jp-state.json", ".pob2jp-keep.txt", "UpdateCheck.lua", "Launch.lua")) {
        if (-not (Test-Path (Join-Path $Root $rel))) { return $false }
    }
    $launch = Get-Content -LiteralPath (Join-Path $Root "Launch.lua") -Raw -Encoding UTF8
    if ($launch -notmatch "poejpSafeTranslate") { return $false }   # 翻訳フック巻戻り検知
    $uc = Get-Content -LiteralPath (Join-Path $Root "UpdateCheck.lua") -Raw -Encoding UTF8
    if ($uc -notmatch "pob2jp: load keep-list") { return $false }   # ループ抑止パッチ巻戻り検知
    $ver = Get-ManifestVersion $Root
    if (-not $ver) { return $false }
    try {
        # 自作stateはBOM無しだが、手編集等でBOMが付くと PS5.1 ConvertFrom-Json が落ちるため先頭BOMを除去
        $json = (Get-Content -LiteralPath (Join-Path $Root ".pob2jp-state.json") -Raw -Encoding UTF8) -replace "^$([char]0xFEFF)", ''
        $st = $json | ConvertFrom-Json
        return ($st.patchedVersion -eq $ver)   # バージョン更新があれば false → フル再適用
    } catch { return $false }
}

function Test-AnchorHealth {
    # 必須アンカー（Launch RenderInit ＋ UpdateCheck A/B/C）を書込前に dry-run 解決。
    # 戻り: @{ LaunchOk; UpdateCheckOk; Methods }。Main/Common は任意（判定外・報告のみ）。
    param([string]$Root)
    $res = @{ LaunchOk = $true; UpdateCheckOk = $true; Methods = @{} }
    $launchPath = Join-Path $Root "Launch.lua"
    if (Test-Path $launchPath) {
        $lt = Get-Content -LiteralPath $launchPath -Raw -Encoding UTF8
        if ($lt -notmatch "poejpSafeTranslate") {
            $r = Resolve-Anchor -Text $lt -Literals @("`tRenderInit(`"DPI_AWARE`")", "RenderInit(`"DPI_AWARE`")") -Regex 'RenderInit\s*\(\s*"DPI_AWARE"\s*\)' -Name "Launch.RenderInit"
            $res.LaunchOk = $r.Found; $res.Methods["Launch.RenderInit"] = $r.Method
        } else { $res.Methods["Launch.RenderInit"] = "already" }
    } else { $res.LaunchOk = $false }
    $ucPath = Join-Path $Root "UpdateCheck.lua"
    if (Test-Path $ucPath) {
        $ut = Get-Content -LiteralPath $ucPath -Raw -Encoding UTF8
        if ($ut -notmatch "pob2jp: load keep-list") {
            foreach ($spec in @($script:UcAnchorA, $script:UcAnchorB, $script:UcAnchorC)) {
                $r = Resolve-Anchor -Text $ut -Literals $spec.Lit -Regex $spec.Rx -Name $spec.Name
                $res.Methods[$spec.Name] = $r.Method
                if (-not $r.Found) { $res.UpdateCheckOk = $false }
            }
        } else { $res.Methods["UpdateCheck"] = "already" }
    } else { $res.UpdateCheckOk = $false }
    return $res
}

# ===== end update-loop fix =====

$Root = Find-PoBRoot $PoBRoot
Write-Host "PoB2 root: $Root"

# 日本語化アップデート自動取得（配布先にも更新を届ける）。best-effort・オフライン時は静かにスキップ。
# 更新でVERSIONが上がったら $Force を立て、高速パスを通さず新CSV/スクリプトを確実に反映する。
if (-not $NoUpdate -and -not $NoHooks) {
    $verFile = Join-Path $PackageRoot "VERSION"
    $verBefore = ""
    if (Test-Path $verFile) { $verBefore = (Get-Content -LiteralPath $verFile -Raw).Trim() }
    $updScript = Join-Path $PSScriptRoot "Update-PoB2-JP.ps1"
    if (Test-Path $updScript) { try { & $updScript } catch {} }
    $verAfter = ""
    if (Test-Path $verFile) { $verAfter = (Get-Content -LiteralPath $verFile -Raw).Trim() }
    if ($verAfter -ne $verBefore) { $Force = $true; Write-Host "PoB2-JP: 更新を反映するため再適用します。" }
}

# 高速パス: 既に最新バージョンへJP適用済みなら、重いコピー/パッチ/keep再生成をスキップして即終了。
# .exe は本スクリプト終了後に PoB を起動するため、通常起動はこの経路で一瞬で完了する。
# 注: この経路では Reset-StaleBackups も意図的にスキップする（同ver中はbak取り直し不要。
#     新ver更新があれば Test-JpCurrent が false を返しフル経路へ落ちて取り直す）。
if (-not $Force -and -not $NoHooks -and (Test-JpCurrent $Root)) {
    Write-Host ("PoB2-JP already current (v{0}); skipping full install. Use -Force to reinstall." -f (Get-ManifestVersion $Root))
    return
}

Reset-StaleBackups $Root

Copy-DirectoryClean (Join-Path $Payload "Data\Translate\ja-JP") (Join-Path $Root "Data\Translate\ja-JP")
Copy-FileWithBackup (Join-Path $Payload "Data\Translate.json") (Join-Path $Root "Data\Translate.json")
Copy-FileWithBackup (Join-Path $Payload "Data\Settings.conf") (Join-Path $Root "Data\Settings.conf")

# ===== Phase 2: pre-flight アンカー健全性 → 縮退判断 =====
# 必須アンカー（Launch RenderInit ＋ UpdateCheck A/B/C）が解決不能なら、ループ抑止できない改変を
# 残さないため、フック/ランタイム差替を当てず data-only（CSVのみ・原本復帰）へ縮退する。
$tier = "full"
$degradeReason = $null
if (-not $NoHooks) {
    $health = Test-AnchorHealth $Root
    if (-not ($health.UpdateCheckOk -and $health.LaunchOk)) {
        $missing = ($health.Methods.GetEnumerator() | Where-Object { $_.Value -eq 'none' } | ForEach-Object { $_.Key }) -join ','
        $tier = "data-only"; $degradeReason = "anchor-missing:$missing"
        $NoHooks = $true; $NoRuntime = $true
        Write-Host "PoB2-JP: required anchors unresolved ($missing); degrading to data-only (CSV only, hooks/runtime reverted to vanilla)."
        Write-JpLog "TIER data-only reason=$degradeReason"
    }
}

if ($NoRuntime) {
    Restore-RuntimeBackups $Root
    if ($tier -eq "data-only") { Remove-AddedRuntime $Root }   # 縮退時は追加DLLも除去し vanilla 完全復帰
} else {
    Copy-DirectoryClean (Join-Path $Payload "Modules\PoeJP") (Join-Path $Root "Modules\PoeJP")
    Patch-LaunchLua (Join-Path $Root "Launch.lua") | Out-Null
    Patch-MainLua (Join-Path $Root "Modules\Main.lua") | Out-Null
    Patch-CommonLua (Join-Path $Root "Modules\Common.lua") | Out-Null
    Install-Runtime $Root
}

if ($NoHooks) {
    Restore-HookBackups $Root
} elseif ($NoRuntime) {
    Copy-DirectoryClean (Join-Path $Payload "Modules\PoeJP") (Join-Path $Root "Modules\PoeJP")
    Patch-LaunchLua (Join-Path $Root "Launch.lua") | Out-Null
}

# pob2jp: 更新ループ抑止（フック適用時のみ）。UpdateCheck.lua をパッチし、改変ファイルを動的に keep化。
# UpdateCheck パッチが失敗（施行時アンカー解決不能/post-verify失敗）したら、ループ抑止できない状態を
# 残さないため、フック/ランタイムを原本へ戻し data-only へロールバックする。
if (-not $NoHooks) {
    $ucResult = Patch-UpdateCheckLua (Join-Path $Root "UpdateCheck.lua")
    if ($ucResult -eq $false) {
        $tier = "data-only"; $degradeReason = "updatecheck-apply-failed"
        Restore-HookBackups $Root
        Restore-RuntimeBackups $Root
        Remove-AddedRuntime $Root
        Write-Host "PoB2-JP: UpdateCheck patch failed; reverted hooks/runtime to data-only (loop-safe)."
        Write-JpLog "TIER data-only reason=updatecheck-apply-failed"
        Write-State $Root $tier $degradeReason
    } else {
        # フック翻訳が実際に当たったか確認（pre-flight通過後でも未知既存フック等で黙ってskipされ得る）。
        # 当たっていなければ loop-safe な full のまま「翻訳が出ない」可能性を degradeReason に明記。
        $launchHas = (Get-Content -LiteralPath (Join-Path $Root "Launch.lua") -Raw -Encoding UTF8) -match "poejpSafeTranslate"
        if (-not $launchHas) {
            $degradeReason = "launch-hook-not-applied(translation-off,loop-safe)"
            Write-Host "PoB2-JP: warning - translator hook not applied (loop-safe); translation may not display."
            Write-JpLog "WARN launch-hook-not-applied"
        }
        Write-KeepList $Root
        Write-State $Root $tier $degradeReason
        Write-JpLog "TIER full ver=$(Get-ManifestVersion $Root)"
    }
} else {
    # data-only: keep は書かない（差分ゼロ）。状態のみ記録。
    Write-State $Root $tier $degradeReason
}

Write-Host "PoB2-JP install complete (tier: $tier)"

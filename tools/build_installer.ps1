# Сборка одного файла dist/dir320-tui.sh (PowerShell 5.1+/pwsh)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$template = Join-Path $root 'installer\dir320-tui.sh.in'
$outDir = Join-Path $root 'dist'
$out = Join-Path $outDir 'dir320-tui.sh'

$map = [ordered]@{
    '@@ADMIN_LUA@@'     = Join-Path $root 'panel\admin.lua'
    '@@PANEL_CONSOLE@@' = Join-Path $root 'panel\panel-console.sh'
    '@@ADMIN_INDEX@@'   = Join-Path $root 'panel\index.html'
    '@@SITE_INDEX@@'    = Join-Path $root 'panel\site-index.html'
    '@@README@@'        = Join-Path $root 'panel\README-DIR320.txt'
}

if (-not (Test-Path $template)) { throw "нет шаблона: $template" }
$src = [IO.File]::ReadAllText($template, [Text.Encoding]::UTF8).Replace("`r`n", "`n")

foreach ($k in $map.Keys) {
    if (-not $src.Contains($k)) { throw "в шаблоне нет токена $k" }
    if (-not (Test-Path $map[$k])) { throw "нет файла: $($map[$k])" }
    $content = [IO.File]::ReadAllText($map[$k], [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    $src = $src.Replace($k, $content)
}

foreach ($m in @('__PANEL_ADMIN_EOF__', '__PANEL_CONSOLE_EOF__', '__PANEL_AINDEX_EOF__', '__PANEL_SITE_EOF__', '__PANEL_README_EOF__')) {
    $cnt = ($src -split "`n" | Where-Object { $_ -eq $m }).Count
    if ($cnt -ne 1) { throw "маркер $m встречается $cnt раз" }
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
[IO.File]::WriteAllText($out, $src, (New-Object Text.UTF8Encoding($false)))
Write-Output ("built {0} ({1} bytes)" -f $out, (Get-Item $out).Length)

<#
.SYNOPSIS
  Remove the LightWave MCP server: its LightWave plugin registrations, its Claude
  registrations and the install folder. LightWave must be closed.

.PARAMETER ConfigDir / InstallDir / ClaudeDesktopConfig
  As for install.ps1.
.PARAMETER NoClaudeCode
  Leave Claude Code's registration alone.
#>
param(
    [string]$ConfigDir,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'LightWaveMCP'),
    [string]$ClaudeDesktopConfig = (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'),
    [switch]$NoClaudeCode
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Ok($msg) { Write-Host "   $msg" -ForegroundColor Green }

$lwRoot = Join-Path $env:USERPROFILE '.LightWaveDigital\LightWave'
$configs = if ($ConfigDir) { @(Get-Item $ConfigDir) } else {
    Get-ChildItem $lwRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^2025\.' }
}
$running = Get-CimInstance Win32_Process -Filter "Name='Layout.exe' OR Name='Modeler.exe'"
if ($running -and -not $ConfigDir) {
    Write-Host "Please close LightWave (Layout and Modeler) first, then run this again." -ForegroundColor Red
    exit 1
}

foreach ($c in $configs) {
    foreach ($f in (Get-ChildItem $c.FullName -Filter 'LWEXT*-64.CFG')) {
        $text = [IO.File]::ReadAllText($f.FullName)
        $new = [regex]::Replace($text, '\{ Entry\r?\n(?:(?!\{ Entry).)*?Name "(LW_Bridge|LW_Bridge_Modeler)"(?:(?!\{ Entry).)*?\r?\n\}\r?\n?', '',
                                [Text.RegularExpressions.RegexOptions]::Singleline)
        if ($new -ne $text) { [IO.File]::WriteAllText($f.FullName, $new, $utf8); Ok "Removed plugins from $($f.FullName)" }
    }
    foreach ($f in (Get-ChildItem $c.FullName -Filter 'LWMASTERS*.CFG')) {
        $text = [IO.File]::ReadAllText($f.FullName)
        $new = [regex]::Replace($text, '(?m)^Plugin MasterHandler \d+ LW_Bridge\r?\n(?:.*\r?\n)*?EndPlugin\r?\n?', '')
        if ($new -ne $text) {
            # Renumber the remaining master plugins.
            $i = 0
            $new = [regex]::Replace($new, '(?m)^Plugin MasterHandler \d+ ', { param($m) $script:i++; "Plugin MasterHandler $script:i " })
            [IO.File]::WriteAllText($f.FullName, $new, $utf8); Ok "Removed the Layout bridge from $($f.FullName)"
        }
    }
}

if (Test-Path $ClaudeDesktopConfig) {
    $cfg = Get-Content -Raw $ClaudeDesktopConfig | ConvertFrom-Json
    if ($cfg.mcpServers -and ($cfg.mcpServers.PSObject.Properties.Name -contains 'lightwave')) {
        $cfg.mcpServers.PSObject.Properties.Remove('lightwave')
        [IO.File]::WriteAllText($ClaudeDesktopConfig, ($cfg | ConvertTo-Json -Depth 10), $utf8)
        Ok "Removed 'lightwave' from Claude Desktop"
    }
}
if (-not $NoClaudeCode -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    & claude mcp remove --scope user lightwave 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "Removed 'lightwave' from Claude Code" }
}

if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
    Ok "Deleted $InstallDir"
}
Write-Host "`nLightWave MCP is uninstalled. (Modeler's Alert Level is left as it is.)" -ForegroundColor Green

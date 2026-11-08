<#
.SYNOPSIS
  Install the LightWave MCP server so Claude can drive LightWave Layout and Modeler.

.DESCRIPTION
  1. Copies the bridge plugins and the MCP server to %LOCALAPPDATA%\LightWaveMCP.
  2. Creates a Python environment there and installs the server's one dependency.
  3. Registers the plugins in LightWave's config: the Layout bridge starts with Layout;
     the Modeler bridge appears in Modeler under Utilities > Additional.
  4. Registers the server with Claude Desktop and, if installed, Claude Code.
  5. Copies LightWave's command reference out of the SDK zip that ships with LightWave,
     for the lw_command_help tool.

  LightWave Layout and Modeler must be closed (they rewrite their config files on exit).
  Every config file that is changed is backed up first (*.before-claude-for-lightwave).
  Run it again to update; run uninstall.ps1 to remove everything.

.PARAMETER ConfigDir
  LightWave config folder. Default: the newest 2025 version under
  %USERPROFILE%\.LightWaveDigital\LightWave.
.PARAMETER InstallDir
  Where to install. Default: %LOCALAPPDATA%\LightWaveMCP.
.PARAMETER ClaudeDesktopConfig
  Claude Desktop's config file. Default: %APPDATA%\Claude\claude_desktop_config.json.
.PARAMETER NoClaudeDesktop / NoClaudeCode
  Don't register the server with that app.
.PARAMETER Yes
  Don't ask questions (installs Python with winget if it's missing).
#>
param(
    [string]$ConfigDir,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'LightWaveMCP'),
    [string]$ClaudeDesktopConfig = (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'),
    [switch]$NoClaudeDesktop,
    [switch]$NoClaudeCode,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg = Split-Path -Parent $here

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "   $msg" -ForegroundColor Green }
function Note($msg) { Write-Host "   $msg" }
function Fail($msg) { Write-Host "`n$msg" -ForegroundColor Red; exit 1 }
function Ask($question) {
    if ($Yes) { return $true }
    return (Read-Host "$question [y/N]") -match '^(y|yes)$'
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Backup($path) {
    $b = "$path.before-claude-for-lightwave"
    if ((Test-Path $path) -and -not (Test-Path $b)) { Copy-Item $path $b }
}

Write-Host "LightWave MCP installer" -ForegroundColor White

# ---------------------------------------------------------------------------
Step "Finding the files to install"
if (Test-Path (Join-Path $pkg 'plugins\lw_bridge.p')) {
    $pluginSrc = Join-Path $pkg 'plugins'          # release zip
    $serverSrc = Join-Path $pkg 'server'
} else {
    $pluginSrc = Join-Path $pkg 'build\plugins\Release'   # repository checkout
    $serverSrc = Join-Path $pkg 'mcp'
}
foreach ($f in "$pluginSrc\lw_bridge.p", "$pluginSrc\lw_bridge_modeler.p", "$serverSrc\lw_mcp_server.py") {
    if (-not (Test-Path $f)) { Fail "Missing $f. Use a release zip, or build the plugins first (build.ps1)." }
}
Ok "From $pkg"

# ---------------------------------------------------------------------------
Step "Finding LightWave"
$lwRoot = Join-Path $env:USERPROFILE '.LightWaveDigital\LightWave'
if (-not $ConfigDir) {
    $candidates = Get-ChildItem $lwRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^2025\.' -and (Test-Path (Join-Path $_.FullName 'prefs')) } |
        Sort-Object { [version]$_.Name } -Descending
    if (-not $candidates) { Fail "No LightWave 2025 settings found in $lwRoot. Run LightWave once, then try again." }
    $ConfigDir = $candidates[0].FullName
}
if (-not (Test-Path $ConfigDir)) { Fail "LightWave config folder not found: $ConfigDir" }
$ConfigDir = (Resolve-Path $ConfigDir).Path
$ver = Split-Path -Leaf $ConfigDir
if ($ver -notmatch '^\d{4}\.\d+\.\d+$') {
    # A custom config folder: take the version from its LW<version>-64.CFG file.
    $cfg = Get-ChildItem $ConfigDir -Filter 'LW2*-64.CFG' | Select-Object -First 1
    if (-not $cfg) { Fail "Can't tell the LightWave version of $ConfigDir" }
    $ver = $cfg.Name -replace '^LW(.+)-64\.CFG$', '$1'
}
if ($ver -notmatch '^2025\.') { Fail "These plugins are built for LightWave 2025; found settings for $ver." }
Ok "LightWave $ver settings in $ConfigDir"
$lwInstall = Get-ChildItem 'C:\Program Files\LightWaveDigital' -Directory -Filter "LightWave_$ver" -ErrorAction SilentlyContinue | Select-Object -First 1

# LightWave rewrites its config files when it exits, so it must be closed.
$defaultConfig = (Resolve-Path (Join-Path $lwRoot $ver) -ErrorAction SilentlyContinue).Path
$running = Get-CimInstance Win32_Process -Filter "Name='Layout.exe' OR Name='Modeler.exe'" | Where-Object {
    $cl = $_.CommandLine
    if ($cl -match '-c"?([^"]+?)"?(\s|$)') { (Resolve-Path $Matches[1] -ErrorAction SilentlyContinue).Path -eq $ConfigDir }
    else { $ConfigDir -eq $defaultConfig }
}
if ($running) {
    Fail ("Please close LightWave first (" + (($running | ForEach-Object { "$($_.Name) [$($_.ProcessId)]" }) -join ', ') +
          "), then run the installer again. LightWave saves its settings when it exits and would undo the installation.")
}

# ---------------------------------------------------------------------------
Step "Finding Python 3.10 or newer"
function Find-Python {
    foreach ($cmd in @(@('py', '-3'), @('python'))) {
        $exe = $cmd[0]
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        try {
            $out = & $exe @($cmd[1..9] | Where-Object { $_ }) -c "import sys; print(sys.executable); print(sys.version_info >= (3, 10))" 2>$null
        } catch { continue }
        if ($LASTEXITCODE -eq 0 -and $out.Count -ge 2 -and $out[1] -eq 'True') { return $out[0] }
    }
    return $null
}
$python = Find-Python
if (-not $python) {
    Note "Python 3.10+ isn't installed."
    if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Ask "Install Python 3.12 now with winget?")) {
        winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $python = Find-Python
    }
    if (-not $python) { Fail "Install Python 3.10 or newer from https://www.python.org/downloads/ (tick 'Add python.exe to PATH'), then run the installer again." }
}
Ok $python

# ---------------------------------------------------------------------------
Step "Installing to $InstallDir"
New-Item -ItemType Directory -Force "$InstallDir\plugins", "$InstallDir\server" | Out-Null
foreach ($p in 'lw_bridge.p', 'lw_bridge_modeler.p') {
    $dst = Join-Path "$InstallDir\plugins" $p
    try { Copy-Item (Join-Path $pluginSrc $p) $dst -Force }
    catch { Fail "Couldn't replace $dst. Close LightWave (Layout and Modeler) and try again." }
}
Get-ChildItem $serverSrc -Filter *.py |
    ForEach-Object { Copy-Item $_.FullName "$InstallDir\server\" -Force }
Copy-Item (Join-Path $serverSrc 'requirements.txt') "$InstallDir\server\" -Force
Get-ChildItem $InstallDir -Recurse -File | Unblock-File
Ok "Plugins and server copied"

$venvPython = Join-Path $InstallDir 'venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    & $python -m venv (Join-Path $InstallDir 'venv')
    if ($LASTEXITCODE -ne 0) { Fail "Couldn't create a Python environment in $InstallDir\venv" }
}
& $venvPython -m pip install --quiet --disable-pip-version-check -r "$InstallDir\server\requirements.txt"
if ($LASTEXITCODE -ne 0) { Fail "Couldn't install the server's Python packages (is the internet reachable?)" }
& $venvPython -c "import sys; sys.path.insert(0, r'$InstallDir\server'); import lw_mcp_server" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "The server doesn't start: run $venvPython $InstallDir\server\lw_mcp_server.py to see why." }
Ok "Python environment ready"

# Command reference for lw_command_help, from the SDK zip that ships with LightWave.
$sdkZip = if ($lwInstall) { Get-ChildItem (Join-Path $lwInstall.FullName 'sdk') -Filter 'lwsdk*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1 }
$docsDir = Join-Path $InstallDir 'sdk-docs'
if ($sdkZip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($sdkZip.FullName)
    try {
        $entries = $zip.Entries | Where-Object { $_.FullName -match '(^|/)html/commands/(layout|modeler|common)\.html$' }
        foreach ($e in $entries) {
            $dst = Join-Path $docsDir "html\commands\$($e.Name)"
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $true)
        }
    } finally { $zip.Dispose() }
    Ok "Command reference copied from $($sdkZip.Name)"
} else {
    Note "LightWave's SDK zip wasn't found, so lw_command_help won't be available (everything else works)."
}

# ---------------------------------------------------------------------------
Step "Registering the plugins with LightWave"
$ext = Join-Path $ConfigDir "LWEXT$ver-64.CFG"
$masters = Join-Path $ConfigDir "LWMASTERS$ver.CFG"
$ourNames = 'LW_Bridge', 'LW_Bridge_Modeler'

function Remove-OurEntries([string]$text) {
    # Drop "{ Entry ... }" blocks whose Name is one of ours.
    $out = New-Object System.Text.StringBuilder
    $block = $null
    foreach ($line in ($text -split "`r?`n")) {
        if ($null -eq $block) {
            if ($line -eq '{ Entry') { $block = @($line) } elseif ($line -ne '') { [void]$out.Append("$line`r`n") }
        } else {
            $block += $line
            if ($line -eq '}') {
                if (-not ($block | Where-Object { $_ -match '^\s*Name "(.+)"$' -and $ourNames -contains $Matches[1] })) {
                    [void]$out.Append(($block -join "`r`n") + "`r`n")
                }
                $block = $null
            }
        }
    }
    return $out.ToString()
}
function Entry($class, $name, $module, $label) {
    $m = $module -replace '\\', '\\'
    return "{ Entry`r`n  Class `"$class`"`r`n  Name `"$name`"`r`n  Module `"$m`"`r`n  InfoTag 409 `"$label`"`r`n}`r`n"
}

Backup $ext
$text = if (Test-Path $ext) { [IO.File]::ReadAllText($ext) } else { '' }
$text = Remove-OurEntries $text
$text += Entry 'MasterHandler' 'LW_Bridge' "$InstallDir\plugins\lw_bridge.p" 'LW Bridge (MCP)'
$text += Entry 'CommandSequence' 'LW_Bridge_Modeler' "$InstallDir\plugins\lw_bridge_modeler.p" 'LW Bridge for Modeler (MCP)'
[IO.File]::WriteAllText($ext, $text, $utf8)
Ok "Plugins listed in $(Split-Path -Leaf $ext)"

Backup $masters
$m = if (Test-Path $masters) { [IO.File]::ReadAllText($masters) } else { '' }
if ($m -notmatch '(?m)^Plugin MasterHandler \d+ LW_Bridge\s*$') {
    $n = ([regex]::Matches($m, '(?m)^Plugin MasterHandler ')).Count + 1
    if ($m -and -not $m.EndsWith("`n")) { $m += "`r`n" }
    $m += "Plugin MasterHandler $n LW_Bridge`r`nEndPlugin`r`n"
    [IO.File]::WriteAllText($masters, $m, $utf8)
}
Ok "Layout bridge starts with Layout ($(Split-Path -Leaf $masters))"

# Modeler at its default Alert Level opens a modal box for every rejected command, which
# stalls Claude until someone clicks OK. Expert reports in the status bar instead.
$mprefs = Join-Path $ConfigDir 'prefs\Modeler\Modeler.lwprefs'
if (Test-Path $mprefs) {
    $p = [IO.File]::ReadAllText($mprefs)
    if ($p -match '"Alert Level": ([0-1]),') {
        Note "Modeler's Alert Level is not Expert: when Claude sends a command Modeler rejects, an"
        Note "error box would pause Claude until you click OK. At Expert, errors go to the status bar."
        if (Ask "   Set Modeler's Alert Level to Expert?") {
            Backup $mprefs
            [IO.File]::WriteAllText($mprefs, ($p -replace '"Alert Level": [0-1],', '"Alert Level": 2,'), $utf8)
            Ok "Modeler Alert Level set to Expert"
        } else {
            Note "Left as it is (change it in Modeler: Edit > General Options > Alert Level)."
        }
    }
}

# ---------------------------------------------------------------------------
Step "Registering the server with Claude"
$serverPy = Join-Path $InstallDir 'server\lw_mcp_server.py'
$envVars = @{}
if (Test-Path "$docsDir\html\commands") { $envVars['LW_SDK_DIR'] = $docsDir }

if (-not $NoClaudeDesktop) {
    $claudeDir = Split-Path -Parent $ClaudeDesktopConfig
    if (Test-Path $claudeDir) {
        Backup $ClaudeDesktopConfig
        $cfg = if (Test-Path $ClaudeDesktopConfig) { Get-Content -Raw $ClaudeDesktopConfig | ConvertFrom-Json } else { $null }
        if ($null -eq $cfg) { $cfg = New-Object PSObject }
        if (-not ($cfg.PSObject.Properties.Name -contains 'mcpServers')) {
            $cfg | Add-Member -NotePropertyName mcpServers -NotePropertyValue (New-Object PSObject)
        }
        $entry = [ordered]@{ command = $venvPython; args = @($serverPy) }
        if ($envVars.Count) { $entry['env'] = $envVars }
        $cfg.mcpServers | Add-Member -NotePropertyName lightwave -NotePropertyValue ([pscustomobject]$entry) -Force
        [IO.File]::WriteAllText($ClaudeDesktopConfig, ($cfg | ConvertTo-Json -Depth 10), $utf8)
        Ok "Claude Desktop: added 'lightwave' to $ClaudeDesktopConfig (restart Claude Desktop to load it)"
    } else {
        Note "Claude Desktop isn't installed (no $claudeDir); skipped."
    }
}

if (-not $NoClaudeCode) {
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if ($claude) {
        & $claude.Source mcp remove --scope user lightwave 2>$null | Out-Null
        $envArgs = @(); foreach ($k in $envVars.Keys) { $envArgs += @('-e', "$k=$($envVars[$k])") }
        & $claude.Source mcp add --scope user @envArgs lightwave -- $venvPython $serverPy | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "Claude Code: added 'lightwave' for your user (all projects)" }
        else { Note "Claude Code: 'claude mcp add' failed; add it by hand: claude mcp add --scope user lightwave -- `"$venvPython`" `"$serverPy`"" }
    } else {
        Note "Claude Code isn't installed; skipped."
    }
}

# ---------------------------------------------------------------------------
Write-Host "`nDone." -ForegroundColor Green
Write-Host @"

Next:
  1. Start LightWave Layout. The bridge starts with it.
  2. For Modeler: in Modeler, choose Utilities > Additional > LW Bridge for Modeler (MCP)
     once per Modeler session.
  3. Restart Claude Desktop (or start a new Claude Code session) and ask, for example:
     "Check the LightWave connection" or "Add a red ball to the scene and render it".

To remove: run Uninstall LightWave MCP.
"@

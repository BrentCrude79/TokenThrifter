#Requires -Version 5.1
<#
  TokenThrifter installer.

    .\install.ps1              install / update, register the Claude Code hook, start the widget
    .\install.ps1 -Uninstall   stop the widget, remove the hook and installed files

  What it touches:
    ~/.claude/tokenthrifter/TokenThrifter.ps1   the widget
    ~/.claude/settings.json                      adds one SessionStart hook (backup written first)
    %APPDATA%\TokenThrifter\                     widget position/preferences (removed on uninstall)
#>
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
Remove-TypeData System.Array -ErrorAction SilentlyContinue   # PS 5.1: keep arrays as arrays in ConvertTo-Json

$InstallDir   = Join-Path $HOME '.claude\tokenthrifter'
$Target       = Join-Path $InstallDir 'TokenThrifter.ps1'
$SettingsPath = Join-Path $HOME '.claude\settings.json'
$Utf8NoBom    = New-Object Text.UTF8Encoding $false

function Stop-Widget {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*TokenThrifter.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-Settings {
    if (Test-Path $SettingsPath) {
        $raw = [IO.File]::ReadAllText($SettingsPath).TrimStart([char]0xFEFF)
        if ($raw.Trim()) { return $raw | ConvertFrom-Json }
    }
    New-Object PSObject
}

function Save-Settings($s) {
    if (Test-Path $SettingsPath) { Copy-Item $SettingsPath "$SettingsPath.tokenthrifter.bak" -Force }
    New-Item -ItemType Directory -Force (Split-Path $SettingsPath) | Out-Null
    [IO.File]::WriteAllText($SettingsPath, ($s | ConvertTo-Json -Depth 100), $Utf8NoBom)
}

# Return the SessionStart groups with every TokenThrifter hook removed.
function Remove-OurHook($s) {
    $groups = @()
    if ($s.hooks -and $s.hooks.SessionStart) {
        foreach ($g in @($s.hooks.SessionStart)) {
            $kept = @(@($g.hooks) | Where-Object { -not ((@($_.args) -join ' ') + $_.command -match 'TokenThrifter\.ps1') })
            if ($kept.Count) { $g.hooks = $kept; $groups += $g }
        }
    }
    , $groups
}

Stop-Widget
$s = Get-Settings
$groups = Remove-OurHook $s

if ($Uninstall) {
    if ($s.hooks) {
        if ($groups.Count) { $s.hooks.SessionStart = $groups }
        elseif ($s.hooks.PSObject.Properties['SessionStart']) { $s.hooks.PSObject.Properties.Remove('SessionStart') }
        Save-Settings $s
    }
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:APPDATA 'TokenThrifter') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'TokenThrifter removed.'
    return
}

# Copy the widget
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'TokenThrifter.ps1') $Target -Force

# Register: every Claude Code session start launches the widget (it is single-instance and detaches).
$launch = "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File','$Target'"
$hook = [pscustomobject]@{
    type    = 'command'
    command = 'powershell.exe'
    args    = @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', $launch)
    timeout = 15
}
$groups += [pscustomobject]@{ hooks = @($hook) }

if (-not $s.hooks) { $s | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) }
if ($s.hooks.PSObject.Properties['SessionStart']) { $s.hooks.SessionStart = $groups }
else { $s.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue $groups }
Save-Settings $s

# Start it now
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$Target`""
Write-Host "TokenThrifter installed to $InstallDir"
Write-Host 'It starts with every Claude Code session and closes shortly after the last one ends.'

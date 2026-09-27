#Requires -Version 5.1
<#
  TokenThrifter - a tiny Windows desktop widget showing how much of your 5-hour and weekly
  allowance is left for Claude Code, Z.ai (GLM Coding Plan) and ChatGPT Codex.

  Data sources (read-only, using credentials already on this machine):
    Claude Code : GET api.anthropic.com/api/oauth/usage with the token Claude Code stores in
                  ~/.claude/.credentials.json. When that token is stale, TokenThrifter runs
                  `claude -p /usage` hidden, which makes Claude Code refresh it (no model call).
    Z.ai        : GET api.z.ai/api/monitor/usage/quota/limit with your Z.ai API key
                  (ZAI_API_KEY, or the Z.ai token Claude Code is configured with).
    Codex       : the latest rate_limits event Codex CLI writes to ~/.codex/sessions (no network).
    CPU / GPU   : Windows performance counters (load, RAM, VRAM) - refreshed every 5 s.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File TokenThrifter.ps1
    -Snapshot <file.png>  render once to a PNG and exit
    -Demo                 use made-up numbers (for screenshots)
  Drag to move. Right-click for Refresh / Always on top / Close with Claude Code / Exit.
#>
param([string]$Snapshot, [switch]$Demo)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Single instance (snapshots may run alongside the live widget)
if (-not $Snapshot) {
    $mutex = New-Object Threading.Mutex($false, 'Local\TokenThrifter_Singleton')
    if (-not $mutex.WaitOne(0)) { exit }
}

# Hide the console window if one was created
Add-Type -Namespace TT -Name Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
[void][TT.Native]::ShowWindow([TT.Native]::GetConsoleWindow(), 0)

$RefreshSeconds = 120
$ConfigDir  = Join-Path $env:APPDATA 'TokenThrifter'
$ConfigPath = Join-Path $ConfigDir 'config.json'

# ---------------------------------------------------------------- data fetch (runs off the UI thread)
$Fetch = {
    param([bool]$Demo)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $now = [DateTimeOffset]::UtcNow

    function ToDto($v) {
        if ($null -eq $v -or $v -eq '' -or $v -eq 0) { return $null }
        if ($v -is [DateTimeOffset]) { return $v }
        if ($v -is [datetime]) { return [DateTimeOffset]$v.ToUniversalTime() }
        if ($v -is [string]) { return [DateTimeOffset]::Parse($v) }
        $n = [int64]$v
        if ($n -gt 100000000000) { return [DateTimeOffset]::FromUnixTimeMilliseconds($n) }
        return [DateTimeOffset]::FromUnixTimeSeconds($n)
    }
    # One rate-limit window. A window whose reset time has passed is full again.
    function Win($used, $resets) {
        $r = ToDto $resets
        if ($r -and $r -le [DateTimeOffset]::UtcNow) { return @{ used = 0.0; resets = $null; state = 'reset' } }
        $state = if ($r) { 'active' } else { 'idle' }
        @{ used = [math]::Min(100, [math]::Max(0, [double]$used)); resets = $r; state = $state }
    }

    if ($Demo) {
        return @{
            claude = @{ ok = $true; plan = 'max';  five = Win 64 $now.AddMinutes(170); week = Win 38 $now.AddHours(54) }
            zai    = @{ ok = $true; plan = 'pro';  five = Win 12 $now.AddMinutes(95);  week = Win 91 $now.AddHours(89) }
            codex  = @{ ok = $true; plan = 'plus'; five = Win 0 $null;                  week = Win 22 $now.AddHours(130) }
        }
    }

    $out = @{}

    # --- Claude Code
    try {
        $credPath = Join-Path $HOME '.claude\.credentials.json'
        if (-not (Test-Path $credPath)) { throw 'Not signed in to Claude Code (no ~/.claude/.credentials.json)' }
        $o = (Get-Content $credPath -Raw | ConvertFrom-Json).claudeAiOauth
        if (-not $o) { throw 'Claude Code is not using a Claude subscription login' }
        $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$o.expiresAt)
        # Stale token: let Claude Code refresh it. "/usage" is a local command - no model call, no usage spent.
        # Skipped while offline (e.g. just after waking from sleep) so a doomed attempt doesn't start the cooldown.
        if ($exp -le $now.AddMinutes(5) -and [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) {
            $stampFile = Join-Path $env:APPDATA 'TokenThrifter\last-reauth.txt'
            $last = if (Test-Path $stampFile) { (Get-Item $stampFile).LastWriteTimeUtc } else { [datetime]::MinValue }
            if (([datetime]::UtcNow - $last).TotalMinutes -ge 10) {
                New-Item -ItemType Directory -Force (Split-Path $stampFile) | Out-Null
                Set-Content $stampFile (Get-Date -Format o)
                $exe = (Get-Command claude -ErrorAction SilentlyContinue).Source
                if (-not $exe) { $exe = Join-Path $HOME '.local\bin\claude.exe' }
                if (Test-Path $exe) {
                    $p = Start-Process $exe -ArgumentList '-p', '/usage', '--no-session-persistence' -WindowStyle Hidden `
                            -WorkingDirectory (Split-Path $stampFile) -PassThru
                    if (-not $p.WaitForExit(60000)) { $p.Kill() }
                    $o = (Get-Content $credPath -Raw | ConvertFrom-Json).claudeAiOauth
                    $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$o.expiresAt)
                    # Refresh didn't take (network still coming up?) - allow another try in ~1 min, not 10.
                    if ($exp -le $now.AddMinutes(5)) { (Get-Item $stampFile).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-9) }
                }
            }
        }
        if ($exp -le $now.AddMinutes(1)) { throw 'Sign-in expired - run "claude" once in a terminal' }
        $u = Invoke-RestMethod 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 15 -Headers @{
            Authorization = "Bearer $($o.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20' }
        $out.claude = @{ ok = $true; plan = $o.subscriptionType
            five = Win $u.five_hour.utilization $u.five_hour.resets_at
            week = Win $u.seven_day.utilization $u.seven_day.resets_at }
    } catch { $out.claude = @{ ok = $false; err = $_.Exception.Message } }

    # --- Z.ai GLM Coding Plan
    try {
        # Key lookup: ZAI_API_KEY, then a Z.ai token Claude Code itself is pointed at (env or ~/.claude/settings.json)
        $envSources = @(@{ get = { param($n) [Environment]::GetEnvironmentVariable($n) } },
                        @{ get = { param($n) [Environment]::GetEnvironmentVariable($n, 'User') } })
        $settingsPath = Join-Path $HOME '.claude\settings.json'
        if (Test-Path $settingsPath) {
            $cfgEnv = (Get-Content $settingsPath -Raw | ConvertFrom-Json).env
            if ($cfgEnv) { $envSources += @{ get = { param($n) $cfgEnv.$n }.GetNewClosure() } }
        }
        $key = $null; $base = 'https://api.z.ai'
        foreach ($src in $envSources) {
            $k = & $src.get 'ZAI_API_KEY'
            if ($k) { $key = $k; break }
            $url = & $src.get 'ANTHROPIC_BASE_URL'
            if ($url -match 'z\.ai|bigmodel\.cn') {
                $k = & $src.get 'ANTHROPIC_AUTH_TOKEN'; if (-not $k) { $k = & $src.get 'ANTHROPIC_API_KEY' }
                if ($k) { $key = $k; if ($url -match 'bigmodel\.cn') { $base = 'https://open.bigmodel.cn' }; break }
            }
        }
        if (-not $key) { throw 'No Z.ai key found - set ZAI_API_KEY' }
        $r = Invoke-RestMethod "$base/api/monitor/usage/quota/limit" -TimeoutSec 15 -Headers @{ Authorization = "Bearer $key" }
        if (-not $r.success) { throw $r.msg }
        $lims = @($r.data.limits)
        # unit 3 = hours (number 5 -> the 5h window), unit 6 = weeks
        $f = $lims | Where-Object { $_.unit -eq 3 -or $_.type -eq 'TOKENS_LIMIT' } | Select-Object -First 1
        $w = $lims | Where-Object { $_.unit -eq 6 } | Select-Object -First 1
        $out.zai = @{ ok = $true; plan = $r.data.level
            five = if ($f) { Win $f.percentage $f.nextResetTime } else { $null }
            week = if ($w) { Win $w.percentage $w.nextResetTime } else { $null } }
    } catch { $out.zai = @{ ok = $false; err = $_.Exception.Message } }

    # --- ChatGPT Codex (local session logs)
    try {
        $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
        $dir = Join-Path $codexHome 'sessions'
        if (-not (Test-Path $dir)) { throw 'Codex CLI not found (no ~/.codex/sessions)' }
        $files = Get-ChildItem $dir -Recurse -Filter *.jsonl | Sort-Object LastWriteTime -Descending | Select-Object -First 10
        $rl = $null
        foreach ($file in $files) {
            $m = Select-String -Path $file.FullName -Pattern '"rate_limits":\{' | Select-Object -Last 1
            if ($m) { $j = $m.Line | ConvertFrom-Json; $rl = $j.payload.rate_limits; $asOf = ToDto $j.timestamp; break }
        }
        if (-not $rl) { throw 'No Codex usage recorded yet - run Codex once' }
        $wins = @($rl.primary, $rl.secondary) | Where-Object { $_ }
        $f = $wins | Where-Object { $_.window_minutes -le 300 } | Select-Object -First 1
        $w = $wins | Where-Object { $_.window_minutes -gt 300 } | Select-Object -First 1
        $out.codex = @{ ok = $true; plan = $rl.plan_type; asOf = $asOf
            five = if ($f) { Win $f.used_percent $f.resets_at } else { $null }
            week = if ($w) { Win $w.used_percent $w.resets_at } else { $null } }
    } catch { $out.codex = @{ ok = $false; err = $_.Exception.Message } }

    $out
}

# ---------------------------------------------------------------- CPU / GPU load (off the UI thread, every few seconds)
# Same Windows performance counters Task Manager uses, so any GPU vendor works with no extra tools.
# GPU counters are keyed by adapter LUID; the display device's AdapterLuid property maps them to a name.
$SysFetch = {
    param([bool]$Demo, $Cache)
    $ErrorActionPreference = 'Stop'
    function Short($n) {
        (($n -replace '\((R|TM|C)\)', '' -replace '\s+CPU\b.*', '' -replace '\s+Processor\b.*', '' -replace '\s+\d+-Core\b', '') -replace '\s{2,}', ' ').Trim()
    }
    function Mem($label, $used, $total) {
        if (-not $total) { return $null }
        @{ label = $label; used = [math]::Min(100, 100 * $used / $total); text = '{0:0.#}/{1:0}G' -f ($used / 1GB), ($total / 1GB) }
    }
    if ($Demo) {
        return @(
            @{ name = 'AMD Ryzen 9 7950X'; tag = 'CPU'; load = 23; mem = @{ label = 'RAM'; used = 41; text = '26.2/64G' } }
            @{ name = 'NVIDIA GeForce RTX 4090'; tag = 'GPU'; load = 87; mem = @{ label = 'VRAM'; used = 72; text = '17.3/24G' } }
        )
    }

    # Adapter list rarely changes - build it once per widget run.
    if (-not $Cache.gpus) {
        $gpus = @()
        foreach ($d in Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue) {
            if ($d.FriendlyName -match 'Microsoft (Basic|Remote)') { continue }
            $luid = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName '{60b193cb-5276-4d0f-96fc-f173abad3ec6} 2' -ErrorAction SilentlyContinue).Data
            $drv  = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName '{a45c254e-df1c-4efd-8020-67d146a850e0} 11' -ErrorAction SilentlyContinue).Data
            $vram = 0
            if ($drv) {
                $reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$drv" -ErrorAction SilentlyContinue
                $q = $reg.'HardwareInformation.qwMemorySize'
                if ($q -is [byte[]]) { $q = [BitConverter]::ToUInt64(($q + (New-Object byte[] 8))[0..7], 0) }
                if ($q) { $vram = [double]$q }
            }
            $gpus += @{ name = Short $d.FriendlyName; luid = [uint64]$luid; vram = $vram }
        }
        $Cache.gpus = $gpus
    }

    $os = Get-CimInstance Win32_OperatingSystem
    $ramTotal = [double]$os.TotalVisibleMemorySize * 1KB
    $ramUsed  = $ramTotal - [double]$os.FreePhysicalMemory * 1KB

    $cpuLoad = @{}; $eng = @{}; $ded = @{}; $shr = @{}
    $paths = '\Processor Information(*)\% Processor Utility', '\GPU Engine(*)\Utilization Percentage',
             '\GPU Adapter Memory(*)\Dedicated Usage', '\GPU Adapter Memory(*)\Shared Usage'
    foreach ($s in (Get-Counter $paths -ErrorAction SilentlyContinue).CounterSamples) {
        $inst = $s.InstanceName; $v = $s.CookedValue
        $luid = if ($inst -match 'luid_0x([0-9a-f]{8})_0x([0-9a-f]{8})') { [uint64]([Convert]::ToUInt64($matches[1], 16) -shl 32) + [Convert]::ToUInt64($matches[2], 16) }
        switch (($s.Path -split '\\')[-1]) {
            '% processor utility'    { if ($inst -match '^(\d+),_total$') { $cpuLoad[[int]$matches[1]] = $v } }
            'utilization percentage' {
                if ($null -ne $luid -and $inst -match 'engtype_(.+)$') {
                    if (-not $eng[$luid]) { $eng[$luid] = @{} }
                    $eng[$luid][$matches[1]] = [double]$eng[$luid][$matches[1]] + $v
                }
            }
            'dedicated usage' { if ($null -ne $luid) { $ded[$luid] = $v } }
            'shared usage'    { if ($null -ne $luid) { $shr[$luid] = $v } }
        }
    }

    $out = @()
    $cpus = @(Get-CimInstance Win32_Processor)
    for ($i = 0; $i -lt $cpus.Count; $i++) {
        $load = if ($cpuLoad.ContainsKey($i)) { $cpuLoad[$i] } else { $cpus[$i].LoadPercentage }
        $out += @{ name = Short $cpus[$i].Name; tag = $(if ($cpus.Count -gt 1) { "CPU $($i + 1)" } else { 'CPU' })
                   load = [math]::Min(100, [double]$load); mem = $(if ($i -eq 0) { Mem 'RAM' $ramUsed $ramTotal }) }
    }
    $n = 0
    foreach ($g in $Cache.gpus) {
        $n++
        # Task Manager's GPU % = busiest engine type (3D, Copy, Video Decode, Compute ...).
        $load = if ($eng[$g.luid]) { [math]::Min(100, ($eng[$g.luid].Values | Measure-Object -Maximum).Maximum) } else { $null }
        # Discrete cards report dedicated VRAM; integrated ones borrow system RAM (limit = half of it).
        $mem = if ($g.vram -gt 512MB) { Mem 'VRAM' ([double]$ded[$g.luid]) $g.vram } else { Mem 'Shared' ([double]$shr[$g.luid]) ($ramTotal / 2) }
        $out += @{ name = $g.name; tag = $(if (@($Cache.gpus).Count -gt 1) { "GPU $n" } else { 'GPU' }); load = $load; mem = $mem }
    }
    $out
}

# Is Claude Code running? True for the terminal CLI and for sessions in the Claude desktop app
# (which runs its own ...\claude-code\<version>\claude.exe). The desktop app shell alone does not count.
function Test-ClaudeCode {
    $cli = (Get-Command claude -ErrorAction SilentlyContinue).Source
    foreach ($p in Get-Process -Name claude -ErrorAction SilentlyContinue) {
        $path = try { $p.Path } catch { $null }
        if (-not $path) { continue }
        if ($path -match '\\claude-code\\' -or ($cli -and $path -eq $cli) -or $path -match '\\\.local\\bin\\claude\.exe$') { return $true }
    }
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue) {
        if ($p.CommandLine -match '@anthropic-ai[\\/]claude-code') { return $true }   # npm-installed CLI
    }
    $false
}

# ---------------------------------------------------------------- look & feel
$P = @{
    Card = '#EE111318'; Edge = '#22FFFFFF'; Text = '#ECEEF1'; Dim = '#8B919A'; Faint = '#5B626C'
    Track = '#1FFFFFFF'; Good = '#3DDC97'; Warn = '#F5B942'; Bad = '#FF5C6C'; None = '#4A5058'
}
$bc = New-Object Windows.Media.BrushConverter
function Brush($hex) { $bc.ConvertFromString($hex) }
function Level($remaining) {
    if ($null -eq $remaining) { $P.None } elseif ($remaining -ge 50) { $P.Good } elseif ($remaining -ge 20) { $P.Warn } else { $P.Bad }
}
function Until($dto) {
    if (-not $dto) { return '' }
    $s = $dto - [DateTimeOffset]::UtcNow
    if ($s.TotalSeconds -le 0) { return 'now' }
    if ($s.TotalDays -ge 1) { return '{0}d {1}h' -f [int][math]::Floor($s.TotalDays), $s.Hours }
    if ($s.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][math]::Floor($s.TotalHours), $s.Minutes }
    '{0}m' -f [math]::Max(1, [int][math]::Ceiling($s.TotalMinutes))
}
function Ago($dto) {
    $s = [DateTimeOffset]::UtcNow - $dto
    if ($s.TotalMinutes -lt 1) { 'just now' } elseif ($s.TotalHours -lt 1) { '{0}m ago' -f [int]$s.TotalMinutes }
    elseif ($s.TotalDays -lt 1) { '{0}h ago' -f [int][math]::Floor($s.TotalHours) } else { '{0}d ago' -f [int][math]::Floor($s.TotalDays) }
}
function Text($str, $size, $color, $weight = 'Normal') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $str; $t.FontSize = $size; $t.Foreground = Brush $color; $t.FontWeight = $weight
    $t.VerticalAlignment = 'Center'; $t
}
function Cols($grid, [string[]]$widths) {
    foreach ($w in $widths) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') }
                    elseif ($w -eq 'auto') { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength([double]$w) }
        [void]$grid.ColumnDefinitions.Add($cd)
    }
}
function Place($grid, $el, $col) { [Windows.Controls.Grid]::SetColumn($el, $col); [void]$grid.Children.Add($el) }

$script:Countdowns = New-Object Collections.ArrayList

# Load meters: fuller is worse.
function LoadLevel($used) {
    if ($null -eq $used) { $P.None } elseif ($used -lt 60) { $P.Good } elseif ($used -lt 85) { $P.Warn } else { $P.Bad }
}

# One labelled bar: label | bar | percent | right-hand note.
function New-Meter($label, $fillPct, $color, $pctText, $note) {
    $g = New-Object Windows.Controls.Grid; $g.Margin = '0,7,0,0'
    Cols $g @('40', '*', '46', '58')
    Place $g (Text $label 11 $P.Dim) 0
    $track = New-Object Windows.Controls.Border
    $track.Height = 6; $track.CornerRadius = 3; $track.Background = Brush $P.Track; $track.VerticalAlignment = 'Center'
    $inner = New-Object Windows.Controls.Grid
    $fillPct = [math]::Min(100, [math]::Max(0, [double]$fillPct))
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength([math]::Max(0.001, $fillPct), 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = New-Object Windows.GridLength([math]::Max(0.001, 100 - $fillPct), 'Star')
    [void]$inner.ColumnDefinitions.Add($c1); [void]$inner.ColumnDefinitions.Add($c2)
    if ($fillPct -gt 0) {
        $fill = New-Object Windows.Controls.Border
        $fill.CornerRadius = 3; $fill.Background = Brush $color
        $glow = New-Object Windows.Media.Effects.DropShadowEffect
        $glow.Color = [Windows.Media.ColorConverter]::ConvertFromString($color); $glow.BlurRadius = 8; $glow.ShadowDepth = 0; $glow.Opacity = 0.55
        $fill.Effect = $glow
        Place $inner $fill 0
    }
    $track.Child = $inner
    Place $g $track 1
    $pct = Text $pctText 12 $color 'SemiBold'; $pct.HorizontalAlignment = 'Right'
    Place $g $pct 2
    $rs = Text $note 10.5 $P.Faint; $rs.HorizontalAlignment = 'Right'
    Place $g $rs 3
    $g
}

function New-UsageRow($label, $used, $note) {
    $pct = if ($null -ne $used) { '{0:0}%' -f $used } else { '--' }
    New-Meter $label $(if ($null -ne $used) { $used } else { 0 }) (LoadLevel $used) $pct $note
}

# Header line shared by providers and devices: status dot | name | small tag.
function New-Header($name, $dotColor, $tag) {
    $h = New-Object Windows.Controls.Grid
    Cols $h @('14', '*', 'auto')
    $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 8; $dot.Height = 8; $dot.Fill = Brush $dotColor
    $dot.HorizontalAlignment = 'Left'
    Place $h $dot 0
    $n = Text $name 13 $P.Text 'SemiBold'; $n.TextTrimming = 'CharacterEllipsis'
    Place $h $n 1
    if ($tag) { $t = Text ([string]$tag).ToUpper() 9.5 $P.Faint 'SemiBold'; $t.Margin = '6,0,0,0'; Place $h $t 2 }
    $h
}

function New-Device($d) {
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = '0,12,0,0'
    $worst = (@($d.load, $d.mem.used) | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum
    [void]$sp.Children.Add((New-Header $d.name (LoadLevel $worst) $d.tag))
    [void]$sp.Children.Add((New-UsageRow 'Load' $d.load ''))
    if ($d.mem) { [void]$sp.Children.Add((New-UsageRow $d.mem.label $d.mem.used $d.mem.text)) }
    $sp
}

function New-BarRow($label, $win) {
    $remaining = if ($win) { 100 - $win.used } else { $null }
    $color = Level $remaining
    $g = New-Meter $label $(if ($null -ne $remaining) { $remaining } else { 0 }) $color $(if ($null -ne $remaining) { '{0:0}%' -f $remaining } else { '--' }) ''
    $rs = $g.Children[3]
    if ($win) {
        switch ($win.state) {
            'active' { $rs.Text = Until $win.resets; [void]$script:Countdowns.Add(@{ tb = $rs; at = $win.resets }) }
            'idle'   { $rs.Text = 'idle' }
            'reset'  { $rs.Text = 'reset' }
        }
        $tip = 'Used {0:0.#}%' -f $win.used
        if ($win.resets) { $tip += '  -  resets ' + $win.resets.LocalDateTime.ToString('ddd h:mm tt') }
        elseif ($win.state -eq 'idle') { $tip += '  -  window starts on next use' }
        $g.ToolTip = $tip
    }
    $g
}

function New-Provider($name, $d) {
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = '0,14,0,0'
    $rem = @()
    if ($d.ok) { foreach ($w in $d.five, $d.week) { if ($w) { $rem += 100 - $w.used } } }
    $worst = if ($rem.Count) { ($rem | Measure-Object -Minimum).Minimum } else { $null }
    [void]$sp.Children.Add((New-Header $name (Level $worst) $d.plan))

    if ($d.ok) {
        [void]$sp.Children.Add((New-BarRow '5h' $d.five))
        [void]$sp.Children.Add((New-BarRow 'Week' $d.week))
        if ($d.asOf -and ([DateTimeOffset]::UtcNow - $d.asOf).TotalMinutes -gt 10) {
            $n = Text ('last seen ' + (Ago $d.asOf)) 10 $P.Faint; $n.Margin = '14,5,0,0'
            [void]$sp.Children.Add($n)
        }
    } else {
        $e = Text $d.err 10.5 $P.Dim; $e.Margin = '14,6,0,0'; $e.TextWrapping = 'Wrap'
        [void]$sp.Children.Add($e)
    }
    $sp
}

# ---------------------------------------------------------------- window
$cfg = @{ Left = $null; Top = $null; Topmost = $false; CloseWithClaude = $true; ShowSystem = $true }
if (Test-Path $ConfigPath) { try { (Get-Content $ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch {} }
function Save-Config { if ($Snapshot) { return }; New-Item -ItemType Directory -Force $ConfigDir | Out-Null; $cfg | ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8 }

$win = New-Object Windows.Window
$win.WindowStyle = 'None'; $win.AllowsTransparency = $true; $win.Background = [Windows.Media.Brushes]::Transparent
$win.ShowInTaskbar = $false; $win.ResizeMode = 'NoResize'; $win.SizeToContent = 'Height'; $win.Width = 300
$win.Topmost = [bool]$cfg.Topmost; $win.Title = 'TokenThrifter'
$win.FontFamily = New-Object Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')
$win.WindowStartupLocation = 'Manual'
if ($null -ne $cfg.Left) { $win.Left = $cfg.Left; $win.Top = $cfg.Top }
else { $wa = [Windows.SystemParameters]::WorkArea; $win.Left = $wa.Right - 320; $win.Top = $wa.Top + 20 }

$card = New-Object Windows.Controls.Border
$card.CornerRadius = 14; $card.Background = Brush $P.Card; $card.BorderBrush = Brush $P.Edge; $card.BorderThickness = 1
$card.Padding = '16,12,16,14'; $card.Margin = 10
$shadow = New-Object Windows.Media.Effects.DropShadowEffect; $shadow.BlurRadius = 18; $shadow.ShadowDepth = 2; $shadow.Opacity = 0.45
$card.Effect = $shadow

$root = New-Object Windows.Controls.StackPanel
$head = New-Object Windows.Controls.Grid; Cols $head @('*', 'auto')
$title = Text 'REMAINING' 10 $P.Dim 'SemiBold'; $title.Margin = '0,2,0,0'
Place $head $title 0
$stamp = Text 'loading...' 10 $P.Faint; Place $head $stamp 1
[void]$root.Children.Add($head)
$body = New-Object Windows.Controls.StackPanel
[void]$root.Children.Add($body)

# CPU / GPU section
$sysPanel = New-Object Windows.Controls.StackPanel; $sysPanel.Margin = '0,14,0,0'
$rule = New-Object Windows.Controls.Border; $rule.Height = 1; $rule.Background = Brush $P.Track
[void]$sysPanel.Children.Add($rule)
$sysTitle = Text 'IN USE' 10 $P.Dim 'SemiBold'; $sysTitle.Margin = '0,12,0,0'
[void]$sysPanel.Children.Add($sysTitle)
$sysBody = New-Object Windows.Controls.StackPanel
[void]$sysPanel.Children.Add($sysBody)
$sysPanel.Visibility = if ($cfg.ShowSystem) { 'Visible' } else { 'Collapsed' }
[void]$root.Children.Add($sysPanel)
$card.Child = $root
$win.Content = $card

$win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch {} })
$win.Add_LocationChanged({ $cfg.Left = $win.Left; $cfg.Top = $win.Top })
$win.Add_Closing({ Save-Config })

# Context menu
$menu = New-Object Windows.Controls.ContextMenu
function Item($header, $action, [switch]$Check, $checked) {
    $mi = New-Object Windows.Controls.MenuItem; $mi.Header = $header
    if ($Check) { $mi.IsCheckable = $true; $mi.IsChecked = $checked }
    $mi.Add_Click($action); [void]$menu.Items.Add($mi); $mi
}
[void](Item 'Refresh now' { Start-Fetch })
[void](Item 'Always on top' { $win.Topmost = $this.IsChecked; $cfg.Topmost = $this.IsChecked; Save-Config } -Check ([bool]$cfg.Topmost))
[void](Item 'Close with Claude Code' { $cfg.CloseWithClaude = $this.IsChecked; Save-Config } -Check ([bool]$cfg.CloseWithClaude))
[void](Item 'Show CPU / GPU' {
    $cfg.ShowSystem = $this.IsChecked; Save-Config
    $sysPanel.Visibility = if ($cfg.ShowSystem) { 'Visible' } else { 'Collapsed' }
    if ($cfg.ShowSystem) { Start-SysFetch }
} -Check ([bool]$cfg.ShowSystem))
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void](Item 'Exit' { $win.Close() })
$card.ContextMenu = $menu

function Save-Snapshot {
    $card.UpdateLayout()
    $w = [int]$card.ActualWidth + 20; $h = [int]$card.ActualHeight + 20
    $rtb = [Windows.Media.Imaging.RenderTargetBitmap]::new($w * 2, $h * 2, 192, 192, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($card)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
}

# ---------------------------------------------------------------- refresh loop
$script:ps = $null; $script:handle = $null; $script:lastFetch = [DateTimeOffset]::MinValue; $script:lastOk = $null
$script:claudeMisses = 0

function Start-Fetch {
    if ($script:handle) { return }
    $script:ps = [powershell]::Create(); [void]$script:ps.AddScript($Fetch).AddArgument([bool]$Demo)
    $script:handle = $script:ps.BeginInvoke(); $script:lastFetch = [DateTimeOffset]::UtcNow
    $stamp.Text = 'updating...'
}

function Render($data) {
    $script:Countdowns.Clear(); $body.Children.Clear()
    [void]$body.Children.Add((New-Provider 'Claude Code' $data.claude))
    [void]$body.Children.Add((New-Provider 'Z.ai GLM' $data.zai))
    [void]$body.Children.Add((New-Provider 'ChatGPT Codex' $data.codex))
}

# CPU / GPU refresh: its own runspace so a slow counter read never delays the token rows.
$SysSeconds = 5
$script:sps = $null; $script:shandle = $null; $script:lastSys = [DateTimeOffset]::MinValue
$script:sysDone = -not $cfg.ShowSystem; $script:mainDone = $false
$SysCache = [hashtable]::Synchronized(@{})

function Start-SysFetch {
    if ($script:shandle -or -not $cfg.ShowSystem) { return }
    $script:sps = [powershell]::Create(); [void]$script:sps.AddScript($SysFetch).AddArgument([bool]$Demo).AddArgument($SysCache)
    $script:shandle = $script:sps.BeginInvoke(); $script:lastSys = [DateTimeOffset]::UtcNow
}

function Render-System($devs) {
    $sysBody.Children.Clear()
    foreach ($d in $devs) { if ($d) { [void]$sysBody.Children.Add((New-Device $d)) } }
    if (-not $sysBody.Children.Count) {
        $e = Text 'No CPU / GPU readings available' 10.5 $P.Dim; $e.Margin = '14,8,0,0'
        [void]$sysBody.Children.Add($e)
    }
}

function Save-SnapshotWhenReady {
    if ($Snapshot -and $script:mainDone -and $script:sysDone) {
        $stamp.Text = 'updated just now'
        $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ContextIdle, [Action]{ Save-Snapshot; $win.Close() }) | Out-Null
    }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$script:tick = 0
$script:lastTick = [DateTimeOffset]::UtcNow
$timer.Add_Tick({
    # A long gap between 1 s ticks means the PC slept: refresh ~20 s after wake, once the network is back.
    $nowTick = [DateTimeOffset]::UtcNow
    if (($nowTick - $script:lastTick).TotalSeconds -gt 60) { $script:lastFetch = $nowTick.AddSeconds(20 - $RefreshSeconds) }
    $script:lastTick = $nowTick
    if ($script:handle -and $script:handle.IsCompleted) {
        try {
            $res = $script:ps.EndInvoke($script:handle); Render $res[0]; $script:lastOk = [DateTimeOffset]::UtcNow
            # Claude row failed (e.g. sign-in refresh pending): retry in ~1 min instead of waiting the full interval.
            if (-not $res[0].claude.ok -and -not $Snapshot) { $script:lastFetch = [DateTimeOffset]::UtcNow.AddSeconds(60 - $RefreshSeconds) }
        }
        catch { $stamp.Text = 'update failed' }
        finally { $script:ps.Dispose(); $script:handle = $null; $script:mainDone = $true; Save-SnapshotWhenReady }
    }
    if ($script:shandle -and $script:shandle.IsCompleted) {
        try { Render-System @($script:sps.EndInvoke($script:shandle)) } catch {}
        finally { $script:sps.Dispose(); $script:shandle = $null; if (-not $script:sysDone) { $script:sysDone = $true; Save-SnapshotWhenReady } }
    }
    if (([DateTimeOffset]::UtcNow - $script:lastFetch).TotalSeconds -ge $RefreshSeconds) { Start-Fetch }
    if (-not $Snapshot -and ([DateTimeOffset]::UtcNow - $script:lastSys).TotalSeconds -ge $SysSeconds) { Start-SysFetch }
    if (($script:tick++ % 15) -eq 0) {
        foreach ($c in $script:Countdowns) { $c.tb.Text = Until $c.at }
        if (-not $script:handle -and $script:lastOk) { $stamp.Text = 'updated ' + (Ago $script:lastOk) }
        # Exit ~45s after the last Claude Code session closes
        if ($cfg.CloseWithClaude -and -not $Snapshot -and -not $Demo) {
            if (Test-ClaudeCode) { $script:claudeMisses = 0 } elseif (++$script:claudeMisses -ge 3) { $win.Close() }
        }
    }
})

Start-Fetch
Start-SysFetch
$timer.Start()
[void]$win.ShowDialog()
$timer.Stop()
if ($mutex) { $mutex.ReleaseMutex() }

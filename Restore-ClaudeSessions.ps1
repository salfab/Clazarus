<#
.SYNOPSIS
    Clazarus: resurrects Claude Code sessions interrupted by a reboot.

.DESCRIPTION
    Claude Code keeps every session in ~/.claude/projects/<project>/<session-id>.jsonl, even
    after it is closed. This script lists them newest first and pre-selects those whose last
    activity falls within -Hours hours of the most recent one before boot: the group that was
    running at shutdown, however long the machine stayed off.

    Arrows: move   Space: toggle   A: all/none   Enter: resurrect   Esc: quit

.EXAMPLE
    .\Restore-ClaudeSessions.ps1
    .\Restore-ClaudeSessions.ps1 -Hours 3 -Days 7
    .\Restore-ClaudeSessions.ps1 -ListOnly
#>
param(
    # Width of the pre-selected group, measured back from the most recent session
    [double]$Hours = 5,
    # Sessions shown: last activity less than N days ago
    [int]$Days = 30,
    # Also include desktop app sessions (they stay in the app's sidebar anyway)
    [switch]$IncludeDesktop,
    # Print the list without the interactive picker
    [switch]$ListOnly
)

$claudeDir   = Join-Path $env:USERPROFILE '.claude'
$registryDir = Join-Path $claudeDir 'sessions'
$boot        = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

# Sessions whose claude process is still running (registry ~/.claude/sessions/<pid>.json)
function Get-LiveSessions {
    if (-not (Test-Path $registryDir)) { return }
    foreach ($f in Get-ChildItem $registryDir -Filter *.json -File) {
        $j = try { Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
        if (-not $j -or -not $j.sessionId) { continue }
        $p = Get-Process -Id $j.pid -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        # Same PID but a different start time = PID reused by Windows
        if ($j.procStart -and [math]::Abs(($p.StartTime - [DateTime]::FromFileTime([int64]$j.procStart)).TotalSeconds) -gt 2) { continue }
        $j
    }
}

function Cut($text, $n) { if ($text.Length -le $n) { $text } else { $text.Substring(0, $n - 1) + '~' } }

# Title column: at most 40 characters, half of the remaining space on a narrow console
$consoleWidth = try { [Console]::WindowWidth } catch { 160 }
$titleWidth = [math]::Max(12, [math]::Min(40, [int](($consoleWidth - 23) / 2)))

function Format-Row($s, [bool]$isChecked, $num) {
    $box = if ($s.Live) { 'live' } elseif ($isChecked) { '[x] ' } else { '[ ] ' }
    "{0,3} {1} {2:dd.MM HH:mm}  {3} {4}" -f $num, $box, $s.LastActivity, (Cut $s.Title $titleWidth).PadRight($titleWidth), $s.Directory
}

function Get-RowColor($s) {
    if ($s.Live) { 'DarkGray' } elseif ($s.InGroup) { 'White' } else { 'Gray' }
}

# Keyboard checklist; returns the indexes of the checked rows
function Show-Picker($items, [bool[]]$checked) {
    $width = [Console]::WindowWidth - 1
    $view = [math]::Min($items.Count, [math]::Max(5, [Console]::WindowHeight - 6))
    $cursor = 0; $top = 0

    Write-Host 'Arrows: move   Space: toggle   A: all/none   Enter: resurrect   Esc: quit' -ForegroundColor DarkGray
    # Reserve the space first: if the console scrolls, the origin stays correct
    for ($r = 0; $r -le $view; $r++) { Write-Host '' }
    $origin = [Console]::CursorTop - ($view + 1)
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            if ($cursor -lt $top) { $top = $cursor }
            if ($cursor -ge $top + $view) { $top = $cursor - $view + 1 }
            for ($r = 0; $r -lt $view; $r++) {
                $i = $top + $r
                [Console]::SetCursorPosition(0, $origin + $r)
                $line = (Cut (Format-Row $items[$i] $checked[$i] ($i + 1)) $width).PadRight($width)
                if ($i -eq $cursor) { Write-Host $line -NoNewline -ForegroundColor Black -BackgroundColor Gray }
                else { Write-Host $line -NoNewline -ForegroundColor (Get-RowColor $items[$i]) }
            }
            [Console]::SetCursorPosition(0, $origin + $view)
            $count = @($checked | Where-Object { $_ }).Count
            $range = if ($items.Count -gt $view) { "   rows $($top + 1)-$($top + $view) of $($items.Count)" } else { '' }
            Write-Host ("    {0} selected{1}" -f $count, $range).PadRight($width) -NoNewline -ForegroundColor DarkGray

            $key = [Console]::ReadKey($true).Key.ToString()
            switch ($key) {
                'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $items.Count - 1) { $cursor++ } }
                'PageUp'    { $cursor = [math]::Max(0, $cursor - $view) }
                'PageDown'  { $cursor = [math]::Min($items.Count - 1, $cursor + $view) }
                'Home'      { $cursor = 0 }
                'End'       { $cursor = $items.Count - 1 }
                'Spacebar'  { if (-not $items[$cursor].Live) { $checked[$cursor] = -not $checked[$cursor] } }
                'A' {
                    $value = -not ($checked -contains $true)
                    for ($j = 0; $j -lt $items.Count; $j++) { if (-not $items[$j].Live) { $checked[$j] = $value } }
                }
                'Enter'  { return @(for ($j = 0; $j -lt $items.Count; $j++) { if ($checked[$j]) { $j } }) }
                'Escape' { return @() }
                'Q'      { return @() }
            }
        }
    } finally {
        [Console]::SetCursorPosition(0, $origin + $view)
        Write-Host ''
        [Console]::CursorVisible = $true
    }
}

# ---------------------------------------------------------------- Collect
$live = @{}
foreach ($s in Get-LiveSessions) { $live[$s.sessionId] = $s }

$since = (Get-Date).AddDays(-$Days)
# Only transcripts at the root of each project (subfolders hold subagent transcripts)
$files = Get-ChildItem (Join-Path $claudeDir 'projects') -Directory | ForEach-Object {
    Get-ChildItem $_.FullName -File -Filter *.jsonl
} | Where-Object { $_.LastWriteTime -ge $since }

$sessions = foreach ($f in $files) {
    $cwd = $null; $entry = $null
    foreach ($line in (Get-Content $f.FullName -TotalCount 50 -Encoding UTF8)) {
        if ($line -notmatch '"cwd"') { continue }
        $j = $line | ConvertFrom-Json
        if ($j.cwd) { $cwd = $j.cwd; $entry = $j.entrypoint; break }
    }
    if (-not $cwd) { continue }
    if (-not $IncludeDesktop -and $entry -and $entry -ne 'cli') { continue }

    # Title: the registry name if the session is running, else the last /rename (custom-title),
    # else the generated title (ai-title)
    $title = if ($live.ContainsKey($f.BaseName)) { $live[$f.BaseName].name }
    if (-not $title) {
        $titles = Select-String -Path $f.FullName -Pattern '"type":"(custom-title|ai-title)"' -Encoding UTF8
        $custom = $titles | Where-Object { $_.Line -match '"custom-title"' } | Select-Object -Last 1
        $pickLine = if ($custom) { $custom } else { $titles | Select-Object -Last 1 }
        if ($pickLine) {
            $t = $pickLine.Line | ConvertFrom-Json
            $title = if ($t.customTitle) { $t.customTitle } else { $t.aiTitle }
        }
    }

    [pscustomobject]@{
        LastActivity = $f.LastWriteTime
        Title        = if ($title) { $title } else { '(untitled)' }
        Directory    = $cwd
        SessionId    = $f.BaseName
        Live         = $live.ContainsKey($f.BaseName)
        InGroup      = $false
    }
}
$sessions = @($sessions | Sort-Object LastActivity -Descending)
if (-not $sessions) { Write-Host "No sessions in the last $Days days."; return }

# Reference = the most recent closed session from before boot (else the most recent closed one):
# a session opened then closed again after the reboot does not shift the group
$closed = @($sessions | Where-Object { -not $_.Live })
$beforeBoot = @($closed | Where-Object { $_.LastActivity -lt $boot })
$reference = if ($beforeBoot) { $beforeBoot[0] } elseif ($closed) { $closed[0] }
if ($reference) {
    $limit = $reference.LastActivity.AddHours(-$Hours)
    foreach ($s in $closed) {
        if ($s.LastActivity -le $reference.LastActivity -and $s.LastActivity -ge $limit) { $s.InGroup = $true }
    }
}

Write-Host ("Last boot: {0:dd.MM.yyyy HH:mm}" -f $boot)
if ($reference) {
    Write-Host ("Pre-selected: sessions active between {0:dd.MM HH:mm} and {1:dd.MM HH:mm} ({2} h window)" -f `
        $limit, $reference.LastActivity, $Hours)
}
Write-Host ''

if ($ListOnly -or [Console]::IsInputRedirected) {
    for ($i = 0; $i -lt $sessions.Count; $i++) {
        Write-Host (Format-Row $sessions[$i] $sessions[$i].InGroup ($i + 1)) -ForegroundColor (Get-RowColor $sessions[$i])
    }
    return
}

$checked = [bool[]]@($sessions | ForEach-Object { $_.InGroup })
$chosen = @(Show-Picker $sessions $checked | ForEach-Object { $sessions[$_] })
if (-not $chosen) { Write-Host 'Nothing to resurrect.'; return }

# ---------------------------------------------------------------- Resurrect
$chosen = @($chosen | Where-Object {
    if (Test-Path $_.Directory) { $true } else { Write-Warning "Folder not found, skipped: $($_.Directory)"; $false }
})
if (-not $chosen) { return }

if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
    # One wt call with every tab chained by ";": no race between windows.
    # Run from Windows Terminal: tabs go into the current window (-w 0), else into a new one.
    $window = if ($env:WT_SESSION) { '0' } else { 'new' }
    $tabs = foreach ($s in $chosen) {
        # wt reads ";" as a command separator, and the title is quoted
        $tabTitle = $s.Title -replace '"', "'" -replace ';', ','
        "new-tab -d `"$($s.Directory)`" --title `"$tabTitle`" claude --resume $($s.SessionId) --remote-control `"$tabTitle`""
    }
    Start-Process wt.exe -ArgumentList ("-w $window " + ($tabs -join ' ; '))
} else {
    foreach ($s in $chosen) {
        $rcName = $s.Title -replace "'", "''"
        Start-Process powershell.exe -WorkingDirectory $s.Directory -ArgumentList '-NoExit', '-Command', "claude --resume $($s.SessionId) --remote-control '$rcName'"
    }
}
$chosen | ForEach-Object { Write-Host "Resurrected: $($_.Title)" }

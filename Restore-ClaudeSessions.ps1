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
    [switch]$ListOnly,
    # Skip the update check of the installed copy
    [switch]$NoUpdate
)

# ---------------------------------------------------------------- Self-update check
# Only the installed copy (a "version" file next to it) follows GitHub's main branch.
# GitHub is asked in the background while the sessions are collected, so the check costs no time.
$versionFile = Join-Path $PSScriptRoot 'version'
$updateCheck = $null
if (-not $NoUpdate -and (Test-Path $versionFile)) {
    $updateCheck = [powershell]::Create().AddScript({
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        (Invoke-RestMethod 'https://api.github.com/repos/salfab/Clazarus/commits/main' -TimeoutSec 3 -UseBasicParsing).sha
    })
    $updateHandle = $updateCheck.BeginInvoke()
}

$claudeDir   = Join-Path $env:USERPROFILE '.claude'
$registryDir = Join-Path $claudeDir 'sessions'
$boot        = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

# ---------------------------------------------------------------- Styling
# 24-bit ANSI colors; stripped when the console cannot render escape sequences
$vt = $(try { [bool]$Host.UI.SupportsVirtualTerminal } catch { $false }) -and -not [Console]::IsOutputRedirected
$esc = [char]27
$reset = "$esc[0m"
$palette = @{
    from     = 217, 119, 87    # Claude coral, start of the banner gradient
    to       = 246, 200, 122   # warm gold, end of the gradient
    accent   = 230, 140, 95    # brand color, banner only
    text     = 235, 235, 240
    soft     = 160, 160, 172
    dim      = 110, 110, 122
    time     = 120, 180, 200
    selected = 110, 200, 140   # green: chosen, not a warning
    cursor   = 140, 175, 255
    cursorBg = 38, 46, 68
}

function Fg([int[]]$rgb) { "$esc[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m" }
function Bg([int[]]$rgb) { "$esc[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m" }
function Paint($text, [int[]]$rgb) { "$(Fg $rgb)$text$reset" }

function Write-Ansi([string]$text, [switch]$NoNewline) {
    if (-not $vt) { $text = $text -replace "$esc\[[0-9;]*m", '' }
    Write-Host $text -NoNewline:$NoNewline
}

# "ANSI Shadow" letters, 6 rows each
$glyphs = @{
    C = @(' ██████╗', '██╔════╝', '██║     ', '██║     ', '╚██████╗', ' ╚═════╝')
    L = @('██╗     ', '██║     ', '██║     ', '██║     ', '███████╗', '╚══════╝')
    A = @(' █████╗ ', '██╔══██╗', '███████║', '██╔══██║', '██║  ██║', '╚═╝  ╚═╝')
    Z = @('███████╗', '╚══███╔╝', '  ███╔╝ ', ' ███╔╝  ', '███████╗', '╚══════╝')
    R = @('██████╗ ', '██╔══██╗', '██████╔╝', '██╔══██╗', '██║  ██║', '╚═╝  ╚═╝')
    U = @('██╗   ██╗', '██║   ██║', '██║   ██║', '██║   ██║', '╚██████╔╝', ' ╚═════╝ ')
    S = @('███████╗', '██╔════╝', '███████╗', '╚════██║', '███████║', '╚══════╝')
}

function Write-Banner {
    $rows = for ($r = 0; $r -lt 6; $r++) { -join ('CLAZARUS'.ToCharArray() | ForEach-Object { $glyphs[[string]$_][$r] }) }
    $len = $rows[0].Length
    $from = $palette.from; $to = $palette.to
    foreach ($row in $rows) {
        $sb = New-Object System.Text.StringBuilder '  '
        for ($i = 0; $i -lt $row.Length; $i++) {
            $ch = $row[$i]
            if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
            # Horizontal gradient; the box-drawing "shadow" is a darker shade of the same color
            $t = $i / ($len - 1)
            $k = if ($ch -eq [char]0x2588) { 1.0 } else { 0.45 }
            $rgb = @(0, 1, 2 | ForEach-Object { [int](($from[$_] + ($to[$_] - $from[$_]) * $t) * $k) })
            [void]$sb.Append((Fg $rgb)).Append($ch)
        }
        Write-Ansi ($sb.ToString() + $reset)
    }
    $tagline = 'rise and resume  ·  Claude Code session resurrector'
    Write-Ansi ((' ' * [math]::Max(2, $len + 2 - $tagline.Length)) + (Paint $tagline $palette.dim))
}

# ---------------------------------------------------------------- Sessions
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

function Cut($text, $n) {
    if ($n -le 0) { '' } elseif ($text.Length -le $n) { $text } else { $text.Substring(0, $n - 1) + '~' }
}

$consoleWidth  = try { [Console]::WindowWidth } catch { 160 }
$consoleHeight = try { [Console]::WindowHeight } catch { 40 }
$rowWidth = $consoleWidth - 1
# Title column: at most 40 characters, half of the remaining space on a narrow console
$titleWidth = [math]::Max(12, [math]::Min(40, [int](($consoleWidth - 23) / 2)))

# Row layout: pointer, mark, time, title, folder
function Format-Row($s, [bool]$isChecked, [bool]$isCursor) {
    if ($isChecked) { $mark = '●'; $markColor = $palette.selected; $titleColor = $palette.text }
    else            { $mark = '○'; $markColor = $palette.dim;      $titleColor = $palette.soft }
    $pointer = if ($isCursor) { '►' } else { ' ' }
    $bg = if ($isCursor) { Bg $palette.cursorBg } else { '' }
    $dirWidth = $rowWidth - 19 - $titleWidth
    $title = (Cut $s.Title $titleWidth).PadRight($titleWidth)
    $dir = (Cut $s.Directory $dirWidth).PadRight([math]::Max(0, $dirWidth))
    # No reset inside the row, so the cursor background spans the whole line
    "$bg$(Fg $palette.cursor)$pointer $(Fg $markColor)$mark  $(Fg $palette.time)$('{0:dd.MM HH:mm}' -f $s.LastActivity)  " +
        "$(Fg $titleColor)$title $(Fg $palette.dim)$dir$reset"
}

function Write-ColumnHeader {
    $header = '     ' + 'LAST ACTIVE'.PadRight(13) + 'SESSION'.PadRight($titleWidth + 1) + 'FOLDER'
    Write-Ansi (Paint $header $palette.dim)
    Write-Ansi (Paint ('─' * $rowWidth) $palette.dim)
}

function Format-Footer($count, $top, $view, $total) {
    $hints = @(('↑↓', 'move'), ('space', 'toggle'), ('a', 'all/none'), ('enter', 'resurrect'), ('esc', 'quit'))
    $plain = ($hints | ForEach-Object { "$($_[0]) $($_[1])" }) -join '   '
    $colored = ($hints | ForEach-Object { "$(Paint $_[0] $palette.text) $(Paint $_[1] $palette.dim)" }) -join '   '
    # Narrow console: keys only, so the footer never wraps and breaks the redraw
    if ($plain.Length + 2 -gt $rowWidth) {
        $plain = ($hints | ForEach-Object { $_[0] }) -join '  '
        $colored = ($hints | ForEach-Object { Paint $_[0] $palette.text }) -join '  '
    }
    if ($plain.Length + 2 -gt $rowWidth) { return '' }
    $status = "$count selected"
    if ($total -gt $view) { $status += "  ·  $($top + 1)-$($top + $view) of $total" }
    $gap = $rowWidth - 2 - $plain.Length - $status.Length
    if ($gap -lt 2) { return '  ' + $colored }
    '  ' + $colored + (' ' * $gap) + (Paint $status $palette.selected)
}

# Keyboard checklist; returns the indexes of the checked rows
function Show-Picker($items, [bool[]]$checked, [int]$view) {
    $cursor = 0; $top = 0
    # Reserve the space first: if the console scrolls, the origin stays correct
    for ($r = 0; $r -lt $view + 2; $r++) { Write-Host '' }
    $origin = [Console]::CursorTop - ($view + 2)
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            if ($cursor -lt $top) { $top = $cursor }
            if ($cursor -ge $top + $view) { $top = $cursor - $view + 1 }
            for ($r = 0; $r -lt $view; $r++) {
                $i = $top + $r
                [Console]::SetCursorPosition(0, $origin + $r)
                Write-Ansi (Format-Row $items[$i] $checked[$i] ($i -eq $cursor)) -NoNewline
            }
            [Console]::SetCursorPosition(0, $origin + $view)
            Write-Ansi (Paint ('─' * $rowWidth) $palette.dim) -NoNewline
            [Console]::SetCursorPosition(0, $origin + $view + 1)
            $count = @($checked | Where-Object { $_ }).Count
            Write-Ansi (Format-Footer $count $top $view $items.Count) -NoNewline

            $key = [Console]::ReadKey($true).Key.ToString()
            switch ($key) {
                'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $items.Count - 1) { $cursor++ } }
                'PageUp'    { $cursor = [math]::Max(0, $cursor - $view) }
                'PageDown'  { $cursor = [math]::Min($items.Count - 1, $cursor + $view) }
                'Home'      { $cursor = 0 }
                'End'       { $cursor = $items.Count - 1 }
                'Spacebar'  { $checked[$cursor] = -not $checked[$cursor] }
                'A' {
                    $value = -not ($checked -contains $true)
                    for ($j = 0; $j -lt $items.Count; $j++) { $checked[$j] = $value }
                }
                'Enter'  { return @(for ($j = 0; $j -lt $items.Count; $j++) { if ($checked[$j]) { $j } }) }
                'Escape' { return @() }
                'Q'      { return @() }
            }
        }
    } finally {
        [Console]::SetCursorPosition(0, $origin + $view + 1)
        Write-Host ''
        [Console]::CursorVisible = $true
    }
}

# ---------------------------------------------------------------- Banner
# Shown before the sessions are read, so the command answers at once
$bannerShown = $consoleWidth -ge 70 -and $consoleHeight -ge 24
Write-Host ''
if ($bannerShown) { Write-Banner }
else { Write-Ansi ('  ' + (Paint 'CLAZARUS' $palette.accent) + '  ' + (Paint 'rise and resume' $palette.dim)) }
Write-Host ''
$bannerLines = if ($bannerShown) { 9 } else { 3 }

# One status line, rewritten in place, then erased before the header takes its place
$showStatus = -not [Console]::IsOutputRedirected
function Write-Status($text) {
    if (-not $showStatus) { return }
    # Never wider than the console: a wrapped status line would no longer be rewritten in place
    $w = [math]::Max(0, $rowWidth - 2)
    Write-Ansi ("`r  " + (Paint (Cut $text $w).PadRight([math]::Min(40, $w)) $palette.dim)) -NoNewline
}
function Clear-Status { if ($showStatus) { Write-Host ("`r" + (' ' * $rowWidth) + "`r") -NoNewline } }

# ---------------------------------------------------------------- Collect
Write-Status 'reading sessions...'
$live = @{}
foreach ($s in Get-LiveSessions) { $live[$s.sessionId] = $s }

$since = (Get-Date).AddDays(-$Days)
# Only transcripts at the root of each project (subfolders hold subagent transcripts)
$files = @(Get-ChildItem (Join-Path $claudeDir 'projects') -Directory | ForEach-Object {
    Get-ChildItem $_.FullName -File -Filter *.jsonl
} | Where-Object { $_.LastWriteTime -ge $since })

$read = 0
$sessions = foreach ($f in $files) {
    $read++
    Write-Status "reading sessions  $read/$($files.Count)"
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

# ---------------------------------------------------------------- Self-update
if ($updateCheck) {
    try {
        if (-not $updateHandle.IsCompleted) { Write-Status 'checking for updates...' }
        $latest = if ($updateHandle.AsyncWaitHandle.WaitOne(3000)) { @($updateCheck.EndInvoke($updateHandle))[0] }
        $current = (Get-Content $versionFile -Raw).Trim()
        if ($latest -and $latest -ne $current) {
            Write-Status "updating Clazarus to $($latest.Substring(0, 7))..."
            $ProgressPreference = 'SilentlyContinue'
            # Pinned to the commit, so a stale raw.githubusercontent.com cache cannot serve an older file
            $download = "$PSCommandPath.download"
            Invoke-WebRequest "https://raw.githubusercontent.com/salfab/Clazarus/$latest/Restore-ClaudeSessions.ps1" `
                -OutFile $download -UseBasicParsing -TimeoutSec 10
            Move-Item $download $PSCommandPath -Force
            Set-Content $versionFile $latest -Encoding ASCII
            # The new version draws its own banner: erase this one first
            Clear-Status
            if ($vt) {
                [Console]::SetCursorPosition(0, [math]::Max(0, [Console]::CursorTop - $bannerLines))
                Write-Host "$esc[J" -NoNewline
            }
            $PSBoundParameters['NoUpdate'] = $true
            & $PSCommandPath @PSBoundParameters
            return
        }
    } catch {
        # Offline or GitHub unreachable: run the installed version as it is
    } finally {
        $updateCheck.Dispose()
    }
}

# ---------------------------------------------------------------- Header
Clear-Status
Write-Ansi ('  ' + (Paint 'last boot  ' $palette.dim) + (Paint ('{0:dd.MM.yyyy HH:mm}' -f $boot) $palette.text))
if ($reference) {
    Write-Ansi ('  ' + (Paint 'window     ' $palette.dim) +
        (Paint ('{0:dd.MM HH:mm} → {1:dd.MM HH:mm}' -f $limit, $reference.LastActivity) $palette.text) +
        (Paint ("  ($Hours h before the last session, pre-selected)") $palette.dim))
}

# Running sessions are information, not choices: one dim line, wrapped, outside the list
$running = @($sessions | Where-Object Live)
$runningLines = 0
if ($running) {
    $label = 'running    '
    $line = ''
    foreach ($name in $running.Title) {
        $candidate = if ($line) { "$line  ·  $name" } else { $name }
        if ($line -and (2 + $label.Length + $candidate.Length) -gt $rowWidth) {
            Write-Ansi ('  ' + (Paint $label $palette.dim) + (Paint $line $palette.dim))
            $label = ' ' * $label.Length; $line = $name; $runningLines++
        } else { $line = $candidate }
    }
    Write-Ansi ('  ' + (Paint $label $palette.dim) + (Paint $line $palette.dim))
    $runningLines++
}
Write-Host ''

$sessions = @($sessions | Where-Object { -not $_.Live })
if (-not $sessions) {
    $why = if ($running) { 'every recent session is already running.' } else { "no sessions in the last $Days days." }
    Write-Ansi ('  ' + (Paint "Nothing to resurrect: $why" $palette.soft))
    return
}

Write-ColumnHeader
if ($ListOnly -or [Console]::IsInputRedirected) {
    foreach ($s in $sessions) { Write-Ansi (Format-Row $s $s.InGroup $false) }
    Write-Ansi (Paint ('─' * $rowWidth) $palette.dim)
    Write-Ansi ('  ' + (Paint '●' $palette.selected) + (Paint ' pre-selected   ' $palette.dim) +
        (Paint '○' $palette.dim) + (Paint ' not selected' $palette.dim))
    return
}

$headerLines = $(if ($bannerShown) { 14 } else { 8 }) + $runningLines
$view = [math]::Min($sessions.Count, [math]::Max(5, $consoleHeight - $headerLines - 3))
$checked = [bool[]]@($sessions | ForEach-Object { $_.InGroup })
$chosen = @(Show-Picker $sessions $checked $view | ForEach-Object { $sessions[$_] })
Write-Host ''
if (-not $chosen) { Write-Ansi ('  ' + (Paint 'Nothing to resurrect.' $palette.soft)); return }

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
Write-Ansi ('  ' + (Paint "Resurrecting $($chosen.Count) session(s)" $palette.text))
foreach ($s in $chosen) {
    Write-Ansi ('  ' + (Paint '► ' $palette.selected) + (Paint $s.Title $palette.text) + '  ' + (Paint $s.Directory $palette.dim))
}

<#
.SYNOPSIS
    Clazarus: resurrects Claude Code sessions interrupted by a reboot.

.DESCRIPTION
    Claude Code keeps every session in ~/.claude/projects/<project>/<session-id>.jsonl, even
    after it is closed. This script pre-selects those whose last activity falls within -Hours
    hours before the last shutdown (or, once some sessions are running again, before the most
    recent closed session), lists them first, then the others, newest first.

    Arrows: move   Space: tick   A: all/none   Enter: resurrect the highlighted session
    R: resurrect all ticked   D: mark for deletion   X: delete the marked ones (after confirmation)
    Esc: quit

.EXAMPLE
    .\Restore-ClaudeSessions.ps1
    .\Restore-ClaudeSessions.ps1 -Hours 3 -Days 7
    .\Restore-ClaudeSessions.ps1 -ListOnly
#>
param(
    # Width of the pre-selected window, measured back from the last shutdown (or last closed session)
    [double]$Hours = 5,
    # Sessions shown: last activity less than N days ago
    [int]$Days = 30,
    # Also include desktop app sessions (they stay in the app's sidebar anyway)
    [switch]$IncludeDesktop,
    # Do not look for sessions inside WSL distributions (reading them starts the distributions)
    [switch]$NoWsl,
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
# Last shutdown: Windows writes it to the registry as a FILETIME, the same instant as the
# Kernel-General event 13 in the System log, but read at once (Get-WinEvent takes over a second)
$shutdown = try {
    $raw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Windows' -ErrorAction Stop).ShutdownTime
    [DateTime]::FromFileTime([BitConverter]::ToInt64($raw, 0))
} catch { $null }

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
    doomed   = 225, 105, 105   # red: marked for deletion
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
    $rows = for ($r = 0; $r -lt 6; $r++) { -join $(foreach ($letter in 'CLAZARUS'.ToCharArray()) { $glyphs[[string]$letter][$r] }) }
    $len = $rows[0].Length
    $from = $palette.from; $to = $palette.to
    # Plain arithmetic in the loop: a pipeline per character costs a visible third of a second
    $out = New-Object System.Text.StringBuilder
    foreach ($row in $rows) {
        [void]$out.Append('  ')
        for ($i = 0; $i -lt $row.Length; $i++) {
            $ch = $row[$i]
            if ($ch -eq ' ') { [void]$out.Append(' '); continue }
            # Horizontal gradient; the box-drawing "shadow" is a darker shade of the same color
            $t = $i / ($len - 1)
            $k = if ($ch -eq [char]0x2588) { 1.0 } else { 0.45 }
            $red   = [int](($from[0] + ($to[0] - $from[0]) * $t) * $k)
            $green = [int](($from[1] + ($to[1] - $from[1]) * $t) * $k)
            $blue  = [int](($from[2] + ($to[2] - $from[2]) * $t) * $k)
            [void]$out.Append("$esc[38;2;$red;$green;${blue}m").Append($ch)
        }
        [void]$out.Append($reset).Append("`n")
    }
    # The running commit sits right of the last character of the logo
    $logo = $out.ToString().TrimEnd("`n")
    if ($commit) { $logo += '  ' + (Paint "v. $commit" $palette.dim) }
    Write-Ansi $logo
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

# Claude Code config folders inside WSL, one per Linux user of each distribution, reached as \\wsl$\ paths.
# Reading a stopped distribution starts it, hence -NoWsl.
function Get-WslSources {
    if ($NoWsl -or -not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return }
    # wsl.exe prints UTF-16: the NUL characters left in the text are dropped. Names have no spaces, which
    # also discards the messages printed when WSL has no distribution. Docker's own distributions are no user sessions.
    $names = @(& wsl.exe -l -q 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() } |
        Where-Object { $_ -match '^\S+$' -and $_ -notmatch '^docker-desktop' })
    foreach ($name in $names) {
        $root = "\\wsl`$\$name"
        $homes = @("$root\root") + @(Get-ChildItem "$root\home" -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
        foreach ($homeDir in $homes) {
            if (Test-Path -LiteralPath "$homeDir\.claude\projects") {
                [pscustomobject]@{ Claude = "$homeDir\.claude"; Distro = $name; Root = $root }
            }
        }
    }
}

# Same as Get-LiveSessions, for a WSL config folder: the registry holds Linux PIDs, checked in the distribution's /proc
function Get-WslLiveSessions($source) {
    $registry = Join-Path $source.Claude 'sessions'
    # Without /proc nothing can be told: no session is taken for running
    if (-not (Test-Path -LiteralPath $registry) -or -not (Test-Path -LiteralPath "$($source.Root)\proc\1")) { return }
    foreach ($f in Get-ChildItem -LiteralPath $registry -Filter *.json -File) {
        $j = try { Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
        if (-not $j -or -not $j.sessionId -or -not $j.pid) { continue }
        if (-not (Test-Path -LiteralPath "$($source.Root)\proc\$($j.pid)")) { continue }
        # The PID may have been reused since a crash: the process must be a claude
        $cmdline = try { Get-Content -LiteralPath "$($source.Root)\proc\$($j.pid)\cmdline" -Raw -ErrorAction Stop } catch { $null }
        if ($null -ne $cmdline -and $cmdline -notmatch 'claude') { continue }
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
function Format-Row($s, [bool]$isChecked, [bool]$isCursor, [bool]$isDoomed = $false) {
    if ($isDoomed)  { $mark = '✕'; $markColor = $palette.doomed;   $titleColor = $palette.doomed }
    elseif ($isChecked) { $mark = '●'; $markColor = $palette.selected; $titleColor = $palette.text }
    else            { $mark = '○'; $markColor = $palette.dim;      $titleColor = $palette.soft }
    $pointer = if ($isCursor) { '►' } else { ' ' }
    $bg = if ($isCursor) { Bg $palette.cursorBg } else { '' }
    $dirWidth = $rowWidth - 19 - $titleWidth
    $title = (Cut $s.Title $titleWidth).PadRight($titleWidth)
    $dir = (Cut $s.Place $dirWidth).PadRight([math]::Max(0, $dirWidth))
    # No reset inside the row, so the cursor background spans the whole line
    "$bg$(Fg $palette.cursor)$pointer $(Fg $markColor)$mark  $(Fg $palette.time)$('{0:dd.MM HH:mm}' -f $s.LastActivity)  " +
        "$(Fg $titleColor)$title $(Fg $palette.dim)$dir$reset"
}

# Second line of a row: the session summary, under the title column
function Format-Summary($s, [bool]$isCursor) {
    $bg = if ($isCursor) { Bg $palette.cursorBg } else { '' }
    $textWidth = [math]::Max(0, $rowWidth - 18)
    $text = if ($s.Summary) { Cut $s.Summary $textWidth } else { '' }
    "$bg$(' ' * 18)$(Fg $palette.dim)$($text.PadRight($textWidth))$reset"
}

function Write-ColumnHeader {
    $header = '     ' + 'LAST ACTIVE'.PadRight(13) + 'SESSION'.PadRight($titleWidth + 1) + 'FOLDER'
    Write-Ansi (Paint $header $palette.dim)
    Write-Ansi (Paint ('─' * $rowWidth) $palette.dim)
}

function Format-Footer($count, $doomedCount, $top, $view, $total) {
    $hints = @(('↑↓', 'move'), ('space', 'tick'), ('a', 'all/none'), ('enter', 'resume this'), ('r', 'resume ticked'),
        ('d', 'mark delete'), ('x', 'delete marked'), ('esc', 'quit'))
    $plain = ($hints | ForEach-Object { "$($_[0]) $($_[1])" }) -join '   '
    $colored = ($hints | ForEach-Object { "$(Paint $_[0] $palette.text) $(Paint $_[1] $palette.dim)" }) -join '   '
    # Narrow console: keys only, so the footer never wraps and breaks the redraw
    if ($plain.Length + 2 -gt $rowWidth) {
        $plain = ($hints | ForEach-Object { $_[0] }) -join '  '
        $colored = ($hints | ForEach-Object { Paint $_[0] $palette.text }) -join '  '
    }
    if ($plain.Length + 2 -gt $rowWidth) { return '' }
    $status = "$count selected"
    if ($doomedCount) { $status += "  ·  $doomedCount to delete" }
    if ($total -gt $view) { $status += "  ·  $($top + 1)-$($top + $view) of $total" }
    $gap = $rowWidth - 2 - $plain.Length - $status.Length
    if ($gap -lt 2) { return '  ' + $colored }
    '  ' + $colored + (' ' * $gap) + (Paint $status $palette.selected)
}

# Deletes a session for good on this machine: its transcript and its subagent folder
function Remove-Session($s) {
    try {
        Remove-Item -LiteralPath $s.FilePath -Force -ErrorAction Stop
        $sub = [IO.Path]::ChangeExtension($s.FilePath, $null).TrimEnd('.')
        if (Test-Path -LiteralPath $sub -PathType Container) { Remove-Item -LiteralPath $sub -Recurse -Force -ErrorAction SilentlyContinue }
        $true
    } catch { $false }
}

# Keyboard checklist, two console lines per session; returns the sessions to resurrect
#   Enter: the highlighted one   R: all the ticked ones   D: mark for deletion   X: delete the marked ones
function Show-Picker($sessionList, [bool[]]$tickedList, [int]$view) {
    $items = [System.Collections.ArrayList]@($sessionList)
    $checked = [System.Collections.ArrayList]@($tickedList)
    $doomed = [System.Collections.ArrayList]@($sessionList | ForEach-Object { $false })
    $cursor = 0; $top = 0
    $listLines = $view * 2
    # Reserve the space first: if the console scrolls, the origin stays correct
    for ($r = 0; $r -lt $listLines + 2; $r++) { Write-Host '' }
    $origin = [Console]::CursorTop - ($listLines + 2)
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            if ($cursor -lt $top) { $top = $cursor }
            if ($cursor -ge $top + $view) { $top = $cursor - $view + 1 }
            for ($r = 0; $r -lt $view; $r++) {
                $i = $top + $r
                [Console]::SetCursorPosition(0, $origin + 2 * $r)
                if ($i -lt $items.Count) {
                    Write-Ansi (Format-Row $items[$i] $checked[$i] ($i -eq $cursor) $doomed[$i]) -NoNewline
                    [Console]::SetCursorPosition(0, $origin + 2 * $r + 1)
                    Write-Ansi (Format-Summary $items[$i] ($i -eq $cursor)) -NoNewline
                } else {
                    # Past the end (after a deletion): blank lines
                    Write-Host (' ' * $rowWidth) -NoNewline
                    [Console]::SetCursorPosition(0, $origin + 2 * $r + 1)
                    Write-Host (' ' * $rowWidth) -NoNewline
                }
            }
            [Console]::SetCursorPosition(0, $origin + $listLines)
            Write-Ansi (Paint ('─' * $rowWidth) $palette.dim) -NoNewline
            [Console]::SetCursorPosition(0, $origin + $listLines + 1)
            $count = @($checked | Where-Object { $_ }).Count
            $doomedCount = @($doomed | Where-Object { $_ }).Count
            Write-Ansi (Format-Footer $count $doomedCount $top $view $items.Count) -NoNewline

            $key = [Console]::ReadKey($true).Key.ToString()
            switch ($key) {
                'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $items.Count - 1) { $cursor++ } }
                'PageUp'    { $cursor = [math]::Max(0, $cursor - $view) }
                'PageDown'  { $cursor = [math]::Min($items.Count - 1, $cursor + $view) }
                'Home'      { $cursor = 0 }
                'End'       { $cursor = $items.Count - 1 }
                'Spacebar'  {
                    $checked[$cursor] = -not $checked[$cursor]
                    if ($checked[$cursor]) { $doomed[$cursor] = $false }
                }
                'A' {
                    $value = -not ($checked -contains $true)
                    for ($j = 0; $j -lt $items.Count; $j++) { $checked[$j] = $value -and -not $doomed[$j] }
                }
                'D' {
                    $doomed[$cursor] = -not $doomed[$cursor]
                    if ($doomed[$cursor]) { $checked[$cursor] = $false }
                    if ($cursor -lt $items.Count - 1) { $cursor++ }
                }
                'X' {
                    if (-not $doomedCount) { continue }
                    [Console]::SetCursorPosition(0, $origin + $listLines + 1)
                    $question = "  Delete $doomedCount session(s) from this machine for good?  [y/N]"
                    Write-Ansi (Paint $question.PadRight($rowWidth) $palette.doomed) -NoNewline
                    $answer = [Console]::ReadKey($true).Key.ToString()
                    [Console]::SetCursorPosition(0, $origin + $listLines + 1)
                    Write-Host (' ' * $rowWidth) -NoNewline
                    if ($answer -ne 'Y') { continue }
                    for ($j = $items.Count - 1; $j -ge 0; $j--) {
                        if ($doomed[$j] -and (Remove-Session $items[$j])) {
                            $items.RemoveAt($j); $checked.RemoveAt($j); $doomed.RemoveAt($j)
                        }
                    }
                    if (-not $items.Count) { return @() }
                    $cursor = [math]::Min($cursor, $items.Count - 1)
                    $top = [math]::Max(0, [math]::Min($top, $items.Count - $view))
                }
                'Enter' {
                    if (-not $doomed[$cursor]) { return @($items[$cursor]) }
                }
                'R' {
                    if ($count) { return @(for ($j = 0; $j -lt $items.Count; $j++) { if ($checked[$j]) { $items[$j] } }) }
                }
                'Escape' { return @() }
                'Q'      { return @() }
            }
        }
    } finally {
        [Console]::SetCursorPosition(0, $origin + $listLines + 1)
        Write-Host ''
        [Console]::CursorVisible = $true
    }
}

# ---------------------------------------------------------------- Banner
# Shown before the sessions are read, so the command answers at once
$bannerShown = $consoleWidth -ge 70 -and $consoleHeight -ge 24

# Commit this copy runs: the one it was installed or updated from, else the clone's HEAD
$commit = $null
if (Test-Path $versionFile) { $v = (Get-Content $versionFile -Raw).Trim(); if ($v -match '^[0-9a-f]{40}$') { $commit = $v.Substring(0, 7) } }
if (-not $commit) { $commit = try { (git -C $PSScriptRoot rev-parse --short HEAD 2>$null) } catch { $null } }

Write-Host ''
if ($bannerShown) { Write-Banner }
else { Write-Ansi ('  ' + (Paint 'CLAZARUS' $palette.accent) + '  ' + (Paint 'rise and resume' $palette.dim) + $(if ($commit) { '  ' + (Paint "v. $commit" $palette.dim) })) }
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

# ---------------------------------------------------------------- Self-update
# Takes GitHub's answer, waiting at most $waitMs; sets $updateTo when main has moved
$updateDecided = -not $updateCheck
$updateTo = $null
function Resolve-Update([int]$waitMs) {
    $script:updateDecided = $true
    try {
        if (-not $updateHandle.AsyncWaitHandle.WaitOne($waitMs)) { return }
        $latest = @($updateCheck.EndInvoke($updateHandle))[0]
        $current = (Get-Content $versionFile -Raw).Trim()
        if ($latest -and $latest -ne $current) { $script:updateTo = $latest }
    } catch {
        # Offline or GitHub unreachable: run the installed version as it is
    }
}

# ---------------------------------------------------------------- Collect
Write-Status 'reading sessions...'
$live = @{}
foreach ($s in Get-LiveSessions) { $live[$s.sessionId] = $s }
# Windows first, then every Claude Code config folder found in WSL
$sources = @([pscustomobject]@{ Claude = $claudeDir; Distro = $null }) + @(Get-WslSources)
foreach ($src in $sources | Where-Object Distro) {
    foreach ($s in Get-WslLiveSessions $src) { $live[$s.sessionId] = $s }
}

$since = (Get-Date).AddDays(-$Days)
# Only transcripts at the root of each project (subfolders hold subagent transcripts)
$files = @(foreach ($src in $sources) {
    $distro = $src.Distro
    Get-ChildItem (Join-Path $src.Claude 'projects') -Directory | ForEach-Object {
        Get-ChildItem $_.FullName -File -Filter *.jsonl
    } | Where-Object { $_.LastWriteTime -ge $since } | ForEach-Object { [pscustomobject]@{ File = $_; Distro = $distro } }
})

$read = 0
$sessions = foreach ($item in $files) {
    $f = $item.File
    # As soon as GitHub answers with a newer version, stop reading: the new version reads them again
    if (-not $updateDecided -and $updateHandle.IsCompleted) {
        Resolve-Update 0
        if ($updateTo) { break }
    }
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

    # A running session only shows on the "running" line: its registry name is all it needs
    $isLive = $live.ContainsKey($f.BaseName)
    $title = if ($isLive) { $live[$f.BaseName].name }
    $summary = $null
    if (-not $isLive) {
        # One pass over the transcript for the title and the summary
        $hits = Select-String -Path $f.FullName -Encoding UTF8 `
            -Pattern '"type":"(custom-title|ai-title)"', '"subtype":"away_summary"', '^\{"type":"last-prompt"'

        # Title: the last /rename (custom-title), else the generated title (ai-title)
        $custom = $hits | Where-Object { $_.Line -match '"type":"custom-title"' } | Select-Object -Last 1
        $pickLine = if ($custom) { $custom } else { $hits | Where-Object { $_.Line -match '"type":"ai-title"' } | Select-Object -Last 1 }
        if ($pickLine) {
            $t = $pickLine.Line | ConvertFrom-Json
            $title = if ($t.customTitle) { $t.customTitle } else { $t.aiTitle }
        }

        # Summary: Claude's last "while you were away" recap, else the last prompt, quoted
        $away = $hits | Where-Object { $_.Line -match '"subtype":"away_summary"' } | Select-Object -Last 1
        $prompt = $hits | Where-Object { $_.Line -match '^\{"type":"last-prompt"' } | Select-Object -Last 1
        if ($away) {
            $summary = ($away.Line | ConvertFrom-Json).content -replace '\s*\(disable recaps in /config\)\s*$', ''
        } elseif ($prompt) {
            $summary = '"' + ($prompt.Line | ConvertFrom-Json).lastPrompt + '"'
        }
        if ($summary) { $summary = ($summary -replace '\s+', ' ').Trim() }
    }

    [pscustomobject]@{
        LastActivity = $f.LastWriteTime
        Title        = if ($title) { $title } else { '(untitled)' }
        Summary      = $summary
        Directory    = $cwd
        Distro       = $item.Distro
        Place        = if ($item.Distro) { "$($item.Distro):$cwd" } else { $cwd }
        SessionId    = $f.BaseName
        FilePath     = $f.FullName
        Live         = $isLive
        InGroup      = $false
    }
}

# Read before GitHub answered: wait for it, a little
if (-not $updateDecided) {
    if (-not $updateHandle.IsCompleted) { Write-Status 'checking for updates...' }
    Resolve-Update 3000
}
if ($updateCheck) { $updateCheck.Dispose() }
if ($updateTo) {
    Write-Status "updating Clazarus to $($updateTo.Substring(0, 7))..."
    try {
        $ProgressPreference = 'SilentlyContinue'
        # Pinned to the commit, so a stale raw.githubusercontent.com cache cannot serve an older file
        $download = "$PSCommandPath.download"
        Invoke-WebRequest "https://raw.githubusercontent.com/salfab/Clazarus/$updateTo/Restore-ClaudeSessions.ps1" `
            -OutFile $download -UseBasicParsing -TimeoutSec 10
        Move-Item $download $PSCommandPath -Force
        Set-Content $versionFile $updateTo -Encoding ASCII
    } catch {
        # Download failed: the installed copy is unchanged, and relaunched below all the same,
        # since the reading stopped early
    }
    # The relaunched script draws its own banner: erase this one first
    Clear-Status
    if ($vt) {
        [Console]::SetCursorPosition(0, [math]::Max(0, [Console]::CursorTop - $bannerLines))
        Write-Host "$esc[J" -NoNewline
    }
    $PSBoundParameters['NoUpdate'] = $true
    & $PSCommandPath @PSBoundParameters
    return
}

$sessions = @($sessions | Sort-Object LastActivity -Descending)

# End of the pre-selected window:
#   no session running yet -> the last shutdown, which is when the sessions were cut off
#   some already running   -> the most recent closed session: the user has started reopening
#                             their sessions, and the ones left are those just before it
$closed = @($sessions | Where-Object { -not $_.Live })
$hasLive = [bool]($sessions | Where-Object Live)
$reference = $null; $referenceLabel = $null
if ($hasLive -or -not $shutdown) {
    if ($closed) { $reference = $closed[0].LastActivity; $referenceLabel = 'the last closed session' }
} else {
    $reference = $shutdown; $referenceLabel = 'the last shutdown'
}
if ($reference) {
    $limit = $reference.AddHours(-$Hours)
    foreach ($s in $closed) {
        if ($s.LastActivity -le $reference -and $s.LastActivity -ge $limit) { $s.InGroup = $true }
    }
}
# Pre-selected sessions first, then newest first
$sessions = @($sessions | Sort-Object @{ Expression = 'InGroup'; Descending = $true }, @{ Expression = 'LastActivity'; Descending = $true })

# ---------------------------------------------------------------- Header
Clear-Status
$shutdownText = if ($shutdown) { '{0:dd.MM.yyyy HH:mm}' -f $shutdown } else { 'unknown' }
Write-Ansi ('  ' + (Paint 'shutdown   ' $palette.dim) + (Paint $shutdownText $palette.text))
if ($reference) {
    Write-Ansi ('  ' + (Paint 'window     ' $palette.dim) +
        (Paint ('{0:dd.MM HH:mm} → {1:dd.MM HH:mm}' -f $limit, $reference) $palette.text) +
        (Paint ("  ($Hours h before $referenceLabel, pre-selected)") $palette.dim))
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
    foreach ($s in $sessions) {
        Write-Ansi (Format-Row $s $s.InGroup $false)
        Write-Ansi (Format-Summary $s $false)
    }
    Write-Ansi (Paint ('─' * $rowWidth) $palette.dim)
    Write-Ansi ('  ' + (Paint '●' $palette.selected) + (Paint ' pre-selected   ' $palette.dim) +
        (Paint '○' $palette.dim) + (Paint ' not selected' $palette.dim))
    return
}

$headerLines = $(if ($bannerShown) { 14 } else { 8 }) + $runningLines
# Sessions that fit, at two lines each
$view = [math]::Min($sessions.Count, [math]::Max(3, [math]::Floor(($consoleHeight - $headerLines - 3) / 2)))
$checked = [bool[]]@($sessions | ForEach-Object { $_.InGroup })
$chosen = @(Show-Picker $sessions $checked $view)
Write-Host ''
if (-not $chosen) { Write-Ansi ('  ' + (Paint 'Nothing to resurrect.' $palette.soft)); return }

# ---------------------------------------------------------------- Shell
# Windows Terminal's settings.json allows comments and trailing commas, which ConvertFrom-Json refuses:
# drop them, leaving the strings untouched (a "//" inside a string is not a comment)
function Read-JsonWithComments([string]$path) {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $pattern = '"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/|,(?=\s*[}\]])'
    [regex]::Replace($raw, $pattern, { param($m) if ($m.Value.StartsWith('"')) { $m.Value } else { '' } }) | ConvertFrom-Json
}

# Git Bash is a generated profile with no command line in settings.json: find bash.exe from git.exe
function Find-GitBash {
    $candidates = @()
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) { $candidates += Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe' }
    $candidates += "$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

# The default profile of Windows Terminal: Name, Kind (powershell, cmd, bash), Exe, and Guid
# (null when the profile cannot be told). Anything unreadable or unknown, such as WSL, gives Windows PowerShell.
function Get-TerminalShell {
    $fallback = [pscustomobject]@{ Name = 'PowerShell'; Kind = 'powershell'; Exe = 'powershell.exe'; Guid = $null }
    $builtin = @{
        '{574e775e-4f2a-5b96-ac1e-a2962a402336}' = 'pwsh.exe'         # PowerShell 7
        '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}' = 'powershell.exe'   # Windows PowerShell, the default default
        '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}' = 'cmd.exe'
        '{2ece5bfe-50ed-5f3a-ab87-5cd4baafed2b}' = 'bash.exe'         # Git Bash
    }
    $settingsPath = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $settingsPath) { return $fallback }
    try {
        $settings = Read-JsonWithComments $settingsPath
        # defaultProfile is a GUID, or a profile name in recent versions
        $default = if ($settings.defaultProfile) { $settings.defaultProfile } else { '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}' }
        $list = if ($settings.profiles.list) { $settings.profiles.list } else { $settings.profiles }
        $prof = @($list) | Where-Object { $_.guid -eq $default -or $_.name -eq $default } | Select-Object -First 1
        $guid = if ($prof -and $prof.guid) { $prof.guid } else { $default }
        $name = if ($prof -and $prof.name) { $prof.name } else { $null }

        $exe = $null
        if ($prof -and $prof.commandline) {
            $cmd = [Environment]::ExpandEnvironmentVariables($prof.commandline.Trim())
            $exe = if ($cmd -match '^"([^"]+)"') { $Matches[1] }
                   elseif ($cmd -match '^(.+?\.exe)(\s|$)') { $Matches[1] }
                   else { ($cmd -split '\s+')[0] }
        } elseif ($builtin.ContainsKey($guid)) { $exe = $builtin[$guid] }
        elseif ($prof -and $prof.source -eq 'Git') { $exe = 'bash.exe' }
        elseif ($prof -and $prof.source -eq 'Windows.Terminal.PowershellCore') { $exe = 'pwsh.exe' }
        if (-not $exe) { return $fallback }

        $kind = switch ([IO.Path]::GetFileNameWithoutExtension($exe).ToLowerInvariant()) {
            { $_ -in 'pwsh', 'powershell' } { 'powershell' }
            'cmd'  { 'cmd' }
            'bash' { 'bash' }
            default { $null }
        }
        if (-not $kind) { return $fallback }
        # A bare "bash.exe" from a Git profile is not the WSL launcher of System32
        if ($kind -eq 'bash' -and -not [IO.Path]::IsPathRooted($exe)) {
            $exe = Find-GitBash
            if (-not $exe) { return $fallback }
        }
        [pscustomobject]@{ Name = $(if ($name) { $name } else { [IO.Path]::GetFileNameWithoutExtension($exe) }); Kind = $kind; Exe = $exe; Guid = $guid }
    } catch { $fallback }
}

# Where claude is, as a full path: a tab opened by wt does not always inherit the PATH of this window (seen when
# Clazarus runs from WSL), and a bare "claude" is then not found. The bare name stays as the last resort.
function Get-ClaudePath {
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $native = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $native) { return $native }
    'claude'
}

# The part of the wt command line that starts the shell, which runs claude and stays open after it.
# No ";" in the result: wt would read it as a command separator.
function Get-ShellCommand($shell, $s, [string]$tabTitle) {
    $id = $s.SessionId
    $claude = Get-ClaudePath
    switch ($shell.Kind) {
        'cmd' {
            # "%" would be expanded by cmd; the quotes are already out of the title
            $t = $tabTitle -replace '%', ''
            # The whole command is wrapped in one more pair of quotes: cmd strips the first and last quote of a
            # line that starts with one and holds more, which would break the quoted path of claude
            "`"$($shell.Exe)`" /k `"`"$claude`" --resume $id --remote-control `"$t`"`""
        }
        'bash' {
            # Single-quoted for bash, and the folder as a /c/... path. No -l on the final bash: the login
            # profile would send it back to the home folder. "|| true" keeps the shell after a failed claude.
            $t = $tabTitle -replace "'", "'\''"
            $dir = ($s.Directory -replace '\\', '/') -replace "'", "'\''"
            if ($dir -match '^([A-Za-z]):(.*)$') { $dir = '/' + $Matches[1].ToLowerInvariant() + $Matches[2] }
            "`"$($shell.Exe)`" -l -i -c `"cd '$dir' && claude --resume $id --remote-control '$t' || true && exec bash -i`""
        }
        default {
            # Encoded, so no quoting level can mangle the title
            $t = $tabTitle -replace "'", "''"
            $exe = $claude -replace "'", "''"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& '$exe' --resume $id --remote-control '$t'"))
            "`"$($shell.Exe)`" -NoExit -EncodedCommand $encoded"
        }
    }
}

# The wsl.exe arguments that start claude in the session's folder inside its distribution. The shell is bash,
# started as a login shell like a terminal would, so claude must be on its PATH; the user's shell then takes over.
# No ";" in the result: wt would read it as a command separator.
function Get-WslArguments($s, [string]$tabTitle) {
    $t = $tabTitle -replace "'", "'\''"
    $inner = "claude --resume $($s.SessionId) --remote-control '$t' || true && exec `$SHELL -i"
    "-d `"$($s.Distro)`" --cd `"$($s.Directory)`" --exec bash -lic `"$inner`""
}

function Test-SessionFolder($s) {
    if ($s.Distro) { Test-Path -LiteralPath ("\\wsl`$\$($s.Distro)" + ($s.Directory -replace '/', '\')) }
    else { Test-Path $s.Directory }
}

# ---------------------------------------------------------------- Resurrect
$chosen = @($chosen | Where-Object {
    if (Test-SessionFolder $_) { $true } else { Write-Warning "Folder not found, skipped: $($_.Place)"; $false }
})
if (-not $chosen) { return }

$shellName = 'PowerShell'
if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
    # Each tab starts the default shell of Windows Terminal, which then runs claude: when claude
    # exits, the tab stays open on that shell's prompt.
    $shell = Get-TerminalShell
    $shellName = $shell.Name
    # One wt call with every tab chained by ";": no race between windows.
    # Run from Windows Terminal: tabs go into the current window (-w 0), else into a new one.
    $window = if ($env:WT_SESSION) { '0' } else { 'new' }
    $tabs = foreach ($s in $chosen) {
        # wt reads ";" as a command separator, and the title is quoted
        $tabTitle = $s.Title -replace '"', "'" -replace ';', ','
        if ($s.Distro) {
            "new-tab --title `"$tabTitle`" wsl.exe $(Get-WslArguments $s $tabTitle)"
        } else {
            # The profile keeps the tab's look (colors, font) when the shell is the profile's own
            $profileArg = if ($shell.Guid) { "-p `"$($shell.Guid)`" " } else { '' }
            "new-tab $profileArg-d `"$($s.Directory)`" --title `"$tabTitle`" $(Get-ShellCommand $shell $s $tabTitle)"
        }
    }
    Start-Process wt.exe -ArgumentList ("-w $window " + ($tabs -join ' ; '))
} else {
    foreach ($s in $chosen) {
        if ($s.Distro) {
            Start-Process wsl.exe -ArgumentList (Get-WslArguments $s ($s.Title -replace '"', "'" -replace ';', ','))
            continue
        }
        $rcName = $s.Title -replace "'", "''"
        Start-Process powershell.exe -WorkingDirectory $s.Directory -ArgumentList '-NoExit', '-Command', "claude --resume $($s.SessionId) --remote-control '$rcName'"
    }
}
if ($chosen | Where-Object Distro) { $shellName += ' / WSL' }
Write-Ansi ('  ' + (Paint "Resurrecting $($chosen.Count) session(s)" $palette.text) + (Paint "  in $shellName" $palette.dim))
foreach ($s in $chosen) {
    Write-Ansi ('  ' + (Paint '► ' $palette.selected) + (Paint $s.Title $palette.text) + '  ' + (Paint $s.Place $palette.dim))
}

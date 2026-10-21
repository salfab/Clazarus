# Clazarus

*Claude + Lazarus.* Brings your Claude Code sessions back after a Windows reboot.

You had a handful of `claude` sessions running in terminal tabs, Windows restarted, and they are
gone. Clazarus lists your recent sessions, pre-selects the ones that were running before the
reboot, and reopens the ones you pick as tabs of a single Windows Terminal window, each in its
own folder with `claude --resume` and Remote Control enabled.

```
   ██████╗██╗      █████╗ ███████╗ █████╗ ██████╗ ██╗   ██╗███████╗
  ██╔════╝██║     ██╔══██╗╚══███╔╝██╔══██╗██╔══██╗██║   ██║██╔════╝
  ██║     ██║     ███████║  ███╔╝ ███████║██████╔╝██║   ██║███████╗
  ██║     ██║     ██╔══██║ ███╔╝  ██╔══██║██╔══██╗██║   ██║╚════██║
  ╚██████╗███████╗██║  ██║███████╗██║  ██║██║  ██║╚██████╔╝███████║
   ╚═════╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝
                rise and resume  ·  Claude Code session resurrector

  last boot  21.10.2026 11:05
  window     21.10 02:03 → 21.10 07:03  (5 h before the last session, pre-selected)
  running    api-refactor

     LAST ACTIVE  SESSION                     FOLDER
──────────────────────────────────────────────────────────────────────
► ●  21.10 07:03  Fix login redirect          C:\src\web
  ●  21.10 06:40  docs-cleanup                C:\src\docs
  ○  20.10 18:12  Spike: new cache layer      C:\src\cache
──────────────────────────────────────────────────────────────────────
  ↑↓ move   space toggle   a all/none   enter resurrect   esc quit
```

In the terminal the banner is a coral-to-gold gradient, selected sessions get a green `●` and
the cursor row is highlighted. Sessions that are already running are not choices: they are only
named on the `running` line.

## Install

```powershell
irm https://raw.githubusercontent.com/salfab/Clazarus/main/install.ps1 | iex
```

Or from a clone:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This copies the script to `%LOCALAPPDATA%\Programs\Clazarus`, adds a `clazarus` command there and
puts that folder on your user `PATH`. Run it again to update; `-Uninstall` removes it.
Terminals opened before the install need a restart to find the command.

## Usage

```powershell
clazarus
```

Without installing: `powershell -ExecutionPolicy Bypass -File .\Restore-ClaudeSessions.ps1`.

| Key | Action |
| --- | --- |
| ↑ / ↓, PgUp / PgDn, Home / End | Move |
| Space | Toggle the current session |
| A | Select all / none |
| Enter | Resurrect the selected sessions |
| Esc / Q | Quit |

Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `-Hours` | `5` | Width of the pre-selected window |
| `-Days` | `30` | Only list sessions active in the last N days |
| `-IncludeDesktop` | off | Also list Claude desktop app sessions (they already stay in the app's sidebar) |
| `-ListOnly` | off | Print the list without the interactive picker |

## How it works

- **Sessions** come from the transcripts Claude Code keeps in
  `~/.claude/projects/<project>/<session-id>.jsonl`, which stay there after a session closes. The
  working directory and the title (your `/rename`, else the generated one) are read from them.
- **Pre-selection**: the reference is the most recent session written before the last boot.
  Every session whose last activity falls within `-Hours` before it is pre-selected. This works
  however long the machine stayed off.
- **Live sessions**: Claude Code keeps a registry of running sessions in `~/.claude/sessions/`.
  Sessions still running are only listed on the `running` line, never offered, and are ignored
  when computing the window, so a session you already reopened never shifts it.
- **Resurrection**: one `wt.exe` call opens every selected session as a tab. Run from Windows
  Terminal, the tabs go into the current window; otherwise into a new one. Without Windows
  Terminal, each session opens in its own PowerShell window.
- **Remote Control**: every resurrected session starts with `--remote-control "<title>"`, so it
  shows up under its own name in the Claude app. Whether a session had Remote Control before the
  reboot is not recorded anywhere that survives it, so it is enabled for all of them.

## Requirements

- Windows, Windows PowerShell 5.1 or PowerShell 7
- [Claude Code](https://claude.com/claude-code) CLI (`claude`) on the `PATH`
- [Windows Terminal](https://aka.ms/terminal) (optional, for tabs)

## Limitations

- A session left idle for more than `-Hours` before the shutdown is not pre-selected. It is still
  listed; select it by hand.
- It relies on Claude Code's local file layout, which is not a public API and may change.

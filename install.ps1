<#
.SYNOPSIS
    Installs Clazarus as a global "clazarus" command (or removes it with -Uninstall).

.DESCRIPTION
    Copies Restore-ClaudeSessions.ps1 to -InstallDir, writes a clazarus.cmd shim next to it and
    adds that folder to the user PATH. The shim works from PowerShell, cmd and Windows Terminal.
    Run from a clone, it installs the local script; run through "irm ... | iex", it downloads it
    from GitHub. The installed copy then updates itself whenever GitHub's main branch moves.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Uninstall
    irm https://raw.githubusercontent.com/salfab/Clazarus/main/install.ps1 | iex
#>
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\Clazarus'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$scriptName = 'Restore-ClaudeSessions.ps1'
$repo       = 'salfab/Clazarus'

# Read the raw user PATH so %VARIABLES% stay unexpanded when it is written back
$envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
$userPath = $envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$entries = @($userPath -split ';' | Where-Object { $_ })
$normalized = $InstallDir.TrimEnd('\')
$isOnPath = [bool]($entries | Where-Object { $_.TrimEnd('\') -ieq $normalized })

function Set-UserPath([string[]]$newEntries) {
    $envKey.SetValue('Path', ($newEntries -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    # Tell running programs (Explorer, Windows Terminal) that the environment changed
    if (-not ('Clazarus.Native' -as [type])) {
        Add-Type -Namespace Clazarus -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint msg, System.UIntPtr wParam,
    string lParam, uint flags, uint timeout, out System.UIntPtr result);
'@
    }
    $result = [UIntPtr]::Zero
    [Clazarus.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
}

if ($Uninstall) {
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    if ($isOnPath) { Set-UserPath @($entries | Where-Object { $_.TrimEnd('\') -ine $normalized }) }
    Write-Host "Clazarus removed from $InstallDir."
    return
}

New-Item -ItemType Directory -Force $InstallDir | Out-Null
$target = Join-Path $InstallDir $scriptName
$local = if ($PSScriptRoot) { Join-Path $PSScriptRoot $scriptName }
if ($local -and (Test-Path $local)) {
    Copy-Item $local $target -Force
    # The clone's commit; without git, "local" makes the first run update from GitHub
    $version = try { git -C $PSScriptRoot rev-parse HEAD 2>$null } catch { $null }
    if (-not $version) { $version = 'local' }
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $version = (Invoke-RestMethod "https://api.github.com/repos/$repo/commits/main" -UseBasicParsing).sha
    Invoke-WebRequest "https://raw.githubusercontent.com/$repo/$version/$scriptName" -OutFile $target -UseBasicParsing
}
# The installed copy compares this with GitHub's main on every start and updates itself
Set-Content (Join-Path $InstallDir 'version') $version -Encoding ASCII

# Shim: forwards every argument, e.g. "clazarus -Hours 3"
Set-Content (Join-Path $InstallDir 'clazarus.cmd') -Encoding ASCII -Value @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0$scriptName" %*
"@

if (-not $isOnPath) { Set-UserPath ($entries + $InstallDir) }
# The current shell does not reread PATH from the registry
if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $normalized })) {
    $env:Path = "$env:Path;$InstallDir"
}

Write-Host "Clazarus installed in $InstallDir. Run: clazarus"
if (-not $isOnPath) { Write-Host 'Terminals opened before this install need a restart to find it.' }

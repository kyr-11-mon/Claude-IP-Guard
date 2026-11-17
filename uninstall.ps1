[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [switch]$RemoveData,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot) -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json') -PathType Leaf)) {
        $InstallDir = $PSScriptRoot
    } else {
        $InstallDir = Join-Path $env:LOCALAPPDATA 'ClaudeIPGuard'
    }
}
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\', '/')

$modulePath = Join-Path $InstallDir 'src\ClaudeIPGuard.psm1'
if (Test-Path -LiteralPath $modulePath -PathType Leaf) {
    Import-Module $modulePath -Force
}

function Test-OwnedText {
    param([string]$Text, [string]$Directory)

    # Literal comparison with a trailing separator: -like would treat [ ] * ? in
    # the install path as wildcards and would also match sibling directories.
    $normalized = $Directory.TrimEnd('\', '/')
    if (Get-Command -Name Test-TextContainsDirectory -ErrorAction SilentlyContinue) {
        return (Test-TextContainsDirectory -Text $Text -Directory $normalized)
    }
    return ([string]$Text).IndexOf(($normalized + '\'), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude (IP Guard).lnk'
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude IP Guard'
$startupEntry = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude IP Guard Monitor.vbs'

function Test-PathOwnedByInstall {
    param([string]$Path, [string]$Directory)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        if ([System.IO.Path]::GetExtension($Path) -ieq '.lnk') {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($Path)
            $text = ([string]$shortcut.TargetPath) + ' ' + ([string]$shortcut.Arguments)
            return (Test-OwnedText -Text $text -Directory $Directory)
        }

        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return (Test-OwnedText -Text ([string]$text) -Directory $Directory)
    } catch {
        return $false
    }
}

function Get-InstalledGuardProcesses {
    param([string]$Directory)

    if (Get-Command -Name Get-GuardMonitorProcesses -ErrorAction SilentlyContinue) {
        return @(Get-GuardMonitorProcesses | Where-Object {
            Test-OwnedText -Text ([string]$_.ScriptPath) -Directory $Directory
        })
    }

    # Fallback for partially removed installations whose module is already gone.
    $result = @()
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            if (Test-OwnedText -Text $commandLine -Directory $Directory -and $commandLine.IndexOf('guard.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $result += $process
            }
        }
    } catch {
        return @()
    }
    return @($result)
}

$guardProcesses = @(Get-InstalledGuardProcesses -Directory $InstallDir)

if ($DryRun) {
    Write-Output ([pscustomobject]@{
        DryRun = $true
        InstallDir = $InstallDir
        GuardProcessIds = @($guardProcesses | ForEach-Object { $_.ProcessId })
        DesktopShortcut = $desktopShortcut
        StartMenuDir = $startMenuDir
        StartupEntry = $startupEntry
        RemoveData = [bool]$RemoveData
    })
    return
}

foreach ($process in $guardProcesses) {
    Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
}

foreach ($path in @($startupEntry, $desktopShortcut)) {
    if (Test-PathOwnedByInstall -Path $path -Directory $InstallDir) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
        Write-Warning ('Left a shortcut that belongs to another installation: {0}' -f $path)
    }
}

if (Test-Path -LiteralPath $startMenuDir) {
    foreach ($name in @('Claude (IP Guard).lnk', 'Status.lnk', 'Uninstall.lnk')) {
        $path = Join-Path $startMenuDir $name
        if (Test-PathOwnedByInstall -Path $path -Directory $InstallDir) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
            Write-Warning ('Left a Start Menu shortcut that belongs to another installation: {0}' -f $path)
        }
    }
    $remaining = @(Get-ChildItem -LiteralPath $startMenuDir -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $startMenuDir -Force -ErrorAction SilentlyContinue
    }
}

if ($RemoveData) {
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
    Write-Host ('Claude IP Guard was removed from {0}.' -f $InstallDir)
} else {
    foreach ($relative in @('src', 'config.json', 'install.json', 'status.ps1', 'uninstall.ps1', 'test.ps1')) {
        $path = Join-Path $InstallDir $relative
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $logPath = Join-Path $InstallDir 'logs\guard.log'
    Write-Host 'Claude IP Guard was removed. Logs were kept.'
    Write-Host ('Logs: {0}' -f $logPath)
}

Write-Host 'Claude itself and its user data were not modified.'
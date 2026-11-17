[CmdletBinding()]
param(
    [ValidateSet('http', 'socks5')]
    [string]$ProxyType = 'http',

    [int]$ProxyPort,

    [string]$ExpectedIp,

    [string]$ClaudeExe = '',

    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'ClaudeIPGuard'),

    [switch]$NoShortcuts,

    [switch]$SkipProxyCheck,

    [switch]$DryRun,

    [switch]$Force,

    # Declared last so existing positional invocations keep binding ExpectedIp
    # as the third argument.
    [string]$ProxyHost = '127.0.0.1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src\ClaudeIPGuard.psm1'
Import-Module $modulePath -Force

if ($ProxyPort -eq 0) {
    $entered = Read-Host 'Local proxy port (for example 1080)'
    $parsed = 0
    if (-not [int]::TryParse($entered, [ref]$parsed)) {
        throw 'Proxy port must be an integer.'
    }
    $ProxyPort = $parsed
}

if ([string]::IsNullOrWhiteSpace($ExpectedIp)) {
    $ExpectedIp = Read-Host 'Expected exit IPv4 address (for example 203.0.113.10)'
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\', '/')
$config = New-GuardConfig -ProxyType $ProxyType -ProxyPort $ProxyPort -ProxyHost $ProxyHost -ExpectedIp $ExpectedIp -ClaudeExe $ClaudeExe
$plan = New-InstallPlan -InstallDir $InstallDir -SourceRoot $PSScriptRoot -ClaudeExe $ClaudeExe -NoShortcuts:$NoShortcuts

if ($DryRun) {
    Write-Output ([pscustomobject]@{
        DryRun = $true
        InstallDir = $plan.InstallDir
        ConfigPath = $plan.ConfigPath
        ModulePath = $plan.ModulePath
        LaunchScript = $plan.LaunchScript
        GuardScript = $plan.GuardScript
        LogPath = $plan.LogPath
        StartupEntry = if ($NoShortcuts) { $null } else { $plan.StartupEntry }
        StartGuard = (-not $NoShortcuts)
        Shortcuts = @($plan.Shortcuts | ForEach-Object { $_.Path })
    })
    return
}

if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'src\launch.ps1') -PathType Leaf)) {
    throw 'The source tree is incomplete: src\launch.ps1 is missing.'
}

if (-not $SkipProxyCheck) {
    if (-not (Test-TcpPort -TargetHost ([string]$config.proxyHost) -Port ([int]$config.proxyPort) -TimeoutMilliseconds 1000)) {
        throw ('The local proxy port {0} on {1} is not accepting connections.' -f $config.proxyPort, $config.proxyHost)
    }
    $actualIp = Get-CurrentExitIp -Config $config
    if ($actualIp -ne [string]$config.expectedIp) {
        throw ('The proxy exit IP is {0}, not the requested {1}. Use -SkipProxyCheck only if you understand the risk.' -f $actualIp, $config.expectedIp)
    }
}

if ((Test-Path -LiteralPath $plan.ConfigPath) -and -not $Force) {
    throw ('An installation already exists at {0}. Use -Force to replace it.' -f $InstallDir)
}

$monitors = @(Get-GuardMonitorProcesses)
foreach ($monitor in $monitors) {
    if (-not (Test-TextContainsDirectory -Text ([string]$monitor.ScriptPath) -Directory $InstallDir)) {
        throw ('Another Claude IP Guard installation is already running its monitor: {0}. Close it before installing.' -f $monitor.InstallDir)
    }
}

function Stop-InstalledGuard {
    param([string]$Directory)

    foreach ($monitor in @(Get-GuardMonitorProcesses)) {
        if (Test-TextContainsDirectory -Text ([string]$monitor.ScriptPath) -Directory $Directory) {
            Stop-Process -Id ([int]$monitor.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
}

Stop-InstalledGuard -Directory $InstallDir

New-Item -ItemType Directory -Path (Join-Path $InstallDir 'src') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallDir 'logs') -Force | Out-Null

$files = @(
    'ClaudeIPGuard.psm1'
    'launch.ps1'
    'guard.ps1'
    'launch.vbs'
    'guard.vbs'
)
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('src\' + $file)) -Destination (Join-Path $InstallDir ('src\' + $file)) -Force
}

foreach ($file in @('status.ps1', 'uninstall.ps1', 'test.ps1')) {
    $source = Join-Path $PSScriptRoot $file
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDir $file) -Force
    }
}

Write-GuardConfig -Config $config -Path $plan.ConfigPath

$metadata = [pscustomobject]@{
    version = '1.0.1'
    installedAt = (Get-Date).ToString('o')
    proxyType = $config.proxyType
    proxyHost = $config.proxyHost
    proxyPort = $config.proxyPort
    checkIntervalSeconds = $config.checkIntervalSeconds
}
$metadataPath = Join-Path $InstallDir 'install.json'
[System.IO.File]::WriteAllText($metadataPath, (($metadata | ConvertTo-Json -Depth 3) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))

$resolvedClaude = $null
try {
    $resolvedClaude = Find-ClaudeExecutable -Config $config
} catch {
    $resolvedClaude = $null
}

if (-not $NoShortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($shortcutSpec in @($plan.Shortcuts)) {
        $parent = Split-Path -Parent $shortcutSpec.Path
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $shortcut = $shell.CreateShortcut($shortcutSpec.Path)
        $shortcut.TargetPath = $shortcutSpec.Target
        $shortcut.Arguments = $shortcutSpec.Arguments
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.Description = $shortcutSpec.Description
        if ($null -ne $resolvedClaude) {
            $shortcut.IconLocation = ($resolvedClaude + ',0')
        }
        $shortcut.Save()
    }

    $startMenuDir = $plan.StartMenuDir
    New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $utilityShortcuts = @(
        [pscustomobject]@{ Name = 'Status.lnk'; Script = (Join-Path $InstallDir 'status.ps1'); Description = 'Show Claude IP Guard status' }
        [pscustomobject]@{ Name = 'Uninstall.lnk'; Script = (Join-Path $InstallDir 'uninstall.ps1'); Description = 'Uninstall Claude IP Guard' }
    )
    foreach ($utility in $utilityShortcuts) {
        $path = Join-Path $startMenuDir $utility.Name
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallDir "{1}"' -f $utility.Script, $InstallDir)
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.Description = $utility.Description
        $shortcut.Save()
    }
}

if (-not $NoShortcuts) {
    $startup = @"
Option Explicit
Dim shell, wscript, guard
Set shell = CreateObject("WScript.Shell")
wscript = "$(Join-Path $env:SystemRoot 'System32\wscript.exe')"
guard = "$($plan.GuardVbs)"
shell.Run Chr(34) & wscript & Chr(34) & " " & Chr(34) & guard & Chr(34), 0, False
"@
    # The startup entry lives under a path that may contain non-ASCII user names.
    # cscript.exe reads files as ANSI unless they carry a UTF-16LE byte order mark.
    [System.IO.File]::WriteAllText($plan.StartupEntry, $startup, (New-Object System.Text.UnicodeEncoding($false, $true)))

    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $plan.GuardVbs + '"') -WindowStyle Hidden | Out-Null

    Start-Sleep -Seconds 1
    if (-not (Test-TcpPort -TargetHost ([string]$config.proxyHost) -Port ([int]$config.proxyPort) -TimeoutMilliseconds 1000)) {
        Write-Warning 'The proxy port is not reachable after installation.'
    }
}

Write-Host 'Claude IP Guard is installed.'
Write-Host ('Install directory: {0}' -f $InstallDir)
Write-Host ('Configuration: {0}' -f $plan.ConfigPath)
Write-Host ('Log: {0}' -f $plan.LogPath)
if ($NoShortcuts) {
    Write-Host 'No shortcuts or monitor were created (-NoShortcuts). Start the monitor manually when needed.'
} else {
    Write-Host 'Launch Claude from the Claude (IP Guard) shortcut.'
}
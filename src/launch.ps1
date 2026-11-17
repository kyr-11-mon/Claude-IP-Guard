[CmdletBinding()]
param(
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'ClaudeIPGuard.psm1'
Import-Module $modulePath -Force

$installRoot = Split-Path -Parent $PSScriptRoot
$guardScriptPath = Join-Path $PSScriptRoot 'guard.ps1'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $installRoot 'config.json'
}

function Show-GuardMessage {
    param(
        [string]$Message,
        [string]$Title = 'Claude IP Guard'
    )

    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch {
        Write-Host $Message
    }
}

function Get-GuardState {
    $ownRunning = $false
    $foreignMonitor = $null
    foreach ($monitor in @(Get-GuardMonitorProcesses)) {
        if (Test-TextContainsDirectory -Text ([string]$monitor.ScriptPath) -Directory $installRoot) {
            $ownRunning = $true
        } elseif ($null -eq $foreignMonitor) {
            $foreignMonitor = $monitor
        }
    }

    return [pscustomobject]@{
        OwnMonitorRunning = $ownRunning
        ForeignMonitor = $foreignMonitor
    }
}

function Start-GuardProcess {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $guardScript = $guardScriptPath
    $arguments = @(
        '-NoProfile'
        '-WindowStyle'
        'Hidden'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        ('"' + $guardScript + '"')
    )
    Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw ('Configuration file was not found: {0}' -f $ConfigPath)
    }

    # A monitor from another install root would keep stopping this Claude session
    # whenever the two configurations disagree, so refuse to start instead.
    $guardState = Get-GuardState
    if ($null -ne $guardState.ForeignMonitor) {
        throw ('Another Claude IP Guard installation ({0}) is already running its monitor. Close it before launching this installation.' -f $guardState.ForeignMonitor.InstallDir)
    }

    $config = Read-GuardConfig -Path $ConfigPath
    if (-not (Test-TcpPort -TargetHost ([string]$config.proxyHost) -Port ([int]$config.proxyPort) -TimeoutMilliseconds 1000)) {
        throw ('The local proxy port {0} on {1} is not accepting connections.' -f $config.proxyPort, $config.proxyHost)
    }

    $exitIp = Get-CurrentExitIp -Config $config
    if ($exitIp -ne [string]$config.expectedIp) {
        throw ('The proxy exit IP is {0}, not the configured {1}.' -f $exitIp, $config.expectedIp)
    }

    $processes = @(Get-ClaudeProcesses)
    if ($processes.Count -gt 0) {
        $violations = @(Get-ClaudeProcessViolations -Processes $processes -Config $config)
        if ($violations.Count -eq 0) {
            if (-not $guardState.OwnMonitorRunning) {
                Start-GuardProcess
            }
            return
        }

        Add-Type -AssemblyName PresentationFramework
        $answer = [System.Windows.MessageBox]::Show(
            'An unprotected Claude process is already running. Close it and start Claude through this launcher?',
            'Claude IP Guard',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            return
        }
        Stop-ClaudeProcesses -Processes $processes | Out-Null
        Start-Sleep -Milliseconds 500
    }

    if (-not $guardState.OwnMonitorRunning) {
        Start-GuardProcess
    }

    $claudeExe = Find-ClaudeExecutable -Config $config
    $arguments = @(Get-ClaudeLaunchArguments -Config $config)
    Start-Process -FilePath $claudeExe -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $claudeExe) | Out-Null

    # MSIX cold start can take much longer than two seconds. Poll instead of
    # sleeping once, otherwise a slow but legitimate start is killed by mistake.
    $deadline = (Get-Date).AddSeconds(20)
    $started = @()
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $started = @(Get-ClaudeProcesses)
        if ($started.Count -eq 0) {
            continue
        }
        $bad = @(Get-ClaudeProcessViolations -Processes $started -Config $config)
        if ($bad.Count -eq 0) {
            return
        }
    }

    Stop-ClaudeProcesses -Processes $started | Out-Null
    throw 'Claude did not start with the required proxy arguments within 20 seconds.'
} catch {
    Show-GuardMessage -Message $_.Exception.Message
    exit 1
}

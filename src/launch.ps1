[CmdletBinding()]
param(
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'ClaudeIPGuard.psm1'
Import-Module $modulePath -Force

$script:GuardScriptPath = Join-Path $PSScriptRoot 'guard.ps1'
$installRoot = Split-Path -Parent $PSScriptRoot
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

function Test-GuardRunning {
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop)
        foreach ($process in $processes) {
            if ([string]$process.CommandLine -like ('*' + $script:GuardScriptPath + '*')) {
                return $true
            }
        }
    } catch {
        return $false
    }
    return $false
}

function Start-GuardProcess {
    if (Test-GuardRunning) {
        return
    }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $guardScript = $script:GuardScriptPath
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

    $config = Read-GuardConfig -Path $ConfigPath
    if (-not (Test-TcpPort -Port ([int]$config.proxyPort) -TimeoutMilliseconds 1000)) {
        throw ('The local proxy port {0} is not accepting connections.' -f $config.proxyPort)
    }

    $exitIp = Get-CurrentExitIp -Config $config
    if ($exitIp -ne [string]$config.expectedIp) {
        throw ('The proxy exit IP is {0}, not the configured {1}.' -f $exitIp, $config.expectedIp)
    }

    $processes = @(Get-ClaudeProcesses)
    if ($processes.Count -gt 0) {
        $violations = @(Get-ClaudeProcessViolations -Processes $processes -Config $config)
        if ($violations.Count -eq 0) {
            Start-GuardProcess
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

    Start-GuardProcess

    $claudeExe = Find-ClaudeExecutable -Config $config
    $arguments = @(Get-ClaudeLaunchArguments -Config $config)
    Start-Process -FilePath $claudeExe -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $claudeExe) | Out-Null

    Start-Sleep -Seconds 2
    $started = @(Get-ClaudeProcesses)
    $bad = @(Get-ClaudeProcessViolations -Processes $started -Config $config)
    if ($started.Count -eq 0 -or $bad.Count -gt 0) {
        Stop-ClaudeProcesses -Processes $started | Out-Null
        throw 'Claude did not start with the required proxy arguments.'
    }
} catch {
    Show-GuardMessage -Message $_.Exception.Message
    exit 1
}
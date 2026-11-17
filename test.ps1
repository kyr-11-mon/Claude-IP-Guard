[CmdletBinding()]
param(
    [string]$InstallDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot) -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json') -PathType Leaf)) {
        $InstallDir = $PSScriptRoot
    } else {
        $InstallDir = Join-Path $env:LOCALAPPDATA 'ClaudeIPGuard'
    }
}
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\', '/')
$modulePath = Join-Path $InstallDir 'src\ClaudeIPGuard.psm1'
Import-Module $modulePath -Force

$configPath = Join-Path $InstallDir 'config.json'
$failures = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host 'FAIL: configuration file is missing.'
    exit 1
}

try {
    $config = Read-GuardConfig -Path $configPath
    Write-Host 'PASS: configuration is valid.'
} catch {
    Write-Host ('FAIL: configuration is invalid: {0}' -f $_.Exception.Message)
    exit 1
}

$guardProcesses = @()
try {
    $guardProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        ([string]$_.CommandLine) -like ('*' + $InstallDir + '*') -and ([string]$_.CommandLine) -like '*guard.ps1*'
    })
} catch {
    $guardProcesses = @()
}
if ($guardProcesses.Count -gt 0) {
    Write-Host 'PASS: monitor is running.'
} else {
    Write-Host 'FAIL: monitor is not running.'
    $failures.Add('monitor')
}

if (Test-TcpPort -Port ([int]$config.proxyPort) -TimeoutMilliseconds 1000) {
    Write-Host 'PASS: proxy port is reachable.'
} else {
    Write-Host 'FAIL: proxy port is not reachable.'
    $failures.Add('proxy')
}

try {
    $ip = Get-CurrentExitIp -Config $config
    if ($ip -eq [string]$config.expectedIp) {
        Write-Host ('PASS: exit IP is {0}.' -f $ip)
    } else {
        Write-Host ('FAIL: exit IP is {0}, expected {1}.' -f $ip, $config.expectedIp)
        $failures.Add('exit-ip')
    }
} catch {
    Write-Host ('FAIL: exit IP check failed: {0}' -f $_.Exception.Message)
    $failures.Add('exit-ip')
}

$processes = @(Get-ClaudeProcesses)
if ($processes.Count -eq 0) {
    Write-Host 'INFO: Claude is not running.'
} else {
    $violations = @(Get-ClaudeProcessViolations -Processes $processes -Config $config)
    if ($violations.Count -eq 0) {
        Write-Host 'PASS: Claude is using the required proxy.'
    } else {
        foreach ($violation in $violations) {
            Write-Host ('FAIL: {0}' -f $violation)
        }
        $failures.Add('process')
    }

    try {
        $connections = @(Get-ClaudeConnections -Processes $processes)
        $public = @(Get-PublicConnections -Connections $connections)
        if ($public.Count -eq 0) {
            Write-Host 'PASS: no public direct connections.'
        } else {
            Write-Host ('FAIL: {0} public direct connection(s).' -f $public.Count)
            $failures.Add('connections')
        }
    } catch {
        Write-Host ('WARN: connection audit unavailable: {0}' -f $_.Exception.Message)
    }
}

if ($failures.Count -eq 0) {
    Write-Host 'All checks passed.'
    exit 0
}

Write-Host ('Checks failed: {0}' -f ($failures -join ', '))
exit 1
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
$logPath = Join-Path $InstallDir 'logs\guard.log'

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host ('Not installed: {0}' -f $configPath)
    exit 1
}

$config = Read-GuardConfig -Path $configPath
Write-Host 'Claude IP Guard status'
Write-Host ('Install directory: {0}' -f $InstallDir)
Write-Host ('Proxy: {0}' -f (Get-ProxyUrl -Config $config))
Write-Host ('Expected exit IP: {0}' -f $config.expectedIp)
Write-Host ('Check interval: {0}s' -f $config.checkIntervalSeconds)

$guardProcesses = @()
try {
    $guardProcesses = @(Get-GuardMonitorProcesses | Where-Object {
        Test-TextContainsDirectory -Text ([string]$_.ScriptPath) -Directory $InstallDir
    })
} catch {
    $guardProcesses = @()
}
Write-Host ('Monitor running: {0}' -f ($guardProcesses.Count -gt 0))

$portOk = Test-TcpPort -TargetHost ([string]$config.proxyHost) -Port ([int]$config.proxyPort) -TimeoutMilliseconds 1000
Write-Host ('Proxy port reachable: {0}' -f $portOk)

if ($portOk) {
    try {
        $ip = Get-CurrentExitIp -Config $config
        Write-Host ('Current exit IP: {0}' -f $ip)
        Write-Host ('Exit IP matches: {0}' -f ($ip -eq [string]$config.expectedIp))
    } catch {
        Write-Host ('Exit IP check failed: {0}' -f $_.Exception.Message)
    }
}

$processes = @(Get-ClaudeProcesses)
Write-Host ('Claude processes: {0}' -f $processes.Count)
if ($processes.Count -gt 0) {
    $violations = @(Get-ClaudeProcessViolations -Processes $processes -Config $config)
    Write-Host ('Proxy argument violations: {0}' -f $violations.Count)
    try {
        $connections = @(Get-ClaudeConnections -Processes $processes)
        $public = @(Get-PublicConnections -Connections $connections)
        Write-Host ('Public direct connections: {0}' -f $public.Count)
    } catch {
        Write-Host 'Public connection audit: unavailable'
    }
}

if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    Write-Host 'Recent log lines:'
    Get-Content -LiteralPath $logPath -Tail 8 -Encoding UTF8 | ForEach-Object { Write-Host ('  ' + $_) }
}

exit 0
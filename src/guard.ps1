[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'ClaudeIPGuard.psm1'
Import-Module $modulePath -Force

$installRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $installRoot 'config.json'
$logPath = Join-Path $installRoot 'logs\guard.log'

$hash = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($installRoot.ToLowerInvariant())
    $digest = $hash.ComputeHash($bytes)
    $suffix = ([System.BitConverter]::ToString($digest) -replace '-', '').Substring(0, 16)
} finally {
    $hash.Dispose()
}

$mutex = New-Object System.Threading.Mutex($false, ('Local\ClaudeIPGuard-' + $suffix))
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        return
    }

    Write-GuardLog -Message 'guard started' -LogPath $logPath

    $consecutiveFailures = 0
    while ($true) {
        $interval = 3
        $config = $null
        try {
            $config = Read-GuardConfig -Path $configPath
            $interval = [int]$config.checkIntervalSeconds
            $proxyReachable = Test-TcpPort -Port ([int]$config.proxyPort) -TimeoutMilliseconds 1000

            $exitIp = $null
            $previousFailures = $consecutiveFailures
            if ($proxyReachable) {
                try {
                    $exitIp = Get-CurrentExitIp -Config $config -TimeoutSeconds 8
                    $consecutiveFailures = 0
                } catch {
                    $consecutiveFailures = $consecutiveFailures + 1
                    Write-GuardLog -Message ('trace check failed: ' + $_.Exception.Message) -LogPath $logPath -Level WARN
                }
            }

            $processes = @(Get-ClaudeProcesses)
            $connections = @()
            $querySucceeded = $true
            if ($processes.Count -gt 0) {
                try {
                    $connections = @(Get-ClaudeConnections -Processes $processes)
                } catch {
                    $querySucceeded = $false
                    Write-GuardLog -Message ('TCP connection audit unavailable: ' + $_.Exception.Message) -LogPath $logPath -Level WARN
                }
            }

            $decision = Get-GuardDecision -Config $config -ProxyReachable $proxyReachable -ExitIp $exitIp -ConsecutiveTraceFailures $previousFailures -Processes $processes -Connections $connections -ConnectionQuerySucceeded $querySucceeded
            if ($decision.Stop) {
                $reasons = @($decision.Reasons) -join ' '
                Write-GuardLog -Message ('stopping Claude: ' + $reasons) -LogPath $logPath -Level ERROR
                $killed = @(Stop-ClaudeProcesses -Processes $processes)
                if ($killed.Count -gt 0) {
                    Write-GuardLog -Message ('closed Claude process IDs: ' + ($killed -join ', ')) -LogPath $logPath -Level ERROR
                }
            }
        } catch {
            Write-GuardLog -Message ('guard configuration error: ' + $_.Exception.Message) -LogPath $logPath -Level ERROR
            Stop-ClaudeProcesses | Out-Null
            $interval = 3
        }

        Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min(30, $interval)))
    }
} finally {
    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}

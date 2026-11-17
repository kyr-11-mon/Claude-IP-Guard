[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'ClaudeIPGuard.psm1'
Import-Module $modulePath -Force

$installRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $installRoot 'config.json'
$logPath = Join-Path $installRoot 'logs\guard.log'

# One monitor per logon session, on purpose: the mutex is not scoped to an
# install directory. The Local namespace is per logon session, so every install
# started in the same session shares this mutex; separate sessions (fast user
# switching, RDP) get separate namespaces. This keeps two installs with
# different proxy settings from running two monitors in one session and
# stopping each other's Claude.
$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeIPGuard-Monitor')
$hasMutex = $false
try {
    # WaitOne throws AbandonedMutexException when a previous monitor was killed
    # without releasing the mutex. That still grants ownership, so treat it as
    # acquired instead of letting the monitor die silently.
    try {
        $hasMutex = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $hasMutex = $true
    }
    if (-not $hasMutex) {
        Write-GuardLogSafe -Message 'another Claude IP Guard monitor is already running; this instance will not start' -LogPath $logPath -Level WARN
        return
    }

    Write-GuardLogSafe -Message 'guard started' -LogPath $logPath

    $consecutiveTraceFailures = 0
    $consecutiveCheckErrors = 0
    $orphanHelperFirstSeen = $null

    while ($true) {
        $interval = 3

        # Reading the configuration is its own phase: a broken configuration must
        # fail closed, and this branch must never throw out of the loop. An
        # unhandled exception would silently kill the monitor while Claude keeps
        # running unprotected.
        try {
            $config = Read-GuardConfig -Path $configPath
            $interval = [int]$config.checkIntervalSeconds
        } catch {
            Write-GuardLogSafe -Message ('guard configuration error: ' + $_.Exception.Message) -LogPath $logPath -Level ERROR
            try {
                $stopped = @(Stop-ClaudeProcesses)
                if ($stopped.Count -gt 0) {
                    Write-GuardLogSafe -Message ('closed Claude process IDs: ' + ($stopped -join ', ')) -LogPath $logPath -Level ERROR
                }
            } catch {
                Write-GuardLogSafe -Message ('failed to stop Claude after a configuration error: ' + $_.Exception.Message) -LogPath $logPath -Level ERROR
            }
            Start-Sleep -Seconds 3
            continue
        }

        $processes = @()
        $connections = @()
        $querySucceeded = $true
        $ignoreOrphanHelpers = $false
        $stopClaude = $false
        $stopReasons = @()
        $checkFailed = $false

        try {
            $proxyReachable = Test-TcpPort -TargetHost ([string]$config.proxyHost) -Port ([int]$config.proxyPort) -TimeoutMilliseconds 1000

            $exitIp = $null
            $previousTraceFailures = $consecutiveTraceFailures
            if ($proxyReachable) {
                try {
                    $exitIp = Get-CurrentExitIp -Config $config -TimeoutSeconds 8
                    $consecutiveTraceFailures = 0
                } catch {
                    $consecutiveTraceFailures = $consecutiveTraceFailures + 1
                    Write-GuardLogSafe -Message ('trace check failed: ' + $_.Exception.Message) -LogPath $logPath -Level WARN
                }
            }

            $processes = @(Get-ClaudeProcesses)
            if ($processes.Count -gt 0) {
                try {
                    $connections = @(Get-ClaudeConnections -Processes $processes)
                } catch {
                    $querySucceeded = $false
                    Write-GuardLogSafe -Message ('TCP connection audit unavailable: ' + $_.Exception.Message) -LogPath $logPath -Level WARN
                }
            }

            # Claude main processes disappear a moment before their helpers on a
            # normal exit. Suppress the orphan-helper violation for a short grace
            # period so that quitting Claude does not look like a failure.
            $mainProcesses = @(Get-ClaudeMainProcesses -Processes $processes)
            if ($mainProcesses.Count -eq 0 -and $processes.Count -gt 0) {
                if ($null -eq $orphanHelperFirstSeen) {
                    $orphanHelperFirstSeen = Get-Date
                }
                if (((Get-Date) - $orphanHelperFirstSeen).TotalSeconds -lt 5) {
                    $ignoreOrphanHelpers = $true
                }
            } else {
                $orphanHelperFirstSeen = $null
            }

            $decision = Get-GuardDecision -Config $config -ProxyReachable $proxyReachable -ExitIp $exitIp -ConsecutiveTraceFailures $previousTraceFailures -Processes $processes -Connections $connections -ConnectionQuerySucceeded $querySucceeded -IgnoreOrphanHelpers:$ignoreOrphanHelpers
            if ($decision.Stop) {
                $stopClaude = $true
                $stopReasons = @($decision.Reasons)
            }
        } catch {
            $checkFailed = $true
            $consecutiveCheckErrors = $consecutiveCheckErrors + 1
            Write-GuardLogSafe -Message ('guard check failed: ' + $_.Exception.Message) -LogPath $logPath -Level WARN
            if ($consecutiveCheckErrors -ge 2) {
                $stopClaude = $true
                $stopReasons = @(('the monitor failed repeatedly: ' + $_.Exception.Message))
            }
        }

        if (-not $checkFailed) {
            # Only a fully successful iteration clears the error streak. An
            # unconditional reset here would erase the first failure before the
            # second one can escalate, so a monitor that fails every cycle would
            # warn forever and never close Claude (fail-open).
            $consecutiveCheckErrors = 0
        }

        if ($stopClaude) {
            $reasons = @($stopReasons) -join ' '
            Write-GuardLogSafe -Message ('stopping Claude: ' + $reasons) -LogPath $logPath -Level ERROR
            try {
                if ($processes.Count -gt 0) {
                    $killed = @(Stop-ClaudeProcesses -Processes $processes)
                } else {
                    # The process list may be empty because enumeration itself
                    # failed; fall back to discovering Claude again so that a
                    # repeated check error still fails closed.
                    $killed = @(Stop-ClaudeProcesses)
                }
                if ($killed.Count -gt 0) {
                    Write-GuardLogSafe -Message ('closed Claude process IDs: ' + ($killed -join ', ')) -LogPath $logPath -Level ERROR
                }
            } catch {
                Write-GuardLogSafe -Message ('failed to stop Claude: ' + $_.Exception.Message) -LogPath $logPath -Level ERROR
            }
        }

        Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min(30, $interval)))
    }
} finally {
    Write-GuardLogSafe -Message 'guard stopped' -LogPath $logPath
    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}

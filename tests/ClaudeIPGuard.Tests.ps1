BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\src\ClaudeIPGuard.psm1'
    $script:GuardScriptPath = Join-Path $PSScriptRoot '..\src\guard.ps1'
    Import-Module $script:ModulePath -Force
}

Describe 'Test-GuardConfig' {
    BeforeEach {
        $script:valid = [pscustomobject]@{
            proxyType = 'http'
            proxyHost = '127.0.0.1'
            proxyPort = 1080
            expectedIp = '203.0.113.10'
            claudePackageName = 'Claude'
            claudeExe = ''
            checkIntervalSeconds = 3
        }
    }

    It 'accepts a valid configuration' {
        { Test-GuardConfig -Config $script:valid } | Should -Not -Throw
    }

    It 'rejects a port below 1' {
        $script:valid.proxyPort = 0
        { Test-GuardConfig -Config $script:valid } | Should -Throw
    }

    It 'rejects a port above 65535' {
        $script:valid.proxyPort = 65536
        { Test-GuardConfig -Config $script:valid } | Should -Throw
    }

    It 'rejects an invalid IPv4 address' {
        $script:valid.expectedIp = 'not-an-ip'
        { Test-GuardConfig -Config $script:valid } | Should -Throw
    }

    It 'rejects a non-loopback proxy host' {
        $script:valid.proxyHost = '192.168.1.2'
        { Test-GuardConfig -Config $script:valid } | Should -Throw
    }

    It 'accepts an IPv6 loopback proxy host' {
        $script:valid.proxyHost = '::1'
        { Test-GuardConfig -Config $script:valid } | Should -Not -Throw
    }

    It 'rejects an unknown proxy type' {
        $script:valid.proxyType = 'ftp'
        { Test-GuardConfig -Config $script:valid } | Should -Throw
    }

    It 'rejects an interval outside 1..30' {
        $script:valid.checkIntervalSeconds = 0
        { Test-GuardConfig -Config $script:valid } | Should -Throw
    }
}

Describe 'New-GuardConfig' {
    It 'creates a normalized configuration with defaults' {
        $config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
        $config.proxyType | Should -Be 'http'
        $config.proxyHost | Should -Be '127.0.0.1'
        $config.proxyPort | Should -Be 1080
        $config.expectedIp | Should -Be '203.0.113.10'
        $config.checkIntervalSeconds | Should -Be 3
    }

    It 'normalizes an abbreviated IPv4 address' {
        $config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '127.1'
        $config.expectedIp | Should -Be '127.0.0.1'
    }
}

Describe 'Get-ProxyUrl' {
    It 'builds an HTTP proxy URL' {
        $config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
        Get-ProxyUrl -Config $config | Should -Be 'http://127.0.0.1:1080'
    }

    It 'builds a SOCKS5 proxy URL' {
        $config = New-GuardConfig -ProxyType socks5 -ProxyPort 1080 -ExpectedIp '203.0.113.10'
        Get-ProxyUrl -Config $config | Should -Be 'socks5://127.0.0.1:1080'
    }

    It 'brackets an IPv6 proxy host' {
        $config = New-GuardConfig -ProxyPort 1080 -ProxyHost '::1' -ExpectedIp '203.0.113.10'
        Get-ProxyUrl -Config $config | Should -Be 'http://[::1]:1080'
    }

    It 'uses socks5h so that curl resolves DNS remotely' {
        $config = New-GuardConfig -ProxyType socks5 -ProxyPort 1080 -ExpectedIp '203.0.113.10'
        Get-ProxyUrl -Config $config -SocksRemoteDns | Should -Be 'socks5h://127.0.0.1:1080'
    }

    It 'keeps the http scheme when remote DNS is requested' {
        $config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
        Get-ProxyUrl -Config $config -SocksRemoteDns | Should -Be 'http://127.0.0.1:1080'
    }
}

Describe 'Get-ClaudeLaunchArguments' {
    BeforeEach {
        $script:config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
    }

    It 'includes the exact proxy and hardening flags' {
        $args = @(Get-ClaudeLaunchArguments -Config $script:config)
        $args | Should -Contain '--proxy-server=http://127.0.0.1:1080'
        $args | Should -Contain '--disable-quic'
        $args | Should -Contain '--webrtc-ip-handling-policy=disable_non_proxied_udp'
    }
}

Describe 'Get-ExitIpFromTrace' {
    It 'parses the ip field' {
        $trace = @('fl=1f2', 'ip=203.0.113.10', 'ts=1', 'loc=JP') -join [Environment]::NewLine
        Get-ExitIpFromTrace -Trace $trace | Should -Be '203.0.113.10'
    }

    It 'returns null when the ip field is missing' {
        Get-ExitIpFromTrace -Trace 'fl=1f2' | Should -BeNullOrEmpty
    }

    It 'returns null for an invalid ip field' {
        Get-ExitIpFromTrace -Trace 'ip=not-an-ip' | Should -BeNullOrEmpty
    }
}

Describe 'Test-PublicAddress' {
    It 'treats loopback and private IPv4 as private' {
        Test-PublicAddress -Address '127.0.0.1' | Should -BeFalse
        Test-PublicAddress -Address '10.1.2.3' | Should -BeFalse
        Test-PublicAddress -Address '172.16.5.4' | Should -BeFalse
        Test-PublicAddress -Address '192.168.1.2' | Should -BeFalse
        Test-PublicAddress -Address '169.254.1.2' | Should -BeFalse
    }

    It 'treats a public IPv4 address as public' {
        Test-PublicAddress -Address '203.0.113.10' | Should -BeTrue
    }

    It 'treats loopback and private IPv6 as private' {
        Test-PublicAddress -Address '::1' | Should -BeFalse
        Test-PublicAddress -Address 'fd00::1' | Should -BeFalse
        Test-PublicAddress -Address 'fe80::1' | Should -BeFalse
    }

    It 'treats a global IPv6 address as public' {
        Test-PublicAddress -Address '2001:db8::1' | Should -BeTrue
    }
}

Describe 'Get-ClaudeMainProcesses' {
    It 'keeps only processes without an Electron type argument' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = '"C:\Apps\Claude.exe" --proxy-server=http://127.0.0.1:1080' }
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 11; CommandLine = '"C:\Apps\Claude.exe" --type=utility --utility-sub-type=network.mojom.NetworkService' }
        )
        $main = @(Get-ClaudeMainProcesses -Processes $processes)
        $main.Count | Should -Be 1
        $main[0].ProcessId | Should -Be 10
    }

    It 'returns an empty list when there is no main process' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 11; CommandLine = '"C:\Apps\Claude.exe" --type=utility' }
        )
        @(Get-ClaudeMainProcesses -Processes $processes).Count | Should -Be 0
    }
}

Describe 'Get-ClaudeProcessViolations' {
    BeforeEach {
        $script:config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
    }

    It 'accepts a guarded main process' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = '"C:\Apps\Claude.exe" --proxy-server=http://127.0.0.1:1080 --disable-quic' }
        )
        @(Get-ClaudeProcessViolations -Processes $processes -Config $script:config).Count | Should -Be 0
    }

    It 'flags an unguarded main process' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = '"C:\Apps\Claude.exe"' }
        )
        @(Get-ClaudeProcessViolations -Processes $processes -Config $script:config).Count | Should -BeGreaterThan 0
    }

    It 'flags a helper-only process set' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 11; CommandLine = '"C:\Apps\Claude.exe" --type=utility' }
        )
        @(Get-ClaudeProcessViolations -Processes $processes -Config $script:config).Count | Should -BeGreaterThan 0
    }

    It 'ignores the Claude Code CLI process' {
        $processes = @(
            [pscustomobject]@{ Name = 'claude.exe'; ProcessId = 12; CommandLine = '"C:\Users\Example\.local\bin\claude.exe"' }
        )
        @(Get-ClaudeProcessViolations -Processes $processes -Config $script:config).Count | Should -Be 0
    }

    It 'flags the wrong proxy port' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = '"C:\Apps\Claude.exe" --proxy-server=http://127.0.0.1:9999' }
        )
        @(Get-ClaudeProcessViolations -Processes $processes -Config $script:config).Count | Should -BeGreaterThan 0
    }

    It 'flags duplicate proxy server arguments' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = '"C:\Apps\Claude.exe" --proxy-server=http://127.0.0.1:1080 --proxy-server=http://127.0.0.1:9999' }
        )
        $violations = @(Get-ClaudeProcessViolations -Processes $processes -Config $script:config)
        $violations.Count | Should -BeGreaterThan 0
        ($violations -join ' ') | Should -Match 'multiple --proxy-server'
    }

    It 'flags a proxy bypass list' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = '"C:\Apps\Claude.exe" --proxy-server=http://127.0.0.1:1080 --proxy-bypass-list=*' }
        )
        $violations = @(Get-ClaudeProcessViolations -Processes $processes -Config $script:config)
        $violations.Count | Should -BeGreaterThan 0
        ($violations -join ' ') | Should -Match 'proxy bypass argument'
    }

    It 'flags a no-proxy-server argument' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = '"C:\Apps\Claude.exe" --proxy-server=http://127.0.0.1:1080 --no-proxy-server' }
        )
        @(Get-ClaudeProcessViolations -Processes $processes -Config $script:config).Count | Should -BeGreaterThan 0
    }

    It 'can ignore helper-only processes during shutdown' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 11; CommandLine = '"C:\Apps\Claude.exe" --type=utility' }
        )
        @(Get-ClaudeProcessViolations -Processes $processes -Config $script:config -IgnoreOrphanHelpers).Count | Should -Be 0
    }
}

Describe 'Get-PublicConnections' {
    It 'keeps public remote connections and drops private/loopback ones' {
        $connections = @(
            [pscustomobject]@{ RemoteAddress = '203.0.113.10'; RemotePort = 443; State = 'Established' }
            [pscustomobject]@{ RemoteAddress = '127.0.0.1'; RemotePort = 1080; State = 'Established' }
            [pscustomobject]@{ RemoteAddress = '192.168.1.2'; RemotePort = 443; State = 'Established' }
            [pscustomobject]@{ RemoteAddress = '::1'; RemotePort = 1080; State = 'Established' }
        )
        $public = @(Get-PublicConnections -Connections $connections)
        $public.Count | Should -Be 1
        $public[0].RemoteAddress | Should -Be '203.0.113.10'
    }
}
Describe 'Test-TcpPort' {
    It 'returns true for a listening loopback port' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            Test-TcpPort -Port $port -TimeoutMilliseconds 1000 | Should -BeTrue
        } finally {
            $listener.Stop()
        }
    }

    It 'can reach an IPv6-only loopback listener' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::IPv6Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            Test-TcpPort -TargetHost '::1' -Port $port -TimeoutMilliseconds 1000 | Should -BeTrue
            Test-TcpPort -Port $port -TimeoutMilliseconds 500 | Should -BeFalse
        } finally {
            $listener.Stop()
        }
    }

    It 'returns false for a closed loopback port' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()
        Test-TcpPort -Port $port -TimeoutMilliseconds 500 | Should -BeFalse
    }

    It 'rejects an invalid port' {
        { Test-TcpPort -Port 0 } | Should -Throw
    }
}

Describe 'Get-ClaudeProcesses' {
    It 'keeps Claude Desktop and ignores the Claude Code CLI' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = 'Claude.exe' }
            [pscustomobject]@{ Name = 'claude.exe'; ProcessId = 11; CommandLine = 'claude.exe --type=utility' }
            [pscustomobject]@{ Name = 'chrome.exe'; ProcessId = 12; CommandLine = 'chrome.exe' }
        )
        $result = @(Get-ClaudeProcesses -Processes $processes)
        $result.Count | Should -Be 1
        $result.ProcessId | Should -Contain 10
    }

    It 'keeps a lower-case Desktop helper whose path is in WindowsApps' {
        $processes = @(
            [pscustomobject]@{
                Name = 'claude.exe'
                ProcessId = 13
                CommandLine = 'claude.exe --type=utility'
                ExecutablePath = 'C:\Program Files\WindowsApps\Claude_1.0.0.0_x64__example\app\claude.exe'
            }
        )
        $result = @(Get-ClaudeProcesses -Processes $processes)
        $result.Count | Should -Be 1
        $result[0].ProcessId | Should -Be 13
    }
}

Describe 'Get-ClaudeConnections' {
    It 'keeps connections owned by Claude processes' {
        $processes = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10 }
            [pscustomobject]@{ Name = 'claude.exe'; ProcessId = 11 }
        )
        $connections = @(
            [pscustomobject]@{ OwningProcess = 10; RemoteAddress = '203.0.113.10'; RemotePort = 443 }
            [pscustomobject]@{ OwningProcess = 11; RemoteAddress = '127.0.0.1'; RemotePort = 1080 }
            [pscustomobject]@{ OwningProcess = 12; RemoteAddress = '203.0.113.11'; RemotePort = 443 }
        )
        $result = @(Get-ClaudeConnections -Processes $processes -Connections $connections)
        $result.Count | Should -Be 2
        $result.OwningProcess | Should -Contain 10
        $result.OwningProcess | Should -Contain 11
    }

    It 'returns an empty list when no Claude process is present' {
        $connections = @([pscustomobject]@{ OwningProcess = 10; RemoteAddress = '203.0.113.10'; RemotePort = 443 })
        @(Get-ClaudeConnections -Processes @() -Connections $connections).Count | Should -Be 0
    }
}

Describe 'Find-ClaudeExecutable' {
    BeforeEach {
        $script:temp = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-ip-guard-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:temp -Force | Out-Null
        $script:config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'uses the configured executable first' {
        $exe = Join-Path $script:temp 'Claude.exe'
        Set-Content -LiteralPath $exe -Value ''
        $script:config.claudeExe = $exe
        Find-ClaudeExecutable -Config $script:config -SearchPaths @() | Should -Be $exe
    }

    It 'finds the executable from an Appx package' {
        $appDir = Join-Path $script:temp 'app'
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        $exe = Join-Path $appDir 'Claude.exe'
        Set-Content -LiteralPath $exe -Value ''
        $package = [pscustomobject]@{ InstallLocation = $script:temp }
        $script:config.claudeExe = ''
        Find-ClaudeExecutable -Config $script:config -AppxPackage $package -SearchPaths @() | Should -Be $exe
    }

    It 'throws when Claude cannot be found' {
        $script:config.claudeExe = ''
        { Find-ClaudeExecutable -Config $script:config -AppxPackage $null -SearchPaths @() } | Should -Throw
    }
}

Describe 'Invoke-TraceRequest and Get-CurrentExitIp' {
    BeforeEach {
        $script:temp = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-ip-guard-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:temp -Force | Out-Null
        $script:fakeCurl = Join-Path $script:temp 'fake-curl.cmd'
        Set-Content -LiteralPath $script:fakeCurl -Value '@echo off', 'echo ip=203.0.113.10', 'echo loc=JP'
        $script:fakeCurlArgs = Join-Path $script:temp 'fake-curl-args.cmd'
        Set-Content -LiteralPath $script:fakeCurlArgs -Value '@echo off', 'echo args=%*', 'echo ip=203.0.113.10'
        $script:config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns the trace body from the configured curl executable' {
        $trace = Invoke-TraceRequest -Config $script:config -CurlPath $script:fakeCurl
        $trace | Should -Match 'ip=203\.0\.113\.10'
    }

    It 'returns the exit IP from the trace' {
        Get-CurrentExitIp -Config $script:config -CurlPath $script:fakeCurl | Should -Be '203.0.113.10'
    }

    It 'uses socks5h so that curl resolves DNS remotely' {
        $socksConfig = New-GuardConfig -ProxyType socks5 -ProxyPort 1080 -ExpectedIp '203.0.113.10'
        $trace = Invoke-TraceRequest -Config $socksConfig -CurlPath $script:fakeCurlArgs
        $trace | Should -Match 'socks5h://127\.0\.0\.1:1080'
    }

    It 'throws when the trace command fails' {
        $failing = Join-Path $script:temp 'failing.cmd'
        Set-Content -LiteralPath $failing -Value '@echo off', 'exit /b 7'
        { Invoke-TraceRequest -Config $script:config -CurlPath $failing } | Should -Throw
    }
}

Describe 'Write-GuardLog' {
    BeforeEach {
        $script:temp = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-ip-guard-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:temp -Force | Out-Null
        $script:log = Join-Path $script:temp 'guard.log'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes a timestamped line' {
        Write-GuardLog -Message 'started' -LogPath $script:log
        (Get-Content -LiteralPath $script:log -Raw) | Should -Match 'started'
    }

    It 'rotates a log that exceeds the limit' {
        Write-GuardLog -Message 'first entry' -LogPath $script:log -MaxBytes 1
        Write-GuardLog -Message 'second entry' -LogPath $script:log -MaxBytes 1
        Test-Path -LiteralPath ($script:log + '.1') | Should -BeTrue
        Test-Path -LiteralPath ($script:log + '.2') | Should -BeFalse
        (Get-Content -LiteralPath $script:log -Raw) | Should -Match 'second entry'
    }
}
Describe 'Write-GuardLogSafe' {
    BeforeEach {
        $script:temp = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-ip-guard-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:temp -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'does not throw when the log cannot be written' {
        $blocker = Join-Path $script:temp 'not-a-directory'
        Set-Content -LiteralPath $blocker -Value 'file'
        { Write-GuardLogSafe -Message 'failure path' -LogPath (Join-Path $blocker 'guard.log') } | Should -Not -Throw
    }
}

Describe 'Test-TextContainsDirectory' {
    It 'matches a path literally even with wildcard characters' {
        Test-TextContainsDirectory -Text 'powershell.exe -File "C:\Tools\ClaudeIPGuard[beta]\src\guard.ps1"' -Directory 'C:\Tools\ClaudeIPGuard[beta]' | Should -BeTrue
    }

    It 'does not match a sibling directory with a longer name' {
        Test-TextContainsDirectory -Text 'powershell.exe -File "C:\Tools\ClaudeIPGuard2\src\guard.ps1"' -Directory 'C:\Tools\ClaudeIPGuard' | Should -BeFalse
    }
}

Describe 'Get-GuardMonitorProcesses' {
    It 'returns only PowerShell processes that run guard.ps1' {
        $processes = @(
            [pscustomobject]@{ Name = 'powershell.exe'; ProcessId = 101; CommandLine = 'powershell.exe -NoProfile -File "C:\Tools\ClaudeIPGuard[beta]\src\guard.ps1"' }
            [pscustomobject]@{ Name = 'powershell.exe'; ProcessId = 102; CommandLine = 'powershell.exe -File "C:\Tools\ClaudeIPGuard\src\status.ps1"' }
            [pscustomobject]@{ Name = 'powershell.exe'; ProcessId = 103; CommandLine = 'powershell.exe -NoProfile -Command "Get-Date"' }
        )
        $monitors = @(Get-GuardMonitorProcesses -Processes $processes)
        $monitors.Count | Should -Be 1
        $monitors[0].ProcessId | Should -Be 101
        $monitors[0].InstallDir | Should -Be 'C:\Tools\ClaudeIPGuard[beta]'
    }
}

Describe 'Read-GuardConfig and Write-GuardConfig' {
    BeforeEach {
        $script:temp = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-ip-guard-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:temp -Force | Out-Null
        $script:configPath = Join-Path $script:temp 'config.json'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'round-trips a valid configuration' {
        $config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
        Write-GuardConfig -Config $config -Path $script:configPath
        $read = Read-GuardConfig -Path $script:configPath
        $read.proxyPort | Should -Be 1080
        $read.expectedIp | Should -Be '203.0.113.10'
    }

    It 'normalizes an abbreviated expected IP when read' {
        $config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '127.1'
        $config.expectedIp = '127.1'
        Write-GuardConfig -Config $config -Path $script:configPath
        $read = Read-GuardConfig -Path $script:configPath
        $read.expectedIp | Should -Be '127.0.0.1'
    }

    It 'creates the parent directory' {
        $nested = Join-Path $script:temp 'a\b\config.json'
        $config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
        Write-GuardConfig -Config $config -Path $nested
        Test-Path -LiteralPath $nested | Should -BeTrue
    }

    It 'rejects malformed JSON' {
        Set-Content -LiteralPath $script:configPath -Value '{not json'
        { Read-GuardConfig -Path $script:configPath } | Should -Throw
    }

    It 'rejects a missing field' {
        Set-Content -LiteralPath $script:configPath -Value '{"proxyType":"http","proxyHost":"127.0.0.1","proxyPort":1080}'
        { Read-GuardConfig -Path $script:configPath } | Should -Throw
    }
}

Describe 'Get-GuardDecision' {
    BeforeEach {
        $script:config = New-GuardConfig -ProxyPort 1080 -ExpectedIp '203.0.113.10'
        $script:guarded = @(
            [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = '"C:\Apps\Claude.exe" --proxy-server=http://127.0.0.1:1080' }
        )
    }

    It 'allows a guarded process with the expected exit IP' {
        $decision = Get-GuardDecision -Config $script:config -ProxyReachable $true -ExitIp '203.0.113.10' -Processes $script:guarded -Connections @()
        $decision.Stop | Should -BeFalse
        @($decision.Reasons).Count | Should -Be 0
    }

    It 'stops when the proxy port is unreachable' {
        $decision = Get-GuardDecision -Config $script:config -ProxyReachable $false -ExitIp '203.0.113.10' -Processes $script:guarded -Connections @()
        $decision.Stop | Should -BeTrue
    }

    It 'stops when the exit IP is different' {
        $decision = Get-GuardDecision -Config $script:config -ProxyReachable $true -ExitIp '198.51.100.20' -Processes $script:guarded -Connections @()
        $decision.Stop | Should -BeTrue
    }

    It 'does not stop on the first trace failure' {
        $decision = Get-GuardDecision -Config $script:config -ProxyReachable $true -ExitIp $null -ConsecutiveTraceFailures 0 -Processes $script:guarded -Connections @()
        $decision.Stop | Should -BeFalse
    }

    It 'stops after two consecutive trace failures' {
        $decision = Get-GuardDecision -Config $script:config -ProxyReachable $true -ExitIp $null -ConsecutiveTraceFailures 1 -Processes $script:guarded -Connections @()
        $decision.Stop | Should -BeTrue
    }

    It 'stops when the main process lacks the proxy argument' {
        $processes = @([pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 10; CommandLine = '"C:\Apps\Claude.exe"' })
        $decision = Get-GuardDecision -Config $script:config -ProxyReachable $true -ExitIp '203.0.113.10' -Processes $processes -Connections @()
        $decision.Stop | Should -BeTrue
    }

    It 'does not stop on orphan helpers when told to ignore them' {
        $helpers = @([pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 11; CommandLine = '"C:\Apps\Claude.exe" --type=utility' })
        $decision = Get-GuardDecision -Config $script:config -ProxyReachable $true -ExitIp '203.0.113.10' -Processes $helpers -Connections @() -IgnoreOrphanHelpers
        $decision.Stop | Should -BeFalse
    }

    It 'stops on a public TCP connection' {
        $connections = @([pscustomobject]@{ RemoteAddress = '198.51.100.20'; RemotePort = 443; State = 'Established' })
        $decision = Get-GuardDecision -Config $script:config -ProxyReachable $true -ExitIp '203.0.113.10' -Processes $script:guarded -Connections $connections -ConnectionQuerySucceeded $true
        $decision.Stop | Should -BeTrue
    }

    It 'does not stop on a public connection when the query failed' {
        $connections = @([pscustomobject]@{ RemoteAddress = '198.51.100.20'; RemotePort = 443; State = 'Established' })
        $decision = Get-GuardDecision -Config $script:config -ProxyReachable $true -ExitIp '203.0.113.10' -Processes $script:guarded -Connections $connections -ConnectionQuerySucceeded $false
        $decision.Stop | Should -BeFalse
    }
}

Describe 'New-InstallPlan' {
    It 'places every artifact under the install directory' {
        $plan = New-InstallPlan -InstallDir 'C:\Users\Example\AppData\Local\ClaudeIPGuard' -SourceRoot 'C:\Repo' -ClaudeExe ''
        $plan.ConfigPath | Should -Be 'C:\Users\Example\AppData\Local\ClaudeIPGuard\config.json'
        $plan.ModulePath | Should -Be 'C:\Users\Example\AppData\Local\ClaudeIPGuard\src\ClaudeIPGuard.psm1'
        $plan.LogPath | Should -Be 'C:\Users\Example\AppData\Local\ClaudeIPGuard\logs\guard.log'
        @($plan.Shortcuts).Count | Should -BeGreaterThan 0
    }

    It 'omits shortcuts when NoShortcuts is set' {
        $plan = New-InstallPlan -InstallDir 'C:\Users\Example\AppData\Local\ClaudeIPGuard' -SourceRoot 'C:\Repo' -ClaudeExe '' -NoShortcuts
        @($plan.Shortcuts).Count | Should -Be 0
    }
}

Describe 'guard.ps1 fail-closed invariants' {
    BeforeAll {
        $script:GuardText = Get-Content -LiteralPath $script:GuardScriptPath -Raw
    }

    It 'treats an abandoned mutex as acquired so a killed monitor cannot fail open' {
        $script:GuardText | Should -Match 'AbandonedMutexException'
    }

    It 'only clears the consecutive check-error counter after a fully successful iteration' {
        $script:GuardText | Should -Match '\$checkFailed = \$true'
        $script:GuardText | Should -Match 'if \(-not \$checkFailed\)'
    }
}
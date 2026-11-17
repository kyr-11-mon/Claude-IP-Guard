Set-StrictMode -Version Latest

$script:GuardVersion = '1.0.0'

function Test-GuardConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if ($null -eq $Config) {
        throw 'Configuration is empty.'
    }

    $proxyType = [string]$Config.proxyType
    if ($proxyType -notin @('http', 'socks5')) {
        throw 'proxyType must be http or socks5.'
    }

    $proxyHost = [string]$Config.proxyHost
    if ($proxyHost -notin @('127.0.0.1', '::1')) {
        throw 'proxyHost must be a loopback address (127.0.0.1 or ::1).'
    }

    $port = 0
    if (-not [int]::TryParse([string]$Config.proxyPort, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw 'proxyPort must be an integer between 1 and 65535.'
    }

    $expected = $null
    if (-not [System.Net.IPAddress]::TryParse([string]$Config.expectedIp, [ref]$expected) -or
        $expected.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'expectedIp must be a valid IPv4 address.'
    }

    $interval = 0
    if (-not [int]::TryParse([string]$Config.checkIntervalSeconds, [ref]$interval) -or
        $interval -lt 1 -or $interval -gt 30) {
        throw 'checkIntervalSeconds must be an integer between 1 and 30.'
    }

    $packageName = [string]$Config.claudePackageName
    if ([string]::IsNullOrWhiteSpace($packageName)) {
        throw 'claudePackageName must not be empty.'
    }

    return $true
}

function New-GuardConfig {
    [CmdletBinding()]
    param(
        [ValidateSet('http', 'socks5')]
        [string]$ProxyType = 'http',

        [string]$ProxyHost = '127.0.0.1',

        [Parameter(Mandatory = $true)]
        [int]$ProxyPort,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedIp,

        [int]$CheckIntervalSeconds = 3,

        [string]$ClaudePackageName = 'Claude',

        [string]$ClaudeExe = ''
    )

    $config = [pscustomobject][ordered]@{
        proxyType = $ProxyType.ToLowerInvariant()
        proxyHost = $ProxyHost
        proxyPort = $ProxyPort
        expectedIp = $ExpectedIp
        claudePackageName = $ClaudePackageName
        claudeExe = $ClaudeExe
        checkIntervalSeconds = $CheckIntervalSeconds
    }

    Test-GuardConfig -Config $config | Out-Null
    return $config
}

function Get-ProxyUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    Test-GuardConfig -Config $Config | Out-Null
    $hostPart = $Config.proxyHost
    if ($hostPart -eq '::1') {
        $hostPart = '[::1]'
    }
    return ('{0}://{1}:{2}' -f $Config.proxyType, $hostPart, $Config.proxyPort)
}

function Get-ClaudeLaunchArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    return @(
        ('--proxy-server=' + (Get-ProxyUrl -Config $Config)),
        '--disable-quic',
        '--webrtc-ip-handling-policy=disable_non_proxied_udp'
    )
}

function Get-ExitIpFromTrace {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Trace
    )

    if ([string]::IsNullOrWhiteSpace($Trace)) {
        return $null
    }

    foreach ($line in ($Trace -split "\r?\n")) {
        $match = [regex]::Match($line, '^\s*ip\s*=\s*(\S+)\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $ip = $null
            if ([System.Net.IPAddress]::TryParse($match.Groups[1].Value, [ref]$ip)) {
                return $ip.IPAddressToString
            }
        }
    }

    return $null
}

function Test-PublicAddress {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Address
    )

    $ip = $null
    if ([string]::IsNullOrWhiteSpace($Address) -or -not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) {
        return $false
    }

    if ($ip.IsIPv4MappedToIPv6) {
        $ip = $ip.MapToIPv4()
    }

    $bytes = $ip.GetAddressBytes()
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        if ($bytes[0] -eq 10) { return $false }
        if ($bytes[0] -eq 127) { return $false }
        if ($bytes[0] -eq 0) { return $false }
        if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }
        if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $false }
        if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $false }
        if ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return $false }
        return $true
    }

    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($ip.Equals([System.Net.IPAddress]::IPv6Loopback)) { return $false }
        if ($ip.Equals([System.Net.IPAddress]::IPv6Any)) { return $false }
        if (($bytes[0] -band 0xFE) -eq 0xFC) { return $false }
        if ($bytes[0] -eq 0xFE -and ($bytes[1] -band 0xC0) -eq 0x80) { return $false }
        return $true
    }

    return $false
}

function Test-ClaudeDesktopProcess {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Process
    )

    if ($null -eq $Process) {
        return $false
    }

    $name = [string]$Process.Name
    $path = ''
    if ($null -ne $Process.PSObject.Properties['ExecutablePath']) {
        $path = [string]$Process.ExecutablePath
    }

    if ($path -match '(?i)(^|\\)\.local\\bin\\claude\.exe$') {
        return $false
    }
    if ($path -match '(?i)\\WindowsApps\\Claude_[^\\]+\\app\\claude\.exe$') {
        return $true
    }
    if ($path -match '(?i)\\Programs\\Claude\\Claude\.exe$') {
        return $true
    }

    return ($name -cmatch '^Claude\.exe$')
}


function Get-ClaudeMainProcesses {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Processes
    )

    if ($null -eq $Processes) {
        return @()
    }

    return @($Processes | Where-Object {
        (Test-ClaudeDesktopProcess -Process $_) -and ([string]$_.CommandLine -notmatch '--type=')
    })
}

function Get-ClaudeProcessViolations {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Processes,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    Test-GuardConfig -Config $Config | Out-Null
    $violations = New-Object System.Collections.Generic.List[string]

    $claudeProcesses = @()
    if ($null -ne $Processes) {
        $claudeProcesses = @($Processes | Where-Object {
            Test-ClaudeDesktopProcess -Process $_
        })
    }
    if ($claudeProcesses.Count -eq 0) {
        return @()
    }

    $main = @(Get-ClaudeMainProcesses -Processes $claudeProcesses)
    if ($main.Count -eq 0) {
        $violations.Add('Claude helper processes are running without a main process.')
        return @($violations)
    }

    $expected = Get-ProxyUrl -Config $Config
    foreach ($process in $main) {
        $cmd = ([string]$process.CommandLine) -replace '"', '' -replace "'", ''
        $match = [regex]::Match($cmd, '(?:^|\s)--proxy-server(?:=|\s+)(\S+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $actual = $null
        if ($match.Success) {
            $actual = $match.Groups[1].Value.TrimEnd(',')
        }

        if ([string]::IsNullOrWhiteSpace($actual) -or $actual -ne $expected) {
            $violations.Add(('Claude main process {0} is not using the required proxy.' -f $process.ProcessId))
        }
    }

    return @($violations)
}

function Get-PublicConnections {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Connections
    )

    if ($null -eq $Connections) {
        return @()
    }

    return @($Connections | Where-Object {
        $remote = [string]$_.RemoteAddress
        $port = 0
        if ([string]::IsNullOrWhiteSpace($remote) -or -not [int]::TryParse([string]$_.RemotePort, [ref]$port) -or $port -le 0) {
            return $false
        }
        Test-PublicAddress -Address $remote
    })
}

function Test-TcpPort {
    [CmdletBinding()]
    param(
        [string]$TargetHost = '127.0.0.1',

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutMilliseconds = 1000
    )

    if ($Port -lt 1 -or $Port -gt 65535) {
        throw 'Port must be between 1 and 65535.'
    }
    if ($TimeoutMilliseconds -lt 1) {
        throw 'TimeoutMilliseconds must be greater than zero.'
    }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-ClaudeProcesses {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Processes
    )

    if ($null -eq $Processes) {
        $Processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Claude.exe' OR Name = 'claude.exe'" -ErrorAction SilentlyContinue)
    }

    if ($null -eq $Processes) {
        return @()
    }

    return @($Processes | Where-Object {
        Test-ClaudeDesktopProcess -Process $_
    } | ForEach-Object {
        $executablePath = ''
        if ($null -ne $_.PSObject.Properties['ExecutablePath']) {
            $executablePath = [string]$_.ExecutablePath
        }
        [pscustomobject]@{
            Name = [string]$_.Name
            ProcessId = [int]$_.ProcessId
            CommandLine = [string]$_.CommandLine
            ExecutablePath = $executablePath
        }
    })
}

function Find-ClaudeExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [AllowNull()]
        [object]$AppxPackage,

        [AllowNull()]
        [string[]]$SearchPaths
    )

    Test-GuardConfig -Config $Config | Out-Null

    if (-not [string]::IsNullOrWhiteSpace([string]$Config.claudeExe)) {
        $configured = [string]$Config.claudeExe
        if (Test-Path -LiteralPath $configured -PathType Leaf -ErrorAction SilentlyContinue) {
            return (Resolve-Path -LiteralPath $configured).Path
        }
        throw ('Configured claudeExe does not exist: {0}' -f $configured)
    }

    if (-not $PSBoundParameters.ContainsKey('AppxPackage')) {
        $AppxPackage = Get-AppxPackage -Name ([string]$Config.claudePackageName) -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($null -ne $AppxPackage -and -not [string]::IsNullOrWhiteSpace([string]$AppxPackage.InstallLocation)) {
        $location = [string]$AppxPackage.InstallLocation
        $candidate = Join-Path $location 'app\Claude.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }

        $found = Get-ChildItem -LiteralPath $location -Filter 'Claude.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $found) {
            return $found.FullName
        }
    }

    if (-not $PSBoundParameters.ContainsKey('SearchPaths')) {
        $candidates = New-Object System.Collections.Generic.List[string]
        $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
        $programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
        $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        if ($localAppData) {
            $candidates.Add((Join-Path $localAppData 'Programs\Claude'))
            $candidates.Add((Join-Path $localAppData 'Claude'))
        }
        if ($programFiles) {
            $candidates.Add((Join-Path $programFiles 'Claude'))
        }
        if ($programFilesX86) {
            $candidates.Add((Join-Path $programFilesX86 'Claude'))
        }
        $SearchPaths = @($candidates)
    }

    if ($null -ne $SearchPaths) {
        foreach ($path in $SearchPaths) {
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }

            if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue) {
                if ((Split-Path -Leaf $path) -match '^claude\.exe$') {
                    return (Resolve-Path -LiteralPath $path).Path
                }
                continue
            }

            foreach ($leaf in @('Claude.exe', 'claude.exe')) {
                $candidate = Join-Path $path $leaf
                if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
                    return (Resolve-Path -LiteralPath $candidate).Path
                }
            }
        }
    }

    throw 'Claude executable was not found. Set claudeExe in config.json to the full path of Claude.exe.'
}

function Invoke-TraceRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string]$CurlPath,

        [int]$TimeoutSeconds = 8,

        [string]$TraceUrl = 'https://claude.ai/cdn-cgi/trace'
    )

    Test-GuardConfig -Config $Config | Out-Null
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 60) {
        throw 'TimeoutSeconds must be between 1 and 60.'
    }

    if ([string]::IsNullOrWhiteSpace($CurlPath)) {
        $CurlPath = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (-not (Test-Path -LiteralPath $CurlPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            $command = Get-Command 'curl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $command) {
                throw 'curl.exe is required but was not found.'
            }
            $CurlPath = $command.Source
        }
    } elseif (-not (Test-Path -LiteralPath $CurlPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw ('curl executable was not found: {0}' -f $CurlPath)
    }

    $arguments = @(
        '--silent',
        '--show-error',
        '--fail',
        '--max-time', [string]$TimeoutSeconds,
        '--proxy', (Get-ProxyUrl -Config $Config),
        $TraceUrl
    )

    $output = & $CurlPath @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ('Trace request failed with exit code {0}.' -f $exitCode)
    }

    if ($null -eq $output) {
        return ''
    }

    return (($output | Out-String).Trim())
}

function Get-CurrentExitIp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string]$CurlPath,

        [int]$TimeoutSeconds = 8,

        [string]$TraceUrl = 'https://claude.ai/cdn-cgi/trace'
    )

    $trace = Invoke-TraceRequest -Config $Config -CurlPath $CurlPath -TimeoutSeconds $TimeoutSeconds -TraceUrl $TraceUrl
    $ip = Get-ExitIpFromTrace -Trace $trace
    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw 'Trace response did not contain a valid IP address.'
    }

    return $ip
}

function Write-GuardLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [int]$MaxBytes = 1048576,

        [int]$Keep = 2
    )

    if ($MaxBytes -lt 1) {
        throw 'MaxBytes must be greater than zero.'
    }
    if ($Keep -lt 1 -or $Keep -gt 9) {
        throw 'Keep must be between 1 and 9.'
    }

    $directory = Split-Path -Parent $LogPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    if (Test-Path -LiteralPath $LogPath -PathType Leaf -ErrorAction SilentlyContinue) {
        $length = (Get-Item -LiteralPath $LogPath).Length
        if ($length -gt $MaxBytes) {
            for ($index = $Keep; $index -ge 1; $index--) {
                $old = '{0}.{1}' -f $LogPath, $index
                if (Test-Path -LiteralPath $old -PathType Leaf -ErrorAction SilentlyContinue) {
                    if ($index -eq $Keep) {
                        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
                    } else {
                        Move-Item -LiteralPath $old -Destination ('{0}.{1}' -f $LogPath, ($index + 1)) -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.1') -Force -ErrorAction SilentlyContinue
        }
    }

    $line = '[{0}] [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message, [Environment]::NewLine
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($LogPath, $line, $encoding)
}

function Read-GuardConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw ('Configuration file was not found: {0}' -f $Path)
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Configuration is not valid JSON.'
    }

    foreach ($name in @('proxyType', 'proxyHost', 'proxyPort', 'expectedIp', 'claudePackageName', 'claudeExe', 'checkIntervalSeconds')) {
        if ($null -eq $config.PSObject.Properties[$name]) {
            throw ('Configuration is missing required field: {0}' -f $name)
        }
    }

    Test-GuardConfig -Config $config | Out-Null
    return $config
}

function Write-GuardConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Test-GuardConfig -Config $Config | Out-Null
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $json = $Config | ConvertTo-Json -Depth 5
    $temp = $Path + '.tmp'
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $json + [Environment]::NewLine, $encoding)
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-GuardDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [bool]$ProxyReachable,

        [AllowNull()]
        [string]$ExitIp,

        [int]$ConsecutiveTraceFailures = 0,

        [AllowNull()]
        [object[]]$Processes,

        [AllowNull()]
        [object[]]$Connections,

        [bool]$ConnectionQuerySucceeded = $true
    )

    Test-GuardConfig -Config $Config | Out-Null
    $reasons = New-Object System.Collections.Generic.List[string]
    $violations = @(Get-ClaudeProcessViolations -Processes $Processes -Config $Config)
    $publicConnections = @()
    if ($ConnectionQuerySucceeded) {
        $publicConnections = @(Get-PublicConnections -Connections $Connections)
    }

    if (-not $ProxyReachable) {
        $reasons.Add('Proxy port is unreachable.')
    } else {
        if ([string]::IsNullOrWhiteSpace($ExitIp)) {
            if (($ConsecutiveTraceFailures + 1) -ge 2) {
                $reasons.Add('Trace request failed twice in a row.')
            }
        } elseif ($ExitIp -ne [string]$Config.expectedIp) {
            $reasons.Add('Exit IP does not match the expected address.')
        }
    }

    foreach ($violation in $violations) {
        $reasons.Add($violation)
    }

    if ($publicConnections.Count -gt 0) {
        $reasons.Add('Claude has a public TCP connection outside the proxy.')
    }

    return [pscustomobject]@{
        Stop = ($reasons.Count -gt 0)
        Reasons = @($reasons)
        Violations = @($violations)
        PublicConnections = @($publicConnections)
    }
}

function New-InstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir,

        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [AllowNull()]
        [string]$ClaudeExe,

        [switch]$NoShortcuts
    )

    $configPath = Join-Path $InstallDir 'config.json'
    $modulePath = Join-Path $InstallDir 'src\ClaudeIPGuard.psm1'
    $launchScript = Join-Path $InstallDir 'src\launch.ps1'
    $guardScript = Join-Path $InstallDir 'src\guard.ps1'
    $launchVbs = Join-Path $InstallDir 'src\launch.vbs'
    $guardVbs = Join-Path $InstallDir 'src\guard.vbs'
    $logPath = Join-Path $InstallDir 'logs\guard.log'
    $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude (IP Guard).lnk'
    $startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude IP Guard'
    $startMenuShortcut = Join-Path $startMenuDir 'Claude (IP Guard).lnk'
    $startupEntry = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude IP Guard Monitor.vbs'

    $shortcuts = @()
    if (-not $NoShortcuts) {
        $target = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $shortcuts = @(
            [pscustomobject]@{ Path = $desktopShortcut; Target = $target; Arguments = ('"{0}"' -f $launchVbs); Description = 'Launch Claude through the guarded proxy' }
            [pscustomobject]@{ Path = $startMenuShortcut; Target = $target; Arguments = ('"{0}"' -f $launchVbs); Description = 'Launch Claude through the guarded proxy' }
        )
    }

    return [pscustomobject]@{
        InstallDir = $InstallDir
        SourceRoot = $SourceRoot
        ConfigPath = $configPath
        ModulePath = $modulePath
        LaunchScript = $launchScript
        GuardScript = $guardScript
        LaunchVbs = $launchVbs
        GuardVbs = $guardVbs
        LogPath = $logPath
        DesktopShortcut = $desktopShortcut
        StartMenuDir = $startMenuDir
        StartMenuShortcut = $startMenuShortcut
        StartupEntry = $startupEntry
        Shortcuts = @($shortcuts)
    }
}

function Get-ClaudeConnections {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Processes,

        [AllowNull()]
        [object[]]$Connections
    )

    if ($null -eq $Processes) {
        $Processes = @(Get-ClaudeProcesses)
    }
    if ($null -eq $Processes -or @($Processes).Count -eq 0) {
        return @()
    }

    $ids = @($Processes | ForEach-Object { [int]$_.ProcessId })
    if ($null -eq $Connections) {
        $Connections = @(Get-NetTCPConnection -ErrorAction Stop)
    }

    return @($Connections | Where-Object {
        $owner = 0
        [int]::TryParse([string]$_.OwningProcess, [ref]$owner) -and ($ids -contains $owner)
    })
}

function Stop-ClaudeProcesses {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Processes
    )

    if ($null -eq $Processes) {
        $Processes = @(Get-ClaudeProcesses)
    }

    $killed = New-Object System.Collections.Generic.List[int]
    foreach ($process in @($Processes)) {
        if ($null -eq $process) { continue }
        $id = 0
        if (-not [int]::TryParse([string]$process.ProcessId, [ref]$id) -or $id -le 0) { continue }
        try {
            Stop-Process -Id $id -Force -ErrorAction Stop
            $killed.Add($id)
        } catch {
            # The process may have exited between enumeration and shutdown.
        }
    }

    return @($killed)
}

Export-ModuleMember -Function @(
    'Test-GuardConfig'
    'New-GuardConfig'
    'Get-ProxyUrl'
    'Get-ClaudeLaunchArguments'
    'Get-ExitIpFromTrace'
    'Test-PublicAddress'
    'Get-ClaudeMainProcesses'
    'Get-ClaudeProcessViolations'
    'Get-PublicConnections'
    'Test-TcpPort'
    'Get-ClaudeProcesses'
    'Find-ClaudeExecutable'
    'Invoke-TraceRequest'
    'Get-CurrentExitIp'
    'Write-GuardLog'
    'Read-GuardConfig'
    'Write-GuardConfig'
    'Get-GuardDecision'
    'New-InstallPlan'
    'Get-ClaudeConnections'
    'Stop-ClaudeProcesses'
)
# Claude IP Guard — 设计文档

- 状态：已实现（v1.0.1，已通过 74 个 Pester 单元测试）
- 版本：1.0.1
- 日期：2026-11-17
- 目标平台：Windows 10/11 x64，Windows PowerShell 5.1
- 方案：B（轻量启动器 + 本地代理端口 + 目标出口 IP + 用户级监控）

## 1. 背景与目标

用户已经有一个本地 HTTP 或 SOCKS5 代理端口，并希望 Claude Desktop 固定通过该代理的某个出口 IP 访问网络：

1. 只让 Claude 使用这个本地代理和指定出口 IP。
2. 不允许 Claude 自行切换到其他线路或其他出口 IP。
3. 当代理不可用、出口 IP 不是指定值，或 Claude 没有走代理时，直接关闭 Claude。
4. 其他应用程序不受影响，仍然直连。
5. 不安装驱动、不修改 TUN、不修改系统代理、不需要管理员权限。
6. 做成可上传 GitHub 的通用工具，不包含任何个人、组织、代理服务商或真实网络信息。

## 2. 范围

### 2.1 v1 包含

- Claude Desktop for Windows（MSIX/AppX 安装版，也兼容部分独立安装版）。
- 通过桌面/开始菜单快捷方式启动 Claude，并附带本地代理参数。
- 用户级后台监控：登录后自动运行，定期检查代理、出口 IP 和 Claude 进程。
- 出口 IP 校验，使用与 Claude 相同的目标域名进行检测。
- 一键安装、测试、状态查看、卸载。
- 完整的 README、隐私说明、故障排查、Pester 测试和 GitHub Actions。

### 2.2 v1 不包含

- 不提供代理服务器，也不修改代理软件配置。
- 不修改 Windows 防火墙、TUN、路由表、系统代理或 hosts。
- 不拦截其他应用；其他应用仍然直连。
- 不提供内核驱动、Windows 服务或管理员级强制隔离。
- 不保证在用户手动禁用监控、结束监控进程或使用其他账户时仍然生效。
- Claude Code CLI 暂不在 v1 的强制保护范围内；README 会明确说明。

> 边界说明：用户如果从 Claude 原始图标启动，监控会在一个检查周期内发现“Claude 主进程没有代理参数”并关闭 Claude。但本工具不是内核级防火墙，不能阻止用户主动停用监控。

## 3. 用户体验

### 3.1 安装

用户下载仓库后双击 install.cmd，按提示输入：

1. 本地代理类型：HTTP（默认）或 SOCKS5。
2. 本地代理主机：默认 127.0.0.1；如果代理只监听 IPv6 回环，可选 ::1。
3. 本地代理端口：例如 1080（只允许本机回环地址）。
4. 目标出口 IPv4：例如 203.0.113.10（文档中的示例地址，不是真实地址）。

安装器会：

- 校验端口和 IP 格式。
- 安装前如果检测到另一份安装的监控正在运行，拒绝安装并提示先关闭它。
- 检查本地代理端口是否可连接。
- 通过该代理请求 Claude 的 trace 端点，确认实际出口 IP 与输入一致；不一致则拒绝安装，除非用户显式使用高级参数跳过。
- 把程序复制到当前用户的本地目录，写入配置文件。
- 创建桌面和开始菜单快捷方式。
- 在当前用户的启动文件夹放置监控启动器。
- 启动监控并做一次自检。

全程不需要管理员权限，不写入 Program Files、ProgramData 或 HKLM。

### 3.2 日常使用

- 双击“Claude (IP Guard)”快捷方式启动 Claude。
- 启动器先检查代理和出口 IP，再启动 Claude，并附带：
  - 代理参数（HTTP 或 SOCKS5）
  - 禁用 QUIC
  - 禁用非代理 UDP 的 WebRTC 策略
- 如果 Claude 已经在运行：
  - 如果现有实例已经是受保护实例，启动器确保监控运行后退出。
  - 如果存在未受保护实例，提示用户是否关闭并重启；用户确认后继续。
- 监控在后台每 3 秒检查一次；发现异常时关闭 Claude，并在本地日志记录原因。
- 桌面通知/弹窗只在启动器阶段使用；后台监控不弹窗，避免打扰。

### 3.3 查看状态

status.cmd 输出：

- 配置文件路径和关键配置摘要（代理、目标出口 IP、检查间隔）。
- 监控是否在运行。
- 本地代理端口是否可连接。
- 经代理访问 Claude trace 的当前出口 IP。
- 当前 Claude 主进程是否带代理参数。
- 最近几条监控日志。

test.cmd 只做检查，不启动 Claude、不修改配置，用于安装后验收和故障排查。

### 3.4 卸载

双击 uninstall.cmd：

- 停止当前用户的监控进程。
- 删除启动文件夹中的监控启动器。
- 删除桌面和开始菜单快捷方式。
- 可选删除配置和日志；默认保留日志目录并提示路径。
- 不删除 Claude 本身，不修改 Claude 的用户数据。

## 4. 架构

组件全部是纯 PowerShell 5.1 + VBScript 启动包装，无第三方运行时、无二进制文件、无管理员权限。

    ┌─────────────────────────────┐
    │ install.cmd / install.ps1   │
    │ 输入端口、出口 IP、校验      │
    └──────────────┬──────────────┘
                   │ 复制并写配置
                   v
    ┌─────────────────────────────┐
    │ %LOCALAPPDATA%\ClaudeIPGuard│
    │  config.json                │
    │  src\*.ps1 / *.vbs          │
    │  logs\guard.log             │
    └───────┬──────────────┬──────┘
            │              │
            v              v
    ┌──────────────┐  ┌─────────────────────┐
    │ launch.vbs   │  │ guard.vbs           │
    │ 隐藏启动     │  │ 登录启动、隐藏运行   │
    │ launch.ps1   │  │ guard.ps1           │
    └──────┬───────┘  └──────────┬──────────┘
           │                     │
           v                     v
    启动 Claude.exe        检查代理 / 出口 IP /
    --proxy-server=...     进程参数 / TCP 连接
           │                     │
           └──────────┬──────────┘
                      v
              异常时关闭 Claude

### 4.1 启动器

launch.ps1 流程：

1. 读取并校验 config.json；配置无效则弹出错误，不启动 Claude。如果检测到另一份安装的监控正在运行，也弹出错误并退出。
2. 检查本地代理端口是否可连接（TCP，使用配置中的 proxyHost（127.0.0.1 或 ::1），超时 1 秒）。
3. 通过代理请求 Claude trace（HTTPS，超时 8 秒），解析当前出口 IP；SOCKS5 使用 socks5h 让代理端做 DNS 解析（远端 DNS），本地不解析，而启动 Claude 的 --proxy-server 仍是 socks5://（Chromium 默认远端解析），二者行为一致且不泄漏本地 DNS。
4. 如果出口 IP 不等于目标 IP，弹出错误并退出；不启动 Claude。
5. 检查现有 Claude 进程：
   - 如果只有受保护主进程，直接退出。
   - 如果存在未受保护主进程，询问用户是否关闭并重启。
6. 确保监控已运行；没有则启动隐藏监控。
7. 解析 Claude 可执行文件路径（见 4.4）。
8. 启动 Claude：
   - HTTP：--proxy-server=http://127.0.0.1:<port>（proxyHost 为 ::1 时写成 http://[::1]:<port>）
   - SOCKS5：--proxy-server=socks5://127.0.0.1:<port>（proxyHost 为 ::1 时写成 socks5://[::1]:<port>）
   - 附加 --disable-quic
   - 附加 --webrtc-ip-handling-policy=disable_non_proxied_udp
9. 启动后最多等待 20 秒，每 500 毫秒轮询一次，直到 Claude 主进程出现且命令行违规数为 0；超时则关闭已启动的 Claude 并报错。

### 4.2 监控

guard.ps1 流程（默认每 3 秒）：

1. 获取固定名称的本地互斥锁 Local\ClaudeIPGuard-Monitor（同一登录会话内单实例；Local 命名空间按登录会话隔离）；获取失败说明已有监控在运行，记录警告后退出，避免两份不同配置互相杀 Claude。
2. 读取配置；配置无效时记录 ERROR、关闭 Claude，但监控循环继续（不会退出）。
3. 检查本地代理 TCP 端口；不可连接则关闭 Claude。
4. 通过代理请求 Claude trace；出口 IP 不等于目标值则立即关闭 Claude。
   - 连续 2 次 trace 请求失败也关闭 Claude，避免代理故障时 Claude 继续直连。
   - 只有连续成功且 IP 一致才视为安全。
   - 检查过程出现未处理异常时：单次异常记录 WARN 并继续，连续两次检查异常才关闭 Claude，成功一轮后计数清零。
5. 只枚举 Claude Desktop 进程（WindowsApps 的 Claude_*\app\Claude.exe、Programs\Claude\Claude.exe，或名称精确为 Claude.exe 的进程）：
   - 明确排除 %USERPROFILE%\.local\bin\claude.exe（Claude Code CLI）。
   - 找出主进程（命令行不包含 --type= 的进程）。
   - 没有主进程但存在 helper 子进程：给 5 秒宽限期，避免 Claude 正常退出时误报；超过宽限期仍只有 helper 则视为异常，关闭全部 Desktop Claude 进程。
   - 主进程必须恰好有一个 --proxy-server 且值与配置一致；缺失、重复或值错误都视为违规。出现 --no-proxy-server、--proxy-bypass-list、--proxy-pac-url、--proxy-auto-detect 也视为违规，关闭全部 Desktop Claude 进程。
6. TCP 连接审计：
   - 对 Claude 进程的所有 TCP 连接，若远端是公网地址（非 127/8、10/8、172.16/12、192.168/16、169.254/16、100.64/10、0/8、::1、::、fc00::/7、fe80::/10；IPv4 映射的 IPv6 地址按 IPv4 判断），视为绕过代理，关闭 Claude。
   - 其余地址（包括保留段）按公网处理（fail-closed），宁可误关也不放过意外的直连。
   - 如果查询连接失败（权限/系统限制），只记录警告，不单独因此关闭；出口 IP 和命令行检查仍然是强制的。
7. 写日志；超过 1 MB 轮转，保留当前日志和 1 个旧文件。
8. 睡眠配置的检查间隔（默认 3 秒），重复。

所有日志都通过安全写入函数（Write-GuardLogSafe）记录；日志写入失败会被忽略，不会让监控退出。

### 4.3 关闭策略

- 只关闭 Claude Desktop 进程，不关闭 Claude Code CLI，也不关闭其他应用。
- 关闭使用当前用户权限即可，不需要管理员。
- 关闭前记录原因和进程 ID，方便排查。
- 不做“优雅退出”等待，避免 Claude 在关闭前继续联网；这可能丢失未发送的输入，README 会提示。

### 4.4 Claude 路径发现

优先级：

1. 配置文件中的可选 claudeExe（绝对路径）。
2. Get-AppxPackage -Name Claude 返回的 InstallLocation 下的 app\Claude.exe（大小写不敏感）。
3. 安装目录下递归查找 Claude.exe。
4. 常见独立安装位置（%LOCALAPPDATA%、%ProgramFiles%）下的 Claude.exe。

找不到时：

- 启动器弹出错误，提示用户在配置中填写 claudeExe。
- 不自动下载或修改 Claude。

### 4.5 配置

安装目录：%LOCALAPPDATA%\ClaudeIPGuard
配置文件：%LOCALAPPDATA%\ClaudeIPGuard\config.json

    {
      "proxyType": "http",
      "proxyHost": "127.0.0.1",
      "proxyPort": 1080,
      "expectedIp": "203.0.113.10",
      "claudePackageName": "Claude",
      "claudeExe": "",
      "checkIntervalSeconds": 3
    }

约束：

- proxyType：http 或 socks5。
- proxyHost：只允许 127.0.0.1 或 ::1，避免把流量发到局域网/公网。
- proxyPort：1–65535。
- expectedIp：合法 IPv4 地址；本版本不做 IPv6 出口校验。
- checkIntervalSeconds：1–30，默认 3。
- 配置中不保存代理用户名/密码；本地代理必须无需认证。
- 出口 IP 不一致时始终关闭 Claude，不提供关闭该行为的配置项。

### 4.6 检测端点

使用 https://claude.ai/cdn-cgi/trace，解析响应中的 ip= 行。

原因：

- 与 Claude 实际访问的域名一致，能反映 Claude 看到的出口。
- 不依赖第三方 IP 查询服务。
- 响应小，适合高频检查。

如果该端点不可达，按失败处理；不会退回直连检测。

## 5. 安装与卸载

### 5.1 安装器参数

install.ps1 支持：

- -ProxyType http|socks5
- -ProxyHost <127.0.0.1|::1>（默认 127.0.0.1；代理只监听 IPv6 回环时用 ::1）
- -ProxyPort <int>
- -ExpectedIp <ipv4>
- -InstallDir <path>（默认 %LOCALAPPDATA%\ClaudeIPGuard）
- -NoShortcuts（测试/便携使用）
- -SkipProxyCheck（高级；跳过安装时出口校验）
- -DryRun（只打印计划，不写文件）
- -Force（覆盖已有安装）

交互模式：未提供必需参数时逐项询问，默认值只用于端口类型和检查间隔，不预设任何真实 IP。

### 5.2 创建的文件

安装目录：

    ClaudeIPGuard\
      config.json
      install.json
      src\
        ClaudeIPGuard.psm1
        launch.ps1
        guard.ps1
        launch.vbs
        guard.vbs
      status.ps1
      test.ps1
      uninstall.ps1
      logs\
        guard.log

用户目录：

    Desktop\Claude (IP Guard).lnk
    Start Menu\Programs\Claude IP Guard\Claude (IP Guard).lnk
    Start Menu\Programs\Claude IP Guard\Status.lnk
    Start Menu\Programs\Claude IP Guard\Uninstall.lnk
    Startup\Claude IP Guard Monitor.vbs

所有路径都在当前用户范围内；不需要管理员。

### 5.3 快捷方式

- 启动快捷方式目标：%SystemRoot%\System32\wscript.exe，参数："<install>\src\launch.vbs"。
- 图标：如果找到 Claude 可执行文件，使用其图标；否则使用系统默认图标。
- 启动文件夹中的 Claude IP Guard Monitor.vbs 直接由系统登录时执行；脚本自身隐藏启动 guard.ps1。
- 启动项 VBS 以 UTF-16LE BOM 写入：cscript 默认按 ANSI 读取，路径含中文用户名时需要 BOM 才能正确解析。
- 卸载时只删除本工具创建的快捷方式，通过文件名和安装目录匹配，不删除其他 Claude 快捷方式。

### 5.4 卸载器

uninstall.ps1：

1. 找到并停止本工具的 guard.ps1 进程（通过命令行包含安装目录匹配）。
2. 删除启动文件夹中的监控 VBS。
3. 删除桌面和开始菜单中的本工具快捷方式。
4. 可选删除安装目录；默认保留日志，提示用户路径。
5. 不删除 Claude，不修改 Claude 数据，不修改系统网络设置。

进程命令行和快捷方式内容都做字面路径匹配：目录末尾带路径分隔符，比较时大小写不敏感，不使用通配符；这样安装目录含 [ ] * ? 时不会失效，也不会误删 ClaudeIPGuard2 这类同前缀目录的文件。

## 6. 安全、隐私与失败模式

### 6.1 安全

- 只接受回环地址作为代理主机，避免凭据/流量被发到局域网。
- 安装时和运行时都校验出口 IP。
- 出口 IP 检测对 SOCKS5 使用 socks5h 让代理端做远端 DNS 解析，避免本地 DNS 泄漏或被污染导致误杀；启动 Claude 的参数仍是 socks5://（由 Chromium 远端解析），二者行为一致。
- 启动参数包含 --disable-quic 和 --webrtc-ip-handling-policy=disable_non_proxied_udp，减少 UDP/WebRTC 绕过。
- 监控检查主进程参数和公网 TCP 连接；异常即关闭 Claude。
- 不使用 Invoke-Expression 执行外部输入；配置只按 JSON 读取和类型校验。
- 不下载或执行远程代码；仓库即全部代码。
- 不需要管理员权限，减少攻击面。

### 6.2 隐私

- 不收集遥测，不上传日志，不访问除 Claude trace 之外的检测端点。
- 日志只保存在本机，包含时间、事件、进程 ID、出口 IP，不做脱敏；公开分享日志前需要自行删除其中的 IP、路径等信息。
- 仓库不包含任何真实 IP、用户名、主机名、代理服务商、订阅地址或令牌。
- README 中的示例使用保留地址（如 203.0.113.10）和通用端口（如 1080）。

### 6.3 失败模式

| 情况 | 行为 |
|---|---|
| 代理端口未监听 | 启动器拒绝启动；监控关闭 Claude |
| 出口 IP 不等于目标 | 启动器拒绝启动；监控立即关闭 Claude |
| 连续 2 次 trace 请求失败 | 监控关闭 Claude |
| Claude 主进程无代理参数 | 监控关闭 Claude |
| Claude 主进程有重复或旁路代理参数 | 监控关闭 Claude |
| Claude 有公网 TCP 直连 | 监控关闭 Claude |
| 监控内部检查异常 | 单次记录 WARN 并继续；连续两次检查异常才关闭 Claude，成功一轮后清零 |
| 日志写入失败 | 忽略，不影响监控循环 |
| 另一安装的监控已在运行 | 启动器/安装器拒绝启动并提示；重复启动的监控自身记录警告后退出 |
| 监控未运行 | 保护失效；启动器会尝试启动；README 说明边界 |
| Claude 更新导致路径变化 | 启动器重新发现；失败时提示配置 claudeExe |
| 用户从原始图标启动 | 监控在 3 秒内关闭未受保护实例 |
| 配置损坏 | 监控记录 ERROR 并关闭 Claude，随后按周期重试，不退出；启动器拒绝启动 |

## 7. 文件结构（GitHub 仓库）

    claude-ip-guard/
      README.md
      LICENSE
      CHANGELOG.md
      SECURITY.md
      .gitignore
      install.cmd
      install.ps1
      uninstall.cmd
      uninstall.ps1
      status.ps1
      test.ps1
      status.cmd
      test.cmd
      src/
        ClaudeIPGuard.psm1
        launch.ps1
        guard.ps1
        launch.vbs
        guard.vbs
      docs/
        DESIGN.md
        TROUBLESHOOTING.md
        PRIVACY.md
      tests/
        ClaudeIPGuard.Tests.ps1
      .github/
        workflows/
          test.yml

说明：

- src/ClaudeIPGuard.psm1 放置可测试的纯函数和进程/网络检查函数。
- launch.ps1、guard.ps1 只做编排，便于测试。
- tests/ 下只有 ClaudeIPGuard.Tests.ps1，测试使用桩程序与假进程对象，不需要 fixture 文件。
- .cmd 文件是双击入口，内部使用 powershell -NoProfile -ExecutionPolicy Bypass -File。
- 不包含二进制、驱动、Mihomo 配置或任何特定代理软件配置。

## 8. 测试计划

### 8.1 单元测试（Pester 5）

覆盖：

- 配置读取：合法、缺字段、端口越界、IP 非法、代理主机非回环、expectedIp 规范化。
- 代理 URL 构造：HTTP/SOCKS5、::1 主机、SOCKS5 远端 DNS（socks5h）。
- 启动参数：正确端口、错误端口、缺失参数、带引号参数。
- 命令行检查：重复 --proxy-server，以及 --no-proxy-server、--proxy-bypass-list、--proxy-pac-url、--proxy-auto-detect 等旁路参数。
- 主进程识别：主进程、Electron 子进程、只有子进程。
- TCP 连接分类：回环、私网、公网、查询失败、IPv6 回环与私网。
- 出口 IP 解析：正常 ip=、空响应、HTML 错误页。
- 关闭决策：IP 不一致、连续失败、配置损坏、未受保护。
- 日志：轮转保留 1 份旧文件、安全写入忽略写入失败。
- 路径与进程识别：字面路径匹配、监控进程识别。
- TCP 端口检查：IPv4 与 IPv6 回环监听。
- 快捷方式/安装计划：-DryRun 不写文件，路径在用户目录内。

测试使用桩程序与假进程对象，不访问真实网络、不启动真实 Claude、不修改系统。当前共 74 个测试。另有两个静态测试检查 guard.ps1 的失败安全不变式（放弃的互斥锁按已获取处理、检查异常计数只在完整成功一轮后清零）。

### 8.2 集成测试（手动）

1. 使用一个可用的本地代理端口和目标 IP 安装。
2. 双击快捷方式，确认 Claude 启动且主进程带 --proxy-server。
3. 从任务管理器确认 Claude 的连接都指向 127.0.0.1:<port>。
4. 用 status.cmd 确认出口 IP。
5. 从原始 Claude 图标启动，确认 3 秒内被关闭。
6. 暂时停止本地代理，确认 Claude 被关闭。
7. 把代理切换到错误出口，确认 Claude 被关闭。
8. 恢复代理，重新用快捷方式启动，确认恢复。
9. 注销/重启，确认监控自动运行。
10. 卸载，确认快捷方式、启动项和监控消失，Claude 本身不受影响。

### 8.3 CI

GitHub Actions windows-latest：

- 用 pwsh 安装 Pester 5（两种 shell 共享 CurrentUser 模块路径）。
- 测试步骤通过 matrix（fail-fast: false，matrix.shell 为 powershell / pwsh）分别在 Windows PowerShell 5.1 和 PowerShell 7 下运行 Invoke-Pester -Path ./tests -PassThru -Output Detailed，并检查 FailedCount。

## 9. 决策记录

1. 选择 B 而不是 TUN/服务：用户明确选择 B，且要求无需管理员；B 只影响通过启动器启动的 Claude，不改变全局网络。
2. 选择 --proxy-server 而不是系统代理/PAC：此前验证 PAC 对 Claude 无效，Chromium 代理参数可靠。
3. 选择“杀进程”而不是仅告警：用户要求“直接拦截”；关闭是唯一无需管理员且确定性的手段。
4. 选择 Claude trace 作为检测端点：与 Claude 实际访问路径一致，避免第三方检测端点造成误判。
5. 选择用户级启动文件夹而不是计划任务：无需管理员，安装/卸载简单；代价是用户可在任务管理器禁用。
6. 不内置代理软件：保持通用、可审计、无供应商绑定；用户已有本地代理端口。
7. v1 不覆盖 Claude Code：Claude Code 通过环境变量代理，缺少可靠的进程级参数标记；先保证 Desktop，避免给出虚假的安全承诺。
8. 监控内部错误与日志写入采用分级处理：单次检查异常只警告，连续两次才关闭 Claude；日志写入失败被忽略。既不静默退出（fail-open），也不因单次抖动误杀。
9. 监控使用 Local 命名空间下固定名称的互斥锁，保证同一登录会话同一时刻只有一个监控，避免两份不同配置的监控互相杀 Claude。
10. 出口 IP 检测对 SOCKS5 使用 socks5h（远端 DNS），避免本地 DNS 泄漏和污染导致的误判；启动 Claude 仍用 socks5://。

## 10. 限制与风险

- 不是内核级防火墙；用户主动停用监控后无法强制。
- 从原始图标启动有最多约 3 秒窗口；期间可能产生少量直连流量。
- 代理必须支持 HTTP CONNECT 或 SOCKS5，且无需认证。
- 代理主机可以是 ::1，但只校验 IPv4 出口。
- 同一登录会话同一时刻只支持一个监控实例；同一会话内两份不同安装不能同时运行（不同登录会话互不影响）。
- 关闭 Claude 可能导致未发送的输入丢失。
- 如果本地代理端口被其他程序占用/替换，插件只能通过出口 IP 发现异常，不能验证代理软件本身。
- Claude 更新可能改变可执行文件路径或参数行为；启动器会重新发现，但需要时更新插件。

## 11. 实施顺序

1. 搭建仓库骨架、LICENSE、README 初稿。
2. 实现 ClaudeIPGuard.psm1 的配置/网络/进程函数。
3. 实现 launch.ps1、guard.ps1 和 VBS 包装。
4. 实现 install.ps1、uninstall.ps1、status.ps1、test.ps1。
5. 写 Pester 测试并跑通。
6. 在本机用临时端口/测试值做无管理员安装、启动、监控、卸载验证；不写入任何真实值到仓库。
7. 完善 README、故障排查、隐私说明、GitHub Actions。
8. git init + 初始提交，交付可上传的仓库目录。

## 12. 验收标准

- 双击安装器，输入端口和目标 IP，全程无 UAC。
- 桌面/开始菜单出现启动快捷方式，启动文件夹出现监控项。
- 通过快捷方式启动 Claude，主进程命令行包含正确的代理参数。
- status.cmd 显示代理可用、出口 IP 等于目标值、监控运行中。
- 原始图标启动的 Claude 在 3 秒内被关闭。
- 代理停止或出口 IP 改变时，Claude 被关闭。
- 卸载后快捷方式、启动项、监控进程消失，Claude 仍可正常使用。
- 仓库中不存在任何真实 IP、用户名、代理服务商、订阅地址或令牌。
- Pester 测试在本地和 GitHub Actions 通过。

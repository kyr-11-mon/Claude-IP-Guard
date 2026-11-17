# Claude IP Guard

让 **Claude Desktop** 只通过你指定的本地代理端口访问网络，并在出口 IP 不符合预期时自动关闭 Claude 的 Windows 小工具。

> 这是一个用户级启动器 + 监控工具，不是 VPN、TUN、防火墙或内核驱动。它保护的是“通过本工具启动的 Claude Desktop”，不是整台电脑，也不能阻止有管理员权限的程序绕过。

## 它解决什么问题

很多人需要让 Claude 固定从某个地区的出口 IP 访问，但又不希望把整台电脑的流量都切到代理，或者担心代理客户端切换节点后 Claude 悄悄走了另一个 IP。

Claude IP Guard 的做法是：

1. 启动 Claude 时强制加上本地代理参数；
2. 在后台定期检查代理端口、真实出口 IP、Claude 进程参数和公网直连；
3. 任一项不符合预期时，直接关闭 Claude，避免继续使用错误线路。

其他应用不受影响，不需要安装驱动、服务或修改系统代理。

## 工作方式

- **启动器**：读取配置，检查本地代理端口和目标出口 IP，然后用
  `--proxy-server=<本地代理>`、`--disable-quic`、`--webrtc-ip-handling-policy=disable_non_proxied_udp`
  启动 Claude Desktop。
- **监控**：默认每 3 秒检查一次：
  - 本地代理端口是否可连接；
  - 通过代理访问 `https://claude.ai/cdn-cgi/trace` 得到的出口 IP 是否等于配置值；
  - Claude Desktop 主进程是否仍带正确的代理参数；
  - Claude 是否出现公网 TCP 直连。
- **失败处理**：代理不可用、IP 不符、进程参数缺失或出现公网直连时，立即结束 Claude Desktop 进程。连续两次无法取得出口 IP 也会结束 Claude。
- **单实例**：监控使用本地互斥锁，重复启动不会产生多个监控进程。

## 系统要求

- Windows 10 / 11 x64
- Windows PowerShell 5.1（系统自带）
- Claude Desktop（Microsoft Store / MSIX 安装，或独立安装）
- 一个本地 HTTP 或 SOCKS5 代理端口，例如 `127.0.0.1:1080`
- 代理不需要用户名密码（v1 不支持代理认证）
- 一个已知的目标出口 IPv4 地址

## 快速开始

### 1. 准备代理

先启动你自己的代理客户端，确认它提供本地 HTTP 或 SOCKS5 端口，并确认当前节点出口 IP。

例如用 curl 检查（把端口和地址换成你自己的）：

```powershell
curl.exe --proxy http://127.0.0.1:1080 https://claude.ai/cdn-cgi/trace
```

输出中应包含：

```text
ip=203.0.113.10
```

这里的 `203.0.113.10` 只是文档示例地址，请替换成你实际的目标 IPv4。

### 2. 安装

解压仓库后，双击 `install.cmd`，按提示输入本地代理端口和目标出口 IPv4。

也可以从 PowerShell 运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -ProxyType http `
  -ProxyPort 1080 `
  -ExpectedIp 203.0.113.10
```

安装器会：

- 检查代理端口和目标出口 IP；
- 把程序安装到 `%LOCALAPPDATA%\ClaudeIPGuard`；
- 写入 `config.json`；
- 创建桌面快捷方式 **Claude (IP Guard)**；
- 创建开始菜单里的 Status / Uninstall 快捷方式；
- 注册登录启动的监控项，并立即启动监控。

全程不需要管理员权限。

### 3. 使用

以后请从桌面的 **Claude (IP Guard)** 快捷方式启动 Claude。

如果直接从原始 Claude 图标启动，监控会在下一个检查周期内关闭这个未受保护的实例；这是有意的 fail-closed 行为，但可能造成最多约一个检查间隔的窗口。

## 安装选项

| 参数 | 说明 |
| --- | --- |
| `-ProxyType http\|socks5` | 本地代理类型，默认 `http` |
| `-ProxyPort <1-65535>` | 本地代理端口；省略时交互输入 |
| `-ExpectedIp <IPv4>` | 目标出口 IPv4；省略时交互输入 |
| `-ClaudeExe <path>` | 手动指定 Claude Desktop 的 `Claude.exe`；默认自动查找 |
| `-InstallDir <path>` | 自定义安装目录，默认 `%LOCALAPPDATA%\ClaudeIPGuard` |
| `-NoShortcuts` | 便携模式：不创建快捷方式、不写登录启动项、不自动启动监控 |
| `-SkipProxyCheck` | 跳过安装时的代理/IP 检查，不推荐 |
| `-DryRun` | 只打印安装计划，不写文件 |
| `-Force` | 覆盖已有安装 |

示例：安装到自定义目录，手动指定 Claude 路径：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -ProxyPort 1080 `
  -ExpectedIp 203.0.113.10 `
  -ClaudeExe "C:\Program Files\WindowsApps\Claude_1.0.0.0_x64__example\app\Claude.exe" `
  -InstallDir "D:\Tools\ClaudeIPGuard"
```

## 配置

安装后配置位于：

```text
%LOCALAPPDATA%\ClaudeIPGuard\config.json
```

示例：

```json
{
  "proxyType": "http",
  "proxyHost": "127.0.0.1",
  "proxyPort": 1080,
  "expectedIp": "203.0.113.10",
  "claudePackageName": "Claude",
  "claudeExe": "",
  "checkIntervalSeconds": 3
}
```

| 字段 | 说明 |
| --- | --- |
| `proxyType` | `http` 或 `socks5` |
| `proxyHost` | 只允许 `127.0.0.1` 或 `::1` |
| `proxyPort` | 1–65535 |
| `expectedIp` | 必须是 IPv4 地址 |
| `claudePackageName` | Claude 的 Appx 包名，默认 `Claude` |
| `claudeExe` | 可选，手动指定 `Claude.exe` 完整路径 |
| `checkIntervalSeconds` | 检查间隔，1–30 秒，默认 3 |

修改配置后，重启监控和 Claude 才会使用新值。监控每次循环都会重新读取配置；配置损坏时会关闭 Claude。

## 日常命令

安装目录下提供：

```text
status.cmd    查看配置、监控、端口、出口 IP、Claude 状态和最近日志
test.cmd      只做检查，全部通过返回 0，否则返回 1
install.cmd   安装/覆盖安装
uninstall.cmd 卸载
```

也可以直接运行 PowerShell 脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeIPGuard\status.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeIPGuard\test.ps1"
```

日志在：

```text
%LOCALAPPDATA%\ClaudeIPGuard\logs\guard.log
```

日志超过 1 MB 会轮转为 `guard.log.1`，最多保留 1 份旧日志。

## 限制与安全边界

- **仅保护 Claude Desktop。** 明确排除 `%USERPROFILE%\.local\bin\claude.exe`（Claude Code CLI）；Claude Code 的网络请求不在本工具保护范围内。
- **只保护通过启动器启动的 Claude。** 原始快捷方式不会被劫持；从原始图标启动的实例会在监控周期内被关闭。
- **直接结束进程。** 失败时不会优雅退出，可能丢失未发送的输入。
- **不是内核级拦截。** 它通过进程参数、出口 IP 和 TCP 连接检查来发现异常；有管理员权限的恶意程序、被篡改的 Claude、或代理提供方自身的行为不在防护范围内。
- **只有 IPv4。** `expectedIp` 必须是 IPv4；IPv6 出口不在校验范围内。
- **代理必须无认证。** v1 不支持用户名/密码；代理端口应只监听回环地址，不要暴露到局域网。
- **最多一个检查间隔的窗口。** 默认 3 秒；从原始图标启动、代理切换节点到监控发现异常之间，可能存在短暂窗口。
- **其他应用不受影响。** 这是设计目标，也意味着本工具不是全局 VPN。
- **Claude 更新可能改变路径。** 启动器每次都会重新查找；如果自动查找失败，用 `-ClaudeExe` 指定新路径并重新安装。
- **不安装驱动、服务、TUN，不修改系统代理，不收集遥测。**

## 故障排查

见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

常见检查：

```powershell
# 代理端口是否可连
Test-NetConnection 127.0.0.1 -Port 1080

# 代理出口 IP
curl.exe --proxy http://127.0.0.1:1080 https://claude.ai/cdn-cgi/trace

# 本工具状态
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeIPGuard\status.ps1"
```

## 卸载

双击开始菜单里的 **Uninstall**，或运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeIPGuard\uninstall.ps1"
```

默认保留日志；加 `-RemoveData` 删除整个安装目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeIPGuard\uninstall.ps1" -RemoveData
```

卸载只删除本工具创建的快捷方式、启动项和安装目录，不会修改 Claude 的数据或你的代理软件。

## 开发与测试

需要 PowerShell 5.1 和 Pester 5：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
```

当前 55 个 Pester 测试，覆盖配置校验、代理 URL、启动参数、trace 解析、公网地址判断、进程识别、违规判断、连接过滤、日志轮转、安装计划等。测试不访问真实网络，不启动真实 Claude。

设计文档见 [docs/DESIGN.md](docs/DESIGN.md)。

## 隐私

本工具不发送遥测，不收集账号信息。它只通过你配置的本地代理访问 `https://claude.ai/cdn-cgi/trace` 来确认出口 IP，日志保存在本机。详见 [docs/PRIVACY.md](docs/PRIVACY.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。

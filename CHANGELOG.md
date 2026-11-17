# Changelog

All notable changes to this project are documented here.

## 1.0.1 - 2026-11-17

### Fixed

- `-ProxyHost ::1` now works end to end: the launcher's TCP check uses the
  configured proxy host instead of an IPv4-only client.
- Log rotation keeps one old file (`guard.log.1`) at 1 MB, matching the
  documentation.
- The monitor no longer exits silently on a failed log write or an unhandled
  check error: log write failures are ignored, a single check error logs a
  warning, and only two consecutive check errors close Claude. The error streak
  is only cleared after a fully successful check, so a monitor that fails on
  every cycle now stops Claude instead of warning forever. An invalid
  configuration closes Claude but keeps the monitor loop running.
- Path matching is literal, with a trailing separator and case-insensitive
  comparison, instead of wildcard-based. Install paths containing `[ ] * ?`
  work again and `ClaudeIPGuard2` no longer collides with `ClaudeIPGuard`.
- SOCKS5 exit-IP detection uses `socks5h` so the proxy resolves DNS remotely.
- `config.json` is read as UTF-8 instead of the system ANSI code page.

### Changed

- Claude process validation rejects a duplicate `--proxy-server` argument and
  the bypass switches `--no-proxy-server`, `--proxy-bypass-list`,
  `--proxy-pac-url`, and `--proxy-auto-detect`.
- A helper process that survives Claude for less than 5 seconds is ignored
  instead of being treated as an unprotected Claude instance.
- The launcher accepts the start only after polling every 500 ms for up to 20
  seconds for the Claude process with valid proxy arguments.
- `expectedIp` is normalized (for example, `127.1` becomes `127.0.0.1`).
- The login monitor entry is written as UTF-16LE with a BOM so `cscript` reads
  paths containing non-ASCII user names correctly.
- A fixed-name mutex (`Local\ClaudeIPGuard-Monitor`) enforces a single
  monitor; the launcher and installer refuse to start when another
  installation's monitor is running.
- `-ProxyHost` is the last installer parameter, so existing positional
  `install.ps1` invocations keep binding `-ExpectedIp` as the third argument.
- CI runs Pester under both Windows PowerShell 5.1 and PowerShell 7; the suite
  now has 74 tests.

## 1.0.0 - 2026-11-17

### Added

- Launcher that starts Claude Desktop with a fixed local HTTP/SOCKS5 proxy,
  disabled QUIC, and non-proxied UDP WebRTC handling.
- User-level background monitor that checks the proxy port, real exit IPv4 via
  `https://claude.ai/cdn-cgi/trace`, Claude process arguments, and public direct
  TCP connections.
- Fail-closed behavior: stop Claude when the proxy is unreachable, the exit IP
  differs, the proxy argument is missing, or a public direct connection appears.
- Desktop and Start Menu shortcuts, login-time monitor startup, status/test/
  uninstall scripts, and a portable `-NoShortcuts` mode.
- Configurable install directory, check interval, Claude package name, and
  optional explicit `Claude.exe` path.
- Pester unit tests for configuration, launch arguments, trace parsing, process
  filtering, connection filtering, logging, and install planning.

### Security

- The monitor only binds to a local proxy port and never opens a listening
  socket of its own.
- Configuration rejects non-loopback proxy hosts and non-IPv4 expected
  addresses.
- The tool does not install a service, driver, TUN adapter, firewall rule, or
  system proxy.

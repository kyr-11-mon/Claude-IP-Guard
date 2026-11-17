# Changelog

All notable changes to this project are documented here.

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

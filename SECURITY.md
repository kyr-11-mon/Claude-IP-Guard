# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.x | Yes |

## Reporting a vulnerability

Please do not open a public issue for a vulnerability that could let Claude
bypass the guard or expose local data.

Use GitHub's private vulnerability reporting for this repository (Security tab
-> Report a vulnerability). If that is unavailable, open a minimal public issue
asking for a private contact channel without including exploit details.

Please include:

- affected version;
- Windows version;
- reproduction steps;
- expected and observed behavior;
- relevant log lines with secrets removed.

## Threat model

Claude IP Guard is a **user-level convenience and safety tool**, not a security
boundary against an administrator or a compromised operating system.

It is designed to catch:

- Claude started without the required proxy argument;
- a proxy that is down or no longer exits through the expected IP;
- a proxy client that switched to a different node;
- direct public TCP connections from Claude.

It is not designed to stop:

- a user or administrator who edits the configuration, stops the monitor, or
  launches a modified Claude binary;
- malware with the same or higher privileges;
- a malicious or compromised proxy provider;
- traffic that never appears as a TCP connection visible to the current user;
- IPv6-only paths, because the expected address is IPv4.

## Secrets

The tool stores no proxy username or password. The proxy must be unauthenticated
and should listen on loopback only. Do not expose the local proxy port to a
LAN or the public internet.

Logs are stored locally under the install directory and may contain process IDs,
file paths, and error messages. Review them before sharing.

## Dependency and update notes

The tool uses Windows PowerShell 5.1 and built-in Windows components. It does not
bundle a proxy, VPN, driver, or network stack. Claude Desktop updates can change
its executable path; reinstall with `-ClaudeExe` if automatic discovery fails.

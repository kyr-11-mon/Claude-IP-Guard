# Privacy

## Summary

Claude IP Guard runs locally. It has no telemetry, no analytics, no account
system, and no update checker.

## What is stored locally

| Data | Location | Purpose |
| --- | --- | --- |
| Configuration | `%LOCALAPPDATA%\ClaudeIPGuard\config.json` | Proxy port, expected IPv4, Claude package/path, check interval |
| Install metadata | `%LOCALAPPDATA%\ClaudeIPGuard\install.json` | Version and install time |
| Logs | `%LOCALAPPDATA%\ClaudeIPGuard\logs\guard.log` | Monitor decisions and errors |

Logs can contain process names, process IDs, executable paths, and error
messages. They do not contain Claude conversation content, proxy credentials, or
browsing history. Logs rotate at 1 MB and keep one old file.

## Network access

The only request the tool makes on its own is:

```text
https://claude.ai/cdn-cgi/trace
```

It is sent **through your configured local proxy** to read the exit IP. For
SOCKS5 proxies the check uses `socks5h`, so the proxy resolves the `claude.ai`
DNS name remotely and the tool does not perform a local DNS lookup for it. The
launcher and monitor do not contact any other server.

Your proxy provider and Anthropic still see Claude's normal traffic, exactly as
they would without this tool. Their handling of that traffic is governed by
their own policies.

## What is not collected

- No telemetry or crash reports.
- No Claude account, conversation, prompt, or file content.
- No proxy username or password.
- No hostname or username sent anywhere.

## Retention and removal

Logs stay on the local disk until you delete them. `uninstall.ps1` keeps logs by
default; use `-RemoveData` to remove the whole install directory.

## Contact

For privacy questions, open a GitHub issue that does not contain personal data,
or use the repository's private security reporting channel for sensitive
reports.

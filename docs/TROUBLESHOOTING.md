# Troubleshooting

## First checks

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeIPGuard\status.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeIPGuard\test.ps1"
```

Then read the last lines of:

```text
%LOCALAPPDATA%\ClaudeIPGuard\logs\guard.log
```

Most failures fall into one of these groups:

- the proxy port is not reachable;
- the proxy exits through a different IP;
- Claude is not running with the expected proxy argument;
- the monitor is not running;
- Claude Desktop cannot be found.

## "The local proxy port is not accepting connections"

1. Start your proxy client.
2. Confirm the HTTP or SOCKS5 port. Do not use the proxy client's controller
   port or a TUN-only port.
3. Test it:

   ```powershell
   Test-NetConnection 127.0.0.1 -Port 1080
   ```

4. If the port is open but requires a username/password, this version cannot use
   it. Configure an unauthenticated local port, bound to `127.0.0.1`.
5. If the port is only listening on another interface, change the proxy client
   to listen on loopback.

## "The proxy exit IP is ... not the requested ..."

The installer and monitor use:

```text
https://claude.ai/cdn-cgi/trace
```

through your proxy. Check it manually:

```powershell
curl.exe --proxy http://127.0.0.1:1080 https://claude.ai/cdn-cgi/trace
```

- If the output has no `ip=` line, the proxy is not passing HTTPS or is
  returning an error page.
- If `ip=` is a different address, your proxy client is on another node or is
  using a different route. Switch to the intended node and retry.
- If the address is IPv6, this version cannot validate it. Use a proxy/node
  that exits through IPv4.
- If you intentionally want to install before the proxy is ready, use
  `-SkipProxyCheck`, but Claude will be closed at launch until the check passes.

Do not edit `expectedIp` to match a random node. The point of the tool is to
fail closed when the route changes.

## Claude starts and immediately closes

This is expected fail-closed behavior. Check the log; the monitor records a
reason such as:

- proxy port unreachable;
- exit IP mismatch;
- Claude process is missing `--proxy-server`;
- Claude opened a public direct TCP connection;
- configuration is invalid.

Fix the underlying condition, then start Claude again from **Claude (IP Guard)**.

If the log says `Claude process is missing --proxy-server`, make sure you did not
start the original Claude shortcut. Only the guarded shortcut adds the required
argument.

## Claude starts but pages do not load

- Confirm the proxy supports HTTP `CONNECT` (for `http`) or SOCKS5 (for
  `socks5`).
- Test the same URL with curl through the proxy.
- Some proxy clients expose a mixed HTTP/SOCKS port; try the matching
  `-ProxyType`.
- The launcher disables QUIC, so a proxy that only handles UDP will not work.
- Check whether the proxy requires authentication; v1 does not support it.

## "Monitor running: False"

Start it manually:

```powershell
wscript.exe "$env:LOCALAPPDATA\ClaudeIPGuard\src\guard.vbs"
```

If it exits immediately:

1. Run the script in a visible PowerShell window to see the error:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeIPGuard\src\guard.ps1"
   ```

2. Check that `config.json` exists and is valid JSON.
3. Check the execution policy:

   ```powershell
   Get-ExecutionPolicy -List
   ```

   The shortcuts already pass `-ExecutionPolicy Bypass`. If you launch the
   `.ps1` manually, use the same flag.

The login entry is:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Claude IP Guard Monitor.vbs
```

If it is missing, rerun `install.cmd` without `-NoShortcuts`.

## Claude Desktop cannot be found

The launcher looks for:

1. `claudeExe` in `config.json`;
2. the Appx package install location (`Claude_*\app\Claude.exe`);
3. common folders under `%LOCALAPPDATA%\Programs\Claude`,
   `%LOCALAPPDATA%\Claude`, `%ProgramFiles%\Claude`, and
   `%ProgramFiles(x86)%\Claude`.

Check what Windows sees:

```powershell
Get-AppxPackage -Name Claude | Select-Object Name, InstallLocation, PackageFullName
```

If Claude is installed elsewhere, find `Claude.exe` and reinstall with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -ProxyPort 1080 `
  -ExpectedIp 203.0.113.10 `
  -ClaudeExe "D:\Apps\Claude\Claude.exe" `
  -Force
```

## After a Claude update

Claude's MSIX folder name contains a version number and can change after an
update. The launcher resolves the current package each time, but if automatic
discovery fails, reinstall with the new `-ClaudeExe` path.

## Claude Code is not protected

This is intentional in v1. The tool only protects Claude Desktop and explicitly
ignores `%USERPROFILE%\.local\bin\claude.exe` (Claude Code CLI). Configure
Claude Code's own proxy environment variables if you need a similar guarantee
there.

## The original Claude icon still works

The original shortcut is not modified. The monitor closes unprotected Claude
Desktop instances on its next check, so there can be a window of up to one check
interval (default 3 seconds). Always use the **Claude (IP Guard)** shortcut.

## Uninstall leaves shortcuts behind

`uninstall.ps1` only removes shortcuts and startup entries that point at the
installation being removed. If you installed to a custom directory, run that
copy's uninstaller with the same `-InstallDir`, or remove the leftover shortcut
manually.

To remove logs too:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeIPGuard\uninstall.ps1" -RemoveData
```

## Logs

```text
%LOCALAPPDATA%\ClaudeIPGuard\logs\guard.log
%LOCALAPPDATA%\ClaudeIPGuard\logs\guard.log.1
```

Logs rotate at 1 MB. They contain monitor decisions and error messages, not
Claude conversation content. Remove or redact paths before sharing publicly.

## Still stuck

Collect:

- Windows version;
- Claude Desktop version and install path;
- proxy type and port (not credentials);
- output of `status.ps1`;
- the last 30 lines of `guard.log`.

Open a GitHub issue with those details, but remove hostnames, usernames, public
IPs, and any tokens first.

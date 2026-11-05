# OpenBao Windows Installer

Idempotent PowerShell installer for a single-node [OpenBao](https://openbao.org/) server on 64-bit Windows.

The script downloads and SHA256-verifies OpenBao and [NSSM](https://nssm.cc/), creates the install layout, writes a starter PebbleDB configuration with static auto-unseal when none exists, and registers an automatically started Windows service as the virtual account `NT SERVICE\OpenBao`. Re-runs preserve the binary when the version matches, the unseal key, configuration, Pebble data, init file, and service settings. The script does not upgrade an existing binary silently or add firewall rules.

On first run, when OpenBao is not yet initialized, the installer runs `bao operator init` once and saves the root token and recovery key to `init\bao-init.json` (Administrators and SYSTEM only). Static auto-unseal reads `unseal.key` at service start, so there is no Shamir unseal step and no reboot startup task.

## Scripts

- `install-openbao-windows.ps1` — loopback HTTP only (`127.0.0.1:8200`, TLS disabled). PebbleDB storage and a local 32-byte static unseal key.
- `uninstall-openbao-windows.ps1` — stops and deletes the `OpenBao` service when it is this NSSM install and deletes the install root (Pebble data, config, unseal key, and init file).
- `login-openbao-ui.ps1` / `login-openbao-ui.cmd` — copy a token to the clipboard and open the UI token sign-in page (UAC once to read `init\`).

## Requirements

- Windows PowerShell 5.1 or later
- 64-bit Windows
- Administrator
- Outbound HTTPS to `github.com` (OpenBao releases) and `nssm.cc`

Default install root is `C:\OpenBao`. Default OpenBao version is `2.7.2`.

## Usage

```powershell
.\install-openbao-windows.ps1
.\uninstall-openbao-windows.ps1
```

## Operations

Sign in to the UI at [http://127.0.0.1:8200/ui/](http://127.0.0.1:8200/ui/) (Token method). Double-click `login-openbao-ui.cmd` (or run the `.ps1`); approve UAC, then paste from the clipboard into the Token field:

```powershell
.\login-openbao-ui.cmd
.\login-openbao-ui.ps1 -UseAppToken          # sampleapp-apps token instead of root
.\login-openbao-ui.ps1 -CreateDesktopShortcut
```

Manual copy (elevated PowerShell):

```powershell
(Get-Content C:\OpenBao\init\bao-init.json -Raw | ConvertFrom-Json).root_token
```

Create a limited token for applications (read-only on KV v2 `secret/sampleapp`, matching [DOTNET.md](DOTNET.md)). Run elevated:

```powershell
$env:BAO_ADDR = "http://127.0.0.1:8200"
$env:BAO_TOKEN = (Get-Content C:\OpenBao\init\bao-init.json -Raw | ConvertFrom-Json).root_token
$Bao = "C:\OpenBao\bao.exe"

& $Bao secrets enable -path=secret -version=2 kv  # ignore error if already enabled

@'
path "secret/data/sampleapp" {
  capabilities = ["read"]
}
path "secret/metadata/sampleapp" {
  capabilities = ["read", "list"]
}
'@ | Set-Content -Path $env:TEMP\sampleapp-read.hcl -Encoding utf8

& $Bao policy write sampleapp-read $env:TEMP\sampleapp-read.hcl
$auth = & $Bao token create -policy=sampleapp-read -display-name=sampleapp-apps -ttl=8760h -renewable=true -format=json | ConvertFrom-Json
$auth.auth.client_token
```

Set `BAO_TOKEN` (or `VAULT_TOKEN`) for apps to the printed token, or persist it for local dev:

```powershell
$auth.auth.client_token | Set-Content C:\OpenBao\init\sampleapp-token.txt -NoNewline
icacls C:\OpenBao\init\sampleapp-token.txt /inheritance:r /grant:r "SYSTEM:F" "Administrators:F"
```

Smoke-test the API with [samples/openbao-connect](samples/openbao-connect/README.md).

## Permissions

The install root grants `BUILTIN\Users` read and execute so a non-elevated administrator can browse `C:\OpenBao`, read `config.hcl`, and view logs without UAC (the same pattern as `C:\Program Files`). The config names the unseal key path but does not contain the key.

`unseal.key`, `init\`, and `data\` have no Users ACE. Opening those paths still requires elevation.

The static unseal key on disk is a deliberate tradeoff for a single-machine dev install: anyone with Administrator access (or backup access to the install root) can read it and unseal the server.

## License

MIT. See [LICENSE](LICENSE).

OpenBao and NSSM are third-party software with their own licenses. This repository covers the installer scripts only.

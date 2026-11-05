# Vault Windows Installer

Idempotent PowerShell installers for a single-node [HashiCorp Vault](https://www.vaultproject.io/) Community server on 64-bit Windows.

Each script downloads and SHA256-verifies Vault and [NSSM](https://nssm.cc/), creates the install layout, writes a starter Raft config when none exists, and registers a manually started Windows service as the virtual account `NT SERVICE\Vault`. Re-runs keep existing Raft data, configuration, and service startup mode. They do not initialize or unseal Vault, create TLS private keys, upgrade an existing binary, or add firewall rules.

## Scripts

- `Install-Vault-Windows.ps1` — TLS listener on `0.0.0.0:8200`. Requires `-VaultDnsName`. Place PEM files at `C:\Vault\certs\vault.crt` and `vault.key` before starting.
- `Install-Vault-Windows-Local.ps1` — loopback HTTP only (`127.0.0.1:8200`, TLS disabled). Do not expose this listener off the machine without TLS.

## Requirements

- Windows PowerShell 5.1 or later
- 64-bit Windows
- Administrator
- Outbound HTTPS to `releases.hashicorp.com` and `nssm.cc`

Default install root is `C:\Vault`. Default Vault version is `2.2.1`.

## Usage

```powershell
# TLS, remote DNS name
.\Install-Vault-Windows.ps1 -VaultDnsName vault.example.com
.\Install-Vault-Windows.ps1 -VaultDnsName vault.example.com -Start -AutoStart

# Localhost only
.\Install-Vault-Windows-Local.ps1
.\Install-Vault-Windows-Local.ps1 -Start -AutoStart
```

After the service is running, initialize and unseal Vault once with the Vault CLI.

## License

MIT. See [LICENSE](LICENSE).

Vault and NSSM are third-party software with their own licenses. This repository covers the installer scripts only.

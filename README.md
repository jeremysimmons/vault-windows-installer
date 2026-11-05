# Vault Windows Installer

Idempotent PowerShell installers for a single-node [HashiCorp Vault](https://www.vaultproject.io/) Community server on 64-bit Windows.

Each script downloads and SHA256-verifies Vault and [NSSM](https://nssm.cc/), creates the install layout, writes a starter Raft config when none exists, and registers a Windows service as the virtual account `NT SERVICE\Vault`. Re-runs keep existing Raft data, configuration, and service startup mode. Neither script creates TLS private keys, upgrades an existing binary, or adds firewall rules. The TLS script does not initialize or unseal Vault. The local script starts the service automatically, creates a new single-node Raft cluster when Vault is uninitialized, unseals it, and registers a startup task that unseals again after reboot.

## Scripts

- `install-vault-windows.ps1` — TLS listener on `0.0.0.0:8200`. Requires `-VaultDnsName`. Place PEM files at `C:\Vault\certs\vault.crt` and `vault.key` before starting.
- `install-vault-windows-local.ps1` — loopback HTTP only (`127.0.0.1:8200`, TLS disabled). Initializes a new Raft cluster and unseals it. Do not expose this listener off the machine without TLS.
- `uninstall-vault-windows.ps1` — stops and deletes the `Vault` service when it is this NSSM install, removes the `Vault-Local-Unseal` task, and deletes the install root (Raft data, config, certs, and init keys).

## Requirements

- Windows PowerShell 5.1 or later
- 64-bit Windows
- Administrator
- Outbound HTTPS to `releases.hashicorp.com` and `nssm.cc`

Default install root is `C:\Vault`. Default Vault version is `2.2.1`.

## Usage

```powershell
# TLS, remote DNS name
.\install-vault-windows.ps1 -VaultDnsName vault.example.com
.\install-vault-windows.ps1 -VaultDnsName vault.example.com -Start -AutoStart

# Localhost only
.\install-vault-windows-local.ps1
.\install-vault-windows-local.ps1 -Start -AutoStart

# Remove the service, unseal task, and C:\Vault
.\uninstall-vault-windows.ps1
```

The TLS installer leaves initialization to the operator. The local installer saves the unseal key and root token under `C:\Vault\init\vault-init.json` (Administrators and SYSTEM only). Sign in to the UI with that root token.

## License

MIT. See [LICENSE](LICENSE).

Vault and NSSM are third-party software with their own licenses. This repository covers the installer scripts only.

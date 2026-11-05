# .NET configuration provider

Read KV v2 secrets from the Vault installed by these scripts into `IConfiguration`.

The local installer listens on `http://127.0.0.1:8200` with TLS disabled. `Install-Vault-Windows.ps1` listens on `https://<VaultDnsName>:8200`. Neither script initializes Vault, unseals it, or enables a secrets engine. Do that once before an application connects.

```powershell
dotnet add package VaultSharp.Extensions.Configuration
```

```csharp
using VaultSharp.Extensions.Configuration;

var builder = WebApplication.CreateBuilder(args);

builder.Configuration.AddVaultConfiguration(
    () => new VaultOptions(
        "http://127.0.0.1:8200",
        Environment.GetEnvironmentVariable("VAULT_TOKEN")!,
        reloadOnChange: true,
        reloadCheckIntervalSeconds: 60),
    basePath: "sampleapp",
    mountPoint: "secret");

builder.Services.AddHostedService<VaultChangeWatcher>();
builder.Services.Configure<AppOptions>(builder.Configuration);

var app = builder.Build();
app.MapGet("/config", (Microsoft.Extensions.Options.IOptionsMonitor<AppOptions> options) => options.CurrentValue);
app.Run();

public sealed class AppOptions
{
    public string ConnectionString { get; set; } = "";
    public FeatureFlagsOptions FeatureFlags { get; set; } = new();
}

public sealed class FeatureFlagsOptions
{
    public bool Beta { get; set; }
}
```

`WebApplication.CreateBuilder` already loads `appsettings.json`, user secrets, and environment variables. Vault is added after those sources, so Vault values win. Call `AddEnvironmentVariables()` again after `AddVaultConfiguration` when environment variables must override Vault.

Set `VAULT_TOKEN` before the process starts. For the TLS installer, pass `https://<VaultDnsName>:8200` and `insecureConnection: true` only when the certificate is not trusted.

KV v2 document at `secret/sampleapp`. Nested JSON becomes configuration sections.

```json
{
  "ConnectionString": "Server=.;Database=App;Trusted_Connection=True",
  "FeatureFlags": { "Beta": true }
}
```

```powershell
$env:VAULT_ADDR = "http://127.0.0.1:8200"
$env:VAULT_TOKEN = "<token>"

vault secrets enable -path=secret -version=2 kv
vault kv put secret/sampleapp @appsettings.vault.json
```

The token needs `read` on `secret/data/sampleapp` and `read` plus `list` on `secret/metadata/sampleapp`. `VaultChangeWatcher` polls metadata and reloads configuration. `IOptionsMonitor<AppOptions>` sees those reloads. Values copied into a singleton at startup do not.

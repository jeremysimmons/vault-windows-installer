# .NET configuration provider

Read KV v2 secrets from the OpenBao instance installed by these scripts into `IConfiguration`.

The installer listens on `http://127.0.0.1:8200` with TLS disabled. The HTTP API remains Vault-compatible, so [VaultSharp.Extensions.Configuration](https://www.nuget.org/packages/VaultSharp.Extensions.Configuration) works unchanged. Enable a KV v2 secrets engine and write secrets before an application connects.

```powershell
dotnet add package VaultSharp.Extensions.Configuration
```

```csharp
using VaultSharp.Extensions.Configuration;

var builder = WebApplication.CreateBuilder(args);

builder.Configuration.AddVaultConfiguration(
    () => new VaultOptions(
        "http://127.0.0.1:8200",
        Environment.GetEnvironmentVariable("BAO_TOKEN")!,
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

`WebApplication.CreateBuilder` already loads `appsettings.json`, user secrets, and environment variables. OpenBao is added after those sources, so OpenBao values win. Call `AddEnvironmentVariables()` again after `AddVaultConfiguration` when environment variables must override OpenBao.

Set `BAO_TOKEN` (or `VAULT_TOKEN`) before the process starts. Use the `root_token` from `C:\OpenBao\init\bao-init.json` for local development only; create a limited policy for applications.

KV v2 document at `secret/sampleapp`. Nested JSON becomes configuration sections.

```json
{
  "ConnectionString": "Server=.;Database=App;Trusted_Connection=True",
  "FeatureFlags": { "Beta": true }
}
```

```powershell
$env:BAO_ADDR = "http://127.0.0.1:8200"
$env:BAO_TOKEN = "<token>"

C:\OpenBao\bao.exe secrets enable -path=secret -version=2 kv
C:\OpenBao\bao.exe kv put secret/sampleapp @appsettings.vault.json
```

The token needs `read` on `secret/data/sampleapp` and `read` plus `list` on `secret/metadata/sampleapp`. `VaultChangeWatcher` polls metadata and reloads configuration. `IOptionsMonitor<AppOptions>` sees those reloads. Values copied into a singleton at startup do not.

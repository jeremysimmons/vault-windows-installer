# OpenBao connection smoke test

```powershell
$env:BAO_ADDR = "http://127.0.0.1:8200"
$env:BAO_TOKEN = (Get-Content C:\OpenBao\init\bao-init.json -Raw | ConvertFrom-Json).root_token

dotnet run --project samples/openbao-connect
```

Reads unauthenticated health and seal status, then `auth/token/lookup-self` with your token. Exit code 0 means the API is reachable and the token is valid.

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Idempotent single-node HashiCorp Vault Community installer for Windows Server.
.DESCRIPTION
    Downloads and SHA256-verifies Vault and NSSM, creates directories and a starter
    localhost-only (127.0.0.1) Raft configuration, and registers an automatically
    started Windows service as the virtual account NT SERVICE\Vault.

    When Vault is not yet initialized, this creates a new single-node Raft cluster
    (it does not join an existing cluster), saves the unseal key and root token
    for Administrators only, and unseals. A startup task unseals again after reboot.
    Re-running preserves Raft data, configuration, and an existing cluster.

    Its HTTP listener is restricted to loopback. Do NOT make it listen on a
    non-loopback interface unless you also configure TLS.
.EXAMPLE
    .\install-vault-windows-local.ps1
.EXAMPLE
    .\install-vault-windows-local.ps1 -Start -AutoStart
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$VaultVersion = '2.2.1',

    [string]$InstallRoot = 'C:\Vault',

    [switch]$ReplaceConfigWithLocalhost,
    [switch]$Start,
    [switch]$AutoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not [Environment]::Is64BitOperatingSystem) { throw 'This installer supports 64-bit Windows only.' }
$ServiceName = 'Vault'
$ServiceIdentity = "NT SERVICE\$ServiceName"
$VaultExe = Join-Path $InstallRoot 'vault.exe'
$NssmExe = Join-Path $InstallRoot 'nssm.exe'
$ConfigDir = Join-Path $InstallRoot 'config'
$DataDir = Join-Path $InstallRoot 'data'
$LogDir = Join-Path $InstallRoot 'logs'
$ConfigFile = Join-Path $ConfigDir 'vault.hcl'
$InitDir = Join-Path $InstallRoot 'init'
$InitFile = Join-Path $InitDir 'vault-init.json'
$UnsealScript = Join-Path $InstallRoot 'unseal-vault.ps1'
$VaultAddress = 'http://127.0.0.1:8200'
$NssmUrl = 'https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip'
# Published in Microsoft's Windows Package Manager repository, NSSM.NSSM 2.24-101.
$NssmArchiveSha256 = '99F5045FFFBFFB745D67FE3A065A953C4A3D9C253B868892D9B685B0EE7D07B8'

function Invoke-Native {
    param([string]$Exe, [string[]]$ArgumentList)
    & $Exe @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Exe $($ArgumentList -join ' ')" }
}

function Assert-Hash {
    param([string]$Path, [string]$Sha256)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ine $Sha256) { throw "SHA256 mismatch for $Path. Expected $Sha256; got $actual." }
}

function Download-File {
    param([string]$Url, [string]$Path)
    Write-Host "Downloading $Url"
    try { Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 180 }
    catch { throw "Could not download $Url. Check Internet access, proxy and TLS settings. $($_.Exception.Message)" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Download missing: $Path" }
}

function Grant-Acl {
    param([string]$Path, [string[]]$ArgumentList)
    Invoke-Native -Exe 'icacls.exe' -ArgumentList (@($Path) + $ArgumentList)
}

function Get-VaultSealStatus {
    param([string]$Address)
    Invoke-RestMethod -Uri ($Address.TrimEnd('/') + '/v1/sys/seal-status') -TimeoutSec 5
}

function Wait-VaultSealStatus {
    param([string]$Address, [int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        try { return Get-VaultSealStatus -Address $Address }
        catch { Start-Sleep -Seconds 2 }
    } while ((Get-Date) -lt $deadline)
    throw "Vault did not respond at $Address within $TimeoutSec seconds."
}

function Submit-VaultUnsealKeys {
    param([string]$Address, [string]$KeysFile)
    $init = Get-Content -LiteralPath $KeysFile -Raw | ConvertFrom-Json
    $status = $null
    foreach ($share in @($init.keys)) {
        $body = @{ key = [string]$share } | ConvertTo-Json -Compress
        $status = Invoke-RestMethod -Method Post -Uri ($Address.TrimEnd('/') + '/v1/sys/unseal') -ContentType 'application/json' -Body $body
        if (-not $status.sealed) { return }
    }
    throw "Vault at $Address remained sealed after submitting the stored unseal keys."
}

function Write-VaultUnsealScript {
    param([string]$Path, [string]$Address, [string]$KeysFile)
    $content = @'
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$Address = '__ADDRESS__'
$KeysFile = '__KEYSFILE__'
function Get-SealStatus {
    Invoke-RestMethod -Uri ($Address.TrimEnd('/') + '/v1/sys/seal-status') -TimeoutSec 5
}
$deadline = (Get-Date).AddSeconds(90)
$status = $null
do {
    try { $status = Get-SealStatus; break } catch { Start-Sleep -Seconds 2 }
} while ((Get-Date) -lt $deadline)
if (-not $status) { throw "Vault did not respond at $Address." }
if (-not $status.initialized) { throw "Vault at $Address is not initialized." }
if (-not $status.sealed) { exit 0 }
if (-not (Test-Path -LiteralPath $KeysFile)) { throw "Vault is sealed and $KeysFile is missing." }
$init = Get-Content -LiteralPath $KeysFile -Raw | ConvertFrom-Json
foreach ($share in @($init.keys)) {
    $body = @{ key = [string]$share } | ConvertTo-Json -Compress
    $status = Invoke-RestMethod -Method Post -Uri ($Address.TrimEnd('/') + '/v1/sys/unseal') -ContentType 'application/json' -Body $body
    if (-not $status.sealed) { exit 0 }
}
throw "Vault at $Address remained sealed after submitting the stored unseal keys."
'@
    $content = $content.Replace('__ADDRESS__', $Address).Replace('__KEYSFILE__', $KeysFile)
    [IO.File]::WriteAllText($Path, $content.Trim() + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

function Install-VaultUnsealTask {
    param([string]$ScriptPath)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT15S'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName 'Vault-Local-Unseal' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("vault-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
try {
    # Create directories, preserving existing contents.
    foreach ($dir in @($InstallRoot, $ConfigDir, $DataDir, $LogDir, $InitDir)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Host "Created $dir"
        }
    }

    # Install Vault only when absent; never silently upgrade a running deployment.
    if (Test-Path -LiteralPath $VaultExe -PathType Leaf) {
        $actualVersion = (& $VaultExe version | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "Unable to determine existing Vault version: $VaultExe" }
        if ($actualVersion -notmatch "\bv$([regex]::Escape($VaultVersion))\b") {
            throw "Existing Vault at $VaultExe is not version $VaultVersion. Upgrade separately; executable not replaced."
        }
        Write-Host "Vault $VaultVersion already installed; preserving executable."
    }
    else {
        $vaultArchiveName = "vault_${VaultVersion}_windows_amd64.zip"
        $vaultBase = "https://releases.hashicorp.com/vault/$VaultVersion"
        $vaultArchive = Join-Path $TempDir $vaultArchiveName
        $sumFile = Join-Path $TempDir "vault_${VaultVersion}_SHA256SUMS"
        Download-File "$vaultBase/$vaultArchiveName" $vaultArchive
        Download-File "$vaultBase/vault_${VaultVersion}_SHA256SUMS" $sumFile
        $hashEntry = Get-Content -LiteralPath $sumFile | Where-Object {
            $_ -match ('^\s*[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape($vaultArchiveName) + '\s*$')
        } | Select-Object -First 1
        if (-not $hashEntry) { throw "Could not locate $vaultArchiveName in official SHA256SUMS" }
        $expectedHash = ([regex]::Match($hashEntry, '[0-9a-fA-F]{64}')).Value
        Assert-Hash $vaultArchive $expectedHash
        $expanded = Join-Path $TempDir 'vault-expanded'
        Expand-Archive -LiteralPath $vaultArchive -DestinationPath $expanded
        $sourceExe = Get-ChildItem -LiteralPath $expanded -Filter 'vault.exe' -Recurse -File | Select-Object -First 1
        if (-not $sourceExe) { throw 'vault.exe not found inside official archive.' }
        Copy-Item -LiteralPath $sourceExe.FullName -Destination $VaultExe
        Write-Host "Installed Vault $VaultVersion to $VaultExe"
    }

    # Install pinned NSSM build, unless already present.
    if (-not (Test-Path -LiteralPath $NssmExe -PathType Leaf)) {
        $nssmArchive = Join-Path $TempDir 'nssm.zip'
        Download-File $NssmUrl $nssmArchive
        Assert-Hash $nssmArchive $NssmArchiveSha256
        $expanded = Join-Path $TempDir 'nssm-expanded'
        Expand-Archive -LiteralPath $nssmArchive -DestinationPath $expanded
        $sourceExe = Get-ChildItem -LiteralPath $expanded -Filter 'nssm.exe' -Recurse -File |
            Where-Object { $_.DirectoryName -match '[\\/]win64$' } | Select-Object -First 1
        if (-not $sourceExe) { throw 'win64/nssm.exe not found inside NSSM archive.' }
        Copy-Item -LiteralPath $sourceExe.FullName -Destination $NssmExe
        Write-Host "Installed NSSM to $NssmExe"
    }
    else { Write-Host 'NSSM already installed; preserving executable.' }

    # Preserve existing/custom config unless explicitly asked to replace it.
    $configExists = Test-Path -LiteralPath $ConfigFile -PathType Leaf
    if (-not $configExists -or $ReplaceConfigWithLocalhost) {
        $config = @"
ui = true

disable_mlock = true

storage "raft" {
  path    = "$(($DataDir -replace '\\', '/'))"
  node_id = "vault-server-1"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"
"@
        if ($configExists) {
            $oldConfig = [IO.File]::ReadAllText($ConfigFile)
            if ($oldConfig -ne ($config + "`r`n")) {
                $backup = "$ConfigFile.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Copy-Item -LiteralPath $ConfigFile -Destination $backup
                [IO.File]::WriteAllText($ConfigFile, $config + "`r`n", (New-Object Text.UTF8Encoding($false)))
                Write-Host "Replaced $ConfigFile; backup: $backup"
            } else { Write-Host 'Existing Vault config already matches localhost mode.' }
        } else {
            [IO.File]::WriteAllText($ConfigFile, $config + "`r`n", (New-Object Text.UTF8Encoding($false)))
            Write-Host "Created $ConfigFile"
        }
    }
    else {
        Write-Host "Existing $ConfigFile preserved."
        $existingConfig = [IO.File]::ReadAllText($ConfigFile)
        if ($existingConfig -notmatch '(?m)^ui\s*=\s*true\s*$' -or
            $existingConfig -notmatch 'address\s*=\s*"127\.0\.0\.1:8200"' -or
            $existingConfig -notmatch 'tls_disable\s*=\s*1') {
            Write-Warning 'Existing config may not be localhost-only. Rerun with -ReplaceConfigWithLocalhost to back it up and switch.'
        }
    }

    # Register service, but never take over an unrelated service named Vault.
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Invoke-Native $NssmExe @('install', $ServiceName, $VaultExe)
        Invoke-Native $NssmExe @('set', $ServiceName, 'AppDirectory', $InstallRoot)
        Invoke-Native $NssmExe @('set', $ServiceName, 'AppParameters', "server -config=`"$ConfigFile`"")
        Invoke-Native $NssmExe @('set', $ServiceName, 'DisplayName', 'HashiCorp Vault')
        Invoke-Native $NssmExe @('set', $ServiceName, 'Description', 'HashiCorp Vault (integrated Raft storage)')
        Invoke-Native $NssmExe @('set', $ServiceName, 'AppStdout', (Join-Path $LogDir 'stdout.log'))
        Invoke-Native $NssmExe @('set', $ServiceName, 'AppStderr', (Join-Path $LogDir 'stderr.log'))
        Invoke-Native $NssmExe @('set', $ServiceName, 'Start', 'SERVICE_DEMAND_START')
        # Passwordless Windows virtual service account; no shared LocalSystem identity.
        Invoke-Native $NssmExe @('set', $ServiceName, 'ObjectName', $ServiceIdentity)
        Write-Host "Registered $ServiceName service under $ServiceIdentity (Manual startup)."
    }
    else {
        $winService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'"
        if (-not $winService -or $winService.PathName -notmatch 'nssm\.exe') {
            throw "Service '$ServiceName' already exists but does not use NSSM. Refusing to modify it."
        }
        $app = ((& $NssmExe get $ServiceName Application) | Out-String).Trim().Trim('"')
        if ($LASTEXITCODE -ne 0 -or $app -ine $VaultExe) {
            throw "Service '$ServiceName' points to '$app', not '$VaultExe'. Refusing to modify it."
        }
        Write-Host 'Vault service already exists; preserving service settings.'
        if ($winService.StartName -ine $ServiceIdentity) {
            throw "Vault service runs as $($winService.StartName), not $ServiceIdentity. Refusing to change its file permissions."
        }
    }

    # Apply least-privilege ACLs. This installer owns C:\Vault (or InstallRoot).
    # Only administrators/SYSTEM get full control. Vault receives read/execute
    # except on its data and logs, where it needs modify rights.
    Grant-Acl $InstallRoot @('/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "${ServiceIdentity}:(OI)(CI)RX")
    foreach ($dir in @($ConfigDir)) {
        Grant-Acl $dir @('/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "${ServiceIdentity}:(OI)(CI)RX")
    }
    foreach ($dir in @($DataDir, $LogDir)) {
        Grant-Acl $dir @('/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "${ServiceIdentity}:(OI)(CI)M")
    }
    # Unseal material stays with Administrators and SYSTEM. The Vault service account cannot read it.
    Grant-Acl $InitDir @('/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
    Write-VaultUnsealScript -Path $UnsealScript -Address $VaultAddress -KeysFile $InitFile
    Install-VaultUnsealTask -ScriptPath $UnsealScript
    Write-Host 'Registered Vault-Local-Unseal startup task.'

    # -Start and -AutoStart remain accepted. Local install always auto-starts.
    Invoke-Native $NssmExe @('set', $ServiceName, 'Start', 'SERVICE_AUTO_START')
    Write-Host 'Configured automatic startup.'
    $current = Get-Service -Name $ServiceName
    if ($current.Status -ne 'Running') {
        Start-Service -Name $ServiceName -ErrorAction Stop
        Write-Host 'Started Vault Windows service.'
    }
    else { Write-Host 'Vault is already running.' }

    $seal = Wait-VaultSealStatus -Address $VaultAddress
    if (-not $seal.initialized) {
        if (Test-Path -LiteralPath $InitFile) {
            throw "Vault is not initialized, but $InitFile already exists. Refusing to create a second cluster."
        }
        $response = Invoke-WebRequest -Method Post -Uri ($VaultAddress.TrimEnd('/') + '/v1/sys/init') -ContentType 'application/json' -Body '{"secret_shares":1,"secret_threshold":1}' -UseBasicParsing
        [IO.File]::WriteAllText($InitFile, $response.Content, (New-Object Text.UTF8Encoding($false)))
        Write-Host "Created a new Raft cluster. Unseal key and root token: $InitFile"
        Submit-VaultUnsealKeys -Address $VaultAddress -KeysFile $InitFile
        Write-Host 'Unsealed Vault.'
    }
    elseif ($seal.sealed) {
        if (-not (Test-Path -LiteralPath $InitFile)) {
            throw "Vault is initialized and sealed, but $InitFile is missing. Refusing to reinitialize existing Raft data."
        }
        Submit-VaultUnsealKeys -Address $VaultAddress -KeysFile $InitFile
        Write-Host 'Unsealed the existing Raft cluster.'
    }
    else { Write-Host 'Vault is already initialized and unsealed.' }

    Write-Host ''
    Write-Host 'Vault installation complete.' -ForegroundColor Green
    Write-Host "Binary:  $VaultExe"
    Write-Host "Config:  $ConfigFile"
    Write-Host "Storage: $DataDir"
    Write-Host "Service: $ServiceName"
    Write-Host "Address: $VaultAddress (loopback only, no TLS)"
    Write-Host "Init:    $InitFile (Administrators only)"
    Write-Host 'UI:      sign in with the root_token from the init file. Raft is already initialized.'
    Write-Host 'No Windows Firewall rules were added.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

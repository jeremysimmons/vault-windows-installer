#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Idempotent single-node HashiCorp Vault Community installer for Windows Server.
.DESCRIPTION
    Downloads and SHA256-verifies Vault and NSSM, creates directories and a starter
    TLS/Raft configuration, and registers a manually-started Windows service
    running as the virtual account NT SERVICE\Vault.

    Re-running preserves Raft data, existing configuration, and service startup
    mode. It never initializes/unseals Vault or creates TLS private keys.
.EXAMPLE
    .\install-vault-windows.ps1 -VaultDnsName vault.example.com
.EXAMPLE
    .\install-vault-windows.ps1 -VaultDnsName vault.example.com -Start -AutoStart
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$')]
    [string]$VaultDnsName,

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$VaultVersion = '2.2.1',

    [string]$InstallRoot = 'C:\Vault',

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
$CertDir = Join-Path $InstallRoot 'certs'
$LogDir = Join-Path $InstallRoot 'logs'
$ConfigFile = Join-Path $ConfigDir 'vault.hcl'
$CertFile = Join-Path $CertDir 'vault.crt'
$KeyFile = Join-Path $CertDir 'vault.key'
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

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("vault-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
try {
    # Create directories, preserving existing contents.
    foreach ($dir in @($InstallRoot, $ConfigDir, $DataDir, $CertDir, $LogDir)) {
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

    # Never overwrite an existing (possibly customized) Vault configuration.
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
        $config = @"
ui = true

disable_mlock = true

storage "raft" {
  path    = "$(($DataDir -replace '\\', '/'))"
  node_id = "vault-server-1"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "$(($CertFile -replace '\\', '/'))"
  tls_key_file  = "$(($KeyFile -replace '\\', '/'))"
}

api_addr     = "https://${VaultDnsName}:8200"
cluster_addr = "https://${VaultDnsName}:8201"
"@
        [IO.File]::WriteAllText($ConfigFile, $config + "`r`n", (New-Object Text.UTF8Encoding($false)))
        Write-Host "Created $ConfigFile"
    }
    else { Write-Host "Existing $ConfigFile preserved." }

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
    foreach ($dir in @($ConfigDir, $CertDir)) {
        Grant-Acl $dir @('/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "${ServiceIdentity}:(OI)(CI)RX")
    }
    foreach ($dir in @($DataDir, $LogDir)) {
        Grant-Acl $dir @('/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "${ServiceIdentity}:(OI)(CI)M")
    }
    foreach ($file in @($CertFile, $KeyFile)) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Grant-Acl $file @('/inheritance:r', '/grant:r', '*S-1-5-18:F', '*S-1-5-32-544:F', "${ServiceIdentity}:R")
        }
    }

    if ($AutoStart -or $Start) {
        if (-not (Test-Path -LiteralPath $CertFile -PathType Leaf) -or -not (Test-Path -LiteralPath $KeyFile -PathType Leaf)) {
            throw "TLS files missing. Install $CertFile and $KeyFile before enabling startup. Installation itself is complete."
        }
    }
    if ($AutoStart) {
        Invoke-Native $NssmExe @('set', $ServiceName, 'Start', 'SERVICE_AUTO_START')
        Write-Host 'Configured automatic startup.'
    }
    if ($Start) {
        $current = Get-Service -Name $ServiceName
        if ($current.Status -ne 'Running') {
            Start-Service -Name $ServiceName -ErrorAction Stop
            Write-Host 'Started Vault Windows service.'
        }
        else { Write-Host 'Vault is already running.' }
    }

    Write-Host ''
    Write-Host 'Vault installation complete.' -ForegroundColor Green
    Write-Host "Binary:  $VaultExe"
    Write-Host "Config:  $ConfigFile"
    Write-Host "Storage: $DataDir"
    Write-Host "Service: $ServiceName"
    Write-Host "TLS:     $CertFile and $KeyFile"
    Write-Host 'Next: install trusted PEM TLS files, start service, then initialize/unseal Vault ONE TIME.'
    Write-Host 'No Windows Firewall rules were added.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

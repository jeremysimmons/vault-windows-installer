#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Idempotent single-node OpenBao installer for Windows.
.DESCRIPTION
    Downloads and SHA256-verifies OpenBao and NSSM, creates directories, a PebbleDB
    configuration with a static auto-unseal key, and registers an automatically
    started Windows service as the virtual account NT SERVICE\OpenBao.

    When OpenBao is not yet initialized, runs operator init once and saves recovery
    material to init\bao-init.json (Administrators only). Re-running preserves the
    binary when the version matches, the unseal key, config, Pebble data, init file,
    and service settings.

    Its HTTP listener is restricted to loopback. Do NOT make it listen on a
    non-loopback interface unless you also configure TLS.
.EXAMPLE
    .\install-openbao-windows.ps1
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$OpenBaoVersion = '2.7.2',

    [string]$InstallRoot = 'C:\OpenBao'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not [Environment]::Is64BitOperatingSystem) { throw 'This installer supports 64-bit Windows only.' }
$ServiceName = 'OpenBao'
$ServiceIdentity = "NT SERVICE\$ServiceName"
$BaoExe = Join-Path $InstallRoot 'bao.exe'
$NssmExe = Join-Path $InstallRoot 'nssm.exe'
$DataDir = Join-Path $InstallRoot 'data'
$LogDir = Join-Path $InstallRoot 'logs'
$ConfigFile = Join-Path $InstallRoot 'config.hcl'
$InitDir = Join-Path $InstallRoot 'init'
$InitFile = Join-Path $InitDir 'bao-init.json'
$UnsealKeyFile = Join-Path $InstallRoot 'unseal.key'
$BaoAddress = 'http://127.0.0.1:8200'
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

function Get-BaoSealStatus {
    param([string]$Address)
    Invoke-RestMethod -Uri ($Address.TrimEnd('/') + '/v1/sys/seal-status') -TimeoutSec 5
}

function Wait-BaoSealStatus {
    param([string]$Address, [int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        try { return Get-BaoSealStatus -Address $Address }
        catch { Start-Sleep -Seconds 2 }
    } while ((Get-Date) -lt $deadline)
    throw "OpenBao did not respond at $Address within $TimeoutSec seconds."
}

function Test-DirEmpty {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $true }
    return -not (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("openbao-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
try {
    foreach ($dir in @($InstallRoot, $DataDir, $LogDir, $InitDir)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Host "Created $dir"
        }
    }

    if (Test-Path -LiteralPath $BaoExe -PathType Leaf) {
        $actualVersion = (& $BaoExe version | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "Unable to determine existing OpenBao version: $BaoExe" }
        if ($actualVersion -notmatch "\bv$([regex]::Escape($OpenBaoVersion))\b") {
            throw "Existing OpenBao at $BaoExe is not version $OpenBaoVersion. Upgrade separately; executable not replaced."
        }
        Write-Host "OpenBao $OpenBaoVersion already installed; preserving executable."
    }
    else {
        $archiveName = "openbao_${OpenBaoVersion}_windows_amd64.zip"
        $releaseBase = "https://github.com/openbao/openbao/releases/download/v$OpenBaoVersion"
        $baoArchive = Join-Path $TempDir $archiveName
        $sumFile = Join-Path $TempDir 'checksums.txt'
        Download-File "$releaseBase/$archiveName" $baoArchive
        Download-File "$releaseBase/checksums.txt" $sumFile
        $hashEntry = Get-Content -LiteralPath $sumFile | Where-Object {
            $_ -match ('^\s*[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape($archiveName) + '\s*$')
        } | Select-Object -First 1
        if (-not $hashEntry) { throw "Could not locate $archiveName in checksums.txt" }
        $expectedHash = ([regex]::Match($hashEntry, '[0-9a-fA-F]{64}')).Value
        Assert-Hash $baoArchive $expectedHash
        $expanded = Join-Path $TempDir 'bao-expanded'
        Expand-Archive -LiteralPath $baoArchive -DestinationPath $expanded
        $sourceExe = Get-ChildItem -LiteralPath $expanded -Filter 'bao.exe' -Recurse -File | Select-Object -First 1
        if (-not $sourceExe) { throw 'bao.exe not found inside official archive.' }
        Copy-Item -LiteralPath $sourceExe.FullName -Destination $BaoExe
        Write-Host "Installed OpenBao $OpenBaoVersion to $BaoExe"
    }

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

    $dataEmpty = Test-DirEmpty -Path $DataDir
    if (-not (Test-Path -LiteralPath $UnsealKeyFile -PathType Leaf)) {
        if (-not $dataEmpty) {
            throw "unseal.key is missing but $DataDir is not empty. Refusing to create a new key against existing data."
        }
        $keyBytes = New-Object byte[] 32
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($keyBytes)
        [IO.File]::WriteAllBytes($UnsealKeyFile, $keyBytes)
        Write-Host "Created $UnsealKeyFile"
    }
    else { Write-Host "Existing $UnsealKeyFile preserved." }

    $installRootForward = ($InstallRoot -replace '\\', '/')
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
        $config = @"
ui = true
disable_mlock = true

storage "pebbledb" {
  path = "$installRootForward/data"
}

seal "static" {
  current_key_id = "local-key-1"
  current_key = "file://$installRootForward/unseal.key"
}

listener "tcp" {
  address = "127.0.0.1:8200"
  tls_disable = true
}

api_addr = "http://127.0.0.1:8200"
"@
        [IO.File]::WriteAllText($ConfigFile, $config + "`r`n", (New-Object Text.UTF8Encoding($false)))
        Write-Host "Created $ConfigFile"
    }
    else { Write-Host "Existing $ConfigFile preserved." }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Invoke-Native $NssmExe @('install', $ServiceName, $BaoExe)
        Invoke-Native $NssmExe @('set', $ServiceName, 'AppDirectory', $InstallRoot)
        Invoke-Native $NssmExe @('set', $ServiceName, 'AppParameters', "server -config=`"$ConfigFile`"")
        Invoke-Native $NssmExe @('set', $ServiceName, 'DisplayName', 'OpenBao')
        Invoke-Native $NssmExe @('set', $ServiceName, 'Description', 'OpenBao (PebbleDB, static auto-unseal)')
        Invoke-Native $NssmExe @('set', $ServiceName, 'AppStdout', (Join-Path $LogDir 'stdout.log'))
        Invoke-Native $NssmExe @('set', $ServiceName, 'AppStderr', (Join-Path $LogDir 'stderr.log'))
        Invoke-Native $NssmExe @('set', $ServiceName, 'Start', 'SERVICE_AUTO_START')
        Invoke-Native $NssmExe @('set', $ServiceName, 'ObjectName', $ServiceIdentity)
        Write-Host "Registered $ServiceName service under $ServiceIdentity (Automatic startup)."
    }
    else {
        $winService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'"
        if (-not $winService -or $winService.PathName -notmatch 'nssm\.exe') {
            throw "Service '$ServiceName' already exists but does not use NSSM. Refusing to modify it."
        }
        $app = ((& $NssmExe get $ServiceName Application) | Out-String).Trim().Trim('"')
        if ($LASTEXITCODE -ne 0 -or $app -ine $BaoExe) {
            throw "Service '$ServiceName' points to '$app', not '$BaoExe'. Refusing to modify it."
        }
        Write-Host 'OpenBao service already exists; preserving service settings.'
        if ($winService.StartName -ine $ServiceIdentity) {
            throw "OpenBao service runs as $($winService.StartName), not $ServiceIdentity. Refusing to change its file permissions."
        }
    }

    # Install root and logs: readable by local Users without elevation (filtered admin token includes Users).
    Grant-Acl $InstallRoot @(
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F',
        '*S-1-5-32-545:(OI)(CI)RX',
        "${ServiceIdentity}:(OI)(CI)RX"
    )
    Grant-Acl $LogDir @(
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F',
        '*S-1-5-32-545:(OI)(CI)RX',
        "${ServiceIdentity}:(OI)(CI)M"
    )
    Grant-Acl $DataDir @(
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F',
        "${ServiceIdentity}:(OI)(CI)M"
    )
    Grant-Acl $UnsealKeyFile @(
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F',
        "${ServiceIdentity}:R"
    )
    Grant-Acl $InitDir @(
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F'
    )

    Invoke-Native $NssmExe @('set', $ServiceName, 'Start', 'SERVICE_AUTO_START')
    Write-Host 'Configured automatic startup.'
    $current = Get-Service -Name $ServiceName
    if ($current.Status -ne 'Running') {
        Start-Service -Name $ServiceName -ErrorAction Stop
        Write-Host 'Started OpenBao Windows service.'
    }
    else { Write-Host 'OpenBao is already running.' }

    $seal = Wait-BaoSealStatus -Address $BaoAddress
    if (-not $seal.initialized) {
        if (Test-Path -LiteralPath $InitFile) {
            throw "OpenBao is not initialized, but $InitFile already exists. Refusing to create a second cluster."
        }
        $env:BAO_ADDR = $BaoAddress
        $initJson = & $BaoExe operator init -recovery-shares=1 -recovery-threshold=1 -format=json
        if ($LASTEXITCODE -ne 0) { throw "bao operator init failed with exit code $LASTEXITCODE." }
        [IO.File]::WriteAllText($InitFile, ($initJson | Out-String).Trim() + "`r`n", (New-Object Text.UTF8Encoding($false)))
        Write-Host "Initialized OpenBao. Root token and recovery key: $InitFile (not printed)."
        $seal = Wait-BaoSealStatus -Address $BaoAddress
    }
    elseif ($seal.sealed) {
        throw "OpenBao is initialized but still sealed. Static auto-unseal should unseal on start; check logs and $UnsealKeyFile. Refusing to re-initialize or submit recovery keys."
    }
    else { Write-Host 'OpenBao is already initialized and unsealed.' }

    if ($seal.sealed) {
        throw "OpenBao remained sealed after initialization. Check $LogDir and $UnsealKeyFile."
    }

    Write-Host ''
    Write-Host 'OpenBao installation complete.' -ForegroundColor Green
    Write-Host "Binary:  $BaoExe"
    Write-Host "Config:  $ConfigFile"
    Write-Host "Storage: $DataDir (PebbleDB)"
    Write-Host "Service: $ServiceName"
    Write-Host "Address: $BaoAddress (loopback only, no TLS)"
    Write-Host "Init:    $InitFile (Administrators only)"
    Write-Host 'UI:      http://127.0.0.1:8200/ui/ — sign in with root_token from the init file.'
    Write-Host 'No Windows Firewall rules were added.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remove the OpenBao service and files created by install-openbao-windows.ps1.
.DESCRIPTION
    Stops and deletes the NSSM service named OpenBao when it points at
    InstallRoot\bao.exe, and deletes InstallRoot. That removes binaries, PebbleDB
    data, configuration, the static unseal key, and the init file.

    An unrelated service named OpenBao is left in place, and a directory that
    does not contain this installer's files is not deleted. Re-running after
    a successful uninstall succeeds. Does not remove Vault or C:\Vault.
.EXAMPLE
    .\uninstall-openbao-windows.ps1
.EXAMPLE
    .\uninstall-openbao-windows.ps1 -InstallRoot D:\OpenBao
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\OpenBao'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName = 'OpenBao'
$BaoExe = Join-Path $InstallRoot 'bao.exe'
$NssmExe = Join-Path $InstallRoot 'nssm.exe'
$ConfigFile = Join-Path $InstallRoot 'config.hcl'

function Invoke-Native {
    param([string]$Exe, [string[]]$ArgumentList)
    & $Exe @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Exe $($ArgumentList -join ' ')" }
}

function Remove-OpenBaoService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Host "Service $ServiceName is not installed."
        return
    }

    $winService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'"
    $servicePath = [string]$winService.PathName
    if ($servicePath -notmatch [regex]::Escape($NssmExe)) {
        throw "Service '$ServiceName' does not use $NssmExe. Refusing to remove it."
    }
    if (-not (Test-Path -LiteralPath $NssmExe -PathType Leaf)) {
        throw "Service '$ServiceName' points at $NssmExe, but that file is missing. Refusing to remove it."
    }

    $app = ((& $NssmExe get $ServiceName Application) | Out-String).Trim().Trim('"')
    if ($LASTEXITCODE -ne 0 -or $app -ine $BaoExe) {
        throw "Service '$ServiceName' points to '$app', not '$BaoExe'. Refusing to remove it."
    }

    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        $service.Refresh()
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, (New-TimeSpan -Seconds 45))
        Write-Host "Stopped $ServiceName."
    }

    Invoke-Native $NssmExe @('remove', $ServiceName, 'confirm')
    Write-Host "Removed $ServiceName service."
}

function Remove-OpenBaoInstallRoot {
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        Write-Host "$InstallRoot does not exist."
        return
    }

    $owned = $false
    foreach ($marker in @($BaoExe, $NssmExe, $ConfigFile)) {
        if (Test-Path -LiteralPath $marker -PathType Leaf) { $owned = $true; break }
    }
    if (-not $owned) {
        throw "$InstallRoot does not contain this installer's bao.exe, nssm.exe, or config.hcl. Refusing to delete it."
    }

    Get-CimInstance Win32_Process -Filter "Name='bao.exe'" | ForEach-Object {
        $processPath = [string]$_.ExecutablePath
        if ($processPath -ieq $BaoExe) {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    $removed = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction Stop
            $removed = $true
            break
        }
        catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Seconds 2
        }
    }
    if (-not $removed) { throw "Could not delete $InstallRoot." }
    Write-Host "Removed $InstallRoot."
}

Remove-OpenBaoService
Remove-OpenBaoInstallRoot

Write-Host ''
Write-Host 'OpenBao uninstall complete.' -ForegroundColor Green
Write-Host 'No Windows Firewall rules were removed; the installer does not add any.'

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remove the HashiCorp Vault service and files created by these installers.
.DESCRIPTION
    Stops and deletes the NSSM service named Vault when it points at
    InstallRoot\vault.exe, removes the Vault-Local-Unseal scheduled task,
    and deletes InstallRoot. That removes binaries, Raft data, configuration,
    TLS material, and the local init key file.

    An unrelated service named Vault is left in place, and a directory that
    does not contain this installer's files is not deleted. Re-running after
    a successful uninstall succeeds.
.EXAMPLE
    .\uninstall-vault-windows.ps1
.EXAMPLE
    .\uninstall-vault-windows.ps1 -InstallRoot D:\Vault
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Vault'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName = 'Vault'
$UnsealTaskName = 'Vault-Local-Unseal'
$VaultExe = Join-Path $InstallRoot 'vault.exe'
$NssmExe = Join-Path $InstallRoot 'nssm.exe'
$UnsealScript = Join-Path $InstallRoot 'unseal-vault.ps1'

function Invoke-Native {
    param([string]$Exe, [string[]]$ArgumentList)
    & $Exe @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Exe $($ArgumentList -join ' ')" }
}

function Remove-VaultService {
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
    if ($LASTEXITCODE -ne 0 -or $app -ine $VaultExe) {
        throw "Service '$ServiceName' points to '$app', not '$VaultExe'. Refusing to remove it."
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

function Remove-VaultUnsealTask {
    $task = Get-ScheduledTask -TaskName $UnsealTaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Host "Scheduled task $UnsealTaskName is not installed."
        return
    }
    Stop-ScheduledTask -TaskName $UnsealTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $UnsealTaskName -Confirm:$false
    Write-Host "Removed scheduled task $UnsealTaskName."
}

function Remove-VaultInstallRoot {
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        Write-Host "$InstallRoot does not exist."
        return
    }

    $owned = $false
    foreach ($marker in @($VaultExe, $NssmExe, $UnsealScript)) {
        if (Test-Path -LiteralPath $marker -PathType Leaf) { $owned = $true; break }
    }
    if (-not $owned) {
        throw "$InstallRoot does not contain this installer's vault.exe, nssm.exe, or unseal-vault.ps1. Refusing to delete it."
    }

    Get-CimInstance Win32_Process -Filter "Name='vault.exe'" | ForEach-Object {
        $processPath = [string]$_.ExecutablePath
        if ($processPath -ieq $VaultExe) {
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

Remove-VaultService
Remove-VaultUnsealTask
Remove-VaultInstallRoot

Write-Host ''
Write-Host 'Vault uninstall complete.' -ForegroundColor Green
Write-Host 'No Windows Firewall rules were removed; the installers do not add any.'

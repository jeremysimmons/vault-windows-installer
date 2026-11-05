#Requires -Version 5.1
<#
.SYNOPSIS
    Copy an OpenBao token to the clipboard and open the UI sign-in page.
.EXAMPLE
    .\login-openbao-ui.ps1
.EXAMPLE
    .\login-openbao-ui.ps1 -UseAppToken
#>
[CmdletBinding()]
param(
    [switch]$UseAppToken,
    [string]$InstallRoot = 'C:\OpenBao',
    [switch]$CreateDesktopShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    if ($UseAppToken) { $argList += '-UseAppToken' }
    if ($CreateDesktopShortcut) { $argList += '-CreateDesktopShortcut' }
    if ($InstallRoot -ne 'C:\OpenBao') { $argList += @('-InstallRoot', "`"$InstallRoot`"") }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    exit 0
}

$UiUrl = 'http://127.0.0.1:8200/ui/vault/auth?with=token'
$tokenFile = if ($UseAppToken) {
    Join-Path $InstallRoot 'init\sampleapp-token.json'
} else {
    Join-Path $InstallRoot 'init\bao-init.json'
}

if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) {
    throw "Token file not found: $tokenFile"
}

$doc = Get-Content -LiteralPath $tokenFile -Raw | ConvertFrom-Json
$token = if ($UseAppToken) { [string]$doc.token } else { [string]$doc.root_token }
if ([string]::IsNullOrWhiteSpace($token)) { throw "No token in $tokenFile" }

Set-Clipboard -Value $token
Start-Process $UiUrl

$label = if ($UseAppToken) { 'sampleapp-apps token' } else { 'root token' }
Write-Host "Copied $label to the clipboard and opened the UI. Paste into the Token field and sign in."

if ($CreateDesktopShortcut) {
    $repoRoot = Split-Path -Parent $PSCommandPath
    $cmdPath = Join-Path $repoRoot 'login-openbao-ui.cmd'
    if (-not (Test-Path -LiteralPath $cmdPath)) {
        $cmdPath = $PSCommandPath
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop 'OpenBao UI.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $cmdPath
    $shortcut.WorkingDirectory = Split-Path -Parent $cmdPath
    $shortcut.Description = 'Open OpenBao UI (token on clipboard)'
    $shortcut.Save()
    Write-Host "Desktop shortcut: $shortcutPath"
}

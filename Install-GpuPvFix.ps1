<#
Installs (or updates / removes) GPU-PV Fix in already running VMs from the Hyper-V host,
using PowerShell Direct. The VM must be running and you need an administrator account inside the VM.

    .\Install-GpuPvFix.ps1 -VMName "GPU-P"
    .\Install-GpuPvFix.ps1 -VMName "GPU-P","GPU-P2" -Credential (Get-Credential)
    .\Install-GpuPvFix.ps1 -VMName "GPU-P" -Uninstall
#>

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory)][string[]]$VMName,
    [pscredential]$Credential,
    [switch]$ResetConfig,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$source = Join-Path $PSScriptRoot "GpuPvFix"
$staging = "C:\ProgramData\Easy-GPU-P\_staging"

foreach ($name in $VMName) {
    $vm = Get-VM -Name $name
    if ($vm.State -ne "Running") { Write-Warning "$name is not running - skipped."; continue }

    $cred = if ($Credential) { $Credential } else { Get-Credential -Message "Administrator account inside VM '$name'" }
    Write-Host "[$name] connecting (PowerShell Direct)..."
    $session = New-PSSession -VMName $name -Credential $cred
    try {
        if ($Uninstall) {
            Invoke-Command -Session $session -ScriptBlock {
                $u = "$env:ProgramData\Easy-GPU-P\GpuPvFix\Uninstall-Guest.ps1"
                if (Test-Path $u) { Set-ExecutionPolicy -Scope Process Bypass -Force; & $u } else { "Not installed." }
            }
            continue
        }

        Invoke-Command -Session $session -ScriptBlock {
            param($dir)
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item $dir -ItemType Directory -Force | Out-Null
        } -ArgumentList $staging
        Copy-Item -ToSession $session -Path (Join-Path $source "*") -Destination $staging -Recurse -Force

        Invoke-Command -Session $session -ScriptBlock {
            param($dir, $reset)
            Set-ExecutionPolicy -Scope Process Bypass -Force
            try { & "$dir\Install-Guest.ps1" -SourceDir $dir -ResetConfig:$reset }
            finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        } -ArgumentList $staging, [bool]$ResetConfig

        Write-Host "[$name] done." -ForegroundColor Green
    } finally {
        Remove-PSSession $session
    }
}

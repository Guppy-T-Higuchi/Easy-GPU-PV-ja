# GPU-PV Fix - uninstaller (run INSIDE the VM as Administrator or SYSTEM)

param([switch]$KeepLogs)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$isAdmin) { throw "Uninstall-Guest.ps1 must run as Administrator (or SYSTEM)." }

$InstallDir = Join-Path $env:ProgramData "Easy-GPU-P\GpuPvFix"
$TaskPath   = "\Easy-GPU-P\"

Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-ScheduledTask -TaskPath $TaskPath -TaskName $_.TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $_.TaskName -Confirm:$false
}
Get-Process -Name GpuPvProbe -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*Easy-GPU-P\GpuPvFix\Monitor.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
if (Test-Path $InstallDir) { & icacls.exe $InstallDir /reset /T /C /Q | Out-Null }   # repair ACLs so everything can be deleted

if ($KeepLogs) {
    Get-ChildItem $InstallDir -Exclude logs -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
} else {
    # The uninstaller itself lives in $InstallDir; deleting the folder while it runs is fine for PowerShell scripts.
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    $parent = Split-Path $InstallDir
    if ((Test-Path $parent) -and !(Get-ChildItem $parent)) { Remove-Item $parent -Force }
}
Write-Host "GPU-PV Fix removed."

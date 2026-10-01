# GPU-PV Fix - installer (run INSIDE the VM as Administrator or SYSTEM).
# Safe to re-run: stops the running instance, updates files, keeps an existing config.json.
#
#   Install-Guest.ps1                 install / update from this folder
#   Install-Guest.ps1 -ResetConfig    also overwrite config.json with the default

param(
    [string]$SourceDir = $PSScriptRoot,
    [switch]$ResetConfig
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$isAdmin) { throw "Install-Guest.ps1 must run as Administrator (or SYSTEM)." }

$InstallDir = Join-Path $env:ProgramData "Easy-GPU-P\GpuPvFix"
$TaskPath   = "\Easy-GPU-P\"
$UsersSid   = New-Object Security.Principal.SecurityIdentifier "S-1-5-32-545"
$UsersGroup = $UsersSid.Translate([Security.Principal.NTAccount]).Value

Write-Host "Installing GPU-PV Fix to $InstallDir"

# 1. stop the running instance
Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-ScheduledTask -TaskPath $TaskPath -TaskName $_.TaskName -ErrorAction SilentlyContinue
}
Get-Process -Name GpuPvProbe -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*Easy-GPU-P\GpuPvFix\Monitor.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

# 2. files + ACLs (SYSTEM runs Monitor.ps1 from here, so users must not be able to modify it)
foreach ($d in @($InstallDir, "$InstallDir\bin", "$InstallDir\state", "$InstallDir\logs")) {
    New-Item $d -ItemType Directory -Force | Out-Null
}
if ((Resolve-Path $SourceDir).Path.TrimEnd('\') -ne (Resolve-Path $InstallDir).Path.TrimEnd('\')) {
    foreach ($f in "GpuPvFix.psm1", "Monitor.ps1", "Check.ps1", "GpuPvProbe.cs", "Install-Guest.ps1", "Uninstall-Guest.ps1", "README.md") {
        if (Test-Path (Join-Path $SourceDir $f)) { Copy-Item (Join-Path $SourceDir $f) $InstallDir -Force }
    }
    if ($ResetConfig -or !(Test-Path "$InstallDir\config.json")) {
        Copy-Item (Join-Path $SourceDir "config.json") $InstallDir -Force
    }
}
& icacls.exe $InstallDir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" /T /C /Q | Out-Null
& icacls.exe "$InstallDir\state" /grant "*S-1-5-32-545:(OI)(CI)M" /T /C /Q | Out-Null
Remove-Item "$InstallDir\state\*" -Force -ErrorAction SilentlyContinue

# 3. build GpuPvProbe.exe with the C# compiler that ships with .NET Framework (separate process: no type clash on re-install)
$exe = "$InstallDir\bin\GpuPvProbe.exe"
$compile = "Add-Type -TypeDefinition (Get-Content -LiteralPath '$InstallDir\GpuPvProbe.cs' -Raw) -OutputAssembly '$exe' -OutputType WindowsApplication -ReferencedAssemblies System.Windows.Forms"
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $compile
if ($LASTEXITCODE -ne 0 -or !(Test-Path $exe)) { throw "Failed to compile GpuPvProbe.exe" }

# 4. scheduled tasks
Import-Module "$InstallDir\GpuPvFix.psm1" -Force
$cfg = Get-GpuPvFixConfig
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Hidden `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask -TaskPath $TaskPath -TaskName "GpuPvFix Monitor" -Settings $settings `
    -Description "GPU-PV Fix: keeps OpenGL/Vulkan on the GPU-PV adapter (monitor, SYSTEM)" `
    -Action (New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\Monitor.ps1`"") `
    -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Principal (New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest) | Out-Null

Register-ScheduledTask -TaskPath $TaskPath -TaskName "GpuPvFix Probe" -Settings $settings `
    -Description "GPU-PV Fix: OpenGL/Vulkan/display probe in each user session" `
    -Action (New-ScheduledTaskAction -Execute $exe `
        -Argument ("--state-dir `"{0}`" --interval-min {1}" -f "$InstallDir\state", [int]$cfg.ProbeIntervalMinutes)) `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
    -Principal (New-ScheduledTaskPrincipal -GroupId $UsersGroup -RunLevel Limited) | Out-Null

# 5. start now (also for users that are already logged on)
Start-ScheduledTask -TaskPath $TaskPath -TaskName "GpuPvFix Monitor"
foreach ($s in Get-GpuPvFixUserSessions) {
    Write-Host "Starting probe in session $($s.SessionId) ($($s.User))"
    try { Start-GpuPvProbeForUser -User $s.User } catch { Write-Warning "  $($_.Exception.Message)" }
}

Write-GpuPvFixLog "installed/updated from $SourceDir"
Write-Host "Done. Check status with: powershell -ExecutionPolicy Bypass -File `"$InstallDir\Check.ps1`""

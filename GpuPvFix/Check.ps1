# GPU-PV Fix - manual check (run inside the VM, e.g. right before connecting with Parsec)
#
#   Check.ps1          probe OpenGL/Vulkan in this session and show device / monitor status
#   Check.ps1 -Fix     also run the remediation steps now (administrator required)
#   Check.ps1 -Log 50  show the last 50 monitor log lines

param([switch]$Fix, [int]$Log = 15)

Import-Module (Join-Path $PSScriptRoot "GpuPvFix.psm1") -Force
$cfg = Get-GpuPvFixConfig

Write-Host "== Display devices" -ForegroundColor Cyan
Get-GpuPvFixDisplayDevices -Config $cfg | Format-Table Kind, Name, Ok, ErrorCode, InstanceId -AutoSize | Out-String | Write-Host

Write-Host "== Probe (this session)" -ForegroundColor Cyan
if (!(Test-Path $ProbeExe)) { Write-Host "GpuPvProbe.exe not found: $ProbeExe" -ForegroundColor Red; exit 1 }
$tmp = Join-Path $env:TEMP "gpupvfix-probe-$PID.json"
$p = Start-Process $ProbeExe -ArgumentList "--once", "--reason", "check", "--out", "`"$tmp`"" -Wait -PassThru -WindowStyle Hidden
$probe = Get-Content $tmp -Raw | ConvertFrom-Json
Remove-Item $tmp -ErrorAction SilentlyContinue
$t = Test-GpuPvProbe -Probe $probe -Config $cfg
Write-Host ("OpenGL : {0}  {1} / {2} / {3} {4}" -f $(if ($probe.opengl.ok) {"OK"} else {"NG"}), $probe.opengl.vendor, $probe.opengl.renderer, $probe.opengl.version, $probe.opengl.error)
Write-Host ("Vulkan : {0}  {1} {2}" -f $(if ($probe.vulkan.ok) {"OK"} else {"NG"}), (($probe.vulkan.devices | ForEach-Object { "$($_.name) [$($_.type)]" }) -join ", "), $probe.vulkan.error)
Write-Host "Attached displays:"
$probe.displays | Where-Object attached | ForEach-Object { Write-Host ("  {0} {1}{2}" -f $_.deviceName, $_.adapter, $(if ($_.primary) {" (primary)"} else {""})) }
Write-Host ("Result : {0}" -f $(if ($t.Ok) {"OK"} else {"NG"})) -ForegroundColor $(if ($t.Ok) {"Green"} else {"Red"})

Write-Host "`n== Background tasks" -ForegroundColor Cyan
Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | Format-Table TaskName, State -AutoSize | Out-String | Write-Host
Write-Host "Resident probe sessions: $((Get-GpuPvProbeSessions) -join ', ')"

if ($Log -gt 0 -and (Test-Path (Join-Path $LogDir "monitor.log"))) {
    Write-Host "`n== monitor.log (last $Log)" -ForegroundColor Cyan
    Get-Content (Join-Path $LogDir "monitor.log") -Tail $Log | Write-Host
}

if ($Fix) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$isAdmin) { Write-Host "`n-Fix requires an elevated PowerShell." -ForegroundColor Red; exit 1 }
    Write-Host "`n== Remediation" -ForegroundColor Cyan
    Write-GpuPvFixLog "manual remediation requested by $env:USERNAME"
    $ok = Invoke-GpuPvFixRemediation -Config $cfg
    Get-Content (Join-Path $LogDir "monitor.log") -Tail 12 | Write-Host
    Write-Host ("Remediation: {0}" -f $(if ($ok) {"OK"} else {"not restored"})) -ForegroundColor $(if ($ok) {"Green"} else {"Red"})
}

if (-not $t.Ok) { exit 2 }

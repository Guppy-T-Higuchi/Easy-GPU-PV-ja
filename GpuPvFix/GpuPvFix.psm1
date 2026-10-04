# GPU-PV Fix - shared functions for Monitor.ps1 / Check.ps1 / Install-Guest.ps1

$script:Root     = $PSScriptRoot
$script:StateDir = Join-Path $PSScriptRoot "state"
$script:LogDir   = Join-Path $PSScriptRoot "logs"
$script:ProbeExe = Join-Path $PSScriptRoot "bin\GpuPvProbe.exe"
$script:TaskPath = "\Easy-GPU-P\"

$script:DefaultConfig = [ordered]@{
    MonitorIntervalSeconds   = 30
    ProbeIntervalMinutes     = 15
    CheckOpenGL              = $true
    CheckVulkan              = $true
    EnsureHyperVVideoEnabled = $true
    Remediate                = $true
    RemediationSteps         = @("scan-devices", "restart-hyperv-video")
    CooldownMinutes          = 5
    MaxRemediationsPerBoot   = 3
    GpuNamePattern           = ""
}

function Get-GpuPvFixConfig {
    $cfg = [ordered]@{}
    foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
    $path = Join-Path $script:Root "config.json"
    if (Test-Path $path) {
        try {
            $json = Get-Content $path -Raw | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch {
            Write-GpuPvFixLog "config.json is invalid, using defaults: $($_.Exception.Message)"
        }
    }
    [pscustomobject]$cfg
}

function Write-GpuPvFixLog {
    param([string]$Message, [string]$Name = "monitor.log")
    try {
        if (!(Test-Path $script:LogDir)) { New-Item $script:LogDir -ItemType Directory -Force | Out-Null }
        $path = Join-Path $script:LogDir $Name
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 1MB) { Move-Item $path "$path.1" -Force }
        Add-Content -Path $path -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8
    } catch {}
}

# ------------------------------------------------------------------ devices

function Get-GpuPvFixDeviceKind {
    # Classifies by driver service / device ID, not by name: names are localized
    # ("Microsoft Hyper-V ビデオ") and the GPU-PV adapter reports Microsoft's vendor ID (PCI\VEN_1414).
    param([string]$Name, [string]$InstanceId, [string]$Service, $Config)
    if ($Service -eq "HyperVideo" -or $InstanceId -like "VMBUS\{DA0A7802-E377-4AAC-8E77-0558EB1073F8}*") { return "HyperVVideo" }
    if ($Service -eq "BasicDisplay") { return "BasicDisplay" }
    if ($Name -like "*Parsec*") { return "ParsecVdd" }
    if ($Config.GpuNamePattern) { if ($Name -match $Config.GpuNamePattern) { return "Gpu" } else { return "Other" } }
    if ($InstanceId -like "PCI\*") { return "Gpu" }
    "Other"
}

function Get-GpuPvFixDisplayDevices {
    param($Config = (Get-GpuPvFixConfig))
    Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" | ForEach-Object {
        $name = [string]$_.Name
        [pscustomobject]@{
            Kind       = Get-GpuPvFixDeviceKind -Name $name -InstanceId $_.PNPDeviceID -Service $_.Service -Config $Config
            Name       = $name
            Service    = [string]$_.Service
            InstanceId = [string]$_.PNPDeviceID
            ErrorCode  = [int]$_.ConfigManagerErrorCode   # 0 = OK, 22 = disabled
            Ok         = ($_.ConfigManagerErrorCode -eq 0)
        }
    }
}

# ------------------------------------------------------------------ sessions / probe processes

function Get-GpuPvFixUserSessions {
    # Interactive sessions = sessions that have an explorer.exe
    $seen = @{}
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='explorer.exe'") {
        if ($seen.ContainsKey($p.SessionId)) { continue }
        $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($o -and $o.User) {
            $seen[$p.SessionId] = $true
            [pscustomobject]@{ SessionId = [int]$p.SessionId; User = "$($o.Domain)\$($o.User)" }
        }
    }
}

function Get-GpuPvProbeSessions {
    @(Get-Process -Name GpuPvProbe -ErrorAction SilentlyContinue | ForEach-Object { $_.SessionId } | Sort-Object -Unique)
}

function Start-GpuPvProbeForUser {
    # Starts the resident probe in an already logged-on user's session via a per-user interactive task.
    param([Parameter(Mandatory)][string]$User)
    $taskName = "GpuPvFix Probe ($($User -replace '[\\/:*?""<>|]', '_'))"
    $cfg = Get-GpuPvFixConfig
    $action = New-ScheduledTaskAction -Execute $script:ProbeExe `
        -Argument ("--state-dir `"{0}`" --interval-min {1}" -f $script:StateDir, [int]$cfg.ProbeIntervalMinutes)
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Hidden
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $taskName -Action $action `
        -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $taskName
}

# ------------------------------------------------------------------ probe results

function ConvertTo-GpuPvFixUtc($value) {
    if ($value -is [datetime]) { return $value.ToUniversalTime() }
    [datetime]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Request-GpuPvProbe {
    $now = (Get-Date).ToUniversalTime()
    Set-Content -Path (Join-Path $script:StateDir "request.txt") -Value $now.ToString("o")
    $now
}

function Get-GpuPvProbeResults {
    # Latest result per session that currently has a resident probe running.
    foreach ($sid in Get-GpuPvProbeSessions) {
        $path = Join-Path $script:StateDir "probe-$sid.json"
        if (!(Test-Path $path)) { continue }
        try {
            $r = Get-Content $path -Raw | ConvertFrom-Json
            $r | Add-Member -NotePropertyName TimestampUtc -NotePropertyValue (ConvertTo-GpuPvFixUtc $r.timestampUtc) -Force
            $r
        } catch {}
    }
}

function Wait-GpuPvProbe {
    param([datetime]$SinceUtc, [int]$TimeoutSeconds = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $sessions = Get-GpuPvProbeSessions
        $fresh = @(Get-GpuPvProbeResults | Where-Object { $_.TimestampUtc -gt $SinceUtc })
        if ($sessions.Count -gt 0 -and $fresh.Count -ge $sessions.Count) { return $fresh }
    } while ((Get-Date) -lt $deadline)
    @(Get-GpuPvProbeResults | Where-Object { $_.TimestampUtc -gt $SinceUtc })
}

function Test-GpuPvProbe {
    # Returns { Ok, Remediable, Summary } for one probe result.
    param($Probe, $Config = (Get-GpuPvFixConfig))
    $gl = $Probe.opengl; $vk = $Probe.vulkan
    $glBad = $Config.CheckOpenGL -and -not $gl.ok
    $vkBad = $Config.CheckVulkan -and -not $vk.ok
    # A missing Vulkan loader is a driver-file problem (re-run Update-VMGpuPartitionDriver.ps1), not a display problem.
    $remediable = $glBad -or ($vkBad -and $vk.loader)
    $glText = if ($gl.ok) { "GL ok ($($gl.renderer))" } else { "GL NG ($($gl.error); renderer=$($gl.renderer))" }
    $vkText = if ($vk.ok) { "VK ok ($(($vk.devices | ForEach-Object name) -join ', '))" } else { "VK NG ($($vk.error))" }
    if ($Probe.error) { $glText = "probe error: $($Probe.error); $glText"; $remediable = $true }
    [pscustomobject]@{
        Ok         = -not ($glBad -or $vkBad -or $Probe.error)
        Remediable = [bool]$remediable
        Summary    = "session $($Probe.sessionId) [$($Probe.user)] $glText; $vkText"
    }
}

# ------------------------------------------------------------------ remediation

function Enable-GpuPvFixHyperVVideo {
    param($Config = (Get-GpuPvFixConfig))
    $hv = Get-GpuPvFixDisplayDevices -Config $Config | Where-Object Kind -eq "HyperVVideo"
    foreach ($d in $hv | Where-Object ErrorCode -eq 22) {
        Write-GpuPvFixLog "Hyper-V Video is disabled -> enabling ($($d.InstanceId))"
        Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Continue
        return $true
    }
    $false
}

function Invoke-GpuPvFixRemediationStep {
    param([string]$Step, $Config)
    switch ($Step) {
        "scan-devices" {
            $out = & pnputil.exe /scan-devices 2>&1
            Write-GpuPvFixLog "  pnputil /scan-devices -> exit $LASTEXITCODE $(($out | Out-String).Trim() -replace '\s+', ' ')"
        }
        "restart-hyperv-video" {
            foreach ($d in Get-GpuPvFixDisplayDevices -Config $Config | Where-Object Kind -eq "HyperVVideo") {
                $out = & pnputil.exe /restart-device "$($d.InstanceId)" 2>&1
                Write-GpuPvFixLog "  pnputil /restart-device $($d.InstanceId) -> exit $LASTEXITCODE $(($out | Out-String).Trim() -replace '\s+', ' ')"
                if ($LASTEXITCODE -ne 0) {
                    Write-GpuPvFixLog "  fallback: Disable/Enable-PnpDevice"
                    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Continue
                    Start-Sleep -Seconds 2
                    Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Continue
                }
            }
        }
        default { Write-GpuPvFixLog "  unknown remediation step '$Step' (ignored)" }
    }
}

function Invoke-GpuPvFixRemediation {
    # Runs the configured steps in order, re-probing after each; stops at the first step that fixes things.
    param($Config = (Get-GpuPvFixConfig))
    foreach ($step in @($Config.RemediationSteps)) {
        Write-GpuPvFixLog "remediation step: $step"
        Invoke-GpuPvFixRemediationStep -Step $step -Config $Config
        Start-Sleep -Seconds 3
        $since = Request-GpuPvProbe
        $results = @(Wait-GpuPvProbe -SinceUtc $since)
        if ($results.Count -eq 0) { Write-GpuPvFixLog "  no fresh probe result after '$step'"; continue }
        $tests = @($results | ForEach-Object { Test-GpuPvProbe -Probe $_ -Config $Config })
        $tests | ForEach-Object { Write-GpuPvFixLog "  $($_.Summary)" }
        if (@($tests | Where-Object { -not $_.Ok }).Count -eq 0) {
            Write-GpuPvFixLog "remediation succeeded after '$step'"
            return $true
        }
    }
    Write-GpuPvFixLog "remediation did not restore OpenGL/Vulkan"
    $false
}

Export-ModuleMember -Function * -Variable Root, StateDir, LogDir, ProbeExe, TaskPath

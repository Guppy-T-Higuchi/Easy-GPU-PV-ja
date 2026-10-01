# GPU-PV Fix - monitor (runs as SYSTEM from the "\Easy-GPU-P\GpuPvFix Monitor" task at startup)
#
# Every MonitorIntervalSeconds:
#   - checks the GPU-PV adapter and Microsoft Hyper-V Video in Device Manager
#   - makes sure the user-session probe (GpuPvProbe.exe) runs in every logged-on session
#   - reads the probe results (OpenGL / Vulkan / display topology)
#   - if OpenGL/Vulkan fell back to software, re-initializes the display path (rate limited)

Import-Module (Join-Path $PSScriptRoot "GpuPvFix.psm1") -Force

$cfg = Get-GpuPvFixConfig
$remediations = 0
$lastActionUtc = [datetime]::MinValue
$lastStatus = $null
$lastHeartbeat = Get-Date
$probeStartAttempts = @{}
$gaveUpLogged = $false

Write-GpuPvFixLog "monitor started (pid $PID, interval $($cfg.MonitorIntervalSeconds)s, remediate=$($cfg.Remediate))"

while ($true) {
    try {
        $devices = @(Get-GpuPvFixDisplayDevices -Config $cfg)
        $gpu = @($devices | Where-Object Kind -eq "Gpu")
        $hv  = @($devices | Where-Object Kind -eq "HyperVVideo")

        # Hyper-V Video must stay enabled: it is the display path GPU-PV OpenGL/Vulkan relies on.
        if ($cfg.EnsureHyperVVideoEnabled -and @($hv | Where-Object ErrorCode -eq 22).Count -gt 0 -and
            ((Get-Date).ToUniversalTime() - $lastActionUtc).TotalMinutes -ge $cfg.CooldownMinutes) {
            if (Enable-GpuPvFixHyperVVideo -Config $cfg) { $lastActionUtc = (Get-Date).ToUniversalTime(); Request-GpuPvProbe | Out-Null }
        }

        # Keep a resident probe in every interactive session (normally started by the logon task).
        $probeSessions = Get-GpuPvProbeSessions
        foreach ($s in Get-GpuPvFixUserSessions) {
            if ($probeSessions -contains $s.SessionId) { continue }
            $last = $probeStartAttempts[$s.SessionId]
            if ($last -and ((Get-Date) - $last).TotalMinutes -lt 5) { continue }
            $probeStartAttempts[$s.SessionId] = Get-Date
            Write-GpuPvFixLog "probe not running in session $($s.SessionId) ($($s.User)) -> starting"
            try { Start-GpuPvProbeForUser -User $s.User } catch { Write-GpuPvFixLog "  failed: $($_.Exception.Message)" }
        }

        $tests = @(Get-GpuPvProbeResults | ForEach-Object { Test-GpuPvProbe -Probe $_ -Config $cfg })
        $bad = @($tests | Where-Object { -not $_.Ok })

        $gpuText = if ($gpu.Count -eq 0) { "GPU missing" } else { ($gpu | ForEach-Object { "$($_.Name)=$(if ($_.Ok) {'OK'} else {"err$($_.ErrorCode)"})" }) -join ", " }
        $hvText  = if ($hv.Count -eq 0) { "HyperV Video missing" } else { ($hv | ForEach-Object { "HyperV Video=$(if ($_.Ok) {'OK'} else {"err$($_.ErrorCode)"})" }) -join ", " }
        $status  = "$gpuText | $hvText | " + $(if ($tests.Count) { ($tests | ForEach-Object Summary) -join " / " } else { "no probe results" })
        if ($status -ne $lastStatus -or ((Get-Date) - $lastHeartbeat).TotalHours -ge 1) {
            Write-GpuPvFixLog "status: $status"
            $lastStatus = $status
            $lastHeartbeat = Get-Date
        }

        $canAct = $cfg.Remediate -and
                  @($gpu | Where-Object Ok).Count -gt 0 -and              # nothing to re-route to without a working GPU-PV adapter
                  @($bad | Where-Object Remediable).Count -gt 0 -and
                  ((Get-Date).ToUniversalTime() - $lastActionUtc).TotalMinutes -ge $cfg.CooldownMinutes

        if ($canAct) {
            if ($remediations -ge $cfg.MaxRemediationsPerBoot) {
                if (!$gaveUpLogged) { Write-GpuPvFixLog "MaxRemediationsPerBoot ($($cfg.MaxRemediationsPerBoot)) reached; monitoring only until reboot"; $gaveUpLogged = $true }
            } else {
                $remediations++
                Write-GpuPvFixLog "OpenGL/Vulkan NG -> remediation #$remediations"
                Invoke-GpuPvFixRemediation -Config $cfg | Out-Null
                $lastActionUtc = (Get-Date).ToUniversalTime()
                $lastStatus = $null
            }
        }
    } catch {
        Write-GpuPvFixLog "monitor error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds ([Math]::Max(5, [int]$cfg.MonitorIntervalSeconds))
}

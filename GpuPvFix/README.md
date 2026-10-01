# GPU-PV Fix

A small guest-side watcher for GPU-PV VMs. It detects when OpenGL / Vulkan stop using the GPU-PV adapter (falling back to software rendering, e.g. after VMConnect is closed) and tries to recover by re-initializing the Hyper-V display path.

## Components

| Component | Runs as | Role |
|---|---|---|
| `GpuPvProbe.exe` (resident) | Each user session (started at logon) | Starts a probe on display changes, device changes, session connect/disconnect, a timer (15 min by default) and requests from the monitor. The resident process never loads GPU drivers itself (~30 MB) |
| `GpuPvProbe.exe --once` | Short-lived child of the above | Creates an OpenGL context (reads `GL_RENDERER`), enumerates Vulkan physical devices and displays, and writes `state\probe-<sessionId>.json` |
| `Monitor.ps1` | SYSTEM (startup task) | Every 30 s checks the GPU-PV adapter, Microsoft Hyper-V Video and the probe results, and runs the remediation steps when needed |
| `Check.ps1` | Manual | Check (and optionally fix) right before connecting with Parsec |

`GpuPvProbe.exe` is compiled inside the guest from `GpuPvProbe.cs` at install time, using the C# compiler that ships with .NET Framework. No binaries are distributed.

## Detection

- OpenGL NG: context creation fails, or the renderer is a software implementation (`GDI Generic`, etc.)
- Vulkan NG: no non-CPU physical device is found
- A missing `vulkan-1.dll` is treated as a driver file problem, not a display problem, so no remediation is attempted (re-run `Update-VMGpuPartitionDriver.ps1`)

## Remediation

The steps in `RemediationSteps` are run in order. After each step the probe runs again, and remediation stops as soon as everything is OK.

1. `scan-devices`: `pnputil /scan-devices` (device rescan, no visible effect)
2. `restart-hyperv-video`: restarts Microsoft Hyper-V Video with `pnputil /restart-device` (falls back to disable/enable). The screen may flicker briefly.

Safeguards:

- At least `CooldownMinutes` (default 5) between remediations
- At most `MaxRemediationsPerBoot` (default 3) remediations per boot
- Nothing is done while the GPU-PV adapter itself is missing or in an error state
- With `EnsureHyperVVideoEnabled`, a disabled Hyper-V Video device is re-enabled

## Install

### Existing VM (from the host)

Run from the repository root in an elevated PowerShell. The VM must be running.

```powershell
.\Install-GpuPvFix.ps1 -VMName "GPU-P"
```

- You will be asked for an administrator account inside the VM (PowerShell Direct)
- Re-running updates the installation and keeps an existing `config.json` (`-ResetConfig` to overwrite it)
- Uninstall: `.\Install-GpuPvFix.ps1 -VMName "GPU-P" -Uninstall`

### Inside the VM

Copy this folder into the VM and run from an elevated PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Guest.ps1
```

## Check / manual fix (inside the VM)

```powershell
# Show status and probe OpenGL/Vulkan in this session
powershell -ExecutionPolicy Bypass -File C:\ProgramData\Easy-GPU-P\GpuPvFix\Check.ps1

# Run the remediation steps now (elevated)
powershell -ExecutionPolicy Bypass -File C:\ProgramData\Easy-GPU-P\GpuPvFix\Check.ps1 -Fix
```

Logs:

- `C:\ProgramData\Easy-GPU-P\GpuPvFix\logs\monitor.log`: status changes and remediation (written on change plus an hourly heartbeat)
- `C:\ProgramData\Easy-GPU-P\GpuPvFix\state\probe-<sessionId>.json`: latest probe result
- `C:\ProgramData\Easy-GPU-P\GpuPvFix\state\probe-<sessionId>.log`: probe history

## Configuration (config.json)

After editing, re-run `Install-Guest.ps1` or reboot the VM.

| Key | Default | Description |
|---|---|---|
| `MonitorIntervalSeconds` | 30 | Monitor check interval |
| `ProbeIntervalMinutes` | 15 | Periodic probe when no events occur (0 = off) |
| `CheckOpenGL` / `CheckVulkan` | true | APIs used for the OK/NG decision |
| `EnsureHyperVVideoEnabled` | true | Re-enable a disabled Hyper-V Video device |
| `Remediate` | true | `false` = detect and log only |
| `RemediationSteps` | `scan-devices`, `restart-hyperv-video` | Steps and their order |
| `CooldownMinutes` | 5 | Minimum time between remediations |
| `MaxRemediationsPerBoot` | 3 | Remediation limit per boot |
| `GpuNamePattern` | empty | Regex for the GPU-PV adapter name (empty = auto-detect) |

## Notes

- The `state` folder is writable by standard users (the probe writes its results there). A standard user in the same VM could therefore write a fake result and trigger a remediation (device restart). The cooldown and per-boot limit keep the impact small.
- Parsec's virtual display is managed by Parsec. This tool only re-probes when the display layout changes on connect.

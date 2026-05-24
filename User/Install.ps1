$flagFile = "C:\ProgramData\Easy-GPU-P\.setup_done"
if (Test-Path $flagFile) { exit 0 }
New-Item -Path $flagFile -ItemType File -Force | Out-Null

$maxWait = 120
$waited = 0
while ($waited -lt $maxWait) {
    $connected = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Measure-Object).Count -gt 0
    if ($connected) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect("8.8.8.8", 53, $null, $null)
            $ok = $async.AsyncWaitHandle.WaitOne(3000, $false)
            $tcp.Close()
            if ($ok) { break }
        } catch {}
    }
    Start-Sleep -Seconds 5
    $waited += 5
}

Get-ChildItem -Path C:\ProgramData\Easy-GPU-P -Recurse | Unblock-File

Function VBCableInstallSetupScheduledTask {
$XML = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Install VB Cable</Description>
    <URI>\Install VB Cable</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$(([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name)</UserId>
      <Delay>PT1M</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>C:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>-ExecutionPolicy Bypass -File "C:\ProgramData\Easy-GPU-P\VBCableInstall.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    try {
        Get-ScheduledTask -TaskName "Install VB Cable" -ErrorAction Stop | Out-Null
        Unregister-ScheduledTask -TaskName "Install VB Cable" -Confirm:$false
        }
    catch {}
    Register-ScheduledTask -XML $XML -TaskName "Install VB Cable" | Out-Null
    }


VBCableInstallSetupScheduledTask

Start-ScheduledTask -TaskName "Install VB Cable"

Start-Process -FilePath "C:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList '-ExecutionPolicy Bypass -File "C:\ProgramData\Easy-GPU-P\SteamInstall.ps1"' `
    -WindowStyle Hidden

Start-Process -FilePath "C:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList '-ExecutionPolicy Bypass -File "C:\ProgramData\Easy-GPU-P\ParsecInstall.ps1"' `
    -WindowStyle Hidden

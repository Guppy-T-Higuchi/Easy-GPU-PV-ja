# Remove the HKCU Run key first (no elevation needed)
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "EasyGPUPSetup" -ErrorAction SilentlyContinue

$flagFile = "C:\ProgramData\Easy-GPU-P\.setup_done"
if (Test-Path $flagFile) { exit 0 }

# Wait for network connectivity
$maxWait = 180
$waited = 0
while ($waited -lt $maxWait) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect("8.8.8.8", 53, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(3000, $false)
        $tcp.Close()
        if ($ok) { break }
    } catch {}
    Start-Sleep -Seconds 5
    $waited += 5
}

Get-ChildItem -Path C:\ProgramData\Easy-GPU-P -Recurse | Unblock-File

function New-SetupScheduledTask {
    param(
        [string]$TaskName,
        [string]$ScriptPath,
        [string]$Description
    )

    $userId   = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name
    $userSid  = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value

    $XML = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$Description</Description>
    <URI>\$TaskName</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$userId</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$userSid</UserId>
      <LogonType>S4U</LogonType>
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
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>-ExecutionPolicy Bypass -File "$ScriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    try {
        Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    } catch {}

    Register-ScheduledTask -XML $XML -TaskName $TaskName | Out-Null
}

New-SetupScheduledTask -TaskName "Easy-GPU-P Install VBCable" `
    -ScriptPath "C:\ProgramData\Easy-GPU-P\VBCableInstall.ps1" `
    -Description "Install VB-Audio Virtual Cable"

New-SetupScheduledTask -TaskName "Easy-GPU-P Install Steam" `
    -ScriptPath "C:\ProgramData\Easy-GPU-P\SteamInstall.ps1" `
    -Description "Install Steam"

New-SetupScheduledTask -TaskName "Easy-GPU-P Install Parsec" `
    -ScriptPath "C:\ProgramData\Easy-GPU-P\ParsecInstall.ps1" `
    -Description "Install Parsec"

Start-ScheduledTask -TaskName "Easy-GPU-P Install VBCable"
Start-ScheduledTask -TaskName "Easy-GPU-P Install Steam"
Start-ScheduledTask -TaskName "Easy-GPU-P Install Parsec"

New-Item -Path $flagFile -ItemType File -Force | Out-Null

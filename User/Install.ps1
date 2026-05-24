# Delete this task immediately so it doesn't re-run on every subsequent logon
schtasks /delete /tn "EasyGPUPSetup" /f 2>$null

$flagFile = "C:\ProgramData\Easy-GPU-P\.setup_done"
if (Test-Path $flagFile) { exit 0 }

# Wait for network connectivity (max 3 minutes)
$maxWait = 180
$waited  = 0
while ($waited -lt $maxWait) {
    try {
        $tcp   = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect("8.8.8.8", 53, $null, $null)
        $ok    = $async.AsyncWaitHandle.WaitOne(3000, $false)
        $tcp.Close()
        if ($ok) { break }
    } catch {}
    Start-Sleep -Seconds 5
    $waited += 5
}

Get-ChildItem -Path C:\ProgramData\Easy-GPU-P -Recurse | Unblock-File

# Run each install script directly — running as SYSTEM, no UAC needed
& "C:\ProgramData\Easy-GPU-P\VBCableInstall.ps1"
& "C:\ProgramData\Easy-GPU-P\SteamInstall.ps1"
& "C:\ProgramData\Easy-GPU-P\ParsecInstall.ps1"

New-Item -Path $flagFile -ItemType File -Force | Out-Null

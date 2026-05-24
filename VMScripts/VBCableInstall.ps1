if (!(Get-WmiObject Win32_SoundDevice | Where-Object name -like "VB-Audio Virtual Cable")) {
    $tmpDir  = Join-Path $env:TEMP "VBCable"
    $zipPath = Join-Path $env:TEMP "VBCable.zip"

    (New-Object System.Net.WebClient).DownloadFile(
        "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip",
        $zipPath
    )
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $tmpDir
    Remove-Item $zipPath -ErrorAction SilentlyContinue

    $catFile  = Join-Path $tmpDir "vbaudio_cable64_win7.cat"
    $certFile = Join-Path $tmpDir "VBCert.cer"

    $VB = @{}
    $VB.DriverFile = $catFile
    $VB.CertName   = $certFile
    $VB.ExportType = [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert
    $VB.Cert       = (Get-AuthenticodeSignature -FilePath $VB.DriverFile).SignerCertificate
    [System.IO.File]::WriteAllBytes($VB.CertName, $VB.Cert.Export($VB.ExportType))

    while (((Get-ChildItem Cert:\LocalMachine\TrustedPublisher) | Where-Object { $_.Subject -like '*Vincent Burel*' }) -eq $null) {
        certutil -Enterprise -Addstore "TrustedPublisher" $VB.CertName
        Start-Sleep -Seconds 5
    }

    Start-Process -FilePath (Join-Path $tmpDir "VBCABLE_Setup_x64.exe") -ArgumentList '-i', '-h' -Wait

    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

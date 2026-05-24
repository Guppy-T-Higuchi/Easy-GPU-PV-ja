if (!(Test-Path "C:\Program Files\Parsec\parsecd.exe")) {
    $installer = "$env:TEMP\parsec-windows.exe"
    try {
        (New-Object System.Net.WebClient).DownloadFile(
            "https://builds.parsec.app/package/parsec-windows.exe",
            $installer
        )
        Start-Process -FilePath $installer -ArgumentList '/S' -Wait
    } finally {
        Remove-Item $installer -ErrorAction SilentlyContinue
    }
}

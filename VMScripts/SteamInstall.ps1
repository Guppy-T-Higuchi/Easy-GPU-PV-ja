if (!(Test-Path "C:\Program Files (x86)\Steam\Steam.exe")) {
    $installer = "$env:TEMP\SteamSetup.exe"
    try {
        (New-Object System.Net.WebClient).DownloadFile(
            "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe",
            $installer
        )
        Start-Process -FilePath $installer -ArgumentList '/S' -Wait
    } finally {
        Remove-Item $installer -ErrorAction SilentlyContinue
    }
}

$steamExe = "C:\Program Files (x86)\Steam\Steam.exe"
$shortcutPath = "$env:PUBLIC\Desktop\Steam.lnk"
if ((Test-Path $steamExe) -and !(Test-Path $shortcutPath)) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $steamExe
    $shortcut.WorkingDirectory = "C:\Program Files (x86)\Steam"
    $shortcut.Description = "Steam"
    $shortcut.Save()
}

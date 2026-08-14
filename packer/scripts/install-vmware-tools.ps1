$ErrorActionPreference = "Stop"

$isoPath = "C:\Windows\Temp\vmware-tools.iso"

$mount = Mount-DiskImage -ImagePath $isoPath -PassThru
$driveLetter = ($mount | Get-Volume).DriveLetter

$setup = "${driveLetter}:\setup64.exe"
if (-not (Test-Path $setup)) {
    $setup = "${driveLetter}:\setup.exe"
}

Start-Process -FilePath $setup -ArgumentList "/S", "/v", "/qn REBOOT=R" -Wait

Dismount-DiskImage -ImagePath $isoPath
Remove-Item $isoPath -Force

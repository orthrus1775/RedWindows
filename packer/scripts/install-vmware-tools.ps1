$ErrorActionPreference = "Stop"

$isoPath = "C:\Windows\Temp\vmware-tools.iso"

$mount = Mount-DiskImage -ImagePath $isoPath -PassThru
$driveLetter = ($mount | Get-Volume).DriveLetter

$setup = "${driveLetter}:\setup64.exe"
if (-not (Test-Path $setup)) {
    $setup = "${driveLetter}:\setup.exe"
}

# InstallShield's /v switch needs its payload concatenated with no space
# (/v"..."), not passed as a separate argument - splitting them causes
# setup64.exe to fall back to its interactive GUI wizard, which then hangs
# forever with -Wait since nothing is present to click it.
Start-Process -FilePath $setup -ArgumentList "/S", '/v"/qn REBOOT=R"' -Wait

Dismount-DiskImage -ImagePath $isoPath
Remove-Item $isoPath -Force

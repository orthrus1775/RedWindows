# RedWindows
Customized Windows 10 for Red Teams.

> Currently a hot mess and will clean it up later, but it works!
## To run
```powershell
iwr "https://raw.githubusercontent.com/orthrus1775/RedWindows/refs/heads/main/RedWindows.ps1" -OutFile "$env:USERPROFILE\Desktop\RedWindows.ps1"; & "$env:USERPROFILE\Desktop\RedWindows.ps1"

```


## Building a base VM with Packer

`packer/windows10.pkr.hcl` builds a clean, unattended-installed Windows 10 Pro
VM in VMware (`vmware-iso` builder). It does **not** run `RedWindows.ps1` -
this just produces the base OS image; run `RedWindows.ps1` yourself afterward
to install the toolset.

### Prerequisites

- [Packer](https://www.packer.io/downloads) installed and on `PATH`.
- VMware Workstation/Player installed (provides `vmrun.exe`, which the
  `vmware-iso` builder needs).
- A Windows 10 Pro ISO. If your ISO is a different edition, see the comments
  in `packer/http/autounattend.xml` for the image-name / product-key
  selection you'll need to change.

### Build

1. Install the required plugin (one-time, from the `packer/` directory):
   ```
   packer init windows10.pkr.hcl
   ```
2. Copy the example var-file and fill in your ISO details:
   ```
   cp example.pkrvars.hcl local.pkrvars.hcl
   ```
   `local.pkrvars.hcl` is gitignored. Set:
   ```hcl
   iso_url      = "C:/isos/win10pro.iso"
   iso_checksum = "sha256:<hash>"
   ```
   Get the checksum with:
   ```powershell
   Get-FileHash C:\isos\win10pro.iso -Algorithm SHA256
   ```
3. Build:
   ```
   packer build -var-file=local.pkrvars.hcl windows10.pkr.hcl
   ```

The unattended install creates a local admin account (`attacker` /
`GoCyber2026!!` by default - see `packer/http/autounattend.xml` and the
`winrm_username`/`winrm_password` variables in `windows10.pkr.hcl`, which must
stay in sync since the answer file isn't templated by Packer) and enables
WinRM so Packer can connect and finish provisioning.

Defaults: 2 CPUs, 16GB RAM, 150GB disk, VMware window visible
(`headless = false`). Override any of these with `-var` or in your
var-file, e.g. `-var cpus=4 -var headless=true`.

The finished VM lands in `packer/output-redwindows10/`.

### Next step

Boot the built VM and run `RedWindows.ps1` from an elevated PowerShell prompt
to install the red-team toolset.

## Volume shadow copies

`vssadmin create shadow` and `diskshadow` are Server-only - client Windows
(10/11 desktop) doesn't support them, so use one of these instead (elevated
shell required either way):

WMI, from an elevated PowerShell prompt:
```powershell
(Get-WmiObject -List Win32_ShadowCopy).Create("C:\", "ClientAccessible")
```

`wmic` (deprecated, removed by default on newer Windows 11 builds unless the
"WMIC" optional feature is re-enabled - check with `where wmic` first), from
an elevated cmd or PowerShell prompt:
```
wmic shadowcopy call create Volume='C:\'
```

Either way, get the device path and pull files off it:
```powershell
Get-CimInstance Win32_ShadowCopy | Select-Object ID, DeviceObject
```
```
copy \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN\Windows\System32\config\SAM C:\temp\SAM
copy \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN\Windows\System32\config\SYSTEM C:\temp\SYSTEM
```

Clean up when done:
```
vssadmin delete shadows /for=C: /all
```

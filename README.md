# RedWindows
Customized Windows 10 for Red Teams — a winget-first Commando VM-style setup.

`RedWindows.ps1` is a thin staged orchestrator; install logic lives under `lib/`.
The package list is declarative in `packages.json` at the repo root (loaded by `lib/Packages.ps1`).

## To run

Run elevated. Fresh Windows boxes usually don't have Git yet — that's fine; the script installs winget → Git later. Bootstrap by downloading the **full repo ZIP** (needs `RedWindows.ps1`, `lib/`, and `packages.json`), not a single-file `iwr` of the `.ps1` alone:

```powershell
$zip = "$env:TEMP\RedWindows.zip"; $dest = "$env:USERPROFILE\Desktop\RedWindows"
iwr "https://github.com/orthrus1775/RedWindows/archive/refs/heads/main.zip" -OutFile $zip
Expand-Archive $zip $env:TEMP -Force
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Move-Item "$env:TEMP\RedWindows-main" $dest
& "$dest\RedWindows.ps1"
```

If Git is already available:

```powershell
git clone https://github.com/orthrus1775/RedWindows.git
cd RedWindows
.\RedWindows.ps1
```


## Building a base VM with Packer

`packer/windows10.pkr.hcl` builds a clean, unattended-installed Windows 10 Pro
VM in VMware (`vmware-iso` builder). It does **not** run `RedWindows.ps1` -
this just produces the base OS image; run `RedWindows.ps1` yourself afterward
to install the toolset.

### Prerequisites

- [Packer](https://www.packer.io/downloads) installed and on `PATH`.
- VMware Workstation/Player + official Packer plugin
  `github.com/vmware/vmware` **>= 2.1.5** (not the old `github.com/hashicorp/vmware`
  source — that repo is gone / superseded).
- Packer serves `windows.iso` from the Workstation install dir on **:8570**; FirstLogon
  downloads/installs Tools, forces **Private** network, enables WinRM, reboots.
  Do **not** attach the Tools ISO as a CD during Setup (`[/S]` dialog).
  Override with `-var tools_iso_dir=...` if needed.

  Packer’s `Starting virtual machine...` line often does **not** update until it
  has guest IP + WinRM (can look hung). Check guest
  `C:\Windows\Temp\packer-firstlogon.log` and host `$env:PACKER_LOG=1`.
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

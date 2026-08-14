packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

# iso_url can be a downloadable URL or a local path (e.g. "file:///C:/isos/win10pro.iso"
# or just "C:/isos/win10pro.iso"). autounattend.xml is set up for a Windows 10 Pro
# image - see http/autounattend.xml for the image-name / product-key selection if
# your ISO is a different edition.
variable "iso_url" {
  type        = string
  description = "URL or local path to the Windows 10 Pro ISO."
}

variable "iso_checksum" {
  type        = string
  description = "Checksum for iso_url, e.g. \"sha256:AAAA...\". For a local ISO: Get-FileHash <path> -Algorithm SHA256."
}

variable "vm_name" {
  type    = string
  default = "redwindows10"
}

# Must match the account created in http/autounattend.xml - that file isn't
# templated by Packer, so if you change the password there, update it here too.
variable "winrm_username" {
  type    = string
  default = "attacker"
}

variable "winrm_password" {
  type      = string
  default   = "GoCyber2026!!"
  sensitive = true
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 16384
}

variable "disk_size" {
  type    = number
  default = 131072 # MB, 128GB
}

variable "headless" {
  type    = bool
  default = false
}

source "vmware-iso" "windows10" {
  vm_name       = var.vm_name
  guest_os_type = "windows9-64" # VMware's internal identifier for Windows 10/11 64-bit

  # Pin an older VMX hardware version and force legacy BIOS. Left unset, current
  # VMware Workstation defaults new VMs to a version high enough to come up as
  # UEFI, which has no floppy controller and makes Setup's answer-file
  # auto-detection unreliable - the exact "stuck on the manual Language to
  # install screen" symptom this whole file exists to avoid.
  version          = "14"
  disk_adapter_type = "lsisas1068"

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  cpus      = var.cpus
  memory    = var.memory
  disk_size = var.disk_size
  disk_type_id = "0" # growable, single file

  floppy_files = [
    "${path.root}/http/autounattend.xml",
    "${path.root}/http/enable-winrm.ps1",
  ]

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = "6h" # unattended install + first boot can take a while on slower hosts

  headless = var.headless

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1"
  shutdown_timeout = "15m"

  output_directory = "output-${var.vm_name}"

  vmx_data = {
    "firmware"                                  = "bios"
    "gui.fitguestusingnativedisplayresolution" = "TRUE"
  }
}

build {
  sources = ["source.vmware-iso.windows10"]

  # Sanity check that WinRM actually came up cleanly and the box is what we expect
  # before Packer calls the build "done".
  provisioner "windows-shell" {
    inline = [
      "whoami",
      "systeminfo | findstr /B /C:\"OS Name\" /C:\"OS Version\""
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "15m"
  }
}

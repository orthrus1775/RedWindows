# Runs once via FirstLogonCommands (autounattend.xml). specialize-pass already ran
# `winrm quickconfig`, but that step happens before a network profile is set, so the
# listener it creates is frequently bound to the wrong firewall profile. Redo the
# config here, after logon, when the adapter is reliably on the Work/Private profile.

# Force the active network connection to Private so WinRM will bind correctly.
Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -ne 'Private' } | ForEach-Object {
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

winrm quickconfig -quiet
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}'

New-NetFirewallRule -DisplayName 'WinRM-HTTP' -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -ErrorAction SilentlyContinue | Out-Null

Restart-Service WinRM
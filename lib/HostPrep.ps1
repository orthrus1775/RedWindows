function Disable-WindowsDefender {
    Write-Status "`n=== Disabling Windows Defender ===" 'Magenta'
    # Best-effort; Tamper Protection may silently block these.

    try {
        Set-MpPreference -DisableRealtimeMonitoring $true `
                          -DisableBehaviorMonitoring $true `
                          -DisableBlockAtFirstSeen $true `
                          -DisableIOAVProtection $true `
                          -DisableScriptScanning $true `
                          -DisableArchiveScanning $true `
                          -MAPSReporting Disabled `
                          -SubmitSamplesConsent NeverSend `
                          -ErrorAction Stop
        Write-Status "[+] Set-MpPreference applied" 'Green'
    } catch {
        Write-Status "[!] Set-MpPreference failed (likely Tamper Protection): $($_.Exception.Message)" 'Yellow'
    }

    $exclusionPaths = @(
        $script:ToolsRoot,
        $script:PayloadRoot,
        $script:AppDataLocal,
        $script:GoUserRoot,
        $script:pipxtools
    )
    foreach ($path in $exclusionPaths) {
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            Write-Status "[+] Exclusion added for $path" 'Green'
        } catch {
            Write-Status "[!] Add-MpPreference exclusion failed for ${path}: $($_.Exception.Message)" 'Yellow'
        }
    }
}

function Disable-ScreenSaver {
    Write-Status "[-] [Screensaver] disabling" 'Cyan'
    try {
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaveActive -Value 0 -Type DWord
        powercfg -x -monitor-timeout-ac 0
        powercfg -x -monitor-timeout-dc 0
        Write-Status "[+] [Screensaver] disabled" 'Green'
        Add-Result -Name 'Screensaver' -Status Installed -Detail 'disabled'
    } catch {
        Write-Status "[!] [Screensaver] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Screensaver' -Status Skipped -Detail $_.Exception.Message
    }
}

function Enable-NumLock {
    # Registry value 2 = NumLock on at logon; also toggle on for this session.
    Write-Status "[-] [NumLock] enabling" 'Cyan'
    try {
        $paths = @(
            'HKCU:\Control Panel\Keyboard',
            'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard'
        )
        foreach ($path in $paths) {
            if (-not (Test-Path $path)) {
                New-Item -Path $path -Force | Out-Null
            }
            Set-ItemProperty -Path $path -Name InitialKeyboardIndicators -Value '2' -Type String -Force
        }

        Add-Type -Namespace RedWindows -Name Keyboard -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Auto, ExactSpelling=true)]
public static extern short GetKeyState(int keyCode);
[DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
'@ -ErrorAction SilentlyContinue

        $VK_NUMLOCK = 0x90
        $KEYEVENTF_EXTENDEDKEY = 0x1
        $KEYEVENTF_KEYUP = 0x2
        # GetKeyState low bit = toggle on for NumLock/CapsLock/ScrollLock.
        if (([RedWindows.Keyboard]::GetKeyState($VK_NUMLOCK) -band 1) -eq 0) {
            [RedWindows.Keyboard]::keybd_event([byte]$VK_NUMLOCK, [byte]0x45, $KEYEVENTF_EXTENDEDKEY, [UIntPtr]::Zero)
            [RedWindows.Keyboard]::keybd_event([byte]$VK_NUMLOCK, [byte]0x45, ($KEYEVENTF_EXTENDEDKEY -bor $KEYEVENTF_KEYUP), [UIntPtr]::Zero)
        }

        Write-Status "[+] [NumLock] enabled (logon + current session)" 'Green'
    } catch {
        Write-Status "[!] [NumLock] failed: $($_.Exception.Message)" 'Yellow'
    }
}

function Set-UsCentralTimeZone {
    # Windows ID "Central Standard Time" is US Central and observes DST.
    $tzId = 'Central Standard Time'
    Write-Status "[-] [Time zone] setting $tzId" 'Cyan'
    try {
        $current = (Get-TimeZone).Id
        if ($current -eq $tzId) {
            Write-Status "[+] [Time zone] already $tzId" 'DarkGray'
            Add-Result -Name 'Time zone' -Status Installed -Detail 'already Central Standard Time'
            return
        }

        Set-TimeZone -Id $tzId
        Write-Status "[+] [Time zone] set to $tzId (was $current)" 'Green'
        Add-Result -Name 'Time zone' -Status Installed -Detail $tzId
    } catch {
        Write-Status "[!] [Time zone] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Time zone' -Status Skipped -Detail $_.Exception.Message
    }
}

function Show-FileExtensions {
    Write-Status "[-] [File extensions] enabling" 'Cyan'
    try {
        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -Value 0 -Type DWord
        Write-Status "[+] [File extensions] enabled" 'Green'
        Add-Result -Name 'File extensions' -Status Installed -Detail 'HideFileExt=0'
    } catch {
        Write-Status "[!] [File extensions] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'File extensions' -Status Skipped -Detail $_.Exception.Message
    }
}

function Set-QuickAccess {
    param(
        [string]$Path = $script:ToolsRoot
    )

    Write-Status "[-] [Quick Access] pinning $Path" 'Cyan'
    try {
        if (-not (Test-Path $Path)) {
            Write-Status "[!] [Quick Access] $Path does not exist - skipping" 'Yellow'
            Add-Result -Name 'Quick Access' -Status Skipped -Detail "$Path not found"
            return
        }

        $shell = New-Object -ComObject Shell.Application
        $shell.Namespace($Path).Self.InvokeVerb('pintohome')

        Write-Status "[+] [Quick Access] pinned $Path" 'Green'
        Add-Result -Name 'Quick Access' -Status Installed -Detail $Path
    } catch {
        Write-Status "[!] [Quick Access] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Quick Access' -Status Skipped -Detail $_.Exception.Message
    }
}

function Set-Background {
    # Pulled from the repo rather than requiring a local Background.png next to the script.
    $imageUrl  = 'https://raw.githubusercontent.com/orthrus1775/RedWindows/main/Background.png'
    $imageDir  = Join-Path $env:USERPROFILE 'Documents'
    $imagePath = Join-Path $imageDir 'Background.png'

    Write-Status "[-] [Background] downloading $imageUrl" 'Cyan'
    try {
        if (-not (Test-Path $imageDir)) {
            New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
        }
        Invoke-WebRequest -Uri $imageUrl -OutFile $imagePath -UseBasicParsing
    } catch {
        Write-Status "[!] [Background] download failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Background' -Status Skipped -Detail $_.Exception.Message
        return
    }

    try {
        Add-Type -Namespace RedWindows -Name Wallpaper -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@ -ErrorAction SilentlyContinue

        # WallpaperStyle 10 = Fill (avoids stretch/tile across resolutions).
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'

        $SPI_SETDESKWALLPAPER = 0x0014
        $SPIF_UPDATEINIFILE   = 0x01
        $SPIF_SENDCHANGE      = 0x02
        [RedWindows.Wallpaper]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $imagePath, $SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE) | Out-Null

        Write-Status "[+] [Background] wallpaper set to $imagePath" 'Green'
        Add-Result -Name 'Background' -Status Installed -Detail $imagePath
    } catch {
        Write-Status "[!] [Background] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Background' -Status Skipped -Detail $_.Exception.Message
    }
}

function Disable-WindowsUpdates {
    Write-Status "[-] [Windows Update] disabling automatic updates" 'Cyan'
    try {
        $updates = (New-Object -ComObject 'Microsoft.Update.AutoUpdate').Settings
        if ($updates.ReadOnly) {
            Write-Status "[!] [Windows Update] settings are read-only (GPO-restricted) - skipping" 'Yellow'
            Add-Result -Name 'Windows Update' -Status Skipped -Detail 'read-only (GPO restricted)'
            return
        }

        $updates.NotificationLevel = 1 # Disabled
        $updates.Save()
        $updates.Refresh()
        Write-Status "[+] [Windows Update] automatic updates disabled" 'Green'
        Add-Result -Name 'Windows Update' -Status Installed -Detail 'disabled'
    } catch {
        Write-Status "[!] [Windows Update] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Windows Update' -Status Skipped -Detail $_.Exception.Message
    }
}

function Install-SshServer {
    Write-Status "[-] [OpenSSH Server] checking capability" 'Cyan'
    try {
        $serverCap = Get-WindowsCapability -Online | Where-Object Name -eq 'OpenSSH.Server~~~~0.0.1.0'
        if ($serverCap.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
        }

        Start-Service sshd
        Set-Service -Name sshd -StartupType Automatic

        if (!(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        }

        Write-Status "[+] [OpenSSH Server] installed and running" 'Green'
        Add-Result -Name 'OpenSSH Server' -Status Installed -Detail 'capability + sshd + firewall rule'
    } catch {
        Write-Status "[!] [OpenSSH Server] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'OpenSSH Server' -Status Skipped -Detail $_.Exception.Message
    }
}

function Add-PythonFirewallRule {
    Write-Status "[-] [Python firewall] adding Private/Public allow rules" 'Cyan'
    try {
        # Refresh PATH; package was just installed via winget in this process.
        Update-SessionPath
        $python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $python) {
            Write-Status "[!] [Python firewall] python is not on PATH - skipping" 'Yellow'
            Add-Result -Name 'Python firewall' -Status Skipped -Detail 'python not on PATH'
            return
        }

        if (!(Get-NetFirewallRule -Name 'Python-In-PrivatePublic' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'Python-In-PrivatePublic' -DisplayName 'Python' -Enabled True -Direction Inbound -Profile Private,Public -Program $python.Source -Action Allow | Out-Null
        }
        if (!(Get-NetFirewallRule -Name 'Python-Out-PrivatePublic' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'Python-Out-PrivatePublic' -DisplayName 'Python' -Enabled True -Direction Outbound -Profile Private,Public -Program $python.Source -Action Allow | Out-Null
        }

        Write-Status "[+] [Python firewall] rules added" 'Green'
        Add-Result -Name 'Python firewall' -Status Installed -Detail "allow $($python.Source) (Private,Public)"
    } catch {
        Write-Status "[!] [Python firewall] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Python firewall' -Status Skipped -Detail $_.Exception.Message
    }
}

function Install-WindowsUpdates {
    Write-Status "[-] [Windows Update] checking for updates" 'Cyan'
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
        }
        Import-Module PSWindowsUpdate

        # IgnoreReboot: Stage 5 finishes cleanup then Complete-Installation restarts.
        Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false | Out-Null

        Write-Status "[+] [Windows Update] updates installed" 'Green'
        Add-Result -Name 'Windows Update' -Status Installed -Detail 'PSWindowsUpdate: Install-WindowsUpdate -AcceptAll'
    } catch {
        Write-Status "[!] [Windows Update] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Windows Update' -Status Skipped -Detail $_.Exception.Message
    }
}

function Set-HighPerformancePowerPlan {
    Write-Status "[-] [Power plan] setting high performance" 'Cyan'
    try {
        $highPerf = powercfg -l | ForEach-Object { if ($_.Contains('Ultimate Performance')) { $_.Split()[3] } }
        if (-not $highPerf) {
            $highPerf = powercfg -l | ForEach-Object { if ($_.Contains('High performance')) { $_.Split()[3] } }
        }

        $currPlan = $(powercfg -getactivescheme).Split()[3]
        if ($highPerf -and $currPlan -ne $highPerf) {
            powercfg -setactive $highPerf
        }

        powercfg -change -monitor-timeout-ac 0
        powercfg -change -monitor-timeout-dc 0
        powercfg -change -standby-timeout-ac 0
        powercfg -change -standby-timeout-dc 0
        powercfg -change hibernate-timeout-ac 0
        powercfg -change hibernate-timeout-dc 0

        Write-Status "[+] [Power plan] set to high performance" 'Green'
        Add-Result -Name 'Power plan' -Status Installed -Detail 'high performance'
    } catch {
        Write-Status "[!] [Power plan] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Power plan' -Status Skipped -Detail $_.Exception.Message
    }
}

function New-RangeAdminUser {
    Write-StatusMessage "Creating range_admin user..."

    $Password = ConvertTo-SecureString -String $script:RangeAdminPassword -AsPlainText -Force
    $Username = $script:RangeAdminUsername

    try {
        $existingUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
        if ($existingUser) {
            Write-StatusMessage "User $Username already exists, skipping creation" "WARNING"
            return
        }

        New-LocalUser $Username -Password $Password -FullName "Range Admin" -Description "Range Engineering User"
        Write-StatusMessage "User $Username created successfully"

        Add-LocalGroupMember -Group "Administrators" -Member $Username
        Write-StatusMessage "User $Username added to Administrators group"
    }
    catch {
        Write-StatusMessage "Error creating user $Username : $_" "ERROR"
    }
}

function New-AttackerUser {
    Write-Status "[-] [attacker user] creating local user" 'Cyan'

    $username = $script:AttackerUsername
    $password = ConvertTo-SecureString -String $script:AttackerPassword -AsPlainText -Force

    try {
        $existingUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
        if ($existingUser) {
            Write-Status "[+] [attacker user] already exists, skipping creation" 'DarkGray'
            Add-Result -Name 'attacker user' -Status Installed -Detail 'already present'
            return
        }

        New-LocalUser $username -Password $password -FullName 'Attacker' -Description 'Red team operator user' | Out-Null
        Write-Status "[+] [attacker user] created" 'Green'

        Add-LocalGroupMember -Group 'Administrators' -Member $username
        Write-Status "[+] [attacker user] added to Administrators group" 'Green'

        Add-Result -Name 'attacker user' -Status Installed -Detail 'local user + Administrators'
    } catch {
        Write-Status "[!] [attacker user] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'attacker user' -Status Failed -Detail $_.Exception.Message
    }
}

function Install-Autologon {
    # Download Autologon directly; Stage 1 may run before winget is usable.
    $autologonDir = Join-Path $script:ToolsRoot 'SysInternals'
    $autologonExe = Join-Path $autologonDir 'Autologon64.exe'

    if (Test-Path $autologonExe) {
        return $autologonExe
    }

    New-Item -ItemType Directory -Path $autologonDir -Force | Out-Null
    $zipPath = Join-Path $script:DlRoot 'AutoLogon.zip'

    Write-Status "[-] [Autologon] downloading Sysinternals AutoLogon" 'Cyan'
    try {
        Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/AutoLogon.zip' -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $autologonDir -Force
        Write-Status "[+] [Autologon] extracted to $autologonDir" 'Green'
        return $autologonExe
    } catch {
        Write-Status "[!] [Autologon] download/extract failed: $($_.Exception.Message)" 'Yellow'
        return $null
    }
}

function Set-AutoLogin {
    Write-Status "[-] [Auto-login] configuring for attacker user" 'Cyan'

    $autologonExe = Install-Autologon
    if (-not $autologonExe -or -not (Test-Path $autologonExe)) {
        Write-Status "[!] [Auto-login] Autologon64.exe unavailable - skipping" 'Yellow'
        Add-Result -Name 'Auto-login' -Status Failed -Detail 'Autologon64.exe unavailable'
        return
    }

    try {
        & $autologonExe $script:AttackerUsername . $script:AttackerPassword /accepteula | Out-Null
        Write-Status "[+] [Auto-login] configured for $($script:AttackerUsername)" 'Green'
        Add-Result -Name 'Auto-login' -Status Installed -Detail $script:AttackerUsername
    } catch {
        Write-Status "[!] [Auto-login] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Auto-login' -Status Failed -Detail $_.Exception.Message
    }
}

function Disable-AutoLogin {
    Write-Status "[-] [Auto-login] disabling for attacker user" 'Cyan'
    try {
        $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $winlogonPath -Name AutoAdminLogon -Value '0' -ErrorAction Stop
        # Clear plaintext DefaultPassword Autologon64.exe left in the registry.
        Remove-ItemProperty -Path $winlogonPath -Name DefaultPassword -ErrorAction SilentlyContinue

        Write-Status "[+] [Auto-login] disabled" 'Green'
        Add-Result -Name 'Auto-login' -Status Installed -Detail 'disabled'
    } catch {
        Write-Status "[!] [Auto-login] disable failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Auto-login' -Status Skipped -Detail $_.Exception.Message
    }
}

function Install-Winget {
    Write-Status "[-] [winget] checking for existing installation" 'Cyan'

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $existing = winget --version 2>$null
        if ($existing) {
            Write-Status "[+] [winget] already installed ($existing)" 'DarkGray'
            Add-Result -Name 'winget' -Status Installed -Detail 'already present'
            return
        }
    }

    Write-Status "[-] [winget] not found, installing latest DesktopAppInstaller" 'Cyan'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'

        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null

        # Installs/upgrades to the current winget release (not the older inbox AppX).
        try {
            Repair-WinGetPackageManager -AllUsers -Force -Latest
        } catch {
            Repair-WinGetPackageManager -AllUsers -Latest
        }

        $verify = winget --version 2>$null
        if ($verify) {
            Write-Status "[+] [winget] installed ($verify)" 'Green'
            Add-Result -Name 'winget' -Status Installed -Detail $verify
            return
        }

        # Fallback: download the latest msixbundle from GitHub and sideload it.
        Write-Status "[-] [winget] repair did not expose winget - downloading latest release" 'Yellow'
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'RedWindows' }
        $asset = $release.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1
        if (-not $asset) { throw 'No .msixbundle asset on latest winget-cli release' }

        $bundlePath = Join-Path $script:DlRoot $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $bundlePath -UseBasicParsing
        Add-AppxPackage -Path $bundlePath

        $verify = winget --version 2>$null
        if ($verify) {
            Write-Status "[+] [winget] installed ($verify)" 'Green'
            Add-Result -Name 'winget' -Status Installed -Detail $verify
        } else {
            Write-Status "[!] [winget] installed but not yet resolvable in this session - expected, resolves after restart" 'Yellow'
            Add-Result -Name 'winget' -Status Installed -Detail 'installed, pending restart'
        }
    } catch {
        Write-Status "[!] [winget] install failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'winget' -Status Failed -Detail $_.Exception.Message
    }
}

function Install-Wsl {
    # Enable WSL + VM Platform only. Do not run `wsl --install` here — it can
    # reboot before Complete-Stage records the next stage. Stage 1 already reboots.
    Write-Status "[-] [WSL] enabling Windows features (no restart)" 'Cyan'
    try {
        $needed = @(
            'Microsoft-Windows-Subsystem-Linux',
            'VirtualMachinePlatform'
        )
        $enabled = @()
        $pending = @()
        foreach ($name in $needed) {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $name
            if ($feature.State -eq 'Enabled') {
                $enabled += $name
                continue
            }
            Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart | Out-Null
            $pending += $name
        }

        if ($pending.Count -eq 0) {
            Write-Status "[+] [WSL] features already enabled" 'DarkGray'
            Add-Result -Name 'WSL' -Status Installed -Detail 'features already enabled'
            return $true
        }

        Write-Status "[+] [WSL] enabled $($pending -join ', '); reboot via Complete-Stage" 'Green'
        Add-Result -Name 'WSL' -Status Installed -Detail "enabled: $($pending -join ', ')"
        return $true
    } catch {
        Write-Status "[!] [WSL] feature enable failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'WSL' -Status Failed -Detail $_.Exception.Message
        return $false
    }
}

function Get-WslDistroName {
    $env:WSL_UTF8 = '1'
    $names = @()
    try {
        $names = @(wsl -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object {
            $_ -and $_ -notmatch 'Windows Subsystem|^NAME'
        })
    } catch {}
    if (-not $names) { return $null }
    $ubuntu = $names | Where-Object { $_ -match '^Ubuntu' } | Select-Object -First 1
    if ($ubuntu) { return $ubuntu }
    return $names[0]
}

function Invoke-WslRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Distro,
        [Parameter(Mandatory)]
        [string]$Bash
    )
    $env:WSL_UTF8 = '1'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        wsl -d $Distro -u root -- bash -lc $Bash
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Complete-Wsl {
    # After Stage 1 reboot: Ubuntu (no OOBE prompt), attacker user + password, apt tools.
    Write-Status "[-] [WSL] finishing install (default v2 + Ubuntu)" 'Cyan'
    try {
        $env:WSL_UTF8 = '1'
        if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
            Write-Status "[!] [WSL] wsl.exe not on PATH after feature reboot" 'Yellow'
            Add-Result -Name 'WSL distro' -Status Failed -Detail 'wsl.exe not on PATH'
            return $false
        }

        Invoke-NativeQuiet { wsl --update *>$null }
        Invoke-NativeQuiet { wsl --set-default-version 2 *>$null }

        $distro = Get-WslDistroName
        if (-not $distro) {
            Write-Status "[-] [WSL] installing Ubuntu (no launch)" 'Cyan'
            Invoke-NativeQuiet { wsl --install -d Ubuntu --no-launch *>$null }
            if ($LASTEXITCODE -ne 0) {
                Write-Status "[!] [WSL] Ubuntu install failed (exit $LASTEXITCODE)" 'Yellow'
                Add-Result -Name 'WSL distro' -Status Failed -Detail "wsl --install -d Ubuntu (exit $LASTEXITCODE)"
                return $false
            }
            $distro = Get-WslDistroName
            if (-not $distro) { $distro = 'Ubuntu' }
        } else {
            Write-Status "[+] [WSL] distro already present ($distro)" 'DarkGray'
        }

        # Skip the interactive UNIX username/password OOBE; install as root.
        $ubuntuExe = @('ubuntu.exe', 'ubuntu2404.exe', 'ubuntu2204.exe', 'ubuntu2004.exe') |
            ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
            Select-Object -First 1
        if ($ubuntuExe) {
            Invoke-NativeQuiet { & $ubuntuExe.Source install --root *>$null }
        }

        $user = $script:AttackerUsername
        $pass = $script:AttackerPassword
        if (-not $user) { $user = 'attacker' }
        if ([string]::IsNullOrWhiteSpace($pass)) {
            Write-Status "[!] [WSL] AttackerPassword unset - cannot set Linux password" 'Yellow'
            Add-Result -Name 'WSL user' -Status Failed -Detail 'AttackerPassword unset'
            return $false
        }

        $userQ = $user -replace "'", "'\''"
        $passQ = $pass -replace "'", "'\''"
        $userSetup = @"
set -e
id '$userQ' >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo '$userQ'
echo '${userQ}:${passQ}' | chpasswd
printf '%s ALL=(ALL) NOPASSWD:ALL\n' '$userQ' > /etc/sudoers.d/$userQ
chmod 440 /etc/sudoers.d/$userQ
printf '[user]\ndefault=%s\n' '$userQ' > /etc/wsl.conf
"@
        Write-Status "[-] [WSL] creating user $user (no prompt)" 'Cyan'
        $userExit = Invoke-WslRoot -Distro $distro -Bash $userSetup
        if ($userExit -ne 0) {
            Write-Status "[!] [WSL] user setup failed (exit $userExit)" 'Yellow'
            Add-Result -Name 'WSL user' -Status Failed -Detail "exit $userExit"
            return $false
        }
        Write-Status "[+] [WSL] user $user set (password from AttackerPassword)" 'Green'
        Add-Result -Name 'WSL user' -Status Installed -Detail "$user (default user)"

        $packageNames = @(Get-WslPackageList)
        if ($packageNames.Count -eq 0) {
            Write-Status "[!] [WSL] wsl_packages.json has no enabled packages" 'Yellow'
            Add-Result -Name 'WSL tools' -Status Skipped -Detail 'empty catalog'
            return $true
        }
        $packages = $packageNames -join ' '
        Write-Status "[-] [WSL] apt-get install $($packageNames.Count) packages from wsl_packages.json" 'Cyan'
        $pkgSetup = @"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y $packages
"@
        $pkgExit = Invoke-WslRoot -Distro $distro -Bash $pkgSetup
        if ($pkgExit -ne 0) {
            Write-Status "[!] [WSL] apt install failed (exit $pkgExit)" 'Yellow'
            Add-Result -Name 'WSL tools' -Status Failed -Detail "apt-get (exit $pkgExit)"
            return $false
        }

        Write-Status "[+] [WSL] Ubuntu + tools ready ($distro)" 'Green'
        Add-Result -Name 'WSL distro' -Status Installed -Detail "$distro, default version 2"
        Add-Result -Name 'WSL tools' -Status Installed -Detail 'apt baseline'
        return $true
    } catch {
        Write-Status "[!] [WSL] finish failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'WSL distro' -Status Failed -Detail $_.Exception.Message
        return $false
    }
}
